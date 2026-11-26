/// Pure-Dart Unix crypt(3) password hashing for the GL.iNet firmware 4.x
/// JSON-RPC login flow.
///
/// The router's `challenge` call returns an algorithm id (`alg`), a salt,
/// a nonce and a `hash-method`. The login password is first turned into a
/// "cipher password" with the Unix crypt algorithm matching `alg`
/// (1 = MD5-crypt, 5 = SHA-256-crypt, 6 = SHA-512-crypt), and the login hash
/// is then `H("<username>:<cipher_password>:<nonce>")` where `H` is the
/// digest named by `hash-method` (default md5), hex-encoded.
///
/// The algorithms here are the public-domain reference algorithms
/// (Ulrich Drepper's MD5-crypt / SHA-crypt specification, as implemented by
/// glibc's `crypt(3)` and Python's `crypt` module). Only the digest
/// primitives come from `package:crypto` — no new dependency. The
/// implementation is verified byte-for-byte against Python's `crypt` module
/// in `test/glinet_crypt_test.dart`.
///
/// No password, cipher password or login hash is ever logged or persisted
/// by this file; the functions are pure and return only the computed string.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// The crypt(3) base-64 alphabet (`./0-9A-Za-z`), in encoding order.
const String _cryptAlphabet =
    './0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz';

/// Encodes the low [count] base-64 digits of the 24-bit value built from
/// ([b2], [b1], [b0]) — most-significant byte first — exactly as the
/// reference `b64_from_24bit` does.
String _encode24(int b2, int b1, int b0, int count) {
  var value = ((b2 & 0xff) << 16) | ((b1 & 0xff) << 8) | (b0 & 0xff);
  final out = StringBuffer();
  for (var i = 0; i < count; i++) {
    out.write(_cryptAlphabet[value & 0x3f]);
    value >>= 6;
  }
  return out.toString();
}

/// Repeats [digest] until it holds [length] bytes and returns the first
/// [length] of them (the "P bytes" / "S bytes" step of SHA-crypt).
Uint8List _repeatDigest(List<int> digest, int length) {
  final out = Uint8List(length);
  for (var i = 0; i < length; i++) {
    out[i] = digest[i % digest.length];
  }
  return out;
}

/// MD5-crypt (`$1$`), fixed at 1000 rounds per the reference algorithm.
///
/// The salt is truncated to 8 characters, matching glibc `crypt(3)`.
String md5Crypt(String password, String salt) {
  final pw = utf8.encode(password);
  final s = utf8.encode(salt.length > 8 ? salt.substring(0, 8) : salt);

  // Alternate digest: MD5(password + salt + password).
  final alt = md5.convert(<int>[...pw, ...s, ...pw]).bytes;

  // MD5(password + "$1$" + salt + <len(pw) bytes of alt> + bit loop).
  final ctx = <int>[...pw, ...utf8.encode(r'$1$'), ...s];
  for (var i = 0; i < pw.length; i++) {
    ctx.add(alt[i % alt.length]);
  }
  var i = pw.length;
  while (i > 0) {
    ctx.add((i & 1) == 1 ? 0 : pw[0]);
    i >>= 1;
  }
  var digest = md5.convert(ctx).bytes;

  for (var round = 0; round < 1000; round++) {
    final c = <int>[];
    if ((round & 1) == 1) {
      c.addAll(pw);
    } else {
      c.addAll(digest);
    }
    if (round % 3 != 0) c.addAll(s);
    if (round % 7 != 0) c.addAll(pw);
    if ((round & 1) == 1) {
      c.addAll(digest);
    } else {
      c.addAll(pw);
    }
    digest = md5.convert(c).bytes;
  }

  final out = StringBuffer(r'$1$')
    ..write(utf8.decode(s))
    ..write(r'$')
    ..write(_encode24(digest[0], digest[6], digest[12], 4))
    ..write(_encode24(digest[1], digest[7], digest[13], 4))
    ..write(_encode24(digest[2], digest[8], digest[14], 4))
    ..write(_encode24(digest[3], digest[9], digest[15], 4))
    ..write(_encode24(digest[4], digest[10], digest[5], 4))
    ..write(_encode24(0, 0, digest[11], 2));
  return out.toString();
}

