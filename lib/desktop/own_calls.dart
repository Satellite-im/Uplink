import 'dart:convert';
import 'dart:io';
import '../platform_info.dart';

import 'package:flutter/foundation.dart';

import '../friends/buddies.dart';
import '../net/crypto.dart';
import '../sms.dart';
import '../standalone/chats.dart';
import '../standalone/overlay.dart';
import 'desk.dart' show restartApp;
import 'platform.dart';
import 'remote.dart';

/// A computer paired with a phone, with friends and circles of its own (Matt, 2026-11-18: "I want desktop to be able to
/// run standalone for internal friends and circles please fix that even if the desktop is linked").
///
/// Texts are the phone's, asked across the link ([LinkCalls], [inner]). Friends by username are this computer's: the
/// phone hands over its identity, its friends and its conversations with them once ([adopt], over the pairing's own
/// sealed link), and from then on this computer is on the relay server's hub as a device of that identity beside the
/// phone (relay/lib/hub.dart: a name's devices are each handed what is sent to it), so friends reach it with the phone
/// switched off. What is about an `@username` address, or a conversation kept here, is answered here, as on the phone
/// ([UsernameOverlay]); the routes' identity and the list of friends are this computer's too.
class DeskOwnCalls extends UsernameOverlay implements CapableCalls, OwnNetworkCalls {
  DeskOwnCalls(LinkCalls link, this.dir, {this.keychain = true}) : super(link, File('${dir.path}/chats.json'));

  /// Where this computer keeps them: its own folder beside the pairing.
  final Directory dir;

  /// Whether the identity is kept in the Keychain (a release build) or in the folder (a test, a build of one's own).
  final bool keychain;

  /// The name the identity is kept under in the Keychain.
  static const _account = 'desk-own-identity';

  /// The identity taken on from the phone, once read; and this computer's friends by username, as JSON.
  NetKeys? _keys;
  String _buddyJson = '[]';

  /// The link to the phone, which answers everything this does not.
  LinkCalls get link => inner as LinkCalls;

  /// Opens the app again ('restartApp'): a new copy, as desk.dart does; false under a test, which sets its own.
  Future<bool> Function() restart = _restartHere;

  static Future<bool> _restartHere() async {
    if (PlatformInfo.environment.containsKey('FLUTTER_TEST')) return false;
    await restartApp();
    return true;
  }

  /// What an Uplink account asks of the install it is on (lib/account/account.dart, SmsAccountPort): answered here, on
  /// this computer, and never passed to the phone. Passed on, as every call this does not answer is, a sign-in here
  /// would have put the account's identity into the phone and its words in the phone's vault (2026-11-18, found as
  /// Matt asked for "a way to login on desktop just to claim a username").
  static const accountCalls = {'identityExport', 'identityImport', 'identityForget', 'secretKeep', 'secretRead', 'restartApp'};

  @override
  Set<String> get caps => link.caps;

  /// The files in [dir]: the friends' list, the identity where the Keychain does not hold it, a secret by its name
  /// (cut down to lower-case letters, digits and _), and what the phone said of its account.
  File get _buddyFile => File('${dir.path}/buddies.json');
  File get _keyFile => File('${dir.path}/identity.key');
  File _secretFile(String name) => File('${dir.path}/secret-${name.replaceAll(RegExp(r'[^a-z0-9_]'), '')}.key');
  File get _phoneAccountFile => File('${dir.path}/phone_account.json');

  /// The Uplink account the phone is signed in to, as it last said in a handover: its address and username, so Settings
  /// › Me can ask this computer to sign in to the same one, and warn before another. Null where it is in none, or is a
  /// phone from before it said.
  ({String address, String username})? get phoneAccount {
    try {
      final m = jsonDecode(_phoneAccountFile.readAsStringSync()) as Map;
      final a = '${m['a'] ?? ''}';
      return a.isEmpty ? null : (address: a, username: '${m['u'] ?? ''}');
    } catch (_) {
      return null;
    }
  }

