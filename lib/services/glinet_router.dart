/// Read-only client for the GL.iNet firmware 4.x JSON-RPC API
/// (`POST {router}/rpc`, default `http://192.168.8.1/rpc`).
///
/// Protocol (verified against the GL.iNet SDK 4.0 API guide and the gli4py
/// reference library, `~/workspace/tools/gli4py`):
///
/// 1. `challenge` with `{"username": ...}` returns `{alg, salt, nonce,
///    "hash-method"}`.
/// 2. The cipher password is `unix_crypt(password, "$<alg>$<salt>$")`
///    (see [glinet_crypt.dart]); the login hash is
///    `H("<username>:<cipher_password>:<nonce>")`.
/// 3. `login` with `{"username", "hash"}` returns `{sid}`. The SID lives in
///    memory only, is valid ~5 minutes, and refreshes on use.
/// 4. Authenticated calls are `call` with params `[sid, module, function,
///    ...extra]`.
///
/// READ-ONLY BY DESIGN: this service implements only the four read calls
/// `system.get_info`, `system.get_status`, `system.get_load` and
/// `clients.get_list`. There is deliberately no reboot, no port-forward
/// write, no config change of any kind — Outride is defensive-only and
/// only ever observes the router.
///
/// SECURITY: the password is never stored, never logged and never leaves
/// the login call (only its crypt/hash derivatives cross the wire, over
/// plain HTTP on the LAN — the router's own API has no TLS option on the
/// default endpoint, so use it only on a trusted local network). The SID
/// is likewise never logged.
///
/// EXPERIMENTAL: no GL.iNet hardware was in hand while this was written;
/// the implementation is verified against the gli4py mock fixtures and
/// golden crypt vectors only. See `docs/glinet-support.md`.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'glinet_crypt.dart';

/// Injectable transport seam: posts a JSON-RPC body to [uri] and returns
/// the raw HTTP response. Pass a fake in tests; otherwise [GlinetRouter]
/// builds one on top of an [http.Client].
typedef GlinetPost = Future<http.Response> Function(
  Uri uri,
  Map<String, String> headers,
  String body,
);

// ─── Exceptions ─────────────────────────────────────────────────────────────

/// Base class for all GL.iNet router errors. [message] is human-readable
/// and safe to show to the operator.
class GlinetException implements Exception {
  const GlinetException(this.message);

  final String message;

  @override
  String toString() => 'GlinetException: $message';
}

/// The router could not be reached at all (connection refused, DNS failure,
/// timeout, TLS/transport error).
class GlinetUnreachableException extends GlinetException {
  const GlinetUnreachableException(super.message);
}

/// Something answered, but it is not a GL.iNet firmware 4.x router (wrong
/// payload shape, non-JSON response, or a challenge that is not a 4.x
/// challenge). Also used when the challenge names an unsupported cipher.
class GlinetNotRouterException extends GlinetException {
  const GlinetNotRouterException(super.message);
}

/// The router answered and is a GL.iNet, but its firmware is older than
/// 4.0 — pre-4.0 firmware speaks a different REST API this client does not
/// implement.
class GlinetFirmwareTooOldException extends GlinetException {
  const GlinetFirmwareTooOldException(super.message);
}

/// Authentication failed: wrong username/password, no session, or an
/// expired SID.
class GlinetAuthException extends GlinetException {
  const GlinetAuthException(super.message);
}

/// Too many failed logins; the router locked the account out temporarily.
class GlinetLockoutException extends GlinetAuthException {
  const GlinetLockoutException(super.message);
}

/// Any other router-side RPC failure (HTTP 5xx, internal error, method not
/// found, unknown error code). [code] is the JSON-RPC error code, if any.
class GlinetApiException extends GlinetException {
  const GlinetApiException(super.message, {this.code});

  final int? code;

  @override
  String toString() =>
      'GlinetApiException: $message${code == null ? '' : ' (code $code)'}';
}

// ─── Lenient parsing helpers ────────────────────────────────────────────────

String? _asString(dynamic value) {
  if (value == null) return null;
  if (value is String) return value;
  return value.toString();
}

int? _asInt(dynamic value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value.trim());
  return null;
}

double? _asDouble(dynamic value) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value.trim());
  return null;
}