/// Shared SHA-256-crypt / SHA-512-crypt core (Drepper's SHA-crypt spec).
///
/// [algorithm] is 5 (SHA-256) or 6 (SHA-512). The salt is truncated to
/// 16 characters and [rounds] defaults to 5000, matching glibc `crypt(3)`
/// and the `passlib` defaults used by the gli4py reference library.
String _shaCrypt({
  required String password,
  required String salt,
  required int algorithm,
  required Hash hash,
  int rounds = 5000,
}) {
  final pw = utf8.encode(password);
  final s = utf8.encode(salt.length > 16 ? salt.substring(0, 16) : salt);

  // Digest B: H(password + salt + password).
  final digestB = hash.convert(<int>[...pw, ...s, ...pw]).bytes;

  // Digest A: H(password + salt + <len(pw) bytes of B> + bit loop).
  // NB (Drepper step 11): the SHA bit loop differs from MD5-crypt — a
  // 1-bit adds the whole digest B, a 0-bit adds the whole password
  // (MD5-crypt instead adds NUL / the first password byte).
  final aCtx = <int>[...pw, ...s];
  for (var i = 0; i < pw.length; i++) {
    aCtx.add(digestB[i % digestB.length]);
  }
  var i = pw.length;
  while (i > 0) {
    if ((i & 1) == 1) {
      aCtx.addAll(digestB);
    } else {
      aCtx.addAll(pw);
    }
    i >>= 1;
  }
  final digestA = hash.convert(aCtx).bytes;

  // P bytes: H(password repeated len(password) times), first len(pw) bytes.
  final pInput = <int>[];
  for (var k = 0; k < pw.length; k++) {
    pInput.addAll(pw);
  }
  final pBytes = _repeatDigest(hash.convert(pInput).bytes, pw.length);

  // S bytes: H(salt repeated (16 + digestA[0]) times), first len(salt) bytes.
  final sInput = <int>[];
  for (var k = 0; k < 16 + digestA[0]; k++) {
    sInput.addAll(s);
  }
  final sBytes = _repeatDigest(hash.convert(sInput).bytes, s.length);

  var c = digestA;
  for (var round = 0; round < rounds; round++) {
    final ctx = <int>[];
    if ((round & 1) == 1) {
      ctx.addAll(pBytes);
    } else {
      ctx.addAll(c);
    }
    if (round % 3 != 0) ctx.addAll(sBytes);
    if (round % 7 != 0) ctx.addAll(pBytes);
    if ((round & 1) == 1) {
      ctx.addAll(c);
    } else {
      ctx.addAll(pBytes);
    }
    c = hash.convert(ctx).bytes;
  }

  final out = StringBuffer(algorithm == 5 ? r'$5$' : r'$6$');
  if (rounds != 5000) {
    out.write('rounds=$rounds\$');
  }
  out
    ..write(utf8.decode(s))
    ..write(r'$');
  if (algorithm == 5) {
    // SHA-256 digest is 32 bytes: 10 triples + the final 2 bytes.
    // Group order per Drepper's SHA-crypt spec, section 22.e
    // (columns #3, #2, #1 of the table).
    out
      ..write(_encode24(c[0], c[10], c[20], 4))
      ..write(_encode24(c[21], c[1], c[11], 4))
      ..write(_encode24(c[12], c[22], c[2], 4))
      ..write(_encode24(c[3], c[13], c[23], 4))
      ..write(_encode24(c[24], c[4], c[14], 4))
      ..write(_encode24(c[15], c[25], c[5], 4))
      ..write(_encode24(c[6], c[16], c[26], 4))
      ..write(_encode24(c[27], c[7], c[17], 4))
      ..write(_encode24(c[18], c[28], c[8], 4))
      ..write(_encode24(c[9], c[19], c[29], 4))
      // Final group holds the last 2 digest bytes → 3 characters
      // (spec section 22.e: three chars for SHA-256, two for SHA-512).
      ..write(_encode24(0, c[31], c[30], 3));
  } else {
    // SHA-512 digest is 64 bytes: 21 triples + the final byte.
    // Group order per Drepper's SHA-crypt spec, section 22.e.
    out
      ..write(_encode24(c[0], c[21], c[42], 4))
      ..write(_encode24(c[22], c[43], c[1], 4))
      ..write(_encode24(c[44], c[2], c[23], 4))
      ..write(_encode24(c[3], c[24], c[45], 4))
      ..write(_encode24(c[25], c[46], c[4], 4))
      ..write(_encode24(c[47], c[5], c[26], 4))
      ..write(_encode24(c[6], c[27], c[48], 4))
      ..write(_encode24(c[28], c[49], c[7], 4))
      ..write(_encode24(c[50], c[8], c[29], 4))
      ..write(_encode24(c[9], c[30], c[51], 4))
      ..write(_encode24(c[31], c[52], c[10], 4))
      ..write(_encode24(c[53], c[11], c[32], 4))
      ..write(_encode24(c[12], c[33], c[54], 4))
      ..write(_encode24(c[34], c[55], c[13], 4))
      ..write(_encode24(c[56], c[14], c[35], 4))
      ..write(_encode24(c[15], c[36], c[57], 4))
      ..write(_encode24(c[37], c[58], c[16], 4))
      ..write(_encode24(c[59], c[17], c[38], 4))
      ..write(_encode24(c[18], c[39], c[60], 4))
      ..write(_encode24(c[40], c[61], c[19], 4))
      ..write(_encode24(c[62], c[20], c[41], 4))
      ..write(_encode24(0, 0, c[63], 2));
  }
  return out.toString();
}