  /// What the phone said of its account in a handover ([handover]'s `account`), kept for [phoneAccount].
  void takePhoneAccount(Object? account) => keepPhoneAccount(dir, account);

  /// The same without a [DeskOwnCalls] made yet: written into [dir], or deleted where the phone says it is in none.
  /// Anything that is not the phone's answer leaves what was kept.
  static void keepPhoneAccount(Directory dir, Object? account) {
    try {
      final f = File('${dir.path}/phone_account.json');
      if (account is Map && '${account['a'] ?? ''}'.isNotEmpty) {
        f.writeAsStringSync(jsonEncode({'a': '${account['a']}', 'u': '${account['u'] ?? ''}'}));
      } else if (account is Map && f.existsSync()) {
        // The phone answered, and is in no account now.
        f.deleteSync();
      }
    } catch (_) {}
  }

  /// The phone's identity let go of here ('identityForget', signing out of an account on this computer): the next
  /// start finds nothing adopted, and the handover takes the phone's identity on again, so a computer signed out goes
  /// back to being the same you as its phone rather than someone new beside it.
  Future<void> _forgetIdentity() async {
    if (keychain) await MacPlatform.keyDelete(_account);
    for (final f in [_keyFile, File('${dir.path}/adopted.json')]) {
      if (f.existsSync()) f.deleteSync();
    }
    _keys = null;
  }

  /// Whether the phone's identity has been taken on here: only then is this used (lib/desktop/main.dart).
  static bool adoptedIn(Directory dir) => File('${dir.path}/adopted.json').existsSync();

  @override
  Future<void> load() async {
    dir.createSync(recursive: true);
    await super.load();
    try {
      _buddyJson = await _buddyFile.readAsString();
    } catch (_) {
      _buddyJson = '[]';
    }
    keepBuddies(_buddyJson);
    String? kept = keychain ? await MacPlatform.keyRead(_account) : null;
    if (kept == null && _keyFile.existsSync()) kept = _keyFile.readAsStringSync().trim();
    if (kept != null && kept.length == 64) {
      try {
        _keys = NetKeys.fromScalar(NetCrypto.unhex(kept));
      } catch (_) {}
    }
  }

  /// Takes on what the phone handed over ([handover]): its identity, its friends by username and its conversations
  /// with them. The identity is kept as the phone keeps it, in the Keychain (or this folder, for a build of one's own).
  static Future<void> adopt(Directory dir, Map<String, Object?> handover, {bool keychain = true}) async {
    dir.createSync(recursive: true);
    final scalar = '${handover['scalar'] ?? ''}';
    final keys = NetKeys.fromScalar(NetCrypto.unhex(scalar));
    if (!keychain || !await MacPlatform.keyWrite(_account, scalar)) File('${dir.path}/identity.key').writeAsStringSync(scalar);
    keepPhoneAccount(dir, handover['account']);
    File('${dir.path}/buddies.json').writeAsStringSync('${handover['buddies'] ?? '[]'}');
    final chats = handover['chats'];
    if (chats is Map && !File('${dir.path}/chats.json').existsSync()) File('${dir.path}/chats.json').writeAsStringSync(jsonEncode(chats));
    File('${dir.path}/adopted.json').writeAsStringSync(jsonEncode({'id': keys.id, 'at': DateTime.now().millisecondsSinceEpoch}));
  }

  /// Friends by username the phone has and this computer does not, or has as less far along, taken in (asked of the
  /// phone each time the two connect): the two keep each other's lists, neither losing one the other made.
  static String mergeBuddies(String mine, String theirs) {
    List<Buddy> read(String j) {
      try {
        return [for (final b in jsonDecode(j) as List) ?Buddy.fromJson(b)];
      } catch (_) {
        return const [];
      }
    }

    int rank(String state) => state == 'yes' ? 2 : 1;
    final out = <String, Buddy>{for (final b in read(mine)) b.id: b};
    for (final b in read(theirs)) {
      final had = out[b.id];
      if (had == null || rank(b.state) > rank(had.state)) out[b.id] = b;
    }
    return jsonEncode([for (final b in out.values) b.toJson()]);
  }