bool _asBool(dynamic value, [bool fallback = false]) {
  if (value is bool) return value;
  if (value is num) return value != 0;
  if (value is String) {
    final lower = value.toLowerCase().trim();
    if (lower == 'true' || lower == '1' || lower == 'yes') return true;
    if (lower == 'false' || lower == '0' || lower == 'no') return false;
  }
  return fallback;
}

List<double> _asDoubleList(dynamic value) {
  if (value is! List) return const [];
  return value.map(_asDouble).whereType<double>().toList();
}

List<Map<String, dynamic>> _asMapList(dynamic value) {
  if (value is! List) return const [];
  return value.whereType<Map<String, dynamic>>().toList();
}

/// Major version of a dotted firmware string such as `4.3.25`, or null
/// when it cannot be parsed.
int? _firmwareMajor(String? version) {
  if (version == null || version.isEmpty) return null;
  return int.tryParse(version.split('.').first.trim());
}

// ─── Models ─────────────────────────────────────────────────────────────────

/// The unauthenticated `challenge` response.
class GlinetChallenge {
  const GlinetChallenge({
    required this.alg,
    required this.salt,
    required this.nonce,
    required this.hashMethod,
  });

  factory GlinetChallenge.fromJson(Map<String, dynamic> json) {
    return GlinetChallenge(
      alg: _asInt(json['alg']) ?? 0,
      salt: _asString(json['salt']) ?? '',
      nonce: _asString(json['nonce']) ?? '',
      // The challenge contract defaults an absent hash-method to md5.
      hashMethod: _asString(json['hash-method']) ?? 'md5',
    );
  }

  /// Challenge algorithm id: 1 = MD5-crypt, 5 = SHA-256-crypt,
  /// 6 = SHA-512-crypt.
  final int alg;

  final String salt;
  final String nonce;

  /// `md5` / `sha256` / `sha512`.
  final String hashMethod;

  /// True only for a challenge this client can actually log in with.
  bool get isValid =>
      (alg == 1 || alg == 5 || alg == 6) &&
      salt.isNotEmpty &&
      nonce.isNotEmpty;
}

/// Result of [GlinetRouter.probe]. Never throws: a failure to reach the
/// router, or an answer that is not a 4.x challenge, is reported here.
class GlinetProbeResult {
  const GlinetProbeResult({
    required this.reachable,
    required this.isGlinet4x,
    this.challengeAlg,
    this.hashMethod,
    this.error,
  });

  const GlinetProbeResult.failed(String message)
      : reachable = false,
        isGlinet4x = false,
        challengeAlg = null,
        hashMethod = null,
        error = message;

  /// The router answered a `challenge` call at all.
  final bool reachable;

  /// The answer was a well-formed firmware 4.x challenge.
  final bool isGlinet4x;

  /// Challenge cipher algorithm id (1/5/6), when one was received.
  final int? challengeAlg;

  /// Challenge hash method, when one was received.
  final String? hashMethod;

  /// Human-readable reason when [reachable] or [isGlinet4x] is false.
  final String? error;
}

/// `system.get_info` — router identity and firmware.
class GlinetRouterInfo {
  const GlinetRouterInfo({
    required this.model,
    required this.firmwareVersion,
    required this.firmwareDate,
    required this.firmwareType,
    required this.mac,
    required this.serialNumber,
    required this.vendor,
    required this.hostname,
    required this.boardModel,
    required this.boardArchitecture,
    required this.openWrtVersion,
    required this.kernelVersion,
    required this.cpuCount,
    required this.countryCode,
  });

  factory GlinetRouterInfo.fromJson(Map<String, dynamic> json) {
    final board = json['board_info'];
    final boardMap = board is Map<String, dynamic> ? board : null;
    return GlinetRouterInfo(
      model: _asString(json['model']) ?? '',
      firmwareVersion: _asString(json['firmware_version']) ?? '',
      firmwareDate: _asString(json['firmware_date']) ?? '',
      firmwareType: _asString(json['firmware_type']) ?? '',
      mac: _asString(json['mac']) ?? '',
      serialNumber: _asString(json['sn']) ?? '',
      vendor: _asString(json['vendor']) ?? '',
      hostname: _asString(boardMap?['hostname']) ?? '',
      boardModel: _asString(boardMap?['model']) ?? '',
      boardArchitecture: _asString(boardMap?['architecture']) ?? '',
      openWrtVersion: _asString(boardMap?['openwrt_version']) ?? '',
      kernelVersion: _asString(boardMap?['kernel_version']) ?? '',
      cpuCount: _asInt(json['cpu_num']),
      countryCode: _asString(json['country_code']) ?? '',
    );
  }

