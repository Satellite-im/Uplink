import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/account/account_crypto.dart';
import 'package:ghost_messaging/account/bip39_words.dart';
import 'package:ghost_messaging/net/crypto.dart';
import 'package:ghost_relay/keccak.dart' as relay_keccak;
import 'package:ghost_relay/secp256k1.dart';
import 'package:pointycastle/export.dart' show Argon2BytesGenerator, Argon2Parameters;

/// An Uplink account's cryptography (lib/account/account_crypto.dart; Matt, 2026-11-17: "i also want accounts to be
/// generated based on ethereum type addresses with a recovery seed we can back up") held to the published vectors, so
/// the words written down open the same address in any BIP-39 wallet, and to the relay's own arithmetic, so what the
/// app signs is what the relay recovers.
void main() {
  final abandon = [...List.filled(11, 'abandon'), 'about'];

  group('BIP-39', () {
    test('the wordlist is the BIP\'s, unchanged', () {
      expect(bip39English.length, 2048);
      final text = '${bip39English.join('\n')}\n';
      expect(NetCrypto.hex(NetCrypto.sha256(utf8.encode(text))), '2f5eed53a4727b4bf8880d8f3f199efc90e58503646d9ff8eff3a2ed3b24dbda');
    });

    test('entropy to words and back (Trezor\'s vectors)', () {
      expect(AccountCrypto.wordsOf(Uint8List(16)), abandon);
      expect(AccountCrypto.wordsOf(List.filled(16, 0x7f)).join(' '), 'legal winner thank year wave sausage worth useful legal winner thank yellow');
      expect(AccountCrypto.wordsOf(List.filled(16, 0xff)).join(' '), 'zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo wrong');
      expect(AccountCrypto.wordsOf(Uint8List(32)).join(' '), '${List.filled(23, 'abandon').join(' ')} art');
      expect(AccountCrypto.entropyOf(abandon), Uint8List(16));
    });

    test('the seed (Trezor\'s vectors, passphrase TREZOR; and none, as Uplink uses it)', () {
      expect(NetCrypto.hex(AccountCrypto.seedOf(abandon, passphrase: 'TREZOR')),
          'c55257c360c07c72029aebc1b53c05ed0362ada38ead3e3e9efa3708e53495531f09a6987599d18264c1e1c92f2cf141630c7a3c4ab7c81b2f001698e7463b04');
      expect(NetCrypto.hex(AccountCrypto.seedOf(abandon)),
          '5eb00bbddcf069084889a8ab9155568165f5c453ccb85e70811aaed6f6da5fc19a5ac40b389cd370d086206dec8aa6c43daea6690f20ad3d8d48b2d2ce9e38e4');
    });

    test('a word copied wrong, two swapped, or one missing does not pass', () {
      expect(AccountCrypto.validWords(abandon), isTrue);
      expect(AccountCrypto.validWords([...List.filled(12, 'abandon')]), isFalse, reason: 'checksum');
      expect(AccountCrypto.validWords([...abandon.sublist(0, 11)]), isFalse);
      expect(AccountCrypto.validWords([...abandon.sublist(0, 11), 'abut']), isFalse, reason: 'not a list word');
      final words = AccountCrypto.newWords();
      expect(words.length, 12);
      expect(AccountCrypto.validWords(words), isTrue);
      expect(AccountCrypto.tidyWords('  Abandon,abandon\n ABOUT '), ['abandon', 'abandon', 'about']);
    });
  });

  group('BIP-32 and the address', () {
    test('BIP-32 test vector 1', () {
      final seed = NetCrypto.unhex('000102030405060708090a0b0c0d0e0f');
      expect(NetCrypto.hex(AccountCrypto.derive(seed, const [])), 'e8f32e723decf4051aefac8e2c93c9c5b214313817cdb01a1494b917c8436b35');
      expect(NetCrypto.hex(AccountCrypto.derive(seed, const [0x80000000])), 'edb2e14f9ee77d26dd93b4ecede8d16ed408ce149b6cd80b0715a2d911a0afea');
      expect(NetCrypto.hex(AccountCrypto.derive(seed, const [0x80000000, 1])), '3c6cb8d0f6a264c91ea8b5030fadaa8e538b020f0a387421a12de9319dc93368');
    });

    test('"abandon … about" is 0x9858EfFD232B4033E47d90003D41EC34EcaEda94 at m/44\'/60\'/0\'/0/0, as in every Ethereum wallet', () {
      final key = AccountCrypto.derive(AccountCrypto.seedOf(abandon), AccountCrypto.ethPath);
      expect(NetCrypto.hex(key), '1ab42cc412b618bdea3a599e3c9bae199ebf030895b039e9db1e30dafb12b727');
      expect(AccountCrypto.addressOf(AccountCrypto.publicOf(key)), '0x9858EfFD232B4033E47d90003D41EC34EcaEda94');
    });

    test('EIP-55\'s own examples', () {
      for (final a in ['0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed', '0xfB6916095ca1df60bB79Ce92cE3Ea74c37c5d359', '0xdbF03B407c01E7cD3CBea99509d93f8DDDC8C6FB', '0xD1220A0cf47c7B9Be7A2E6BA89F429762e7b9aDb']) {
        expect(AccountCrypto.checksummed(a.toLowerCase()), a);
        expect(AccountCrypto.goodAddress(a), isTrue);
      }
      expect(AccountCrypto.goodAddress('0x5aaeb6053F3E94C9b9A09f33669435E7Ef1BeAed'), isFalse, reason: 'one capital dropped');
      expect(AccountCrypto.keccak(const []), NetCrypto.unhex('c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470'));
    });
  });

  group('signing as the account', () {
    test('a signature recovers to the address, in the app and in the relay', () {
      final key = AccountCrypto.derive(AccountCrypto.seedOf(abandon), AccountCrypto.ethPath);
      final message = utf8.encode('{"op":"put","a":"0x9858EfFD232B4033E47d90003D41EC34EcaEda94"}');
      final sig = AccountCrypto.sign(key, message);
      expect(sig.length, 65);
      expect(AccountCrypto.signer(message, sig), '0x9858EfFD232B4033E47d90003D41EC34EcaEda94');
      expect(Secp256k1.signer(message, sig), '0x9858effd232b4033e47d90003d41ec34ecaeda94', reason: 'the relay\'s own BigInt arithmetic');
      final bent = Uint8List.fromList(message)..[3] ^= 1;
      expect(Secp256k1.signer(bent, sig), isNot('0x9858effd232b4033e47d90003d41ec34ecaeda94'));
      expect(AccountCrypto.sign(key, message), sig, reason: 'RFC 6979: the same message signs the same');
    });

    test('a signature is in the form wallets make: low s, v of 27 or 28', () {
      final key = AccountCrypto.derive(AccountCrypto.seedOf(abandon), AccountCrypto.ethPath);
      for (final words in ['hello world', '', 'x' * 300]) {
        final sig = AccountCrypto.sign(key, utf8.encode(words));
        final s = BigInt.parse(NetCrypto.hex(sig.sublist(32, 64)), radix: 16);
        expect(s <= AccountCrypto.k1.n >> 1, isTrue);
        expect([27, 28], contains(sig[64]));
        expect(Secp256k1.signer(utf8.encode(words), sig), '0x9858effd232b4033e47d90003d41ec34ecaeda94');
      }
    });

    test('the relay\'s Keccak agrees with pointycastle\'s at every length around the rate', () {
      for (final n in [0, 1, 55, 135, 136, 137, 271, 272, 1000]) {
        final data = List.generate(n, (i) => (i * 31 + 7) & 0xff);
        expect(relay_keccak.keccak256(data), AccountCrypto.keccak(data), reason: '$n bytes');
      }
    });
  });

  group('what the seed makes', () {
    test('the same words make the same Uplink identity, and other words another', () {
      final seed = AccountCrypto.seedOf(abandon);
      final a = AccountCrypto.identityOf(seed), b = AccountCrypto.identityOf(seed);
      expect(a.id, b.id);
      expect(a.public.length, 33);
      expect(AccountCrypto.identityOf(AccountCrypto.seedOf(AccountCrypto.newWords())).id, isNot(a.id));
      // The identity key and the seal key are not the account key, nor each other.
      expect(NetCrypto.hex(a.scalar), isNot(NetCrypto.hex(AccountCrypto.seedSealKey(seed))));
      expect(NetCrypto.hex(a.scalar), isNot(NetCrypto.hex(AccountCrypto.derive(seed, AccountCrypto.ethPath))));
    });

    test('HKDF-SHA256 is RFC 5869\'s (test case 3: no salt, no info)', () {
      final okm = AccountCrypto.hkdf(List.filled(22, 0x0b), '', '', length: 42);
      expect(NetCrypto.hex(okm), '8da4e775a563c18f715f802a063c5a31b8a11f5c5ee1879ec3454e5f3c738d2d9d201395faa4b61a96c8');
    });
  });

  group('Argon2id and sealing', () {
    test('pointycastle\'s Argon2id gives RFC 9106\'s test vector', () {
      final g = Argon2BytesGenerator()
        ..init(Argon2Parameters(Argon2Parameters.ARGON2_id, Uint8List.fromList(List.filled(16, 2)),
            desiredKeyLength: 32, secret: Uint8List.fromList(List.filled(8, 3)), additional: Uint8List.fromList(List.filled(12, 4)), iterations: 3, memory: 32, lanes: 4, version: Argon2Parameters.ARGON2_VERSION_13));
      expect(NetCrypto.hex(g.process(Uint8List.fromList(List.filled(32, 1)))), '0d640df58d78766c08c037a34a8b53c9d01ef0452d75b65eb52520e96b01e659');
    });

    final backup = AccountBackup(words: abandon, identity: NetCrypto.hex(NetKeys.generate().scalar), mode: 'bound', username: 'maya', displayName: 'Maya Chen', bio: 'hi', keptKey: 'ab' * 32, friends: const [{'u': 'sam', 'i': '00', 'k': 'AA=='}], circles: const []);
    const address = '0x9858EfFD232B4033E47d90003D41EC34EcaEda94';

    test('sealed with the password, opened with it; a wrong password does not open it', () async {
      final blob = await AccountCrypto.sealWithPassword(backup, 'correct horse battery', address, memoryKiB: 8 * 1024, passes: 1);
      final m = jsonDecode(blob) as Map;
      expect(m['k'], 'argon2id');
      expect(blob.contains('maya'), isFalse);
      final back = await AccountCrypto.openWithPassword(blob, 'correct horse battery', address);
      expect(back!.words, abandon);
      expect(back.identity, backup.identity);
      expect(back.username, 'maya');
      expect(back.friends.length, 1);
      expect(await AccountCrypto.openWithPassword(blob, 'correct horse batterY', address), isNull);
      expect(await AccountCrypto.openWithPassword(blob, 'correct horse battery', '0x0000000000000000000000000000000000000001'), isNull, reason: 'bound to its address');
    });

    test('sealed with the seed, opened with it; another seed does not open it, nor is it the password\'s', () async {
      final seed = AccountCrypto.seedOf(abandon);
      final blob = AccountCrypto.sealWithSeed(backup, seed, address);
      expect(AccountCrypto.openWithSeed(blob, seed, address)!.identity, backup.identity);
      expect(AccountCrypto.openWithSeed(blob, AccountCrypto.seedOf(AccountCrypto.newWords()), address), isNull);
      expect(await AccountCrypto.openWithPassword(blob, 'anything', address), isNull);
    });

    test('the default settings are the ones said, and take a believable time here', () async {
      expect((AccountCrypto.argonMemoryKiB, AccountCrypto.argonPasses, AccountCrypto.argonLanes), (65536, 3, 1));
      final watch = Stopwatch()..start();
      await AccountCrypto.passwordKeyAway('pw', Uint8List(16));
      // ignore: avoid_print
      print('Argon2id 64 MiB, 3 passes: ${watch.elapsedMilliseconds} ms');
      expect(watch.elapsed, lessThan(const Duration(seconds: 20)));
    });

    test('the bind proof is the identity\'s P-256 signature, as the relay checks it', () {
      final id = NetKeys.generate();
      final proof = AccountCrypto.bindProof(id, address);
      expect(NetCrypto.verify(id.public, utf8.encode('ghost-account bind v1|${address.toLowerCase()}'), proof), isTrue);
    });
  });
}