  /// The phone's list taken in ([mergeBuddies]).
  void takeBuddies(String theirs) => _keepBuddyJson(mergeBuddies(_buddyJson, theirs));

  /// This computer's list, for the phone to take in.
  String get buddyJson => _buddyJson;

  /// Takes a new list of friends: held, written to its file, and the screens told the choices changed.
  void _keepBuddyJson(String json) {
    _buddyJson = json;
    keepBuddies(json);
    try {
      _buddyFile.writeAsStringSync(json);
    } catch (_) {}
    Sms.instance.prefsChanged.add(null);
  }

  @override
  Future<Object?> answerOwn(String method, Map a) async {
    final keys = _keys;
    switch (method) {
      // Who this computer is on the routes: the phone's identity, taken on.
      case 'netIdentity' when keys != null:
        return {'id': keys.id, 'key': base64Encode(keys.public)};
      case 'netSign' when keys != null:
        return NetCrypto.sign(keys, (a['message'] as List).cast<int>());
      case 'netPeers' when keys != null:
        return UsernameChats.peersOf(buddyList, keys);
      // An Uplink account on this computer ([accountCalls]): its identity, the account's words and password key kept
      // beside it (the Keychain, or this folder in a build of one's own, as the standalone computer keeps them), and a
      // clean start. None of these reaches the phone.
      case 'identityExport':
        if (keys == null) throw StateError('This computer has not taken on an identity yet');
        return keys.scalar;
      case 'identityImport':
        final made = NetKeys.fromScalar((a['scalar'] as List).cast<int>());
        final hex = NetCrypto.hex(made.scalar);
        if (!keychain || !await MacPlatform.keyWrite(_account, hex)) {
          _keyFile.writeAsStringSync(hex, flush: true);
        } else if (_keyFile.existsSync()) {
          // The Keychain took it: a key left in the folder from before would be read in its place by a build without it.
          _keyFile.deleteSync();
        }
        _keys = made;
        return null;
      case 'identityForget':
        await _forgetIdentity();
        return true;
      case 'secretKeep':
        final name = '${a['name']}', value = '${a['value'] ?? ''}';
        final file = _secretFile(name);
        if (value.isEmpty) {
          if (keychain) await MacPlatform.keyDelete('desk-own-secret-$name');
          if (file.existsSync()) file.deleteSync();
          return null;
        }
        if (!keychain || !await MacPlatform.keyWrite('desk-own-secret-$name', value)) file.writeAsStringSync(value, flush: true);
        return null;
      case 'secretRead':
        final name = '${a['name']}';
        final kept = keychain ? await MacPlatform.keyRead('desk-own-secret-$name') : null;
        if (kept != null) return kept;
        final file = _secretFile(name);
        return file.existsSync() ? file.readAsStringSync() : null;
      case 'restartApp':
        // What an account changes here (the identity, the friends' list) is written as it is changed, before this.
        return restart();
      // Friends by username, kept here.
      case 'buddiesKeep':
        _keepBuddyJson((a['json'] as String?) ?? '[]');
        return null;
      case 'buddiesKept':
        return _buddyJson;
      // Where encryption stands: the phone's for its numbers, these for friends by username.
      case 'e2eList':
        List<Object?> phone;
        try {
          phone = UsernameChats.phoneRecords(await inner.invokeMethod<List>('e2eList'));
        } catch (_) {
          phone = const [];
        }
        return [...phone, ...chats.states()];
      // The computer has no texts route of its own: what a friend is sent goes by the hub.
      case 'netSmsAvailable':
        return false;
      case 'netSmsDrain':
        return const [];
      // A new message from a friend: told of on this computer, not by the phone.
      case 'notifyChat' || 'cancelChat':
        return null;
    }
    // Whatever is left of the account's calls (none should be) is refused rather than passed to the phone.
    if (accountCalls.contains(method)) throw StateError('$method is this computer\'s, not the phone\'s');
    return UsernameOverlay.pass;
  }

  @visibleForTesting
  NetKeys? get keys => _keys;
}