  /// Short model id, e.g. `b1300`.
  final String model;

  /// e.g. `4.3.25`.
  final String firmwareVersion;
  final String firmwareDate;
  final String firmwareType;
  final String mac;
  final String serialNumber;
  final String vendor;
  final String hostname;

  /// Full board model string, e.g. `GL.iNet GL-B1300`.
  final String boardModel;
  final String boardArchitecture;
  final String openWrtVersion;
  final String kernelVersion;
  final int? cpuCount;
  final String countryCode;

  /// True when the reported firmware is a 4.x release.
  bool get isFirmware4x => _firmwareMajor(firmwareVersion) == 4;
}

/// One interface entry of `system.get_status` (`network` list).
class GlinetNetworkStatus {
  const GlinetNetworkStatus({
    required this.interface,
    required this.online,
    required this.up,
  });

  factory GlinetNetworkStatus.fromJson(Map<String, dynamic> json) {
    return GlinetNetworkStatus(
      interface: _asString(json['interface']) ?? '',
      online: _asBool(json['online']),
      up: _asBool(json['up']),
    );
  }

  final String interface;
  final bool online;
  final bool up;
}

/// One radio entry of `system.get_status` (`wifi` list).
///
/// The router also returns each radio's Wi-Fi password (`passwd`); it is
/// deliberately never parsed or stored.
class GlinetWifiStatus {
  const GlinetWifiStatus({
    required this.ssid,
    required this.name,
    required this.band,
    required this.channel,
    required this.up,
    required this.guest,
  });

  factory GlinetWifiStatus.fromJson(Map<String, dynamic> json) {
    return GlinetWifiStatus(
      ssid: _asString(json['ssid']) ?? '',
      name: _asString(json['name']) ?? '',
      band: _asString(json['band']) ?? '',
      channel: _asInt(json['channel']),
      up: _asBool(json['up']),
      guest: _asBool(json['guest']),
    );
  }

  final String ssid;
  final String name;

  /// e.g. `2G` / `5G` / `6G`.
  final String band;
  final int? channel;
  final bool up;
  final bool guest;
}

/// One service entry of `system.get_status` (`service` list).
class GlinetServiceStatus {
  const GlinetServiceStatus({required this.name, required this.status});

  factory GlinetServiceStatus.fromJson(Map<String, dynamic> json) {
    return GlinetServiceStatus(
      name: _asString(json['name']) ?? '',
      status: _asInt(json['status']) ?? 0,
    );
  }

  final String name;

  /// Service state code as reported by the router (0 = stopped).
  final int status;
}

/// Aggregated client counts of `system.get_status` (`client` list).
class GlinetClientCounts {
  const GlinetClientCounts({
    required this.cableTotal,
    required this.wirelessTotal,
  });

  factory GlinetClientCounts.fromJson(Map<String, dynamic> json) {
    return GlinetClientCounts(
      cableTotal: _asInt(json['cable_total']) ?? 0,
      wirelessTotal: _asInt(json['wireless_total']) ?? 0,
    );
  }

  final int cableTotal;
  final int wirelessTotal;
}

/// `system.get_status` — networks, Wi-Fi radios, services and system metrics.
class GlinetRouterStatus {
  const GlinetRouterStatus({
    required this.networks,
    required this.wifi,
    required this.services,
    required this.clientCounts,
    required this.uptimeSeconds,
    required this.memoryTotal,
    required this.memoryFree,
    required this.memoryBuffCache,
    required this.loadAverage,
    required this.mode,
    required this.timestamp,
  });

