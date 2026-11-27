import 'dart:async';
import 'dart:convert';
import '../platform_info.dart';

import 'package:flutter/foundation.dart';

import 'dart:io' show Directory;

import '../circles/circles.dart';
import '../files/files_store.dart' show FilesStore;
import '../friends/buddies.dart';
import '../friends/friends.dart';
import '../inbox/account_helper.dart' show AccountHelper;
import '../inbox/inbox.dart' show Inbox, InboxNetwork;
import '../me/lookup_budget.dart';
import '../me/me.dart';
import '../net/carrier.dart';
import '../net/crypto.dart';
import '../net/forward_secrecy.dart' show ForwardSecrecy;
import '../net/hub_carrier.dart';
import '../net/ledger.dart' show Ledger;
import '../net/name_watch.dart' show NameWatch;
import '../net/net.dart';
import '../net/p2p/p2p.dart';
import '../sms.dart';
import '../voice/channels.dart' show Voice;
import 'account_crypto.dart';

/// An Uplink account on this install (Matt, 2026-11-17: "We need to have a way to login to existing accounts. We might
/// need to add password based authentication as well as SMS verification for verified numbers"; "I like your
/// recommendation let's do it for now"; "i also want accounts to be generated based on ethereum type addresses with a
/// recovery seed we can back up").
///
/// - **Making one** ([draft], then [create]): twelve recovery words, the address they make (the account's id), a password.
///   The Uplink identity is the words' own where this install has nothing yet (no username, friends or circles), and
///   then the install takes it on and starts again; elsewhere it is the key the install already has, so nobody who
///   knows it has to add it again. Either way the identity and the words go in a backup sealed with the password and
///   with the words, kept on the relay (relay/lib/accounts.dart), and the device is listed under the account.
/// - **Signing in** ([findByName], [textCode], [signInWithPassword]; or [signInWithWords]) opens the backup, then
///   [finish] makes its identity this install's, puts its profile, friends and circles in place, and starts the app
///   again from nothing, so nothing goes on as the fresh install it was.
/// - **On this device**: the address and this device's number in the preferences, the password's sealed copy there
///   too (it is sealed; it is what "show my recovery words" and a new password open), and the words in the install's
///   secure storage (Android's Keystore-sealed vault, the Keychain), never in the preferences. A page in a browser
///   keeps no words and no password key at all ([keepsWords]): it opens them from the sealed copy with the password
///   each time they are wanted ([keysWith]).
/// - **Signed out, or removed from the account from another device**, a device of its own (an iPhone, a computer with
///   no phone, a page in a browser) can delete everything of the account it keeps ([signOut] with everything; always
///   in a browser, and always once removed); an Android phone, or a computer paired with one, forgets the account's
///   words and keys.
class Account extends ChangeNotifier {
  Account({required this.relay, required this.port, required this.store, required this.profiles});

  /// The app's account, made on first use; a test puts its own in place.
  static Account? _instance;
  static Account get instance => _instance ??= Account(relay: HubAccountRelay(), port: SmsAccountPort(), store: _NoStore(), profiles: AppAccountProfiles());
  static set instance(Account? a) => _instance = a;

  // What it works through: the relay's accounts, the install itself (its key, its vault, starting again), the
  // preferences, and the profile that goes in a backup.
  final AccountRelay relay;
  final AccountPort port;
  MeStore store;
  final AccountProfiles profiles;

  /// Puts the app's preferences in place (people.dart) and asks the relay whether this device is still signed in; or,
  /// where a sign-in here was cut short, finishes it ([resume]).
  void start(MeStore store) {
    this.store = store;
    notifyListeners();
    unawaited(() async {
      if (!keepsWords) await _dropKeptWords();
      await (signedIn ? check() : resume());
    }());
  }

  // --- what this device keeps -----------------------------------------------------------------------------------------

  // Names in the install's secure storage: the recovery words, and the key the password made ([PasswordKey]).
  static const _words = 'account_words';
  static const _pwKey = 'account_pwkey';

  /// Whether this install keeps the recovery words and the key the password makes where it keeps its keys (Android's
  /// Keystore-sealed vault, the Keychain): every device but a page in a browser. A browser keeps neither: anything that
  /// runs in the page can open what the page keeps (lib/web/store.dart), so there the words are opened from the
  /// password's copy of the backup each time they are wanted ([keysWith], [revealWords]) and forgotten again, and only
  /// what the app needs from them day to day is kept: the key the account's devices seal copies to each other with
  /// ([Me.mineSecret]), which opens those copies of what is said with friends by username, both ways and never
  /// changing, and none of the account's other keys.
  static bool get keepsWords => !Sms.browser;

  /// What this install keeps of an account opened just now with [words] (and [pk], where the password was typed):
  /// the words and the password's key, or, in a browser, the one key made from the words that the app needs.
  Future<void> _keepKeys(List<String> words, PasswordKey? pk) async {
    if (keepsWords) {
      await port.secretKeep(_words, words.join(' '));
      if (pk != null) await port.secretKeep(_pwKey, pk.toJson());
      return;
    }
    await port.secretKeep(Me.mineSecret, NetCrypto.hex(Me.mineKeyOf(words)));
  }

  /// A browser's store from a build before it kept no words: the key made from them kept in their place, and the
  /// words and the password's key deleted.
  Future<void> _dropKeptWords() async {
    try {
      final words = await _keptWords();
      final pk = await port.secretRead(_pwKey);
      if (words == null && (pk == null || pk.isEmpty)) return;
      if (words != null) await port.secretKeep(Me.mineSecret, NetCrypto.hex(Me.mineKeyOf(words)));
      await port.secretKeep(_words, '');
      await port.secretKeep(_pwKey, '');
    } catch (_) {}
  }

  /// The account's address, EIP-55 capitals; null where this device is in none.
  String? get address {
    final a = store.choice('acct_address', '');
    return a.isEmpty ? null : a;
  }

  bool get signedIn => address != null;

  /// A new number for this device, as it becomes the account's ([create], [finish]): a removal the account signed for
  /// whatever number it had before can never be taken for one of this sign-in's, whenever it was signed or however a
  /// relay hands it back (third review: one signed in the ten minutes' allowance before the device joined again, or
  /// any, for an install from before devices kept when they joined, was taken).
  void _newDevice() => store.set('acct_device', NetCrypto.hex(NetCrypto.randomBytes(16)));

  /// This device's number under the account (32 hex digits), what the devices list knows it by.
  String get device {
    var d = store.choice('acct_device', '');
    if (d.length != 32) {
      d = NetCrypto.hex(NetCrypto.randomBytes(16));
      store.set('acct_device', d);
    }
    return d;
  }

  /// 'seed' where the identity is the words' own, 'bound' where it was the install's before the account.
  String get mode => store.choice('acct_mode', 'seed');

  /// The relay said this device was removed from the account (from another device): with the account's own signed
  /// words for it, on a device of its own ([removalProven]); on an Android phone or a paired computer, by its saying so.
  bool removedHere = false;

  /// A device of its own the relay doesn't know as one of the account's, with nothing signed by the account to say it
  /// was removed: another relay than the account's (Settings › Routes), a relay that lost what it kept, a sign-up whose
  /// listing never arrived, or a relay saying what isn't so. Nothing is deleted or forgotten for it; Settings › Me says
  /// so, and offers to sign in again (lib/ui/account_screens.dart).
  bool unknownHere = false;

  /// When this device last became the account's (ms; `acct_joined`): a removal signed before it is an old one, said
  /// again (a relay replaying what it kept from before this device was added again), and is not taken.
  int get joinedAt => int.tryParse(store.choice('acct_joined', '')) ?? 0;

