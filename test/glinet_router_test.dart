// Tests for lib/services/glinet_router.dart using a scripted fake transport
// — no network, no router.
//
// Response payloads for system.get_info / get_status / get_load /
// clients.get_list are copied verbatim from the gli4py reference library's
// mock fixtures (~/workspace/tools/gli4py/gli4py/mock/fixtures/*.json).
// They are LIBRARY FIXTURES (synthetic mock data: MACs like 94:83:C4:11:22:33,
// hostnames like GL-MOCK-2G, model GL-B1300), not live router data and not
// measurements.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:outride/services/glinet_router.dart';

// ─── gli4py mock fixtures (verbatim) ────────────────────────────────────────

const String _systemInfoFixture = r'''
{
  "mac": "94:83:C4:11:22:33",
  "disable_guest_during_scan_wifi": false,
  "hardware_version": "v1.0",
  "country_code": "US",
  "sn_bak": "GL-MOCK-SN-BAK",
  "software_feature": {
    "ipv6": true,
    "adguard": false,
    "passthrough": false,
    "repeater_eap": true,
    "vpn": true,
    "ids_ips": false,
    "bark": false,
    "tor": false,
    "secondwan": false,
    "sms_forward": false,
    "nas": false
  },
  "vendor": "GL.iNet",
  "hardware_feature": {
    "reset_button": "gpio-63",
    "nand": false,
    "bluetooth": false,
    "wan": "eth1",
    "usb_reset": "",
    "switch_button": "",
    "radio": "radio0 radio1",
    "lan": "eth0",
    "usb": "1-1,2-1",
    "build_in_modem": "",
    "noled": false,
    "hwnat": false,
    "microsd": "",
    "modem_reset": 2,
    "fan": false,
    "mcu": false,
    "nowds": false
  },
  "cpu_num": 4,
  "board_info": {
    "architecture": "ARMv7 Processor rev 5 (v7l)",
    "hostname": "GL-B1300",
    "kernel_version": "5.4.179",
    "openwrt_version": "OpenWrt 21.02.2",
    "model": "GL.iNet GL-B1300"
  },
  "firmware_date": "2025-03-31 20:12:50",
  "model": "b1300",
  "ddns": "mockddns",
  "sn": "GL-MOCK-SN-12345",
  "firmware_type": "release1",
  "firmware_version": "4.3.25"
}
''';

const String _systemStatusFixture = r'''
{
  "network": [
    {"online": true, "up": true, "interface": "wan"},
    {"online": false, "up": false, "interface": "wwan"},
    {"online": false, "up": false, "interface": "tethering"},
    {"online": false, "up": false, "interface": "wan6"},
    {"online": false, "up": false, "interface": "wwan6"},
    {"online": false, "up": false, "interface": "tethering6"}
  ],
  "wifi": [
    {"guest": false, "ssid": "GL-MOCK-2G", "up": true, "channel": 1, "band": "2G", "name": "default_radio0", "passwd": "None"},
    {"guest": false, "ssid": "GL-MOCK-5G", "up": true, "channel": 48, "band": "5G", "name": "default_radio1", "passwd": "None"},
    {"guest": true, "ssid": "GL-MOCK-2G-Guest", "up": false, "channel": 1, "band": "2G", "name": "guest2g", "passwd": "None"},
    {"guest": true, "ssid": "GL-MOCK-5G-Guest", "up": false, "channel": 48, "band": "5G", "name": "guest5g", "passwd": "None"}
  ],
  "service": [
    {"name": "wgclient", "status": 0},
    {"name": "wgserver", "status": 0},
    {"name": "ovpnclient", "status": 0},
    {"name": "ovpnserver", "status": 0}
  ],
  "client": [
    {"cable_total": 2, "wireless_total": 1}
  ],
  "system": {
    "netnat_enabled": false,
    "ddns_enabled": false,
    "tzoffset": "+0000",
    "guest_ip": "192.168.9.1",
    "flash_app": 610304,
    "flash_total": 33554432,
    "memory_total": 254586880,
    "memory_free": 137543680,
    "ipv6_enabled": false,
    "memory_buff_cache": 33550336,
    "uptime": 86400.0,
    "load_average": [0.15, 0.2, 0.18],
    "guest_netmask": "255.255.255.0",
    "mode": 4,
    "flash_free": 14135296,
    "timestamp": 1750000000
  }
}
''';

