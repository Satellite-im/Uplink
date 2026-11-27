import 'dart:convert';
import '../aside.dart';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

import '../net/crypto.dart';
import 'argon2_browser.dart';
import 'bip39_words.dart';
import 'gzip.dart';
import '../net/fast_gcm.dart';

/// The cryptography of an Uplink account (Matt, 2026-11-17: "We need to have a way to login to existing accounts. We might
/// need to add password based authentication as well as SMS verification for verified numbers", and "i also want
/// accounts to be generated based on ethereum type addresses with a recovery seed we can back up"):
///
/// - **Recovery words**: twelve BIP-39 words, 128 bits from the system's secure random. Twelve rather than twenty-four
///   because 128 bits is already the strength of the secp256k1 key they make (an attacker's best is about 2^128 either
///   way), and every extra word written down by hand is another chance to copy one wrong.
/// - **The account's address**: the words' BIP-39 seed (PBKDF2-HMAC-SHA512, 2048 rounds, salt "mnemonic"), BIP-32 down
///   m/44'/60'/0'/0/0 as Ethereum wallets go, and the address of that secp256k1 key: Keccak-256 of the 64-byte public
///   key, its last 20 bytes, written 0x… with EIP-55's capitals. The same words in MetaMask show the same address.
/// - **The Uplink identity** (the P-256 key an install is known by, [NetKeys]) made from the same seed by HKDF-SHA256 with
///   its own label, so a device restored from the words alone is the same Uplink identity where the account began with
///   it. An install that had its own key before it made an account keeps that key, carried in the sealed backup.
/// - **The backup** (identity, words, profile) sealed twice with AES-256-GCM: once under a key from the password
///   (Argon2id, 64 MiB, 3 passes, 1 lane, 16-byte salt) and once under a key from the seed (HKDF-SHA256), so either one
///   opens it. The relay keeps the two sealed blobs and can open neither.
class AccountCrypto {
  /// The curve the account's own key is on, as Ethereum's are.
  static final ECDomainParameters k1 = ECCurve_secp256k1();

  // --- recovery words (BIP-39) -----------------------------------------------------------------------------------------

  /// Twelve new words: 16 bytes from the secure random, and the first 4 bits of their SHA-256 as the checksum.
  static List<String> newWords() => wordsOf(NetCrypto.randomBytes(16));

  /// The words that spell [entropy] (16 to 32 bytes, a multiple of 4).
  static List<String> wordsOf(List<int> entropy) {
    if (entropy.length < 16 || entropy.length > 32 || entropy.length % 4 != 0) throw ArgumentError('entropy');
    final checkBits = entropy.length * 8 ~/ 32;
    final hash = NetCrypto.sha256(entropy);
    final bits = StringBuffer();
    for (final b in entropy) {
      bits.write((b & 0xff).toRadixString(2).padLeft(8, '0'));
    }
    bits.write(hash[0].toRadixString(2).padLeft(8, '0').substring(0, checkBits));
    final all = bits.toString();
    return [for (var i = 0; i < all.length; i += 11) bip39English[int.parse(all.substring(i, i + 11), radix: 2)]];
  }

  /// The words as typed, tidied: lower case, one space between, nothing around.
  static List<String> tidyWords(String typed) => typed.trim().toLowerCase().split(RegExp(r'[\s,]+')).where((w) => w.isNotEmpty).toList();

  /// Each word's place in the list, which is its 11-bit number.
  static final Map<String, int> _index = {for (var i = 0; i < bip39English.length; i++) bip39English[i]: i};

  /// Whether [word] is one of the 2048.
  static bool isWord(String word) => _index.containsKey(word);

  /// The bytes [words] spell, or null where they are not 12, 15, 18, 21 or 24 of the list's words with a checksum that
  /// adds up (one copied wrong, two swapped).
  static Uint8List? entropyOf(List<String> words) {
    if (words.length < 12 || words.length > 24 || words.length % 3 != 0) return null;
    final bits = StringBuffer();
    for (final w in words) {
      final i = _index[w];
      if (i == null) return null;
      bits.write(i.toRadixString(2).padLeft(11, '0'));
    }
    final all = bits.toString();
    final checkBits = all.length ~/ 33;
    final entropyBits = all.length - checkBits;
    final entropy = Uint8List.fromList([for (var i = 0; i < entropyBits; i += 8) int.parse(all.substring(i, i + 8), radix: 2)]);
    final want = NetCrypto.sha256(entropy)[0].toRadixString(2).padLeft(8, '0').substring(0, checkBits);
    return all.substring(entropyBits) == want ? entropy : null;
  }