  /// Whether [proof] (what `acct-hello` hands back with `known: false`, relay/lib/accounts.dart) is the account's own
  /// signed removal of [device]: the account key's signature (EIP-191) over a `devices` body naming [address] and
  /// removing [device], made no earlier than ten minutes (the relay's allowance for clocks) before [joinedAt]. Nothing
  /// else that a relay says, or makes up, passes: only the account's words can make it.
  static bool removalProven(Object? proof, {required String address, required String device, int joinedAt = 0}) {
    if (proof is! Map || proof['body'] is! String || proof['sig'] is! String) return false;
    try {
      final text = proof['body'] as String;
      final signer = AccountCrypto.signer(utf8.encode(text), NetCrypto.unhex(proof['sig'] as String));
      if (signer == null || signer.toLowerCase() != address.toLowerCase()) return false;
      final body = jsonDecode(text) as Map;
      final at = body['at'];
      return body['op'] == 'devices' && '${body['a']}'.toLowerCase() == address.toLowerCase() && body['remove'] == device && at is num && at >= joinedAt - 600000;
    } catch (_) {
      return false;
    }
  }

  Future<List<String>?> _keptWords() async {
    final w = await port.secretRead(_words);
    if (w == null || w.isEmpty) return null;
    final words = w.split(' ');
    return AccountCrypto.validWords(words) ? words : null;
  }

  /// The recovery words this device keeps, to hand to a new device of the person's that a phone signed in here scanned
  /// the code of (GMFB-45; lib/account/handover.dart). Asked only once the phone's own lock was passed
  /// (lib/ui/handover_screens.dart). Null where this device is signed in to nothing or keeps no words (a browser,
  /// [keepsWords]): the password opens them there ([revealWords]).
  Future<List<String>?> wordsForNewDevice() async => signedIn && keepsWords ? _keptWords() : null;

  /// Notes in the preferences that this device is in the account at [address], with the password's sealed copy.
  void _keepHere({required String address, required String mode, required String sealed}) {
    store.set('acct_address', address);
    store.set('acct_mode', mode);
    store.set('acct_sealed', sealed);
    store.set('acct_joined', '${DateTime.now().millisecondsSinceEpoch}');
    unknownHere = false;
    // Why the device had started again with nothing (StandaloneCalls.noteKey), said on the welcome until now.
    if (store.choice('acct_note', '').isNotEmpty) store.set('acct_note', '');
    notifyListeners();
  }

  // --- making an account -----------------------------------------------------------------------------------------------

  /// New recovery words and the address they make, to be written down and confirmed before anything is sent anywhere.
  AccountDraft draft() {
    final words = AccountCrypto.newWords();
    return AccountDraft(words, _keysOf(words).address);
  }

  /// What [words] make: the BIP-39 seed, the account's own key (secp256k1) and its address.
  static ({Uint8List seed, Uint8List key, String address}) _keysOf(List<String> words) {
    final seed = AccountCrypto.seedOf(words);
    final key = AccountCrypto.derive(seed, AccountCrypto.ethPath);
    return (seed: seed, key: key, address: AccountCrypto.addressOf(AccountCrypto.publicOf(key)));
  }

  /// Makes the account [draft] names, sealed with [password]. True where this install took on the words' identity and
  /// is to start again ([restart]); false where it keeps its own and goes on as it was.
  Future<bool> create(AccountDraft draft, String password) async {
    final keys = _keysOf(draft.words);
    final fresh = profiles.fresh;
    final NetKeys identity = fresh ? AccountCrypto.identityOf(keys.seed) : NetKeys.fromScalar(await port.identityExport());
    final backup = profiles.fill(AccountBackup(words: draft.words, identity: NetCrypto.hex(identity.scalar), mode: fresh ? 'seed' : 'bound'));
    final pk = await PasswordKey.make(password);
    final sealed = await _put(keys, identity, backup, pk);
    _newDevice();
    // Listed under the account before this device calls itself signed in to it, as [finish] does: kept the other way
    // round, a listing that never arrived left a device that thought itself the account's and wasn't on its list, and
    // the relay said so at its next start. Asked twice; where it still doesn't arrive nothing is kept here, and the
    // account, made on the relay, is signed in to as any is.
    try {
      await _addDevice(keys.key, keys.address);
    } catch (_) {
      try {
        await Future<void>.delayed(addAgainAfter);
        await _addDevice(keys.key, keys.address);
      } catch (_) {
        throw AccountError('Your account was made, but this device couldn\'t be added to it just now. Sign in to it with your username and password in Settings › Me.');
      }
    }
    await _keepKeys(draft.words, pk);
    _keepHere(address: keys.address, mode: backup.mode, sealed: sealed);
    if (fresh) await port.identityImport(identity.scalar, identity.public);
    return fresh;
  }

  /// How long [create] waits before asking a second time to list this device.
  @visibleForTesting
  static Duration addAgainAfter = const Duration(seconds: 2);

  /// Seals [backup] both ways and keeps it on the relay; the password's copy, to keep here too.
  Future<String> _put(({Uint8List seed, Uint8List key, String address}) keys, NetKeys identity, AccountBackup backup, PasswordKey password) async {
    final pw = AccountCrypto.sealWithPasswordKey(backup, password, keys.address);
    final seed = AccountCrypto.sealWithSeed(backup, keys.seed, keys.address);
    await relay.ask(_signed('acct-put', 'put', keys, {
      'id': identity.id,
      'key': base64Encode(identity.public),
      'bind': base64Encode(AccountCrypto.bindProof(identity, keys.address)),
      'pw': pw,
      // What the relay checks the proof of the password against before it hands the password's copy to anyone.
      'pwv': password.verifier,
      'seed': seed,
    }));
    return pw;
  }

  /// A request the relay checks as the account's own: a body naming [op], the address, this hub connection and the
  /// time, with [more], signed with the account's key.
  Map<String, Object?> _signed(String dir, String op, ({Uint8List seed, Uint8List key, String address}) keys, Map<String, Object?> more) {
    final body = jsonEncode({'op': op, 'a': keys.address, 'by': relay.hubId, 'at': DateTime.now().millisecondsSinceEpoch, ...more});
    return {'dir': dir, 'body': body, 'sig': NetCrypto.hex(AccountCrypto.sign(keys.key, utf8.encode(body)))};
  }

  // A page in a browser is none of the five: "web" (a device list from before this draws it as a computer).
  static String get _platform => Sms.browser ? 'web' : PlatformInfo.isAndroid ? 'android' : PlatformInfo.isIOS ? 'ios' : PlatformInfo.isMacOS ? 'macos' : PlatformInfo.isWindows ? 'windows' : 'linux';

  /// Lists this device under the account; the account's devices as they then are.
  Future<List<AccountDevice>> _addDevice(Uint8List key, String address) async {
    final m = await relay.ask(_signed('acct-devices', 'devices', (seed: Uint8List(0), key: key, address: address), {
      // With its name on the hub (GMFB-53), which the hub vouches for in what the account sends its own name.
      'add': {'d': device, 'n': profiles.deviceName, 'p': _platform, if (HubCarrier.device.isNotEmpty) 'h': HubCarrier.device},
    }));
    return AccountDevice.list(m['list'], device);
  }

  // --- signing in --------------------------------------------------------------------------------------------------

  /// Whether [username] has an account, and whether its number has to be sent a code first.
  Future<({bool phone})> findByName(String username) async {
    final m = await relay.ask({'dir': 'acct-find', 'name': tidyHandle(username)});
    if (m['none'] == true) throw AccountNotFound();
    return (phone: m['phone'] == true);
  }

  /// Texts a code to the number verified on [username]'s account; [number] has to be that number.
  Future<void> textCode(String username, String number) async {
    await relay.ask({'dir': 'acct-text', 'name': tidyHandle(username), 'number': number});
  }