  factory GlinetRouterStatus.fromJson(Map<String, dynamic> json) {
    final clientList = _asMapList(json['client']);
    final system = json['system'];
    final systemMap = system is Map<String, dynamic> ? system : null;
    return GlinetRouterStatus(
      networks: _asMapList(json['network'])
          .map(GlinetNetworkStatus.fromJson)
          .toList(),
      wifi:
          _asMapList(json['wifi']).map(GlinetWifiStatus.fromJson).toList(),
      services: _asMapList(json['service'])
          .map(GlinetServiceStatus.fromJson)
          .toList(),
      clientCounts: clientList.isEmpty
          ? const GlinetClientCounts(cableTotal: 0, wirelessTotal: 0)
          : GlinetClientCounts.fromJson(clientList.first),
      uptimeSeconds: _asDouble(systemMap?['uptime']),
      memoryTotal: _asInt(systemMap?['memory_total']),
      memoryFree: _asInt(systemMap?['memory_free']),
      memoryBuffCache: _asInt(systemMap?['memory_buff_cache']),
      loadAverage: _asDoubleList(systemMap?['load_average']),
      mode: _asInt(systemMap?['mode']),
      timestamp: _asInt(systemMap?['timestamp']),
    );
  }

  final List<GlinetNetworkStatus> networks;
  final List<GlinetWifiStatus> wifi;
  final List<GlinetServiceStatus> services;
  final GlinetClientCounts clientCounts;

  /// Router uptime in seconds, when reported.
  final double? uptimeSeconds;
  final int? memoryTotal;
  final int? memoryFree;
  final int? memoryBuffCache;

  /// 1 / 5 / 15 minute load averages, when reported.
  final List<double> loadAverage;
  final int? mode;
  final int? timestamp;
}

/// `system.get_load` — CPU load averages and memory.
class GlinetRouterLoad {
  const GlinetRouterLoad({
    required this.memoryTotal,
    required this.memoryFree,
    required this.memoryBuffCache,
    required this.loadAverage,
  });

  factory GlinetRouterLoad.fromJson(Map<String, dynamic> json) {
    return GlinetRouterLoad(
      memoryTotal: _asInt(json['memory_total']),
      memoryFree: _asInt(json['memory_free']),
      memoryBuffCache: _asInt(json['memory_buff_cache']),
      loadAverage: _asDoubleList(json['load_average']),
    );
  }

  final int? memoryTotal;
  final int? memoryFree;
  final int? memoryBuffCache;

  /// 1 / 5 / 15 minute load averages.
  final List<double> loadAverage;

  double? get load1Min => loadAverage.isEmpty ? null : loadAverage[0];
  double? get load5Min => loadAverage.length < 2 ? null : loadAverage[1];
  double? get load15Min => loadAverage.length < 3 ? null : loadAverage[2];
}

/// One entry of `clients.get_list`.
class GlinetClient {
  const GlinetClient({
    required this.mac,
    required this.ip,
    required this.name,
    required this.alias,
    required this.online,
    required this.iface,
    required this.blocked,
    required this.onlineTime,
    required this.txBytes,
    required this.rxBytes,
    required this.totalTxBytes,
    required this.totalRxBytes,
    required this.vendor,
    required this.clientClass,
  });

  factory GlinetClient.fromJson(Map<String, dynamic> json) {
    return GlinetClient(
      mac: _asString(json['mac']) ?? '',
      ip: _asString(json['ip']) ?? '',
      name: _asString(json['name']) ?? '',
      alias: _asString(json['alias']),
      online: _asBool(json['online']),
      iface: _asString(json['iface']) ?? '',
      blocked: _asBool(json['blocked']),
      onlineTime: _asInt(json['online_time']),
      txBytes: _asInt(json['tx']),
      rxBytes: _asInt(json['rx']),
      totalTxBytes: _asInt(json['total_tx']),
      totalRxBytes: _asInt(json['total_rx']),
      vendor: _asString(json['vendor']),
      clientClass: _asString(json['class']),
    );
  }

  final String mac;
  final String ip;
  final String name;

  /// Operator-assigned alias, when set.
  final String? alias;
  final bool online;

  /// e.g. `cable`, `2.4G`, `5G`.
  final String iface;
  final bool blocked;

  /// Epoch seconds the client has been online, when reported.
  final int? onlineTime;

  /// Current throughput counters, when reported.
  final int? txBytes;
  final int? rxBytes;