const String _systemLoadFixture = r'''
{
  "memory_free": 137641984,
  "memory_buff_cache": 33554432,
  "memory_total": 254586880,
  "load_average": [0.15, 0.2, 0.18]
}
''';

const String _clientsFixture = r'''
{
  "clients": [
    {
      "limit_tx": 0, "ip": "192.168.1.10", "last_rx": [0], "last_tx": [0],
      "limit_rx": 0, "total_tx_init": 84930211, "alias": "HomeAssistant-Yellow",
      "total_tx": 84935402, "last_update_rate": 1790276100, "type": 2,
      "mac": "B8:27:EB:44:55:66", "remote": false, "iface": "cable",
      "tx": 342, "online": true, "name": "homeassistant", "blocked": false,
      "total_rx_init": 112049382, "online_time": 1790100000,
      "total_rx": 112055102, "rx": 512
    },
    {
      "limit_tx": 0, "ip": "192.168.1.20", "last_rx": [0], "last_tx": [0],
      "limit_rx": 0, "total_tx_init": 150240, "alias": "Proxmox-Node-01",
      "total_tx": 150240, "last_update_rate": 1790276100, "type": 2,
      "mac": "00:1E:67:A1:B2:C3", "remote": false, "iface": "cable",
      "tx": 890, "online": true, "name": "pve", "blocked": false,
      "total_rx_init": 4509320, "online_time": 1789500000,
      "total_rx": 4509320, "rx": 1205
    },
    {
      "limit_tx": 0, "class": "smartappliances", "ip": "192.168.1.30",
      "last_rx": [16], "last_tx": [32], "limit_rx": 0, "total_tx_init": 45201,
      "alias": "Shelly-LivingRoom-Main", "total_tx": 45300,
      "last_update_rate": 1790276100, "type": 0,
      "mac": "E8:DB:84:77:88:99", "remote": false, "iface": "2.4G",
      "tx": 12, "online": true, "name": "shelly1-A4B5C6", "blocked": false,
      "total_rx_init": 12050, "online_time": 1790250000,
      "total_rx": 12100, "rx": 8
    },
    {
      "limit_tx": 0, "ip": "192.168.1.40", "last_rx": [0], "last_tx": [0],
      "limit_rx": 0, "total_tx_init": 55392019, "total_tx": 55392019,
      "last_update_rate": 1790276100, "type": 0,
      "mac": "F4:0F:24:D4:E5:F6", "remote": false, "iface": "5G",
      "tx": 0, "online": false, "name": "Georges-iPhone", "blocked": false,
      "total_rx_init": 19403920, "online_time": 1790260000,
      "total_rx": 19403920, "rx": 0
    },
    {
      "limit_tx": 0, "class": "smartappliances", "ip": "192.168.1.50",
      "last_rx": [64], "last_tx": [64], "limit_rx": 0, "total_tx_init": 94032,
      "alias": "ESP32-Bluetooth-Proxy-Hallway", "total_tx": 94050,
      "last_update_rate": 1790276100, "type": 0,
      "mac": "24:6F:28:11:22:33", "remote": false, "iface": "2.4G",
      "tx": 45, "online": true, "name": "esphome-bt-proxy", "blocked": false,
      "total_rx_init": 30492, "online_time": 1790270000,
      "total_rx": 30510, "rx": 22
    }
  ]
}
''';

// ─── Scripted fake transport ────────────────────────────────────────────────

/// Records every request body and answers from a script keyed by RPC call:
/// `challenge`, `login`, `logout`, or `call:<module>.<function>`.
class _ScriptedPost {
  _ScriptedPost(this._script);