  /// The account [username] opened with [password] ([number] and [code] where its number is verified). Throws
  /// [AccountNeedsCode] where a code is wanted first and [AccountError] where the password is not the one.
  ///
  /// The password is stretched here with the settings and salt the relay gives (`acct-find`), and only the proof it
  /// makes ([PasswordKey.auth]) is sent; the relay hands the sealed copy over only for the right one, so nobody can
  /// take the copy away and try passwords against it.
  Future<AccountRestore> signInWithPassword(String username, String password, {String? number, String? code}) async {
    final name = tidyHandle(username);
    final found = await relay.ask({'dir': 'acct-find', 'name': name});
    if (found['none'] == true) throw AccountNotFound();
    if (found['phone'] == true && code == null) throw AccountNeedsCode();
    final kdf = found['kdf'];
    // Never weaker than an account is made with: a relay offering cheaper settings would be after a proof it could
    // try passwords against more cheaply than the copy it keeps.
    if (kdf is! Map || kdf['m'] is! int || kdf['t'] is! int || (kdf['m'] as int) < AccountCrypto.argonMemoryKiB || (kdf['t'] as int) < AccountCrypto.argonPasses) {
      throw AccountError('That account could not be read.');
    }
    final pk = await PasswordKey.forKdf(kdf, password);
    if (pk == null) throw AccountError('That account could not be read.');
    final m = await relay.ask({'dir': 'acct-get', 'name': name, 'number': ?number, 'code': ?code, 'auth': NetCrypto.hex(pk.auth)});
    if (m['blob'] is! String) {
      if (m['phone'] == true) throw AccountNeedsCode();
      throw AccountError('That account could not be read.');
    }
    final blob = m['blob'] as String;
    final address = AccountCrypto.checksummed(m['a'] as String);
    final backup = AccountCrypto.openWithPasswordKey(blob, pk, address);
    if (backup == null) throw AccountError('That password isn\'t right.');
    if (_keysOf(backup.words).address != address) throw AccountError('That backup is not this account\'s.');
    return AccountRestore(address, backup, blob, passwordKey: pk);
  }

  /// The account [words] make, opened with them: no password and no code, the words being the account itself. Where
  /// the relay has no backup for it ([AccountRestore.backedUp] false) the words still make the address and the Uplink
  /// identity of an account that began with them; a new password is then needed to keep a backup again.
  Future<AccountRestore> signInWithWords(List<String> words) async {
    if (!AccountCrypto.validWords(words)) throw AccountError('Those words don\'t add up. Check each one, and their order.');
    final keys = _keysOf(words);
    final m = await relay.ask(_signed('acct-seed', 'seed', keys, const {}));
    if (m['none'] == true) {
      final identity = AccountCrypto.identityOf(keys.seed);
      return AccountRestore(keys.address, AccountBackup(words: words, identity: NetCrypto.hex(identity.scalar)), null, backedUp: false);
    }
    final backup = AccountCrypto.openWithSeed(m['blob'] as String, keys.seed, keys.address);
    if (backup == null) throw AccountError('The backup kept for these words could not be opened.');
    return AccountRestore(keys.address, backup, m['pw'] as String?);
  }

  /// Makes [restore] this install: its identity in place of this one's, its profile, friends and circles, this
  /// device listed under it, and the app started again ([restart]). [password] is needed where nothing was backed up.
  /// True where the app is starting again; false where it cannot by itself (an iPhone) and the person is to.
  Future<bool> finish(AccountRestore restore, {String? password}) async {
    final keys = _keysOf(restore.backup.words);
    final identity = NetKeys.fromScalar(NetCrypto.unhex(restore.backup.identity));
    var sealed = restore.sealed;
    var pk = restore.passwordKey;
    if (!restore.backedUp || sealed == null) {
      if (password == null) throw AccountError('Choose a password to keep a backup.');
      pk = await PasswordKey.make(password);
      sealed = await _put(keys, identity, restore.backup, pk);
    }
    _newDevice();
    await _addDevice(keys.key, keys.address);
    await _keepKeys(restore.backup.words, pk);
    // The identity this install had until now, where it is another and its own: kept beside the words, so what it was in
    // circles becomes the account's (Voice.carryOver) rather than someone else beside it. Not a paired computer's: the
    // identity it took on is its phone's, still the phone's after this, and never to be folded into another. Nor a
    // page in a browser's, which is signed in from its first page, before it can have been in any circle: kept, it would
    // be one more private key in the browser for nothing.
    try {
      final before = NetKeys.fromScalar(await port.identityExport());
      // Only an identity with no friends of its own: one that has them is someone people know, perhaps another person
      // who used this computer, and not to be made the account's in anyone's eyes.
      if (keepsWords && !Sms.paired && Buddies.instance.all.isEmpty && before.id != identity.id) await port.secretKeep(Voice.wasKey, NetCrypto.hex(before.scalar));
    } catch (_) {}
    // The new identity, then everything that hangs off it, then this device's account; the old identity is gone
    // from the moment the first is written, so nothing below may fail half way and leave this install between the two.
    await port.identityImport(identity.scalar, identity.public);
    await profiles.apply(restore.backup);
    _keepHere(address: restore.address, mode: restore.backup.mode, sealed: sealed);
    return restart();
  }

  /// Whether making [restore] this install would change who it is: its identity is not the one here now. On a computer
  /// paired with a phone, whose identity is the phone's, that splits the two into different people to everyone who
  /// writes to them, so Settings asks first (Matt, 2026-11-18: "messages from desktop are coming through differently
  /// than messages on mobile even though they're both me").
  Future<bool> wouldChangeIdentity(AccountRestore restore) async {
    try {
      return NetKeys.fromScalar(await port.identityExport()).id != NetKeys.fromScalar(NetCrypto.unhex(restore.backup.identity)).id;
    } catch (_) {
      return true;
    }
  }

  /// Starts the app again; false where it cannot by itself.
  Future<bool> restart() async {
    await profiles.stopAll();
    return port.restart();
  }

  // --- on a signed-in device -----------------------------------------------------------------------------------------

  /// The recovery words, for [password]: what is kept here is opened with it, so the words are shown only to someone
  /// who knows it.
  Future<List<String>> revealWords(String password) async {
    final address = this.address;
    if (address == null) throw AccountError('This device is not signed in.');
    final blob = store.choice('acct_sealed', '');
    final pk = await PasswordKey.forBlob(blob, password);
    final backup = pk == null ? null : AccountCrypto.openWithPasswordKey(blob, pk, address);
    if (backup == null) throw AccountError('That password isn\'t right.');
    // Typed here at last (a device signed in by its words): kept, so the backup can be brought up to date from now on.
    // Not in a browser, which keeps no password key ([keepsWords]).
    if (keepsWords) await port.secretKeep(_pwKey, pk!.toJson());
    return backup.words;
  }

  /// The account opened with [password] from the password's copy of the backup kept here: what lists the devices,
  /// removes one, or brings the backup up to date where this install keeps no words (a browser, [keepsWords]). Held by
  /// whoever asked for as long as they need it, never kept. Throws [AccountError] where the password isn't right.
  Future<AccountKeys> keysWith(String password) async {
    final address = this.address;
    if (address == null) throw AccountError('This device is not signed in.');
    final blob = store.choice('acct_sealed', '');
    final pk = await PasswordKey.forBlob(blob, password);
    final backup = pk == null ? null : AccountCrypto.openWithPasswordKey(blob, pk, address);
    if (backup == null) throw AccountError('That password isn\'t right.');
    final keys = _keysOf(backup.words);
    if (keys.address != address) throw AccountError('That backup is not this account\'s.');
    return AccountKeys._(keys, backup.words, pk!);
  }