  /// Cumulative counters, when reported.
  final int? totalTxBytes;
  final int? totalRxBytes;
  final String? vendor;
  final String? clientClass;

  /// Best display name: alias, then hostname, then MAC.
  String get displayName {
    if (alias != null && alias!.isNotEmpty) return alias!;
    if (name.isNotEmpty) return name;
    return mac;
  }
}

// ─── Client ─────────────────────────────────────────────────────────────────

/// Read-only client for one GL.iNet firmware 4.x router.
///
/// Construct with the router's RPC endpoint (default
/// `http://192.168.8.1/rpc`). For tests, inject [post] (or an [http.Client])
/// instead of hitting the network.
///
/// Typical use:
/// ```dart
/// final router = GlinetRouter();
/// final probe = await router.probe();
/// if (!probe.isGlinet4x) { /* not a 4.x router */ }
/// await router.login(username: 'root', password: password);
/// final info = await router.routerInfo();
/// final clients = await router.listClients();
/// await router.logout();
/// ```
class GlinetRouter {
  GlinetRouter({
    Uri? rpcUri,
    http.Client? httpClient,
    GlinetPost? post,
    this.timeout = const Duration(seconds: 10),
  })  : rpcUri = rpcUri ?? Uri.parse('http://192.168.8.1/rpc'),
        _httpClient = httpClient,
        _post = post;

  /// The JSON-RPC endpoint, e.g. `http://192.168.8.1/rpc`.
  final Uri rpcUri;

  /// Per-request timeout applied to every RPC call.
  final Duration timeout;

  final http.Client? _httpClient;
  final GlinetPost? _post;

  /// Session id from [login]. Memory only; never persisted or logged.
  String? _sid;

  /// True after a successful [login] until [logout] or session expiry.
  bool get isLoggedIn => _sid != null;

  int _nextId = 0;

  /// Lazily-created HTTP client owned by this router (only when no
  /// client or [post] function was injected). The injected client is
  /// never closed here — its owner closes it.
  http.Client? _ownedClient;

  /// Closes the owned HTTP client, if this router created one. Safe to
  /// call more than once; a no-op when a [post] function was injected
  /// or an [http.Client] was injected (the caller owns that one).
  void close() {
    _ownedClient?.close();
    _ownedClient = null;
  }

  // ── Transport ──

  Future<http.Response> _doPost(String body) {
    const headers = {'Content-Type': 'application/json'};
    if (_post != null) {
      return _post(rpcUri, headers, body).timeout(timeout);
    }
    final client = _httpClient ?? (_ownedClient ??= http.Client());
    return client.post(rpcUri, headers: headers, body: body).timeout(timeout);
  }

  /// Sends one JSON-RPC 2.0 request and returns its `result` value.
  ///
  /// Throws [GlinetUnreachableException] on transport failure,
  /// [GlinetNotRouterException] when the answer is not a JSON-RPC response
  /// from a GL.iNet router, and a mapped [GlinetException] for a JSON-RPC
  /// `error` object.
  Future<dynamic> _rpc(String method, Object params) async {
    final id = ++_nextId;
    final payload = jsonEncode({
      'jsonrpc': '2.0',
      'method': method,
      'params': params,
      'id': id,
    });

    http.Response response;
    try {
      response = await _doPost(payload);
    } on TimeoutException {
      throw GlinetUnreachableException(
        'Timed out reaching the router at $rpcUri.',
      );
    } on SocketException catch (e) {
      throw GlinetUnreachableException(
        'Could not reach the router at $rpcUri (${e.message}).',
      );
    } on http.ClientException catch (e) {
      throw GlinetUnreachableException(
        'Could not reach the router at $rpcUri (${e.message}).',
      );
    } on HttpException catch (e) {
      throw GlinetUnreachableException(
        'Could not reach the router at $rpcUri (${e.message}).',
      );
    }

    // A non-2xx status is a router/server failure regardless of the body
    // (gli4py raises ServerError for HTTP 5xx the same way).
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw GlinetApiException(
        'Router returned HTTP ${response.statusCode}.',
        code: response.statusCode,
      );
    }

