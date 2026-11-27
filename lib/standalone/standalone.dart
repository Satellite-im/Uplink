import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../platform_info.dart';

import 'package:flutter/foundation.dart';

import '../desktop/desk_voice.dart';
import '../desktop/platform.dart';
import '../friends/buddies.dart';
import '../net/crypto.dart';
import '../sms.dart';
import 'chats.dart';
import 'store.dart';
import 'store_files.dart';

/// Uplink on an iPhone of its own (Matt, 2026-11-15: "investigate if we can within apples rules make a
/// bridge for messaging through RCS like we're doing with mautrix on android and if not we'll want to roll a version
/// of the app that works without sms"; "it's unlikely the user will ever have two phones").
///
/// iOS lets no app read or send texts (outside the EU, where iOS 26 gives the default messaging app a framework for
/// it), and the Google Messages bridge needs an Android phone running Google Messages. So here there are no texts:
/// people are reached by username, over the relay server, sealed as the phone seals its routes' packets.
///
/// This stands where the Android phone's channel stands ([SmsCalls]): the same calls by the same names, answered
/// here, so the phone's own screens and start-up run unchanged ([Sms.standalone]).
///
/// - **Who this iPhone is**: a P-256 key made here, kept in the Keychain ([NetKeys]); the same arithmetic the phone's
///   E2eCrypto does, so an iPhone and an Android phone seal to each other.
/// - **Friends by username** ([Buddies]): their list is kept here, and each one's sealing key is made here from it,
///   as android Buddies.kt does. Each friend is a conversation, addressed `@username` ([addressOf]), so what
///   [Friends] does for a phone-number friend (send, acknowledge, take back) it does for them.
/// - **The conversations** are kept in a file of this app's (`standalone.json`): what was written and what came, and
///   each conversation's read, archived, pinned and muted.
///
/// Where all of that is kept is [StandaloneStore] (store.dart): a folder and the Keychain here, a browser's own store
/// for the app in a web page, which runs these same calls (lib/web).
class StandaloneCalls implements SmsCalls {
  /// Kept in [dir], and in the Keychain where [keychain] (a build for a device; a test keeps it all in the folder).
  StandaloneCalls(Directory dir, {bool keychain = true}) : this.on(StandaloneFiles(dir, keychain: keychain));

  /// Kept wherever [store] keeps things: a browser's own store (lib/web), which has no folder.
  StandaloneCalls.on(this.store) {
    chats = UsernameChats(save: _save, buddies: () => _buddyList);
  }

  /// Where the JSON, the identity's key and the secrets are kept (store.dart).
  final StandaloneStore store;

  /// Who this iPhone is, once [load] has run; the person's choices; and the friends by username, as the JSON
  /// [Buddies] gave to be kept.
  NetKeys? _keys;
  Map<String, String> _prefs = {};
  String _buddies = '[]';

  /// The conversations: every one an iPhone has is with a friend by username.
  late final UsernameChats chats;

  /// Starts the app again: on a Mac a new copy of the app is opened and this one ends; an iPhone cannot, and says so
  /// (false), and the person is asked to. Never under a test.
  Future<bool> Function() restart = _restartHere;

  /// Opens a web address in this device's own browser, and says whether it could ([MacPlatform.openLink]); a page
  /// in a browser opens it beside itself (lib/web).
  Future<bool> Function(String url) openLink = MacPlatform.openLink;

  static Future<bool> _restartHere() async {
    if (PlatformInfo.environment.containsKey('FLUTTER_TEST') || !PlatformInfo.isMacOS) return false;
    // …/Uplink.app/Contents/MacOS/Uplink, three folders up.
    final app = File(PlatformInfo.resolvedExecutable).parent.parent.parent.path;
    if (!app.endsWith('.app')) return false;
    await Process.start('/bin/sh', ['-c', 'sleep 1; /usr/bin/open -n "\$0"', app], mode: ProcessStartMode.detached);
    exit(0);
  }

  /// The address a friend by username is spoken of by: `@` and their username.
  static String addressOf(String username) => UsernameChats.addressOf(username);

  /// Where an iPhone keeps it: the app's Application Support folder, which iOS keeps and backs up. iOS gives a Flutter
  /// app no HOME, so the container is found from its tmp folder, which is in it.
  static Directory defaultDir() {
    final home = PlatformInfo.environment['HOME'] ?? Directory.systemTemp.parent.path;
    return Directory('$home/Library/Application Support/Ghost Messaging');
  }