  /// A new password: the backup opened with [old], its profile brought up to now, and sealed again both ways.
  Future<void> changePassword(String old, String next) async {
    final address = this.address;
    if (address == null) throw AccountError('This device is not signed in.');
    final backup = await AccountCrypto.openWithPassword(store.choice('acct_sealed', ''), old, address);
    if (backup == null) throw AccountError('That password isn\'t right.');
    final keys = _keysOf(backup.words);
    final identity = NetKeys.fromScalar(NetCrypto.unhex(backup.identity));
    final pk = await PasswordKey.make(next);
    final sealed = await _put(keys, identity, profiles.fill(backup), pk);
    store.set('acct_sealed', sealed);
    if (keepsWords) await port.secretKeep(_pwKey, pk.toJson());
    notifyListeners();
  }

  /// Seals the backup again with this install's profile, friends and circles as they are now, both ways, with the
  /// password's key kept here: at most once a day, as the app starts ([check]). Nothing where the password has not
  /// been typed on this device (signed in by its words, and the words not yet shown or the password not changed), nor
  /// in a browser, which keeps neither ([refreshWith]).
  Future<bool> refresh({bool force = false}) async {
    final address = this.address;
    final today = DateTime.now().toUtc().toIso8601String().substring(0, 10);
    if (address == null || (!force && store.choice('acct_refreshed', '') == today)) return false;
    final words = await _keptWords();
    final pk = PasswordKey.fromJson(await port.secretRead(_pwKey));
    if (words == null || pk == null) return false;
    return _reseal(words, pk, address, today);
  }

  /// [refresh] where this install keeps no words (a browser): the backup opened with [password], brought up to now and
  /// sealed again both ways. Throws [AccountError] where the password isn't right; false where nothing could be sealed.
  Future<bool> refreshWith(String password) async {
    final k = await keysWith(password);
    return _reseal(k._words, k._pk, k._keys.address, DateTime.now().toUtc().toIso8601String().substring(0, 10));
  }

  /// Seals the backup again, both ways (under the words and under the password's key), put together with what the
  /// relay keeps now. False where [words] do not make [address], or nothing could be sealed.
  Future<bool> _reseal(List<String> words, PasswordKey pk, String address, String today) async {
    final keys = _keysOf(words);
    if (keys.address != address) return false;
    final identity = NetKeys.fromScalar(await port.identityExport());
    final mine = profiles.fill(AccountBackup(words: words, identity: NetCrypto.hex(identity.scalar), mode: mode));
    var backup = mine;
    // Put together with what is kept now: every device of the account seals it again in its turn, and the last used to
    // decide alone, so one in fewer circles (or with fewer friends) took the others' out of what the next device signing
    // in is given (2026-11-19, found as the check below began to reach the relay at all).
    // Not read (the relay away, too many asks): nothing sealed now rather than this device's alone over the others'.
    final got = await relay.ask(_signed('acct-seed', 'seed', keys, const {}));
    final blob = got['blob'];
    final kept = blob is String ? AccountCrypto.openWithSeed(blob, keys.seed, keys.address) : null;
    if (blob is String && kept == null) return false;
    // A circle left here stays left: not brought back from the copy kept before it was.
    if (kept != null) {
      backup = mine.copyWith(circles: _union(mine.circles, [for (final c in kept.circles) if (!(c is Map && c['s'] is String && Circles.instance.removed(c['s'] as String))) c], 's'), friends: _union(mine.friends, kept.friends, 'i'));
    }
    String sealed;
    try {
      sealed = await _put(keys, identity, backup, pk);
    } on AccountError catch (e) {
      // Too much put together to keep (a backup is at most so big on the relay): this device's own, as before.
      if (identical(backup, mine) || !e.message.contains('too big')) rethrow;
      sealed = await _put(keys, identity, mine, pk);
    }
    store.set('acct_sealed', sealed);
    store.set('acct_refreshed', today);
    return true;
  }

  /// Takes in the friends and circles the account's kept copy has and this device does not (Matt, 2026-11-25:
  /// "messages are still not kept in sync across all devices, all my devices have different sidebars"). The copy is put
  /// together from every device's as each seals it again ([_reseal]), but a device read it once, as it signed in:
  /// whatever another device added afterwards stayed on that device and in the copy. Read with the words kept here
  /// (no password is needed to read), so not in a browser; at most once in ten minutes unless [force]. True where the
  /// copy was read.
  Future<bool> takeIn({bool force = false}) async {
    final address = this.address;
    final into = profiles;
    if (address == null || !keepsWords || into is! AccountTakesIn) return false;
    final now = DateTime.now().millisecondsSinceEpoch;
    final last = int.tryParse(store.choice('acct_taken', '')) ?? 0;
    if (!force && now - last < const Duration(minutes: 10).inMilliseconds) return false;
    final words = await _keptWords();
    if (words == null) return false;
    final keys = _keysOf(words);
    if (keys.address != address) return false;
    final got = await relay.ask(_signed('acct-seed', 'seed', keys, const {}));
    final blob = got['blob'];
    final kept = blob is String ? AccountCrypto.openWithSeed(blob, keys.seed, keys.address) : null;
    if (kept == null) return false;
    store.set('acct_taken', '$now');
    await (into as AccountTakesIn).takeIn(kept);
    return true;
  }

  /// While the app runs: the account's kept copy read again every half hour ([takeIn]), and sealed again soon after
  /// this device's own friends or circles change ([refresh]), so another device's reading finds them. It was sealed at
  /// most once a day, as the app started.
  Timer? _keeping;
  String _sealedFor = '';
  void _keepInStep() {
    _keeping ??= Timer.periodic(const Duration(minutes: 30), (_) => unawaited(inStep()));
  }

  /// One turn of keeping in step: read, and seal again where what this device has differs from what it last sealed.
  Future<void> inStep() async {
    if (address == null) return;
    try {
      await takeIn();
      final mine = profiles.fill(AccountBackup(words: const [], identity: ""));
      final now = '${[for (final f in mine.friends) if (f is Map) f['i']].join(',')}|${[for (final c in mine.circles) if (c is Map) c['s']].join(',')}';
      if (now != _sealedFor && await refresh(force: _sealedFor.isNotEmpty)) _sealedFor = now;
      if (_sealedFor.isEmpty) _sealedFor = now;
    } catch (_) {}
  }

  /// [mine], then each of [theirs] whose [key] none of [mine] has: this device's own copy of anything both have.
  static List<Object?> _union(List<Object?> mine, List<Object?> theirs, String key) {
    final have = {for (final x in mine) if (x is Map && x[key] is String) x[key]};
    return [...mine, for (final x in theirs) if (x is Map && x[key] is String && !have.contains(x[key])) x];
  }

  /// The account's keys, from the words kept here; throws where this device isn't signed in or can't read them.
  Future<({Uint8List seed, Uint8List key, String address})> _keys() async {
    if (!keepsWords) throw AccountError('Type your password first: this browser keeps nothing that can change your account.');
    final words = await _keptWords();
    if (words == null || address == null) throw AccountError('This device\'s copy of the account can\'t be read. Sign in again.');
    return _keysOf(words);
  }