    Map<String, dynamic> body;
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Response is not a JSON object.');
      }
      body = decoded;
    } on FormatException {
      throw GlinetNotRouterException(
        'The device at $rpcUri did not return a JSON-RPC response — '
        'not a GL.iNet firmware 4.x router.',
      );
    }

    if (body.containsKey('error')) {
      throw _mapRpcError(body['error']);
    }
    if (!body.containsKey('result')) {
      throw GlinetNotRouterException(
        'The device at $rpcUri returned a JSON object without a '
        '"result" — not a GL.iNet firmware 4.x router.',
      );
    }
    return body['result'];
  }

  /// Maps a JSON-RPC `error` object to a typed exception, using the error
  /// codes documented by the gli4py reference library.
  GlinetException _mapRpcError(dynamic error) {
    if (error is! Map<String, dynamic>) {
      return const GlinetApiException('Router returned an unknown error.');
    }
    final code = _asInt(error['code']);
    final message = _asString(error['message']);
    final detail = message == null || message.isEmpty
        ? 'Router reported an error.'
        : message;
    switch (code) {
      case -32000:
        // "Access denied" — the code for a wrong password at login.
        return GlinetAuthException('Wrong username or password. ($detail)');
      case -32003:
        return const GlinetLockoutException(
          'Too many failed logins — the router locked logins out for a '
          'few minutes. Wait and try again.',
        );
      case -1:
        // Invalid user / permission denied / not logged in (stale SID).
        _sid = null;
        return const GlinetAuthException(
          'Session expired — please log in again.',
        );
      case -32601:
        return GlinetApiException(
          'The router does not support this call. ($detail)',
          code: code,
        );
      case -32603:
        return GlinetApiException(
          'Router internal error. ($detail)',
          code: code,
        );
      default:
        return GlinetApiException(detail, code: code);
    }
  }

  /// One unauthenticated `challenge` round-trip.
  Future<GlinetChallenge> _challenge(String username) async {
    final result = await _rpc('challenge', {'username': username});
    if (result is! Map<String, dynamic>) {
      throw const GlinetNotRouterException(
        'The challenge response was not an object — not a GL.iNet '
        'firmware 4.x router.',
      );
    }
    return GlinetChallenge.fromJson(result);
  }

  // ── Public API ──

  /// Unauthenticated reachability check: issues a `challenge` call and
  /// reports whether a GL.iNet firmware 4.x router answered.
  ///
  /// Never throws — an unreachable host, a timeout, or an answer that is
  /// not a 4.x challenge is reported as a failed [GlinetProbeResult].
  Future<GlinetProbeResult> probe({String username = 'root'}) async {
    try {
      final challenge = await _challenge(username);
      if (!challenge.isValid) {
        // The device answered — it is reachable — but the challenge
        // is not a 4.x challenge. reachable stays true so the UI can
        // tell "something answered, not a GL.iNet 4.x router" apart
        // from "nothing there".
        return GlinetProbeResult(
          reachable: true,
          isGlinet4x: false,
          error: 'The device at $rpcUri answered, but its challenge is not a '
              'firmware 4.x challenge (alg ${challenge.alg}) — not a GL.iNet '
              'firmware 4.x router.',
        );
      }
      return GlinetProbeResult(
        reachable: true,
        isGlinet4x: true,
        challengeAlg: challenge.alg,
        hashMethod: challenge.hashMethod,
      );
    } on GlinetException catch (e) {
      return GlinetProbeResult.failed(e.message);
    } catch (e) {
      // probe() never throws: a malformed router address (e.g. host
      // '/') makes the HTTP layer throw ArgumentError/FormatException
      // outside the GlinetException mapping.
      return GlinetProbeResult.failed('Could not probe $rpcUri: $e');
    }
  }

  /// Logs in with the challenge/cipher/login-hash flow and keeps the
  /// session id in memory only.
  ///
  /// The [password] is used only to compute the cipher password and login
  /// hash for this call; it is never stored or logged.
  ///
  /// Throws [GlinetUnreachableException] when the router cannot be
  /// reached, [GlinetNotRouterException] when the challenge is not a 4.x
  /// challenge, [GlinetAuthException] for a wrong username/password, and
  /// [GlinetLockoutException] after too many failed logins.
  Future<void> login({
    required String username,
    required String password,
  }) async {
    final challenge = await _challenge(username);
    if (!challenge.isValid) {
      throw GlinetNotRouterException(
        'The device at $rpcUri answered, but its challenge is not a '
        'firmware 4.x challenge (alg ${challenge.alg}) — not a GL.iNet '
        'firmware 4.x router.',
      );
    }
    final cipherPassword = glinetCipherPassword(
      alg: challenge.alg,
      salt: challenge.salt,
      password: password,
    );
    final hash = glinetLoginHash(
      username: username,
      cipherPassword: cipherPassword,
      nonce: challenge.nonce,
      hashMethod: challenge.hashMethod,
    );
    final result = await _rpc('login', {'username': username, 'hash': hash});
    if (result is! Map<String, dynamic>) {
      throw const GlinetAuthException(
        'Login failed: the router did not return a session.',
      );
    }
    final sid = _asString(result['sid']);
    if (sid == null || sid.isEmpty) {
      throw const GlinetAuthException(
        'Login failed: the router did not return a session.',
      );
    }
    _sid = sid;
  }

  /// Authenticated `system.get_info`. Also verifies the firmware is 4.x.
  ///
  /// Throws [GlinetFirmwareTooOldException] when the router reports a
  /// pre-4.0 firmware version. Firmware newer than 4.x (e.g. 5.x) is
  /// accepted — the 4.x RPC surface is the baseline — but
  /// [GlinetRouterInfo.isFirmware4x] reports false for it, so the UI
  /// can say the version is unverified rather than supported.
  Future<GlinetRouterInfo> routerInfo() async {
    final result = await _call('system', 'get_info');
    if (result is! Map<String, dynamic>) {
      throw const GlinetApiException(
        'system.get_info returned an unexpected response.',
      );
    }
    final info = GlinetRouterInfo.fromJson(result);
    final major = _firmwareMajor(info.firmwareVersion);
    if (major == null) {
      throw const GlinetApiException(
        'The router did not report a firmware version.',
      );
    }
    if (major < 4) {
      throw GlinetFirmwareTooOldException(
        'Router firmware ${info.firmwareVersion} is older than 4.0 and '
        'uses a different API this client does not speak. Upgrade the '
        'router firmware to 4.x.',
      );
    }
    return info;
  }

  /// Authenticated `system.get_status`.
  Future<GlinetRouterStatus> routerStatus() async {
    final result = await _call('system', 'get_status');
    if (result is! Map<String, dynamic>) {
      throw const GlinetApiException(
        'system.get_status returned an unexpected response.',
      );
    }
    return GlinetRouterStatus.fromJson(result);
  }

  /// Authenticated `system.get_load`.
  Future<GlinetRouterLoad> routerLoad() async {
    final result = await _call('system', 'get_load');
    if (result is! Map<String, dynamic>) {
      throw const GlinetApiException(
        'system.get_load returned an unexpected response.',
      );
    }
    return GlinetRouterLoad.fromJson(result);
  }

  /// Authenticated `clients.get_list`.
  Future<List<GlinetClient>> listClients() async {
    final result = await _call('clients', 'get_list');
    if (result is! Map<String, dynamic>) {
      throw const GlinetApiException(
        'clients.get_list returned an unexpected response.',
      );
    }
    return _asMapList(result['clients'])
        .map(GlinetClient.fromJson)
        .toList();
  }

  /// Ends the session. Best-effort: the local SID is always cleared, even
  /// if the router cannot be reached; a live SID expires server-side in
  /// about 5 minutes anyway.
  Future<void> logout() async {
    final sid = _sid;
    _sid = null;
    if (sid == null) return;
    try {
      await _rpc('logout', {'sid': sid});
    } on GlinetException {
      // Best effort — the session is already forgotten locally.
    }
  }

  // ── Authenticated calls ──

  /// One authenticated `call` — params `[sid, module, function, ...extra]`.
  Future<dynamic> _call(String module, String function, [Object? extra]) {
    final sid = _sid;
    if (sid == null) {
      throw const GlinetAuthException(
        'Not logged in — call login() first.',
      );
    }
    final params = <Object>[sid, module, function];
    if (extra != null) params.add(extra);
    return _rpc('call', params);
  }
}