  /// Whether [words] are recovery words whose checksum adds up ([entropyOf]).
  static bool validWords(List<String> words) => entropyOf(words) != null;

  /// BIP-39's seed: PBKDF2-HMAC-SHA512 of the words joined by spaces, salted "mnemonic" and [passphrase], 2048 rounds,
  /// 64 bytes. Uplink never asks for a passphrase; it is here for the BIP's own test vectors. The words are the list's,
  /// all ASCII, so NFKD changes nothing.
  static Uint8List seedOf(List<String> words, {String passphrase = ''}) {
    final kdf = PBKDF2KeyDerivator(HMac(SHA512Digest(), 128))..init(Pbkdf2Parameters(Uint8List.fromList(utf8.encode('mnemonic$passphrase')), 2048, 64));
    return kdf.process(Uint8List.fromList(utf8.encode(words.join(' '))));
  }

  // --- the account key (BIP-32, secp256k1) ----------------------------------------------------------------------------

  /// Ethereum's first account's path: m/44'/60'/0'/0/0.
  static const ethPath = [0x8000002C, 0x8000003C, 0x80000000, 0, 0];

  // HMAC-SHA512; bytes read as a big-endian number; and a number written as [n] big-endian bytes.
  static Uint8List _hmac512(List<int> key, List<int> data) => (HMac(SHA512Digest(), 128)..init(KeyParameter(Uint8List.fromList(key)))).process(Uint8List.fromList(data));
  static BigInt _int(List<int> b) => b.fold(BigInt.zero, (v, x) => (v << 8) | BigInt.from(x & 0xff));
  static Uint8List _fixed(BigInt v, [int n = 32]) => Uint8List.fromList([for (var i = n - 1; i >= 0; i--) ((v >> (8 * i)) & BigInt.from(0xff)).toInt()]);

  /// The private key (32 bytes) BIP-32 makes from [seed] down [path] (an index of 2^31 or more is hardened).
  static Uint8List derive(List<int> seed, List<int> path) {
    var i = _hmac512(utf8.encode('Bitcoin seed'), seed);
    var key = _int(i.sublist(0, 32));
    var chain = i.sublist(32);
    final n = k1.n;
    if (key == BigInt.zero || key >= n) throw StateError('unusable seed');
    for (final index in path) {
      final data = index >= 0x80000000 ? [0, ..._fixed(key)] : publicOf(_fixed(key), compressed: true);
      i = _hmac512(chain, [...data, (index >> 24) & 0xff, (index >> 16) & 0xff, (index >> 8) & 0xff, index & 0xff]);
      final tweak = _int(i.sublist(0, 32));
      // A tweak past n, or a key of nothing, is one in 2^127: BIP-32 says go to the next index, which no wallet does.
      if (tweak >= n) throw StateError('unusable index');
      key = (tweak + key) % n;
      if (key == BigInt.zero) throw StateError('unusable index');
      chain = i.sublist(32);
    }
    return _fixed(key);
  }

  /// secp256k1's public key of [scalar]: 65 bytes (04, x, y), or 33 [compressed].
  static Uint8List publicOf(List<int> scalar, {bool compressed = false}) => (k1.G * _int(scalar))!.getEncoded(compressed);

  /// Keccak-256 (Ethereum's, not SHA3-256's padding).
  static Uint8List keccak(List<int> data) => KeccakDigest(256).process(Uint8List.fromList(data));

  /// The address of a 65-byte public key: Keccak-256 of x and y, its last 20 bytes, as EIP-55 writes it.
  static String addressOf(List<int> public65) => checksummed(NetCrypto.hex(keccak(public65.sublist(1)).sublist(12)));

  /// EIP-55: each letter of the hex capitalised where the Keccak-256 of the lower-case hex has a nibble of 8 or more.
  static String checksummed(String hex40) {
    final lower = hex40.toLowerCase().replaceFirst('0x', '');
    final hash = NetCrypto.hex(keccak(utf8.encode(lower)));
    final out = StringBuffer('0x');
    for (var i = 0; i < lower.length; i++) {
      final c = lower[i];
      out.write(int.parse(hash[i], radix: 16) >= 8 ? c.toUpperCase() : c);
    }
    return out.toString();
  }