/// SHA-256-crypt (`$5$`), default 5000 rounds.
String sha256Crypt(String password, String salt, {int rounds = 5000}) =>
    _shaCrypt(
      password: password,
      salt: salt,
      algorithm: 5,
      hash: sha256,
      rounds: rounds,
    );

/// SHA-512-crypt (`$6$`), default 5000 rounds.
String sha512Crypt(String password, String salt, {int rounds = 5000}) =>
    _shaCrypt(
      password: password,
      salt: salt,
      algorithm: 6,
      hash: sha512,
      rounds: rounds,
    );

/// Computes a Unix crypt(3) hash from a full salt string such as
/// `$1$AbC12345$`, `$5$rounds=1000$XyZ98765$` or `$6$QwErTy12$`.
///
/// Throws [ArgumentError] for an unknown algorithm id or a malformed salt.
String unixCrypt(String password, String salt) {
  final match =
      RegExp(r'^\$(\d+)\$(?:rounds=(\d+)\$)?([^$]{1,16})\$?$')
          .firstMatch(salt);
  if (match == null) {
    throw ArgumentError('Malformed crypt salt: "$salt"');
  }
  final alg = int.parse(match.group(1)!);
  final rounds = match.group(2) == null ? 5000 : int.parse(match.group(2)!);
  final saltValue = match.group(3)!;
  switch (alg) {
    case 1:
      return md5Crypt(password, saltValue);
    case 5:
      return sha256Crypt(password, saltValue, rounds: rounds);
    case 6:
      return sha512Crypt(password, saltValue, rounds: rounds);
    default:
      throw ArgumentError('Unsupported crypt algorithm id: $alg');
  }
}

/// The GL.iNet "cipher password": `unix_crypt(password, "$<alg>$<salt>$")`.
///
/// [alg] is the challenge's algorithm id (1 = MD5-crypt, 5 = SHA-256-crypt,
/// 6 = SHA-512-crypt). Throws [ArgumentError] for any other id.
String glinetCipherPassword({
  required int alg,
  required String salt,
  required String password,
  int rounds = 5000,
}) {
  switch (alg) {
    case 1:
      return md5Crypt(password, salt);
    case 5:
      return sha256Crypt(password, salt, rounds: rounds);
    case 6:
      return sha512Crypt(password, salt, rounds: rounds);
    default:
      throw ArgumentError('Unsupported GL.iNet cipher algorithm id: $alg');
  }
}

/// The GL.iNet login hash: `H("<username>:<cipherPassword>:<nonce>")`,
/// hex-encoded, where `H` is the digest named by [hashMethod]
/// (`md5` / `sha256` / `sha512`; default `md5` per the challenge contract).
///
/// Throws [ArgumentError] for an unknown hash method.
String glinetLoginHash({
  required String username,
  required String cipherPassword,
  required String nonce,
  String hashMethod = 'md5',
}) {
  final data = utf8.encode('$username:$cipherPassword:$nonce');
  switch (hashMethod.toLowerCase().trim()) {
    case 'md5':
      return md5.convert(data).toString();
    case 'sha256':
      return sha256.convert(data).toString();
    case 'sha512':
      return sha512.convert(data).toString();
    default:
      throw ArgumentError('Unsupported GL.iNet hash method: "$hashMethod"');
  }
}