  /// The devices signed in to the account; with [keys] ([keysWith]) where this install keeps no words (a browser).
  /// Whether the device numbered [device] is on this account's list now and is [hub] on the hub, the name the hub
  /// vouched for on a packet the account sent its own name (GMFB-53: a history goes only to the listed device that asked
  /// for it); with its name on the list. The relay's `acct-hello` with both numbers, which needs no key. Null where it
  /// isn't, or the relay can't say (one from before keeps no hub names: nothing is vouched for there).
  Future<String?> vouches(String device, String hub) async {
    final a = address;
    if (a == null || hub.isEmpty) return null;
    try {
      final m = await relay.ask({'dir': 'acct-hello', 'a': a, 'd': device, 'h': hub}).timeout(const Duration(seconds: 10));
      if (m['known'] != true || m['hm'] != true) return null;
      return m['n'] is String ? m['n'] as String : '';
    } catch (_) {
      return null;
    }
  }

  Future<List<AccountDevice>> devices({AccountKeys? keys}) async {
    final m = await relay.ask(_signed('acct-devices', 'devices', keys?._keys ?? await _keys(), const {}));
    return AccountDevice.list(m['list'], device);
  }

  /// Signs the device [d] out of the account, and answers the devices left; [keys] as [devices]'.
  Future<List<AccountDevice>> removeDevice(String d, {AccountKeys? keys}) async {
    final m = await relay.ask(_signed('acct-devices', 'devices', keys?._keys ?? await _keys(), {'remove': d}));
    return AccountDevice.list(m['list'], device);
  }

  /// Where the relay doesn't hold the account at all ([unknownHere]: another relay than the account's, or one that lost
  /// what it kept): the account put on it from this device, as [refresh] puts it each day (with what is kept there, where
  /// anything is), and this device listed under it. Not a sign-in, which puts the backup's friends and circles in place
  /// of this device's and loses whatever came since the backup was last sealed (third review). [password] where this
  /// install keeps no words (a browser). Throws [AccountError] where it can't.
  Future<void> listHereAgain({String? password}) async {
    final address = this.address;
    if (address == null) throw AccountError('This device is not signed in.');
    final List<String> words;
    final PasswordKey pk;
    if (!keepsWords || password != null) {
      if (password == null) throw AccountError('Type your password first.');
      final k = await keysWith(password);
      words = k._words;
      pk = k._pk;
    } else {
      final w = await _keptWords();
      final p = PasswordKey.fromJson(await port.secretRead(_pwKey));
      if (w == null) throw AccountError('This device\'s copy of the account can\'t be read. Sign in again.');
      if (p == null) throw AccountError('Show your recovery words once (above, after your password), then try this again.');
      words = w;
      pk = p;
    }
    final keys = _keysOf(words);
    if (keys.address != address) throw AccountError('That backup is not this account\'s.');
    if (!await _reseal(words, pk, address, DateTime.now().toUtc().toIso8601String().substring(0, 10))) throw AccountError('Your account could not be put on this relay just now. Try again in a while.');
    await _addDevice(keys.key, keys.address);
    unknownHere = false;
    removedHere = false;
    notifyListeners();
  }