  static final _addressShape = RegExp(r'^0x[0-9a-fA-F]{40}$');

  /// Whether [address] is 0x and 40 hex digits whose capitals, where it has any, are EIP-55's.
  static bool goodAddress(String address) {
    if (!_addressShape.hasMatch(address)) return false;
    final body = address.substring(2);
    if (body == body.toLowerCase() || body == body.toUpperCase()) return true;
    return checksummed(body) == address;
  }

  // --- signing as the account (what the relay checks) --------------------------------------------------------------

  /// What is signed for [message]: Keccak-256 of EIP-191's personal-message form, as a wallet's personal_sign makes it.
  static Uint8List personalHash(List<int> message) => keccak([...utf8.encode('\x19Ethereum Signed Message:\n${message.length}'), ...message]);

  /// [scalar]'s signature over [message] (EIP-191): r, s (the low one) and v (27 or 28), 65 bytes, recoverable to the
  /// address. k is RFC 6979's, so the same message signs the same.
  static Uint8List sign(List<int> scalar, List<int> message) {
    final hash = personalHash(message);
    final d = _int(scalar);
    final signer = ECDSASigner(null, HMac(SHA256Digest(), 64))..init(true, PrivateKeyParameter<ECPrivateKey>(ECPrivateKey(d, k1)));
    final sig = signer.generateSignature(hash) as ECSignature;
    var s = sig.s;
    if (s > k1.n >> 1) s = k1.n - s;
    final own = publicOf(scalar);
    for (var v = 0; v < 2; v++) {
      final back = recover(hash, sig.r, s, v);
      if (back != null && _same(back, own)) return Uint8List.fromList([..._fixed(sig.r), ..._fixed(s), 27 + v]);
    }
    throw StateError('no recovery id');
  }

