// Golden-vector tests for the pure-Dart Unix crypt(3) implementation in
// lib/services/glinet_crypt.dart.
//
// Every expected value below was generated with Python's `crypt` module
// (glibc crypt(3)) in the sandbox — e.g.
//   python3 -c "import crypt; print(crypt.crypt('testpass', '\$6\$QwErTy12\$'))"
// — and the login hashes with hashlib over
// "<username>:<cipher_password>:<nonce>". They are fixed reference values,
// not live router data.

import 'package:flutter_test/flutter_test.dart';

import 'package:outride/services/glinet_crypt.dart';

void main() {
  group('md5Crypt (\$1\$)', () {
    test('matches glibc for testpass / AbC12345', () {
      expect(
        md5Crypt('testpass', 'AbC12345'),
        r'$1$AbC12345$0aKXxl0Agc3s4nE/Krewg.',
      );
    });

    test('matches glibc for hunter2 / s4ltS4lt', () {
      expect(
        md5Crypt('hunter2', 's4ltS4lt'),
        r'$1$s4ltS4lt$XvIM72smivDjWGhgQAqIy1',
      );
    });

    test('empty password', () {
      expect(
        md5Crypt('', 'emptyslt'),
        r'$1$emptyslt$SV5SIC5zY2cmwmf75JZuZ1',
      );
    });

    test('salt longer than 8 chars is truncated like glibc', () {
      expect(
        md5Crypt('testpass', '123456789ABCDEF'),
        r'$1$12345678$duTc/02K9TK/XCYFyofbZ/',
      );
    });
  });

  group('sha256Crypt (\$5\$)', () {
    test('matches glibc for testpass / XyZ98765', () {
      expect(
        sha256Crypt('testpass', 'XyZ98765'),
        r'$5$XyZ98765$oChLSlBUQaexsHsUQi.dQlihW7OEG3iDDyi5Y/HRa/0',
      );
    });

    test('matches glibc for a long passphrase', () {
      expect(
        sha256Crypt('correct horse battery staple', 'aB3dEfGh'),
        r'$5$aB3dEfGh$NNy8bMmeZShCZ2G3A6EWTzkBXopKGHN2MSI9HD05MMD',
      );
    });

    test('explicit rounds=1000 is honoured and round-trips in the output', () {
      expect(
        sha256Crypt('testpass', 'XyZ98765', rounds: 1000),
        r'$5$rounds=1000$XyZ98765$6G.8Egs6Lo2.sOfG3Xay0LMTQst3iPAUFoDevHxHU97',
      );
    });

    test('salt longer than 16 chars is truncated like glibc', () {
      expect(
        sha256Crypt('testpass', '1234567890ABCDEF1234'),
        r'$5$1234567890ABCDEF$/BkY8tMZBn.NeSABExqgJAcvKCWzT4ftMwl7G1Xw135',
      );
    });
  });

  group('sha512Crypt (\$6\$)', () {
    test('matches glibc for testpass / QwErTy12', () {
      expect(
        sha512Crypt('testpass', 'QwErTy12'),
        r'$6$QwErTy12$0Uyhq9.8c6.W1iUP5pE/6QNk2HwP4TlIBxNKHTWDpwv25uF21l7GnKGUlZWdxO7HFNV.8tAlGiA9MSs2zr/NW0',
      );
    });

    test('matches glibc for p@ssw0rd! / Zz9x8c7v', () {
      expect(
        sha512Crypt('p@ssw0rd!', 'Zz9x8c7v'),
        r'$6$Zz9x8c7v$U5ijjast56RdlwlxMwhAbfgqFVc6ZDaN/zXMy1fW4y/X06oMVA07EPowo/3QXT725bcFC6TIX/qUhbclMlxc/.',
      );
    });

    test('explicit rounds=10000', () {
      expect(
        sha512Crypt('testpass', 'QwErTy12', rounds: 10000),
        r'$6$rounds=10000$QwErTy12$SRJS..fHCDcnbWEdghsiwsjKQipKdsJxL2HSiekn7ccuB6C4KbiUXiAkRgZTtCwroMLYI7y81jC.0zXRbopzp0',
      );
    });

    test('100-char password', () {
      expect(
        sha512Crypt('a' * 100, 'longsalt'),
        r'$6$longsalt$SmMRzmePzO1IyUEh8UI/3BM1tRh9t2ML45zVkNThNdNizkCKk4Slh60rNllwCF60636UFdWzoFHGq0tE4JUn90',
      );
    });
  });

  group('unixCrypt', () {
    test('parses \$1\$ / \$5\$ / \$6\$ salt strings', () {
      expect(
        unixCrypt('testpass', r'$1$AbC12345$'),
        r'$1$AbC12345$0aKXxl0Agc3s4nE/Krewg.',
      );
      expect(
        unixCrypt('testpass', r'$5$XyZ98765$'),
        r'$5$XyZ98765$oChLSlBUQaexsHsUQi.dQlihW7OEG3iDDyi5Y/HRa/0',
      );
      expect(
        unixCrypt('testpass', r'$6$QwErTy12$'),
        r'$6$QwErTy12$0Uyhq9.8c6.W1iUP5pE/6QNk2HwP4TlIBxNKHTWDpwv25uF21l7GnKGUlZWdxO7HFNV.8tAlGiA9MSs2zr/NW0',
      );
    });

    test('parses rounds=N in the salt string', () {
      expect(
        unixCrypt('testpass', r'$5$rounds=1000$XyZ98765$'),
        r'$5$rounds=1000$XyZ98765$6G.8Egs6Lo2.sOfG3Xay0LMTQst3iPAUFoDevHxHU97',
      );
    });

    test('rejects unknown algorithms and malformed salts', () {
      expect(() => unixCrypt('testpass', r'$2$AbC12345$'),
          throwsArgumentError);
      expect(() => unixCrypt('testpass', 'not-a-salt'), throwsArgumentError);
      expect(() => unixCrypt('testpass', r'$9$salt$'), throwsArgumentError);
    });
  });

  group('glinetCipherPassword', () {
    test('alg 1 / 5 / 6 select the right crypt', () {
      expect(
        glinetCipherPassword(alg: 1, salt: 'AbC12345', password: 'testpass'),
        r'$1$AbC12345$0aKXxl0Agc3s4nE/Krewg.',
      );
      expect(
        glinetCipherPassword(alg: 5, salt: 'XyZ98765', password: 'testpass'),
        r'$5$XyZ98765$oChLSlBUQaexsHsUQi.dQlihW7OEG3iDDyi5Y/HRa/0',
      );
      expect(
        glinetCipherPassword(alg: 6, salt: 'QwErTy12', password: 'testpass'),
        r'$6$QwErTy12$0Uyhq9.8c6.W1iUP5pE/6QNk2HwP4TlIBxNKHTWDpwv25uF21l7GnKGUlZWdxO7HFNV.8tAlGiA9MSs2zr/NW0',
      );
    });

    test('unknown alg throws', () {
      expect(
        () => glinetCipherPassword(alg: 2, salt: 'x', password: 'y'),
        throwsArgumentError,
      );
    });
  });

  group('glinetLoginHash', () {
    // cipher passwords from the vectors above; hashes are
    // H("<username>:<cipher>:<nonce>") via hashlib.
    test('md5 login hash, root / n0nc3v4lu3', () {
      expect(
        glinetLoginHash(
          username: 'root',
          cipherPassword: r'$1$AbC12345$0aKXxl0Agc3s4nE/Krewg.',
          nonce: 'n0nc3v4lu3',
        ),
        'db2e143e4de78aff04efa16c3f457e49',
      );
    });

    test('md5 login hash, admin / abcdef123456', () {
      expect(
        glinetLoginHash(
          username: 'admin',
          cipherPassword: r'$1$AbC12345$0aKXxl0Agc3s4nE/Krewg.',
          nonce: 'abcdef123456',
        ),
        '4ba81e6029f59c364a57d77372a6b314',
      );
    });

    test('sha256 login hash, root / n0nc3v4lu3', () {
      expect(
        glinetLoginHash(
          username: 'root',
          cipherPassword:
              r'$5$XyZ98765$oChLSlBUQaexsHsUQi.dQlihW7OEG3iDDyi5Y/HRa/0',
          nonce: 'n0nc3v4lu3',
          hashMethod: 'sha256',
        ),
        'c9666e35022217ea5a090ca2f60828e9a9bdba8bb8e56fb18f7f8638e5321dd4',
      );
    });

    test('sha512 login hash, root / n0nc3v4lu3', () {
      expect(
        glinetLoginHash(
          username: 'root',
          cipherPassword:
              r'$6$QwErTy12$0Uyhq9.8c6.W1iUP5pE/6QNk2HwP4TlIBxNKHTWDpwv25uF21l7GnKGUlZWdxO7HFNV.8tAlGiA9MSs2zr/NW0',
          nonce: 'n0nc3v4lu3',
          hashMethod: 'sha512',
        ),
        '052d8dc51153ca56b7072ca06313a82cda3caa9e85366e03a8544925dcf0b06fc3f188aaa07a60f7d4a5905c2797e740f16af7b3d52bf8770709768ef50445d5',
      );
    });

    test('sha512 login hash, admin / abcdef123456', () {
      expect(
        glinetLoginHash(
          username: 'admin',
          cipherPassword:
              r'$6$QwErTy12$0Uyhq9.8c6.W1iUP5pE/6QNk2HwP4TlIBxNKHTWDpwv25uF21l7GnKGUlZWdxO7HFNV.8tAlGiA9MSs2zr/NW0',
          nonce: 'abcdef123456',
          hashMethod: 'sha512',
        ),
        '97796ff0302831b95cf0f669d50bea78bc4256b4fd8181423bcd4ca3fc90374904210f5d67aca88ab4f949937adaa92b306abd8da12e74e7a0dd789797a1a4f8',
      );
    });

    test('sha256 login hash with rounds=1000 cipher', () {
      expect(
        glinetLoginHash(
          username: 'root',
          cipherPassword:
              r'$5$rounds=1000$XyZ98765$6G.8Egs6Lo2.sOfG3Xay0LMTQst3iPAUFoDevHxHU97',
          nonce: 'n0nc3v4lu3',
          hashMethod: 'sha256',
        ),
        'd6aff044941e585780e0a716f16a156dbde39dc25d14cf5f61fd4f14589f0f1f',
      );
    });

    test('hash-method defaults to md5 and is case-insensitive', () {
      expect(
        glinetLoginHash(
          username: 'root',
          cipherPassword: r'$1$AbC12345$0aKXxl0Agc3s4nE/Krewg.',
          nonce: 'n0nc3v4lu3',
          hashMethod: 'MD5',
        ),
        'db2e143e4de78aff04efa16c3f457e49',
      );
    });

    test('unknown hash method throws', () {
      expect(
        () => glinetLoginHash(
          username: 'root',
          cipherPassword: 'x',
          nonce: 'y',
          hashMethod: 'sha1',
        ),
        throwsArgumentError,
      );
    });
  });
}