  /// A sign-in cut short by the app starting again (2026-11-19: on a computer the account's own choices were still being
  /// written as the app closed, so it came back signed out, with the account's words in its vault and the relay listing
  /// it): finished now, where the relay still lists this device under the words' account and the identity here is that
  /// account's. True where it was; anything else is left as it is, for the person to sign in again.
  Future<bool> resume() async {
    try {
      final words = await _keptWords();
      if (words == null || signedIn) return false;
      // Tried once a day: where it cannot be taken up (another identity here), not asked of the relay at every start.
      final today = DateTime.now().toUtc().toIso8601String().substring(0, 10);
      if (store.choice('acct_resumed', '') == today) return false;
      store.set('acct_resumed', today);
      // Asked as the app starts: the hub it is asked through is made a moment after (Net.start reads the identity first).
      final r = relay;
      if (r is HubAccountRelay && !await r.hubMade()) return false;
      final keys = _keysOf(words);
      final hello = await relay.ask({'dir': 'acct-hello', 'a': keys.address, 'd': device});
      if (hello['known'] != true || signedIn) return false;
      final got = await relay.ask(_signed('acct-seed', 'seed', keys, const {}));
      final blob = got['blob'];
      if (got['none'] == true || blob is! String) return false;
      final backup = AccountCrypto.openWithSeed(blob, keys.seed, keys.address);
      if (backup == null) return false;
      final here = NetKeys.fromScalar(await port.identityExport());
      if (here.id != NetKeys.fromScalar(NetCrypto.unhex(backup.identity)).id || signedIn) return false;
      _keepHere(address: keys.address, mode: backup.mode, sealed: (got['pw'] as String?) ?? '');
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Whether the relay still has this device under the account; where it does not, this device forgets the account.
  Future<void> check() async {
    final address = this.address;
    if (address == null) return;
    // Asked as the app starts, before the hub it goes through is made (Net.start reads the identity first): it used to
    // fail there every time, unsaid, so the backup was never sealed again and a device taken off was never told.
    final r = relay;
    if (r is HubAccountRelay && !await r.hubMade()) return;
    if (_checking) return;
    _checking = true;
    try {
      // Signed in before devices kept when they joined: from now (a removal signed before it is an old one).
      if (store.choice('acct_joined', '').isEmpty) store.set('acct_joined', '${DateTime.now().millisecondsSinceEpoch}');
      final m = await relay.ask({'dir': 'acct-hello', 'a': address, 'd': device, if (HubCarrier.device.isNotEmpty) 'h': HubCarrier.device});
      // Listed from before its hub name was kept (or under another): listed again with it, where this device can sign
      // (not a browser, which keeps no account key: it is listed with it as it signs in). GMFB-53.
      if (m['known'] == true && m['hm'] == false && keepsWords) {
        try {
          final keys = await _keys();
          await _addDevice(keys.key, keys.address);
        } catch (_) {}
      }
      if (m['known'] == false) {
        // Whether this relay holds the account at all: where it does, this device isn't on its list. A relay from before
        // it said so says nothing of it either way.
        final held = m['account'] == true, says = m.containsKey('account');
        if (!Sms.standalone && (held || !says)) {
          // An Android phone, or a computer paired with one, on a relay that holds the account and doesn't list it (or
          // one from before relays said which): it forgets the account's words and keys, as it always has. Not where
          // the relay says it holds no such account at all, which is below (GMFB-25: moving to a relay of one's own
          // forgot the account on a phone, and on a phone alone).
          removedHere = true;
          await _forgetHere();
        } else if (!Sms.standalone) {
          // An Android phone on a relay that doesn't hold the account at all: as every other device.
          if (!unknownHere) {
            unknownHere = true;
            notifyListeners();
          }
        } else if (removalProven(m['removed'], address: address, device: device, joinedAt: joinedAt) || (Sms.browser && held)) {
          // A device of its own the account removed (its own signed words say so): it stops being the account
          // altogether, everything of it this device keeps deleted, and the app starts again with nothing. Kept, its
          // identity, friends and circles went on reading and writing as the account after it was taken off the list.
          // A browser does so too wherever the relay holds the account and doesn't list it, signed or not: what it
          // keeps is a copy of what the account's other devices have, and it can't be on another relay than its page's.
          removedHere = true;
          await _wipe('removed');
        } else if (held) {
          // The relay holds the account and doesn't list this device, with nothing signed to say why (a relay from
          // before removals were kept, a removal made before it was, a sign-up whose listing never arrived): what every
          // device did before, as an Android phone still does. The account's words and keys are forgotten, so it can
          // change nothing of the account; its conversations stay.
          removedHere = true;
          await _forgetHere();
        } else {
          // The relay doesn't hold the account at all: another relay than the account's, or one that lost what it kept.
          // Said, with what to do; nothing deleted or forgotten (a relay switch once cost every conversation).
          if (!unknownHere) {
            unknownHere = true;
            notifyListeners();
          }
        }
      } else {
        if (unknownHere) {
          unknownHere = false;
          notifyListeners();
        }
        // The account's friends and circles as its other devices have made them since ([takeIn]), then this device's
        // sealed with them, and both again as the app goes on ([_keepInStep]).
        await takeIn();
        await refresh();
        _keepInStep();
      }
    } catch (_) {
    } finally {
      _checking = false;
    }
  }

  bool _checking = false;

  Future<void> _forgetHere() async {
    store.set('acct_address', '');
    store.set('acct_sealed', '');
    store.set('acct_mode', '');
    await port.secretKeep(_words, '');
    await port.secretKeep(_pwKey, '');
    // What a browser keeps in the words' place.
    if (!keepsWords) await port.secretKeep(Me.mineSecret, '');
    // Out of the account, this install is no longer whoever it was before signing in either (Voice.carryOver).
    await port.secretKeep(Voice.wasKey, '');
    // And this device's forward-secrecy prekeys and what it knew of others' (GMFB-26): nothing of the account left.
    try {
      await Net.instance.board?.fs?.wipe();
    } catch (_) {}
    try {
      await Circles.instance.keys?.wipe();
    } catch (_) {}
    // And its place on the direct network (lib/net/p2p): the node is stopped, and its key, the cards it holds and
    // what it told whom are deleted, here too where the routes were never set up. A node id is never carried from one
    // account to the next.
    try {
      await Net.instance.p2p?.wipe();
    } catch (_) {}
    // Only what is there: a build or a device that never had a node writes nothing of the direct network now.
    for (final name in P2p.secretNames) {
      try {
        if ((await port.secretRead(name) ?? '').isNotEmpty) await port.secretKeep(name, '');
      } catch (_) {}
    }
    for (final name in P2p.keptNames) {
      if (store.choice(name, '').isNotEmpty) store.set(name, '');
    }
    // And the relay this device hosts (lib/relay_host): stopped and switched off, everyone on it seeing it gone, its pass
    // phrase forgotten and its folder kept (its key, where its people said they live); this app's relay set back to the
    // one before it. And the pass phrase given for someone else's relay.
    try {
      await Net.instance.relayHost?.signedOut();
    } catch (_) {}
    try {
      if ((await port.secretRead(Net.joinPassName) ?? '').isNotEmpty) await port.secretKeep(Net.joinPassName, '');
    } catch (_) {}
    // And the ledger the relay is checked by, and what the name watch kept (lib/net/ledger.dart, name_watch.dart): what
    // went to whom and came from whom, and what the relay said of friends' usernames, are nothing of the next account's.
    try {
      await Net.instance.ledger?.wipe();
    } catch (_) {}
    // And where none is running, its files: they are kept apart, out of any backup (lib/net/kept_files.dart).
    try {
      final files = Net.ledgerStore();
      if (files != null) await Ledger.forget(files);
    } catch (_) {}
    // And which route each person was last on (lib/net/routes_kept.dart), kept beside the ledger's files.
    try {
      await Net.instance.forgetRoutesUsed();
    } catch (_) {}
    NameWatch.instance?.wipe();
    LookupBudget.instance.clear();
    // (A build before the ledger had files of its own kept it with the choices.)
    for (final name in [...Ledger.keptIn(store.choice(Ledger.indexName, '')), ...NameWatch.keptNames]) {
      if (store.choice(name, '').isNotEmpty) store.set(name, '');
    }
    notifyListeners();
  }

  /// Signs this device out: taken off the account's list, the words forgotten here, and a new identity of its own in
  /// place of the account's, so it is no longer the account to anyone; then the app starts again. What stays on the
  /// device is said where this is asked (lib/ui/account_screens.dart): its conversations, spaces and choices. With
  /// [everything], always in a browser, a device of its own deletes everything of the account it keeps instead
  /// ([_wipe]).
  Future<bool> signOut({bool everything = false}) async {
    await _leaveList();
    if (Sms.standalone && (everything || Sms.browser)) return _wipe('signed-out');
    await _forgetHere();
    // A computer paired with a phone goes back to the phone's identity (it is taken on again as the app starts);
    // anywhere else, a new identity of its own.
    if (!await port.identityForget()) {
      final fresh = NetKeys.generate();
      await port.identityImport(fresh.scalar, fresh.public);
    }
    await profiles.forget();
    return restart();
  }

  /// This device taken off the account's list: signed with the account's key where the words are kept here, or, where
  /// they are not (a browser), asked by this device's own number alone (`acct-leave`, relay/lib/accounts.dart), which
  /// only it and the account's devices know. A relay from before that has no answer to it is given a few seconds; the
  /// device then stays on the list, with when it was last seen, until it is removed from another.
  Future<void> _leaveList() async {
    final address = this.address;
    if (address == null) return;
    try {
      final words = await _keptWords();
      if (words != null) {
        await relay.ask(_signed('acct-devices', 'devices', _keysOf(words), {'remove': device}));
      } else {
        await relay.ask({'dir': 'acct-leave', 'a': address, 'd': device}).timeout(const Duration(seconds: 6));
      }
    } catch (_) {}
  }

  /// Everything here was deleted ([_wipe]) and the app could not start again by itself (an iPhone, a computer that
  /// can't open itself again): it shows only that it is to be opened again, offline (RestartScreen).
  bool ended = false;

  /// Everything of the account this device of its own keeps deleted, and the app started again with nothing, the
  /// welcome saying why ([note]: 'signed-out', 'removed'). The routes are stopped first, so nothing more is said or
  /// written as the account from the moment it begins; then the account's words and keys are forgotten by their
  /// owners, what else the device keeps of it (a computer's Files spaces' files), and the store itself: in a browser
  /// the whole database, its key with it; on an iPhone or a computer the JSON (conversations, choices, friends,
  /// circles' and spaces' keys), who it is, and every secret.
  Future<bool> _wipe(String note) async {
    await profiles.stopAll();
    // A browser's database goes whole below; what the words' owners forget is a computer's or an iPhone's Keychain.
    // The routes being stopped, forward secrecy's prekeys and the circles' keys are deleted by name here.
    if (keepsWords) {
      await _forgetHere();
      for (final name in const [ForwardSecrecy.secretsName, CircleKeys.secretsName]) {
        try {
          if ((await port.secretRead(name) ?? '').isNotEmpty) await port.secretKeep(name, '');
        } catch (_) {}
      }
    }
    await profiles.wipe();
    await port.wipeHere(note);
    final again = await restart();
    if (!again) {
      ended = true;
      notifyListeners();
    }
    return again;
  }
}

/// The account opened with its password ([Account.keysWith]), held by a screen while it lists or removes devices or
/// brings the backup up to date, where the install keeps no words (a browser). Nothing outside this file reads what is
/// in it, and it is never kept.
class AccountKeys {
  AccountKeys._(this._keys, this._words, this._pk);
  final ({Uint8List seed, Uint8List key, String address}) _keys;
  final List<String> _words;
  final PasswordKey _pk;
}

/// An account not yet made: its recovery words and the address they make ([Account.draft]).
class AccountDraft {
  const AccountDraft(this.words, this.address);
  final List<String> words;
  final String address;
}

/// An account opened on a new device, not yet made its own ([Account.finish]).
class AccountRestore {
  const AccountRestore(this.address, this.backup, this.sealed, {this.backedUp = true, this.passwordKey});
  final String address;
  final AccountBackup backup;

  /// The password's copy, to keep on this device; null where the relay had none.
  final String? sealed;

  /// Whether the relay held a backup for it. False for words with none kept: [Account.finish] then needs a password.
  final bool backedUp;

  /// The key the password made, where it was typed: kept with the words, so the backup can be sealed again.
  final PasswordKey? passwordKey;
}

/// A device signed in to the account, as the relay lists it.
class AccountDevice {
  const AccountDevice({required this.id, required this.name, required this.platform, required this.since, required this.seen, this.here = false});
  final String id;
  final String name;
  final String platform;

  /// When it was added and when it was last seen, as the relay wrote them.
  final String since;
  final String seen;

  /// This device.
  final bool here;

  /// The relay's [list] as devices; the one whose id is [mine] is marked [here].
  static List<AccountDevice> list(Object? list, String mine) => [
        for (final d in (list as List? ?? const []).whereType<Map>())
          AccountDevice(id: '${d['d']}', name: '${d['n'] ?? ''}', platform: '${d['p'] ?? ''}', since: '${d['at'] ?? ''}', seen: '${d['seen'] ?? ''}', here: d['d'] == mine),
      ];
}

/// Why something about the account did not work, in words a person can be shown.
class AccountError implements Exception {
  AccountError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Nobody on the relay asked has that username. An account is kept on the relay it was made on, so on a relay of one's
/// own this may only mean the account is on another: the sign-in screen says which relay was asked (GMFB-25).
class AccountNotFound extends AccountError {
  AccountNotFound() : super('No account has that username.');
}

/// The account has a verified number, and a code texted to it is wanted before its backup is handed over.
class AccountNeedsCode extends AccountError {
  AccountNeedsCode() : super('A code texted to the account\'s number is needed.');
}

// --- what the account is spoken through --------------------------------------------------------------------------------

/// The relay's accounts (relay/lib/accounts.dart): [ask] says something and gives back its answer, or throws
/// [AccountError] with the relay's words.
abstract class AccountRelay {
  Future<Map<String, dynamic>> ask(Map<String, Object?> what);

  /// The hub's name for this connection: written into what is signed, so it can't be said again from another.
  String get hubId;
}

/// Through the app's hub connection, as Settings › Me speaks to handles (lib/me/me.dart).
class HubAccountRelay implements AccountRelay {
  HubAccountRelay({HubCarrier? Function()? hub}) : _hub = hub ?? (() => Net.instance.hub);
  final HubCarrier? Function() _hub;

  @override
  String get hubId => _hub()?.signer.id ?? Net.instance.id ?? '';

  /// Waits for the app's hub to be made (Net.start makes it once the identity is read, a moment after the app starts);
  /// false where it is not within [within].
  Future<bool> hubMade({Duration within = const Duration(seconds: 20)}) async {
    const step = Duration(milliseconds: 250);
    for (var waited = Duration.zero; _hub() == null; waited += step) {
      if (waited >= within) return false;
      await Future<void>.delayed(step);
    }
    return true;
  }

  /// Says [what] to the relay once the hub is up (waited for, up to ten seconds) and gives the first answer with the
  /// same `dir`. An `err` about it is thrown as an [AccountError].
  @override
  Future<Map<String, dynamic>> ask(Map<String, Object?> what, {Duration wait = const Duration(seconds: 25)}) async {
    unawaited(Net.instance.want('account', true));
    final hub = _hub();
    if (hub == null) throw AccountError('The relay server can\'t be reached right now.');
    if (hub.state.value != CarrierState.up) {
      final up = Completer<void>();
      void changed() {
        if (hub.state.value == CarrierState.up && !up.isCompleted) up.complete();
      }

      hub.state.addListener(changed);
      try {
        await up.future.timeout(const Duration(seconds: 10));
      } on TimeoutException {
        throw AccountError('The relay server can\'t be reached right now.');
      } finally {
        hub.state.removeListener(changed);
      }
    }
    final dir = what['dir'];
    final answer = hub.handles.firstWhere((m) => m['dir'] == dir || (m['dir'] == 'err' && m['about'] == dir)).timeout(wait, onTimeout: () => throw AccountError('The relay server did not answer.'));
    if (!hub.sayHandles(what)) throw AccountError('The relay server can\'t be reached right now.');
    final m = await answer;
    if (m['dir'] == 'err') throw AccountError((m['err'] as String?) ?? 'That did not work.');
    return m;
  }
}

/// What the account asks of the install: its key, keeping a secret, starting again.
abstract class AccountPort {
  /// This install's identity: its private key read out, and another put in its place.
  Future<Uint8List> identityExport();
  Future<void> identityImport(List<int> scalar, List<int> public);

  /// The install's secure storage, by name; '' is kept in place of a secret to forget it.
  Future<void> secretKeep(String name, String value);
  Future<String?> secretRead(String name);

  /// Starts the app again; false where it can't by itself.
  Future<bool> restart();

  /// Lets go of this install's identity where it has one to go back to (a computer paired with a phone takes the
  /// phone's on again); false where it has none, and signing out makes a new one.
  Future<bool> identityForget();

  /// Everything a device of its own keeps deleted (lib/standalone: its conversations and choices, who it is, every
  /// secret), with [note] kept for the welcome to say as it starts again. Asked only where [Sms.standalone].
  Future<void> wipeHere(String note);
}

/// The install as the app reaches it: its native side, through [Sms].
class SmsAccountPort implements AccountPort {
  /// A paired computer that has not taken on an identity of its own asks everything of the phone: an account's calls
  /// would change the phone's identity and vault from the computer, so none is made from there.
  static Future<T> _own<T>(Future<T> Function() call) async {
    if (Sms.followsPhone) throw AccountError('This computer hasn\'t become the same you as your phone yet.');
    return call();
  }

  @override
  Future<Uint8List> identityExport() => _own(() => Sms.instance.identityExport());
  @override
  Future<void> identityImport(List<int> scalar, List<int> public) => _own(() => Sms.instance.identityImport(scalar, public));
  @override
  Future<void> secretKeep(String name, String value) => _own(() => Sms.instance.secretKeep(name, value));
  @override
  Future<String?> secretRead(String name) => _own(() => Sms.instance.secretRead(name));
  @override
  Future<bool> restart() => _own(() => Sms.instance.restartApp());
  @override
  Future<bool> identityForget() => Sms.instance.identityForget();
  @override
  Future<void> wipeHere(String note) => Sms.instance.wipeHere(note);
}

/// What an account carries besides its identity: the profile, friends by username, circles, the key Uplink's own kept
/// lists are sealed with.
abstract class AccountProfiles {
  /// Nothing here yet that anyone knows this install's key by: no username, friends or circles.
  bool get fresh;

  /// What this device is called in the account's list.
  String get deviceName;

  /// [backup] with this install's profile, friends and circles as they are now.
  AccountBackup fill(AccountBackup backup);

  /// [backup]'s profile, friends and circles put in place here.
  Future<void> apply(AccountBackup backup);

  /// This install's profile, friends and circles forgotten (signing out).
  Future<void> forget();

  /// Everything that speaks as this install stopped, before it starts again as another.
  Future<void> stopAll();

  /// What this install keeps of the account besides its store deleted, as everything of it is ([Account.signOut] with
  /// everything, or removed): a computer's or an iPhone's Files spaces' files.
  Future<void> wipe();
}

/// A profile that can take in what the account's kept copy has and this device does not ([Account.takeIn]): the
/// app's own. Apart from [AccountProfiles], so a stand-in for that need not have it.
abstract class AccountTakesIn {
  Future<void> takeIn(AccountBackup kept);
}

/// The app's own: the profile in Settings › Me, the friends list and the circles.
class AppAccountProfiles implements AccountProfiles, AccountTakesIn {
  /// The app's own, but for a test's [home] (in place of [appFolder]), [files] and [networks]: a test must never delete
  /// what the computer running it keeps.
  AppAccountProfiles({String? home, FilesStore? files, List<InboxNetwork>? networks}) : _home = home, _files = files, _networks = networks;

  /// The folder this copy of the app keeps everything in, as it started: an iPhone's Application Support folder
  /// (lib/main.dart), a computer's store folder, GHOST_DESK_DIR's where that is set (lib/desktop/main.dart). What
  /// [wipe] deletes folders under; where it was never said (an Android phone, a browser, a test), none. Not
  /// DeskStore.defaultDir(): a copy of the app started with another folder (a developer's beside the installed one; on
  /// Windows the two share %APPDATA%) deleted the installed one's sessions (third review).
  static String? appFolder;

  /// Where [wipe] deletes folders: [home] for a test, else [appFolder].
  String? get wipeFolder => _home ?? appFolder;
  final String? _home;
  final FilesStore? _files;
  final List<InboxNetwork>? _networks;

  MeStore? get _store => Account.instance.store is _NoStore ? null : Account.instance.store;

  @override
  // A computer paired with a phone is never fresh: its identity is the phone's, and an account made there keeps it
  // (bound), so the two stay one person rather than the computer taking the words' identity alone.
  bool get fresh => !Sms.paired && Me.instance.username == null && Buddies.instance.all.isEmpty && Circles.instance.all.isEmpty && Me.instance.links.isEmpty;

  @override
  String get deviceName {
    // A page can't learn the name of the computer it is on, and is no kind of computer itself.
    if (Sms.browser) return Sms.browserName;
    final host = PlatformInfo.localHostname;
    final kind = PlatformInfo.isAndroid ? 'Android phone' : PlatformInfo.isIOS ? 'iPhone' : PlatformInfo.isMacOS ? 'Mac' : PlatformInfo.isWindows ? 'Windows PC' : 'Computer';
    return host.isEmpty || host == 'localhost' ? kind : '$kind · $host';
  }

  @override
  AccountBackup fill(AccountBackup backup) => backup.copyWith(
        username: Me.instance.username ?? '',
        displayName: Me.instance.displayName,
        bio: Me.instance.bio,
        keptKey: _store?.choice('kept_key', '') ?? '',
        friends: [for (final b in Buddies.instance.friends) b.toJson()],
        circles: [for (final c in Circles.instance.all) c.toJson()],
      );

  @override
  Future<void> apply(AccountBackup b) async {
    final store = _store;
    if (store == null) return;
    store.set('me_username', b.username);
    store.set('me_display', b.displayName);
    store.set('me_bio', b.bio);
    if (b.keptKey.length == 64) store.set('kept_key', b.keptKey);
    store.set('circles', jsonEncode(b.circles));
    store.set('circles_gone', '[]');
    await Sms.instance.buddiesKeep(jsonEncode(b.friends));
  }

  /// Friends first: a circle's people are named by them. Neither takes anything away ([Buddies.takeFromAccount],
  /// [Circles.fromAccount]).
  @override
  Future<void> takeIn(AccountBackup kept) async {
    if (_store == null) return;
    final friends = await Buddies.instance.takeFromAccount(kept.friends);
    Circles.instance.fromAccount(kept.circles);
    // What a friend new here said was passed over until now: asked for again, from the start.
    if (friends > 0) Friends.instance.catchUpAgain();
  }

  /// What this install keeps of its circles besides the list itself, much of it by each circle's seed (its key), and
  /// each as it reads when empty: it goes with the circles at sign-out, and comes back with them at sign-in. Read where
  /// each is written, in lib/circles/circles.dart; and the spaces' read marks (lib/voice/channels.dart), by each space's
  /// seed. (Each is read as JSON beside others in one go: an empty text would lose those with it.)
  static const circleLeftovers = {
    'circles_gone': '[]',
    'circles_seen': '{}',
    'circles_was': '{}',
    'circles_last_join': '{}',
    'circles_joined_at': '{}',
    'circles_joins': '{}',
    'circles_announce': '[]',
    'circles_system': '{}',
    'circle_invites': '[]',
    'circles_joined': '{}',
    'voice_read': '{}',
  };

  @override
  Future<void> forget() async {
    final store = _store;
    if (store == null) return;
    for (final k in ['me_username', 'me_display', 'me_bio', 'kept_key']) {
      store.set(k, '');
    }
    store.set('circles', '[]');
    // The history handover's asking and answers are this account's (GMFB-53): the next account signed in here asks
    // for its own, with an asking of its own.
    for (final k in ['history_n', 'history_done', 'history_tries', 'history_last', 'history_answered', 'history_note', 'history_empty', 'history_partial']) {
      store.set(k, '');
    }
    // A device of its own keeps its conversations and spaces at sign-out, and says so (lib/ui/account_screens.dart):
    // not the circles' seeds, kept where the circles were.
    if (Sms.standalone) {
      for (final e in circleLeftovers.entries) {
        final had = store.choice(e.key, '');
        if (had.isNotEmpty && had != e.value) store.set(e.key, e.value);
      }
    }
    await Sms.instance.buddiesKeep('[]');
  }

  @override
  Future<void> stopAll() async {
    // An iPhone's push token first (relay/lib/pushes.dart: `{"push": null}`), so a device that is about to be someone
    // else, or nothing, is not woken for the identity it was ("New message" alerts on a wiped iPhone). Only where one
    // was given: no other device has one.
    try {
      if (Net.instance.push != null) {
        Net.instance.setPush(null);
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
    } catch (_) {}
    try {
      await Net.instance.shutdown();
    } catch (_) {}
  }

  /// The other networks' folders under the app's own (lib/inbox: each network's `_dir`; Google Messages' helper on a
  /// computer, lib/desktop/gm_web.dart), deleted with everything else of the person's on a device of its own ([wipe]),
  /// after each network has signed itself out where it has a way to (Telegram logs out, Signal unlinks).
  static const otherNetworkFolders = ['tdlib', 'signal', 'whatsapp', 'matrix', 'gmessages'];

  @override
  Future<void> wipe() async {
    // A browser keeps no files of anyone's (lib/files is not in a page), and runs no other network.
    if (Sms.browser) return;
    // Files spaces' files.
    try {
      await (_files ?? FilesStore.instance).wipe();
    } catch (_) {}
    // Every other network's sign-in here: signed out, and its folder deleted. A device that stops being the person keeps
    // no Telegram, Signal, WhatsApp, Matrix, Messenger, Instagram, Discord, X, Slack or Google Messages session of theirs.
    final networks = _networks ?? Inbox.instance.networks;
    await Future.wait([
      for (final n in networks)
        () async {
          try {
            await n.signOut().timeout(const Duration(seconds: 12));
          } catch (_) {}
        }(),
    ]);
    final home = wipeFolder;
    if (home == null) return;
    final helpers = [for (final n in networks) if (n is AccountHelper) n.service.id];
    // Call recordings and their list, and the voice changer's folder (its ElevenLabs key): where an iPhone or a
    // computer keeps them (CallRecorder.folder, VoiceChanger.defaultFolder), in the app's folder. And the folder of the
    // relay this computer hosts (lib/relay_host: its key, where its people said they live), which a plain sign-out keeps.
    for (final path in [for (final name in ['recordings', 'voicechanger', 'relay', ...otherNetworkFolders, ...helpers]) '$home/$name']) {
      try {
        final dir = Directory(path);
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      } catch (_) {}
    }
  }
}

/// Stands in for the preferences until [Account.start]: kept in memory only, so nothing reads as signed in.
class _NoStore implements MeStore {
  final Map<String, String> _kept = {};
  @override
  String choice(String key, String fallback) => _kept[key] ?? fallback;
  @override
  bool flag(String key, {bool fallback = true}) => _kept[key] == null ? fallback : _kept[key] == 'on';
  @override
  void set(String key, String value) => _kept[key] = value;
  @override
  void setFlag(String key, bool on) => set(key, on ? 'on' : 'off');
}