  static bool _same(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// The 65-byte public key that signed [hash] as (r, s) with recovery id [v] (0 or 1), or null (SEC 1, 4.1.6).
  static Uint8List? recover(List<int> hash, BigInt r, BigInt s, int v) {
    final n = k1.n;
    if (r <= BigInt.zero || r >= n || s <= BigInt.zero || s >= n) return null;
    try {
      final big = k1.curve.decodePoint([2 + (v & 1), ..._fixed(r)]);
      if (big == null) return null;
      final e = _int(hash);
      final ri = r.modInverse(n);
      final q = ((big * s)! + (k1.G * ((n - e) % n))!)! * ri;
      if (q == null || q.isInfinity) return null;
      return q.getEncoded(false);
    } catch (_) {
      return null;
    }
  }

  /// The address that signed [message] with [signature] (65 bytes from [sign]), or null.
  static String? signer(List<int> message, List<int> signature) {
    if (signature.length != 65) return null;
    final v = signature[64] >= 27 ? signature[64] - 27 : signature[64];
    if (v != 0 && v != 1) return null;
    final pub = recover(personalHash(message), _int(signature.sublist(0, 32)), _int(signature.sublist(32, 64)), v);
    return pub == null ? null : addressOf(pub);
  }

  // --- what the seed makes besides the address ---------------------------------------------------------------------

  /// HKDF-SHA256 (RFC 5869) of [ikm] under [salt] and [info], [length] bytes.
  static Uint8List hkdf(List<int> ikm, String salt, String info, {int length = 32}) {
    final prk = NetCrypto.hmac(utf8.encode(salt), ikm);
    final out = <int>[];
    var block = <int>[];
    for (var i = 1; out.length < length; i++) {
      block = NetCrypto.hmac(prk, [...block, ...utf8.encode(info), i]);
      out.addAll(block);
    }
    return Uint8List.fromList(out.sublist(0, length));
  }

  /// HKDF's salt for everything the seed makes here; each use has a label of its own.
  static const _salt = 'ghost-account v1';

  /// The Uplink identity the seed makes: a P-256 scalar from HKDF, tried again with a counter in the rare case (one in
  /// 2^32) it is nothing or past the curve's order.
  static NetKeys identityOf(List<int> seed) {
    final n = NetCrypto.curve.n;
    for (var i = 0;; i++) {
      final d = hkdf(seed, _salt, 'ghost identity p256 v1|$i');
      final v = _int(d);
      if (v > BigInt.zero && v < n) return NetKeys.fromScalar(d);
    }
  }

  /// The key the seed's copy of the backup is sealed with.
  static Uint8List seedSealKey(List<int> seed) => hkdf(seed, _salt, 'ghost backup seal v1');

  // --- the password ----------------------------------------------------------------------------------------------------

  /// Argon2id's settings for a password (RFC 9106's second recommendation, with one lane since Dart runs it on one
  /// thread): 64 MiB, 3 passes. About half a second on a Mac and one to two on a phone, in an isolate so nothing stalls.
  static const argonMemoryKiB = 64 * 1024, argonPasses = 3, argonLanes = 1;

  /// The key [password] makes under [salt] with those settings (or the ones a blob names).
  static Uint8List passwordKey(String password, List<int> salt, {int memoryKiB = argonMemoryKiB, int passes = argonPasses, int lanes = argonLanes}) {
    final g = Argon2BytesGenerator()..init(Argon2Parameters(Argon2Parameters.ARGON2_id, Uint8List.fromList(salt), desiredKeyLength: 32, iterations: passes, memory: memoryKiB, lanes: lanes, version: Argon2Parameters.ARGON2_VERSION_13));
    return g.process(Uint8List.fromList(utf8.encode(password)));
  }

  /// [passwordKey] off the main isolate: a phone's frames go on while 64 MiB are worked through.
  static Future<Uint8List> passwordKeyAway(String password, List<int> salt, {int memoryKiB = argonMemoryKiB, int passes = argonPasses, int lanes = argonLanes}) {
    final s = Uint8List.fromList(salt);
    // In a browser the browser's own JavaScript does it, on a worker (argon2_browser.dart): Dart there would take most
    // of a minute with the page frozen. Dart's all the same where that can't be had, since a slow sign-in is one still.
    final browsers = browserArgon2id(Uint8List.fromList(utf8.encode(password)), s, memoryKiB: memoryKiB, passes: passes, lanes: lanes);
    if (browsers != null) return browsers.then((key) => key, onError: (Object _) => passwordKey(password, s, memoryKiB: memoryKiB, passes: passes, lanes: lanes));
    return runAside(() => passwordKey(password, s, memoryKiB: memoryKiB, passes: passes, lanes: lanes));
  }

  // --- sealing ---------------------------------------------------------------------------------------------------------

  /// What a sealed copy is bound to: the account's address and which copy it is ('password' or 'seed').
  static Uint8List _aad(String address, String kind) => Uint8List.fromList(utf8.encode('ghost-account v1|${address.toLowerCase()}|$kind'));

  /// [clear] under [key]: 12 random bytes, then AES-256-GCM's output with its tag; the address and kind are bound in, so
  /// a blob moved to another account or swapped between the two kinds does not open.
  static Uint8List gcmSeal(List<int> key, List<int> clear, String address, String kind) {
    final nonce = NetCrypto.randomBytes(12);
    return Uint8List.fromList([...nonce, ...FastGcm(key).seal(nonce, _aad(address, kind), Uint8List.fromList(clear))]);
  }

  /// What [gcmSeal] sealed, opened; null where the key, the address or the kind is not the one it was sealed with.
  static Uint8List? gcmOpen(List<int> key, List<int> sealed, String address, String kind) {
    if (sealed.length < 28) return null;
    try {
      return FastGcm(key).open(Uint8List.fromList(sealed.sublist(0, 12)), _aad(address, kind), Uint8List.fromList(sealed.sublist(12)));
    } catch (_) {
      return null;
    }
  }

  /// The password's copy: `{"v":1,"k":"argon2id","m":KiB,"t":passes,"p":lanes,"s":salt,"c":sealed}` as JSON, base64
  /// inside. The settings travel with it so they can be raised later without stranding old blobs.
  static Future<String> sealWithPassword(AccountBackup backup, String password, String address, {int memoryKiB = argonMemoryKiB, int passes = argonPasses}) async =>
      sealWithPasswordKey(backup, await PasswordKey.make(password, memoryKiB: memoryKiB, passes: passes), address);

  /// The same, with the key the password already made: no Argon2 run.
  static String sealWithPasswordKey(AccountBackup backup, PasswordKey key, String address) =>
      jsonEncode({'v': 1, 'k': 'argon2id', 'm': key.memoryKiB, 't': key.passes, 'p': key.lanes, 's': base64Encode(key.salt), 'c': base64Encode(gcmSeal(key.key, backup.pack(), address, 'password'))});

  /// What [blob] holds, opened with [password]; null where the password is not the one, or the blob is not one.
  static Future<AccountBackup?> openWithPassword(String blob, String password, String address) async {
    final key = await PasswordKey.forBlob(blob, password);
    return key == null ? null : openWithPasswordKey(blob, key, address);
  }

  /// The same, with the key the password already made.
  static AccountBackup? openWithPasswordKey(String blob, PasswordKey key, String address) {
    try {
      final m = jsonDecode(blob) as Map;
      if (m['v'] != 1 || m['k'] != 'argon2id') return null;
      final clear = gcmOpen(key.key, base64Decode(m['c'] as String), address, 'password');
      return clear == null ? null : AccountBackup.unpack(clear);
    } catch (_) {
      return null;
    }
  }

  /// The seed's copy: `{"v":1,"k":"seed","c":sealed}`.
  static String sealWithSeed(AccountBackup backup, List<int> seed, String address) =>
      jsonEncode({'v': 1, 'k': 'seed', 'c': base64Encode(gcmSeal(seedSealKey(seed), backup.pack(), address, 'seed'))});

  /// What the seed's copy holds; null where [blob] is not one, or [seed] is not the one it was sealed with.
  static AccountBackup? openWithSeed(String blob, List<int> seed, String address) {
    try {
      final m = jsonDecode(blob) as Map;
      if (m['v'] != 1 || m['k'] != 'seed') return null;
      final clear = gcmOpen(seedSealKey(seed), base64Decode(m['c'] as String), address, 'seed');
      return clear == null ? null : AccountBackup.unpack(clear);
    } catch (_) {
      return null;
    }
  }

  /// The proof that the Uplink identity [identity] belongs to the account at [address]: its P-256 signature, which the
  /// relay checks with the key the identity is known by.
  static Uint8List bindProof(NetKeys identity, String address) => NetCrypto.sign(identity, utf8.encode('ghost-account bind v1|${address.toLowerCase()}'));
}

/// What both sealed copies hold: who this account is on Uplink and what a new device needs to be it.
class AccountBackup {
  AccountBackup({required this.words, required this.identity, this.mode = 'seed', this.username = '', this.displayName = '', this.bio = '', this.keptKey = '', this.friends = const [], this.circles = const [], DateTime? at}) : at = at ?? DateTime.now();