  final Map<String, List<http.Response>> _script;

  /// Decoded request bodies, in order.
  final List<Map<String, dynamic>> requests = [];

  /// Exceptions to throw instead of responding, keyed the same way.
  final Map<String, Object> throwFor = {};

  Future<http.Response> call(
    Uri uri,
    Map<String, String> headers,
    String body,
  ) async {
    final decoded = jsonDecode(body) as Map<String, dynamic>;
    requests.add(decoded);
    expect(headers['Content-Type'], 'application/json');
    expect(uri.toString(), 'http://192.168.8.1/rpc');

    final method = decoded['method'] as String;
    var key = method;
    if (method == 'call') {
      final params = decoded['params'] as List;
      key = 'call:${params[1]}.${params[2]}';
    }
    if (throwFor.containsKey(key)) throw throwFor[key]!;
    final queue = _script[key];
    if (queue == null || queue.isEmpty) {
      fail('No scripted response for "$key"');
    }
    return queue.removeAt(0);
  }
}

http.Response _rpcResult(Object? result, {int id = 0}) => http.Response(
      jsonEncode({'jsonrpc': '2.0', 'id': id, 'result': result}),
      200,
      headers: {'content-type': 'application/json'},
    );

http.Response _rpcError(int code, String message) => http.Response(
      jsonEncode({
        'jsonrpc': '2.0',
        'id': 0,
        'error': {'code': code, 'message': message},
      }),
      200,
      headers: {'content-type': 'application/json'},
    );

/// A challenge for alg 6 / sha512, matching the crypt golden vectors:
/// password `testpass`, salt `QwErTy12`, nonce `n0nc3v4lu3`.
Map<String, dynamic> get _sha512Challenge => {
      'alg': 6,
      'salt': 'QwErTy12',
      'nonce': 'n0nc3v4lu3',
      'hash-method': 'sha512',
    };

/// Script that answers challenge + login (sid `test-sid-123`) and then the
/// four read calls with the gli4py fixtures.
_ScriptedPost _loggedInScript() {
  return _ScriptedPost({
    'challenge': [_rpcResult(_sha512Challenge)],
    'login': [
      _rpcResult({'sid': 'test-sid-123'}),
    ],
    'call:system.get_info': [
      _rpcResult(jsonDecode(_systemInfoFixture)),
    ],
    'call:system.get_status': [
      _rpcResult(jsonDecode(_systemStatusFixture)),
    ],
    'call:system.get_load': [
      _rpcResult(jsonDecode(_systemLoadFixture)),
    ],
    'call:clients.get_list': [
      _rpcResult(jsonDecode(_clientsFixture)),
    ],
    'logout': [_rpcResult(null)],
  });
}

Future<GlinetRouter> _loggedInRouter(_ScriptedPost script) async {
  final router = GlinetRouter(post: script.call);
  await router.login(username: 'root', password: 'testpass');
  return router;
}