  /// Throws [StoreLost] where what is kept is there and can't be opened (a browser's store, lib/web/store.dart): the
  /// page wipes it and the person signs in again, rather than this device quietly becoming someone new. Throws
  /// whatever else stopped it being read just now (a browser's store busy or full, a file that can't be read): this
  /// start is not made, and its caller says so and tries again ([loadAgain]). Started empty, its first write would
  /// have replaced the conversations it couldn't read.
  Future<void> load() async {
    await store.open();
    final text = await store.readState();
    if (text != null) {
      try {
        final j = jsonDecode(text) as Map;
        _prefs = {for (final e in ((j['prefs'] as Map?) ?? const {}).entries) '${e.key}': '${e.value}'};
        _buddies = (j['buddies'] as String?) ?? '[]';
        chats.load(j);
      } catch (_) {
        // Read, and it makes no sense: kept aside (a browser's store is lost instead), and the app starts without it.
        _prefs = {};
        _buddies = '[]';
        chats.load(const {});
        await store.unreadableState();
      }
    }
    _keys = await _identity();
  }

  /// [load], tried [tries] times a moment apart where what is kept couldn't be read just now; the last error where it
  /// never could, for the caller to say (StoreUnreadableNotice) rather than start with nothing. A store lost is not
  /// tried again.
  Future<void> loadAgain({int tries = 3, Duration apart = const Duration(milliseconds: 400)}) async {
    for (var i = 1;; i++) {
      try {
        return await load();
      } on StoreLost {
        rethrow;
      } catch (_) {
        if (i >= tries) rethrow;
        await Future<void>.delayed(apart);
      }
    }
  }

  Future<NetKeys> _identity() async {
    final kept = await store.readIdentity();
    if (kept != null && kept.length == 64) {
      try {
        return NetKeys.fromScalar(NetCrypto.unhex(kept));
      } catch (_) {}
    }
    final made = NetKeys.generate();
    await store.writeIdentity(NetCrypto.hex(made.scalar));
    return made;
  }

  /// The write before this one: each waits for the last, so the file is never written by two at once.
  Future<void> _last = Future.value();

  /// Nothing more is kept ([close], or everything here wiped): what is asked to be written after is let go.
  bool _closed = false;
  bool get closed => _closed;

  /// Why everything here was wiped ('signed-out', 'removed'), for the page in a browser that loads again after
  /// (lib/web/app.dart); null where it wasn't.
  String? endNote;

  void _save() {
    if (_closed) return;
    final text = jsonEncode({'prefs': _prefs, 'buddies': _buddies, ...chats.toJson()});
    _last = _last.catchError((_) {}).then((_) => store.writeState(text));
  }

  /// Every write done: before the app starts again, before a page in a browser hands over to another tab of itself
  /// (lib/web), and for a test.
  Future<void> flushed() => _last;

  /// Nothing more is written from here: a page in a browser handing over to another tab, which will write the same
  /// store (lib/web/app.dart). What was asked before is still written ([flushed]).
  void close() {
    _closed = true;
    store.close();
  }

  /// Everything this device keeps deleted: the conversations and choices, who it is, every secret (lib/account: signed
  /// out with everything deleted, or removed from the account from another device). What was being written is
  /// finished first, so it can't put back what is deleted; nothing is written after but, where it is given, [note]
  /// alone, for the welcome to say as the app starts again (lib/standalone/welcome.dart). A page in a browser keeps
  /// nothing at all, and is loaded again with the note instead ([endNote]).
  Future<void> wipe({String? note}) async {
    _closed = true;
    await _last.catchError((_) {});
    await store.wipe();
    endNote = note;
    _prefs = {};
    _buddies = '[]';
    chats.load(const {});
    if (note != null) {
      try {
        await store.writeState(jsonEncode({
          'prefs': {noteKey: note},
        }));
      } catch (_) {}
    }
  }

  /// The pref that carries why the app starts again with nothing ([wipe]), for the welcome to say.
  static const noteKey = 'acct_note';

  List<Buddy> get _buddyList {
    try {
      return [for (final j in jsonDecode(_buddies) as List) ?Buddy.fromJson(j)];
    } catch (_) {
      return const [];
    }
  }

  // --- the calls ---------------------------------------------------------------------------------------------------