  /// The recovery words (a password alone then also gives back the words, for "show my recovery words").
  final List<String> words;

  /// The Uplink identity's private key, 32 bytes as hex: the seed's own ('seed'), or the install's from before ('bound').
  final String identity;
  final String mode;
  final String username;
  final String displayName;
  final String bio;

  /// The key Uplink's own lists kept on the relay are sealed with (lib/me/me.dart's kept_key), so they open again.
  final String keptKey;

  /// Friends by username and circles, as each keeps itself (Buddy.toJson, Circle.toJson), when this was sealed.
  final List<Object?> friends;
  final List<Object?> circles;
  final DateTime at;

  Map<String, Object?> toJson() => {
        'v': 1,
        'w': words.join(' '),
        'i': identity,
        'm': mode,
        'u': username,
        'n': displayName,
        'b': bio,
        'k': keptKey,
        'f': friends,
        'c': circles,
        'at': at.millisecondsSinceEpoch,
      };

  /// The backup [j] is; null where it is another version, or has no words or identity.
  static AccountBackup? fromJson(Object? j) {
    if (j is! Map || j['v'] != 1 || j['w'] is! String || j['i'] is! String) return null;
    return AccountBackup(
      words: (j['w'] as String).split(' '),
      identity: j['i'] as String,
      mode: (j['m'] as String?) ?? 'seed',
      username: (j['u'] as String?) ?? '',
      displayName: (j['n'] as String?) ?? '',
      bio: (j['b'] as String?) ?? '',
      keptKey: (j['k'] as String?) ?? '',
      friends: (j['f'] as List?) ?? const [],
      circles: (j['c'] as List?) ?? const [],
      at: j['at'] is num ? DateTime.fromMillisecondsSinceEpoch((j['at'] as num).toInt()) : null,
    );
  }

  /// The JSON, gzipped: friends and circles compress well, and the relay keeps a limited size.
  Uint8List pack() => Uint8List.fromList(gzip.encode(utf8.encode(jsonEncode(toJson()))));