void main() {
  group('payload building', () {
    test('challenge / login / call JSON shapes match the JSON-RPC contract',
        () async {
      final script = _loggedInScript();
      final router = await _loggedInRouter(script);
      await router.routerInfo();
      await router.routerStatus();
      await router.routerLoad();
      await router.listClients();
      await router.logout();

      // challenge
      final challenge = script.requests[0];
      expect(challenge['jsonrpc'], '2.0');
      expect(challenge['method'], 'challenge');
      expect(challenge['params'], {'username': 'root'});
      expect(challenge['id'], isA<int>());

      // login — the hash must be the golden sha512 login hash for
      // root / testpass / QwErTy12 / n0nc3v4lu3.
      final login = script.requests[1];
      expect(login['method'], 'login');
      expect(login['params'], {
        'username': 'root',
        'hash':
            '052d8dc51153ca56b7072ca06313a82cda3caa9e85366e03a8544925dcf0b06fc3f188aaa07a60f7d4a5905c2797e740f16af7b3d52bf8770709768ef50445d5',
      });

      // call — params are [sid, module, function].
      final infoCall = script.requests[2];
      expect(infoCall['method'], 'call');
      expect(infoCall['params'], ['test-sid-123', 'system', 'get_info']);

      expect(
        (script.requests[3]['params'] as List).sublist(1),
        ['system', 'get_status'],
      );
      expect(
        (script.requests[4]['params'] as List).sublist(1),
        ['system', 'get_load'],
      );
      expect(
        (script.requests[5]['params'] as List).sublist(1),
        ['clients', 'get_list'],
      );

      // logout — params are {"sid": ...} (gli4py mock server shape).
      final logout = script.requests[6];
      expect(logout['method'], 'logout');
      expect(logout['params'], {'sid': 'test-sid-123'});
      expect(router.isLoggedIn, isFalse);
    });

    test('login defaults an absent hash-method to md5', () async {
      final script = _ScriptedPost({
        'challenge': [
          _rpcResult({'alg': 1, 'salt': 'AbC12345', 'nonce': 'n0nc3v4lu3'}),
        ],
        'login': [
          _rpcResult({'sid': 's'}),
        ],
      });
      final router = GlinetRouter(post: script.call);
      await router.login(username: 'root', password: 'testpass');
      // Golden md5 login hash for root / testpass / AbC12345 / n0nc3v4lu3.
      expect((script.requests[1]['params'] as Map)['hash'],
          'db2e143e4de78aff04efa16c3f457e49');
      expect(router.isLoggedIn, isTrue);
    });

    test('default RPC uri is http://192.168.8.1/rpc', () {
      expect(
        GlinetRouter().rpcUri.toString(),
        'http://192.168.8.1/rpc',
      );
    });
  });

  group('probe', () {
    test('well-formed 4.x challenge → reachable + isGlinet4x', () async {
      final script = _ScriptedPost({
        'challenge': [_rpcResult(_sha512Challenge)],
      });
      final router = GlinetRouter(post: script.call);
      final result = await router.probe();
      expect(result.reachable, isTrue);
      expect(result.isGlinet4x, isTrue);
      expect(result.challengeAlg, 6);
      expect(result.hashMethod, 'sha512');
      expect(result.error, isNull);
    });

    test('challenge with a bad shape → not a 4.x router, no throw', () async {
      final script = _ScriptedPost({
        'challenge': [
          _rpcResult({'foo': 'bar'}),
        ],
      });
      final router = GlinetRouter(post: script.call);
      final result = await router.probe();
      // The device answered a challenge call — reachable — but the
      // challenge is not 4.x, so it is not a GL.iNet 4.x router.
      expect(result.reachable, isTrue);
      expect(result.isGlinet4x, isFalse);
      expect(result.error, contains('not a GL.iNet firmware 4.x router'));
    });

    test('unsupported cipher alg in challenge → not a 4.x router, no throw',
        () async {
      final script = _ScriptedPost({
        'challenge': [
          _rpcResult({
            'alg': 2,
            'salt': 'x',
            'nonce': 'y',
            'hash-method': 'md5',
          }),
        ],
      });
      final router = GlinetRouter(post: script.call);
      final result = await router.probe();
      expect(result.reachable, isTrue);
      expect(result.error, contains('not a GL.iNet firmware 4.x router'));
    });

    test('malformed router address → failed, no throw', () async {
      final script = _ScriptedPost({'challenge': []});
      script.throwFor['challenge'] = ArgumentError('Invalid host');
      final router = GlinetRouter(post: script.call);
      final result = await router.probe();
      expect(result.reachable, isFalse);
      expect(result.isGlinet4x, isFalse);
      expect(result.error, isNotNull);
    });

    test('unreachable host → reachable false, no throw', () async {
      final script = _ScriptedPost({'challenge': []});
      script.throwFor['challenge'] =
          const SocketException('Connection refused');
      final router = GlinetRouter(post: script.call);
      final result = await router.probe();
      expect(result.reachable, isFalse);
      expect(result.error, contains('Could not reach'));
    });

    test('timeout → reachable false, no throw', () async {
      final script = _ScriptedPost({'challenge': []});
      script.throwFor['challenge'] = TimeoutException('timed out');
      final router = GlinetRouter(post: script.call);
      final result = await router.probe();
      expect(result.reachable, isFalse);
      expect(result.error, contains('Timed out'));
    });

    test('non-JSON (HTML) answer → not a GL.iNet router, no throw',
        () async {
      final script = _ScriptedPost({
        'challenge': [
          http.Response('<html>not a router</html>', 200),
        ],
      });
      final router = GlinetRouter(post: script.call);
      final result = await router.probe();
      expect(result.reachable, isFalse);
      expect(result.error, contains('not a GL.iNet firmware 4.x router'));
    });

    test('JSON without a result → not a GL.iNet router, no throw', () async {
      final script = _ScriptedPost({
        'challenge': [
          http.Response(jsonEncode({'status': 'ok'}), 200),
        ],
      });
      final router = GlinetRouter(post: script.call);
      final result = await router.probe();
      expect(result.reachable, isFalse);
      expect(result.error, contains('not a GL.iNet firmware 4.x router'));
    });
  });

  group('response parsing (gli4py mock fixtures)', () {
    test('routerInfo parses the system_info fixture', () async {
      final script = _loggedInScript();
      final router = await _loggedInRouter(script);
      final info = await router.routerInfo();
      expect(info.model, 'b1300');
      expect(info.boardModel, 'GL.iNet GL-B1300');
      expect(info.firmwareVersion, '4.3.25');
      expect(info.isFirmware4x, isTrue);
      expect(info.firmwareDate, '2025-03-31 20:12:50');
      expect(info.mac, '94:83:C4:11:22:33');
      expect(info.serialNumber, 'GL-MOCK-SN-12345');
      expect(info.vendor, 'GL.iNet');
      expect(info.hostname, 'GL-B1300');
      expect(info.openWrtVersion, 'OpenWrt 21.02.2');
      expect(info.cpuCount, 4);
    });

    test('routerStatus parses the system_status fixture', () async {
      final script = _loggedInScript();
      final router = await _loggedInRouter(script);
      final status = await router.routerStatus();
      expect(status.networks.length, 6);
      expect(status.networks.first.interface, 'wan');
      expect(status.networks.first.online, isTrue);
      expect(status.networks[1].online, isFalse);
      expect(status.wifi.length, 4);
      expect(status.wifi[0].ssid, 'GL-MOCK-2G');
      expect(status.wifi[0].band, '2G');
      expect(status.wifi[0].channel, 1);
      expect(status.wifi[0].up, isTrue);
      expect(status.wifi[1].ssid, 'GL-MOCK-5G');
      expect(status.wifi[1].channel, 48);
      expect(status.wifi[2].guest, isTrue);
      expect(status.wifi[2].up, isFalse);
      expect(status.services.length, 4);
      expect(status.services.first.name, 'wgclient');
      expect(status.clientCounts.cableTotal, 2);
      expect(status.clientCounts.wirelessTotal, 1);
      expect(status.uptimeSeconds, 86400.0);
      expect(status.memoryTotal, 254586880);
      expect(status.memoryFree, 137543680);
      expect(status.loadAverage, [0.15, 0.2, 0.18]);
      expect(status.mode, 4);
      expect(status.timestamp, 1750000000);
    });

    test('routerLoad parses the system_load fixture', () async {
      final script = _loggedInScript();
      final router = await _loggedInRouter(script);
      final load = await router.routerLoad();
      expect(load.memoryTotal, 254586880);
      expect(load.memoryFree, 137641984);
      expect(load.memoryBuffCache, 33554432);
      expect(load.loadAverage, [0.15, 0.2, 0.18]);
      expect(load.load1Min, 0.15);
      expect(load.load5Min, 0.2);
      expect(load.load15Min, 0.18);
    });

    test('listClients parses the clients fixture', () async {
      final script = _loggedInScript();
      final router = await _loggedInRouter(script);
      final clients = await router.listClients();
      expect(clients.length, 5);

      final ha = clients[0];
      expect(ha.mac, 'B8:27:EB:44:55:66');
      expect(ha.ip, '192.168.1.10');
      expect(ha.name, 'homeassistant');
      expect(ha.alias, 'HomeAssistant-Yellow');
      expect(ha.displayName, 'HomeAssistant-Yellow');
      expect(ha.online, isTrue);
      expect(ha.iface, 'cable');
      expect(ha.blocked, isFalse);
      expect(ha.totalTxBytes, 84935402);
      expect(ha.totalRxBytes, 112055102);

      final shelly = clients[2];
      expect(shelly.iface, '2.4G');
      expect(shelly.clientClass, 'smartappliances');

      final iphone = clients[3];
      expect(iphone.online, isFalse);
      expect(iphone.iface, '5G');
      expect(iphone.displayName, 'Georges-iPhone');

      expect(clients.where((c) => c.online).length, 4);
    });
  });

  group('lenient parsing', () {
    test('missing / odd fields degrade to null / empty, never throw',
        () async {
      final script = _ScriptedPost({
        'challenge': [_rpcResult(_sha512Challenge)],
        'login': [
          _rpcResult({'sid': 's'}),
        ],
        'call:system.get_info': [
          _rpcResult({'model': 'ax1800'}),
        ],
        'call:system.get_status': [
          _rpcResult({}),
        ],
        'call:system.get_load': [
          _rpcResult({'load_average': ['0.5', 'bad', 0.25]}),
        ],
        'call:clients.get_list': [
          _rpcResult({
            'clients': [
              {'mac': 'AA:BB:CC:DD:EE:FF'},
              'not-a-map',
              {'mac': 123, 'ip': '192.168.8.2', 'online': 'yes'},
            ],
          }),
        ],
      });
      final router = GlinetRouter(post: script.call);
      await router.login(username: 'root', password: 'testpass');

      // Missing firmware version is a real error (cannot verify 4.x).
      expect(
        router.routerInfo(),
        throwsA(isA<GlinetApiException>()),
      );

      final status = await router.routerStatus();
      expect(status.networks, isEmpty);
      expect(status.wifi, isEmpty);
      expect(status.clientCounts.cableTotal, 0);
      expect(status.uptimeSeconds, isNull);

      final load = await router.routerLoad();
      expect(load.loadAverage, [0.5, 0.25]);
      expect(load.memoryTotal, isNull);

      final clients = await router.listClients();
      expect(clients.length, 2);
      expect(clients[0].ip, '');
      expect(clients[0].online, isFalse);
      expect(clients[1].mac, '123');
      expect(clients[1].online, isTrue);
    });

    test('pre-4.0 firmware is reported, not silently accepted', () async {
      final script = _ScriptedPost({
        'challenge': [_rpcResult(_sha512Challenge)],
        'login': [
          _rpcResult({'sid': 's'}),
        ],
        'call:system.get_info': [
          _rpcResult({
            'model': 'b1300',
            'firmware_version': '3.215',
            'mac': '94:83:C4:11:22:33',
          }),
        ],
      });
      final router = GlinetRouter(post: script.call);
      await router.login(username: 'root', password: 'testpass');
      expect(
        router.routerInfo(),
        throwsA(
          isA<GlinetFirmwareTooOldException>().having(
            (e) => e.message,
            'message',
            contains('older than 4.0'),
          ),
        ),
      );
    });
  });

  group('error mapping', () {
    test('wrong password (-32000) → GlinetAuthException', () async {
      final script = _ScriptedPost({
        'challenge': [_rpcResult(_sha512Challenge)],
        'login': [_rpcError(-32000, 'Access denied')],
      });
      final router = GlinetRouter(post: script.call);
      expect(
        router.login(username: 'root', password: 'wrong'),
        throwsA(isA<GlinetAuthException>()),
      );
      expect(router.isLoggedIn, isFalse);
    });

    test('lockout (-32003) → GlinetLockoutException', () async {
      final script = _ScriptedPost({
        'challenge': [_rpcResult(_sha512Challenge)],
        'login': [
          _rpcError(-32003, 'Login failed too many times'),
        ],
      });
      final router = GlinetRouter(post: script.call);
      expect(
        router.login(username: 'root', password: 'wrong'),
        throwsA(isA<GlinetLockoutException>()),
      );
    });

    test('stale SID (-1) clears the session and reports auth failure',
        () async {
      final script = _ScriptedPost({
        'challenge': [_rpcResult(_sha512Challenge)],
        'login': [
          _rpcResult({'sid': 'stale'}),
        ],
        'call:system.get_info': [
          _rpcError(-1, 'Invalid user, permission denied or not logged in!'),
        ],
      });
      final router = GlinetRouter(post: script.call);
      await router.login(username: 'root', password: 'testpass');
      expect(router.isLoggedIn, isTrue);
      await expectLater(
        router.routerInfo(),
        throwsA(isA<GlinetAuthException>()),
      );
      expect(router.isLoggedIn, isFalse);
    });

    test('method not found (-32601) → GlinetApiException with code',
        () async {
      final script = _ScriptedPost({
        'challenge': [_rpcResult(_sha512Challenge)],
        'login': [
          _rpcResult({'sid': 's'}),
        ],
        'call:system.get_info': [
          _rpcError(-32601, 'Method not found'),
        ],
      });
      final router = GlinetRouter(post: script.call);
      await router.login(username: 'root', password: 'testpass');
      expect(
        router.routerInfo(),
        throwsA(
          isA<GlinetApiException>()
              .having((e) => e.code, 'code', -32601),
        ),
      );
    });

    test('unreachable host at login → GlinetUnreachableException', () async {
      final script = _ScriptedPost({'challenge': []});
      script.throwFor['challenge'] =
          const SocketException('Connection refused');
      final router = GlinetRouter(post: script.call);
      expect(
        router.login(username: 'root', password: 'testpass'),
        throwsA(isA<GlinetUnreachableException>()),
      );
    });

    test('non-GL.iNet answer at login → GlinetNotRouterException', () async {
      final script = _ScriptedPost({
        'challenge': [
          http.Response('<html>some other device</html>', 200),
        ],
      });
      final router = GlinetRouter(post: script.call);
      expect(
        router.login(username: 'root', password: 'testpass'),
        throwsA(isA<GlinetNotRouterException>()),
      );
    });

    test('HTTP 500 → GlinetApiException', () async {
      final script = _ScriptedPost({
        'challenge': [
          http.Response('Internal Server Error', 500),
        ],
      });
      final router = GlinetRouter(post: script.call);
      expect(
        router.login(username: 'root', password: 'testpass'),
        throwsA(isA<GlinetApiException>()),
      );
    });

    test('call without login → GlinetAuthException', () async {
      final script = _ScriptedPost({});
      final router = GlinetRouter(post: script.call);
      expect(
        router.routerInfo(),
        throwsA(isA<GlinetAuthException>()),
      );
      expect(script.requests, isEmpty);
    });

    test('login with an unsupported challenge alg → GlinetNotRouterException',
        () async {
      final script = _ScriptedPost({
        'challenge': [
          _rpcResult({
            'alg': 2,
            'salt': 'x',
            'nonce': 'y',
            'hash-method': 'md5',
          }),
        ],
      });
      final router = GlinetRouter(post: script.call);
      expect(
        router.login(username: 'root', password: 'testpass'),
        throwsA(isA<GlinetNotRouterException>()),
      );
    });

    test('logout clears the session even when the router is unreachable',
        () async {
      final script = _loggedInScript();
      script.throwFor['logout'] =
          const SocketException('Connection refused');
      final router = await _loggedInRouter(script);
      expect(router.isLoggedIn, isTrue);
      await router.logout();
      expect(router.isLoggedIn, isFalse);
      expect(
        router.routerInfo(),
        throwsA(isA<GlinetAuthException>()),
      );
    });
  });
}