  @override
  Future<T?> invokeMethod<T>(String method, [dynamic arguments]) async {
    final a = arguments is Map ? arguments : const {};
    return (await _answer(method, a)) as T?;
  }

  /// Answers one of the phone's calls by its name, in the shape the phone answers in.
  Future<Object?> _answer(String method, Map a) async {
    int thread() => (a['thread'] as num).toInt();
    switch (method) {
      // Who this iPhone is, and who it reaches.
      case 'netIdentity':
        final k = _keys!;
        return {'id': k.id, 'key': base64Encode(k.public)};
      case 'netSign':
        return NetCrypto.sign(_keys!, (a['message'] as List).cast<int>());
      case 'netPeers':
        return UsernameChats.peersOf(_buddyList, _keys!);

      // An Uplink account (lib/account; Matt, 2026-11-17: "We need to have a way to login to existing accounts"): this
      // install's key to seal into the account's backup, a restored key put in its place, the account's words kept
      // beside the key in the Keychain, and a clean start once a device has signed in.
      case 'identityExport':
        return _keys!.scalar;
      case 'identityImport':
        // Once everything here is wiped (or another tab has the store), nothing is put back.
        if (_closed) return null;
        final made = NetKeys.fromScalar((a['scalar'] as List).cast<int>());
        await store.writeIdentity(NetCrypto.hex(made.scalar), imported: true);
        _keys = made;
        return null;
      case 'secretKeep':
        if (_closed) return null;
        final name = '${a['name']}', value = '${a['value'] ?? ''}';
        if (value.isEmpty) {
          await store.deleteSecret(name);
          return null;
        }
        await store.writeSecret(name, value);
        return null;
      case 'secretRead':
        return store.readSecret('${a['name']}');
      // Everything of the account on this device deleted (lib/account: signed out with everything, or removed).
      case 'wipeHere':
        await wipe(note: a['note'] is String ? a['note'] as String : null);
        return null;
      case 'restartApp':
        await flushed();
        return restart();
      case 'buddiesKeep':
        _buddies = (a['json'] as String?) ?? '[]';
        _save();
        Sms.instance.prefsChanged.add(null);
        return null;
      case 'buddiesKept':
        return _buddies;
      case 'e2eList':
        return chats.states();
      case 'e2e':
        final address = '${a['address']}';
        return chats.states().firstWhere((s) => s['address'] == address, orElse: () => {'address': address, 'state': 'none'});
      case 'friendSet':
        return null;

      // What friends write, kept here ([Friends] by the routes).
      case 'netTextOut':
        return chats.textOut('${a['address']}', '${a['body']}', at: (a['at'] as num?)?.toInt());
      case 'netTextState':
        chats.textState((a['id'] as num).toInt(), '${a['state']}');
        return null;
      case 'netTextDrop':
        chats.dropRow((a['id'] as num).toInt());
        return null;
      case 'callNote':
        chats.callNote('${a['address']}', '${a['body']}', (a['at'] as num?)?.toInt() ?? DateTime.now().millisecondsSinceEpoch, out: a['out'] == true);
        return null;
      case 'netTextIn':
        chats.textIn('${a['address']}', '${a['body']}', (a['at'] as num?)?.toInt() ?? DateTime.now().millisecondsSinceEpoch);
        return null;

      // A new device's history (GMFB-53): what is held here for it, and what another device held, taken.
      case 'netHistory':
        return [for (final c in chats.history()) {'a': c.address, 'r': [for (final r in c.rows) [r.t, r.at, r.o ? 1 : 0]]}];
      case 'netHistoryKeep':
        return chats.keepHistory('${a['address']}', UsernameChats.pastRows(a['rows']));

      // The list and a conversation.
      case 'conversations':
        return [for (final t in chats.sorted()) chats.conversation(t)];
      case 'conversationsPage':
        // `pinned` asks for the pinned ones as well as the newest, as Android's does (pinnedToo): they head the list
        // however old they are.
        final all = chats.sorted(archived: a['archived'] == true);
        final offset = (a['offset'] as num?)?.toInt() ?? 0, limit = (a['limit'] as num?)?.toInt() ?? 0;
        final page = limit <= 0 ? all.skip(offset).toList() : all.skip(offset).take(limit).toList();
        if (a['pinned'] == true && offset == 0) page.addAll(all.where((t) => t.pinned && !page.contains(t)));
        final next = limit > 0 && offset + limit < all.length ? offset + limit : null;
        return {'items': [for (final t in page) chats.conversation(t)], 'next': next};
      case 'conversation':
        final t = chats.threads[thread()];
        return t == null ? null : chats.conversation(t);
      case 'archivedCount':
        return chats.sorted(archived: true).length;
      case 'messages':
        return chats.messages(thread(), (a['limit'] as num?)?.toInt() ?? 0);
      case 'people':
        final t = chats.threads[thread()];
        return t == null ? const [] : [chats.person(t.address)];
      case 'threadFor':
        final addresses = ((a['addresses'] as List?) ?? const []).map((x) => '$x').toList();
        if (addresses.length != 1) return -1;
        final t = chats.threadWith(addresses.first);
        _save();
        return t.id;
      case 'send':
        final addresses = ((a['addresses'] as List?) ?? const []).map((x) => '$x').toList();
        if (addresses.length != 1) throw StateError('Only words to one friend can be sent from this iPhone yet');
        return chats.send(addresses.first, '${a['body'] ?? ''}');
      case 'markRead':
        chats.markRead(thread());
        return null;
      case 'setOpenThread':
        chats.open = (a['thread'] as num?)?.toInt() ?? -1;
        return null;
      case 'deleteThread':
        chats.delete([thread()]);
        return null;
      case 'deleteThreads':
        chats.delete([for (final id in (a['threads'] as List? ?? const [])) (id as num).toInt()]);
        return null;
      case 'deleteMessage':
        chats.deleteRow((a['id'] as num).toInt());
        return null;
      case 'archive':
        chats.archive(thread(), a['archived'] == true);
        return null;
      case 'threadFlag':
        chats.flag('${a['name']}', thread(), a['on'] == true);
        return null;
      case 'draft':
        return chats.draft(thread());
      case 'setDraft':
        chats.setDraft(thread(), '${a['text'] ?? ''}');
        return null;
      case 'contact':
        return chats.person('${a['address']}');
      case 'searchContacts':
        return chats.search('${a['query'] ?? ''}');

      // The app's choices, kept with the rest.
      case 'prefs':
        return Map<String, String>.from(_prefs);
      case 'setPref':
        _prefs['${a['key']}'] = '${a['value']}';
        _save();
        return null;

      // Where it stands: set up (there is nothing to be made the default for), no texts, nothing waiting.
      case 'status':
        return {'isDefault': true, 'contacts': true, 'notifications': true, 'phone': false, 'sms': false};
      case 'netSmsAvailable':
        return false;
      case 'netSmsDrain':
        return const [];
      case 'ownNumber':
        return null;
      case 'groups':
        return const [];
      case 'computers':
      case 'deskList':
      case 'blockedNumbers':
        return const [];

      // A link opened in this device's own browser: a link in a message, and signing up with Discord (Matt,
      // 2026-11-20: "when clicking sign up with discord it says "no browser could be opened""), which had nothing here.
      case 'openLink':
        return openLink('${a['url'] ?? ''}');

      // The iPhone's own: pictures, the microphone, playing (ios/Runner/DeskChannels.swift, as on a Mac).
      case 'pickImages':
        return await MacPlatform.pickPictures(most: (a['most'] as num?)?.toInt() ?? 5);
      case 'voiceLength':
        final bytes = a['bytes'];
        return bytes is Uint8List ? await MacPlatform.voiceLength(bytes) : 0;
      // A voice message from this device's own microphone, for a network's chat, a space or a friend (GMFB-32): no
      // texts here, so always a file, never a carrier's limit (lib/desktop/desk_voice.dart).
      case 'voiceStart':
        return DeskVoice.start();
      case 'voiceLevel':
        return DeskVoice.level();
      case 'voiceCancel':
        await DeskVoice.cancel();
        return null;
      case 'voiceFinish':
        return DeskVoice.finish();
    }
    // Everything else is the Android phone's alone (texts, MMS, the default app, its updates): nothing here.
    return null;
  }
}

/// Sets the app up as an iPhone of its own, before anything is drawn: the calls answered here, and the routes,
/// directory and calls run here ([Sms.standalone]).
Future<void> standaloneSetup({Directory? dir, bool? keychain}) async {
  final calls = StandaloneCalls(dir ?? StandaloneCalls.defaultDir(), keychain: keychain ?? kReleaseMode);
  // What can't be read just now is not started on (lib/main.dart says so instead).
  await calls.loadAgain();
  Sms.calls = calls;
  Sms.standalone = true;
}