  /// What [pack] made, read back; null where it isn't one.
  static AccountBackup? unpack(List<int> bytes) {
    try {
      return fromJson(jsonDecode(utf8.decode(gzip.decode(bytes))));
    } catch (_) {
      return null;
    }
  }

  /// This backup with the parts given changed. The words, identity and mode stay; it is dated now.
  AccountBackup copyWith({List<Object?>? friends, List<Object?>? circles, String? username, String? displayName, String? bio, String? keptKey}) => AccountBackup(
        words: words,
        identity: identity,
        mode: mode,
        username: username ?? this.username,
        displayName: displayName ?? this.displayName,
        bio: bio ?? this.bio,
        keptKey: keptKey ?? this.keptKey,
        friends: friends ?? this.friends,
        circles: circles ?? this.circles,
      );
}

/// The key a password makes for the backup, with the salt and settings it was made under. Kept in the install's
/// secure storage beside the words once the password has been typed on this device, so the backup can be sealed again
/// as friends and circles change without asking for the password each time; it opens no more than the words beside it.
class PasswordKey {
  PasswordKey(this.key, this.salt, {this.memoryKiB = AccountCrypto.argonMemoryKiB, this.passes = AccountCrypto.argonPasses, this.lanes = AccountCrypto.argonLanes});
  final Uint8List key;
  final Uint8List salt;
  final int memoryKiB, passes, lanes;

  /// A new salt and the key [password] makes under it.
  static Future<PasswordKey> make(String password, {int memoryKiB = AccountCrypto.argonMemoryKiB, int passes = AccountCrypto.argonPasses}) async {
    final salt = NetCrypto.randomBytes(16);
    return PasswordKey(await AccountCrypto.passwordKeyAway(password, salt, memoryKiB: memoryKiB, passes: passes), salt, memoryKiB: memoryKiB, passes: passes);
  }

  /// The proof that whoever has this key knows the password: what the relay is shown before it hands the password's
  /// copy over (relay/lib/accounts.dart's `acct-get`). HKDF of the key under its own label, so it opens nothing.
  Uint8List get auth => AccountCrypto.hkdf(key, 'ghost-account v1', 'password auth v1');

  /// The SHA-256 of [auth], as the relay keeps it (`pwv`), in hex.
  String get verifier => NetCrypto.hex(NetCrypto.sha256(auth));

  /// The key [password] makes under the salt and settings [blob] names; null where it names none or too much.
  static Future<PasswordKey?> forBlob(String blob, String password) async {
    try {
      return await forKdf(jsonDecode(blob) as Map, password);
    } catch (_) {
      return null;
    }
  }

  /// The same from the settings and salt alone (`{"v":1,"k":"argon2id","m","t","p","s"}`), as `acct-find` gives them.
  static Future<PasswordKey?> forKdf(Map m, String password) async {
    try {
      if (m['v'] != 1 || m['k'] != 'argon2id') return null;
      final memory = (m['m'] as num).toInt(), passes = (m['t'] as num).toInt(), lanes = (m['p'] as num).toInt();
      // Settings past these would be someone making the phone spend minutes or run out of memory.
      if (memory < 8 * 1024 || memory > 256 * 1024 || passes < 1 || passes > 10 || lanes < 1 || lanes > 4) return null;
      final salt = base64Decode(m['s'] as String);
      if (salt.length < 16) return null;
      return PasswordKey(await AccountCrypto.passwordKeyAway(password, salt, memoryKiB: memory, passes: passes, lanes: lanes), salt, memoryKiB: memory, passes: passes, lanes: lanes);
    } catch (_) {
      return null;
    }
  }

  /// As kept in the install's secure storage: the key itself, with its salt and settings.
  String toJson() => jsonEncode({'k': base64Encode(key), 's': base64Encode(salt), 'm': memoryKiB, 't': passes, 'p': lanes});

  static PasswordKey? fromJson(String? text) {
    if (text == null || text.isEmpty) return null;
    try {
      final m = jsonDecode(text) as Map;
      return PasswordKey(base64Decode(m['k'] as String), base64Decode(m['s'] as String), memoryKiB: (m['m'] as num).toInt(), passes: (m['t'] as num).toInt(), lanes: (m['p'] as num).toInt());
    } catch (_) {
      return null;
    }
  }
}
