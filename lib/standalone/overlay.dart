import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../friends/file_card.dart';
import '../friends/buddies.dart';
import '../sms.dart';
import 'chats.dart';

/// On the Android phone: its friends by username, beside its texts (Matt, 2026-11-15: "Yes, Android next", so an
/// iPhone without texts and an Android phone write to each other). Android's store of texts has no room for someone
/// with no number, so their conversations are kept here in Dart ([UsernameChats]) and this stands in front of the
/// phone's channel ([inner]):
///
/// - What is about an `@username` address, or a conversation or row this keeps, is answered here.
/// - The list, contacts and where encryption stands are the phone's with these added.
/// - Everything else goes to the phone as it did.
///
/// Its ids start at [UsernameChats.base], 2^40, far past any Android hands out. A paired computer, which asks the
/// phone's Android side, does not see these conversations yet.
class OverlayCalls extends UsernameOverlay implements PhoneSide {
  OverlayCalls(super.inner, super.file);

  static const base = UsernameOverlay.base;

  /// Where the phone keeps it: the app's own files.
  static File defaultFile() => File('${Directory.systemTemp.parent.path}/files/username_chats.json');
}

/// Friends by username kept in Dart in front of other calls ([inner]): the phone's ([OverlayCalls]), and a computer
/// paired with one that has friends and circles of its own (lib/desktop/own_calls.dart). [answerOwn] answers first
/// what the one built on this keeps itself.
abstract class UsernameOverlay implements SmsCalls {
  UsernameOverlay(this.inner, this.file) {
    chats = UsernameChats(base: base, save: _save, buddies: () => _buddies);
  }

  // 2^40, written out: `1 << 40` is 0 in a browser, where a shift keeps 32 bits (test/source_guards_test.dart).
  static const base = 0x10000000000;

  /// What the one built on this answers itself, before anything here; [pass] for what it leaves to this.
  Future<Object?> answerOwn(String method, Map a) async => pass;

  /// The friends by username kept, as their list was last given.
  List<Buddy> get buddyList => _buddies;

  /// The calls this stands in front of, and the file the conversations with friends by username are kept in.
  final SmsCalls inner;
  final File file;
  late final UsernameChats chats;
  List<Buddy> _buddies = const [];

  /// Reads the conversations kept, and the friends by username from where [inner] keeps their list.
  Future<void> load() async {
    try {
      chats.load(jsonDecode(await file.readAsString()) as Map);
    } catch (_) {}
    try {
      keepBuddies(await inner.invokeMethod<String>('buddiesKept') ?? '[]');
    } catch (_) {}
  }

  /// Takes the friends' list as JSON; a list that cannot be read is no friends.
  void keepBuddies(String json) {
    try {
      _buddies = [for (final j in jsonDecode(json) as List) ?Buddy.fromJson(j)];
    } catch (_) {
      _buddies = const [];
    }
  }

  Future<void> _last = Future.value();

  /// Writes the conversations, one write after another, each to a new file that then takes the old one's place.
  void _save() {
    final text = jsonEncode(chats.toJson());
    _last = _last.catchError((_) {}).then((_) async {
      file.parent.createSync(recursive: true);
      final temp = File('${file.path}.new');
      await temp.writeAsString(text, flush: true);
      await temp.rename(file.path);
    });
  }

  @visibleForTesting
  Future<void> flushed() => _last;

  @override
  Future<T?> invokeMethod<T>(String method, [dynamic arguments]) async {
    final a = arguments is Map ? arguments : const {};
    final mine = await _answer(method, a);
    if (!identical(mine, _pass)) return mine as T?;
    return inner.invokeMethod<T>(method, arguments);
  }

  /// Not answered here: the phone's.
  static const pass = Object();
  static const _pass = pass;

  bool _isName(Object? address) => address is String && UsernameChats.isUsername(address);

  /// What this answers of a call, or [pass] for what goes on to [inner].
  Future<Object?> _answer(String method, Map a) async {
    final own = await answerOwn(method, a);
    if (!identical(own, pass)) return own;
    final thread = (a['thread'] as num?)?.toInt();
    final ours = thread != null && chats.ownsThread(thread);
    final row = (a['id'] as num?)?.toInt();
    switch (method) {
      // The list kept where the phone works out the sealing keys: passed on, and read here too.
      case 'buddiesKeep':
        keepBuddies((a['json'] as String?) ?? '[]');
        return _pass;

      // What friends write.
      case 'netTextOut' when _isName(a['address']):
        return chats.textOut(a['address'] as String, '${a['body']}', at: (a['at'] as num?)?.toInt());
      case 'callNote' when _isName(a['address']):
        chats.callNote(a['address'] as String, '${a['body']}', (a['at'] as num?)?.toInt() ?? DateTime.now().millisecondsSinceEpoch, out: a['out'] == true);
        return null;
      // A new device's history (GMFB-53): the conversations with friends by username are kept here, not by Android.
      case 'netHistory':
        return [for (final c in chats.history()) {'a': c.address, 'r': [for (final r in c.rows) [r.t, r.at, r.o ? 1 : 0]]}];
      case 'netHistoryKeep' when _isName(a['address']):
        return chats.keepHistory(a['address'] as String, UsernameChats.pastRows(a['rows']));
      case 'netTextIn' when _isName(a['address']):
        final address = a['address'] as String, body = '${a['body']}';
        chats.textIn(address, body, (a['at'] as num?)?.toInt() ?? DateTime.now().millisecondsSinceEpoch);
        // Android's notifications see only its own store: told of this one (android Notifier.chat).
        final t = chats.threadWith(address);
        if (!t.muted) {
          final name = chats.person(address)['name'] as String? ?? address;
          unawaited(inner.invokeMethod('notifyChat', {'thread': t.id, 'who': name, 'body': FileCard.preview(body)}).catchError((_) => null));
        }
        return null;
      case 'netTextState' when row != null && chats.ownsRow(row):
        chats.textState(row, '${a['state']}');
        return null;
      case 'netTextDrop' when row != null && chats.ownsRow(row):
        chats.dropRow(row);
        return null;
      case 'deleteMessage' when row != null && chats.ownsRow(row):
        chats.deleteRow(row);
        return null;

      // Where encryption stands: friends by username are on, and friends.
      case 'e2eList':
        return [...UsernameChats.phoneRecords(await inner.invokeMethod<List>('e2eList')), ...chats.states()];
      case 'e2e' when _isName(a['address']):
        final address = a['address'] as String;
        return chats.states().firstWhere((s) => s['address'] == address, orElse: () => {'address': address, 'state': 'none'});
      case 'friendSet' when _isName(a['address']):
        return null;
      case 'contact' when _isName(a['address']):
        return chats.person(a['address'] as String);
      case 'searchContacts':
        final found = [...?(await inner.invokeMethod<List>('searchContacts', a))];
        return [...found, ...chats.search('${a['query'] ?? ''}')];

      // The list: the phone's, with these.
      case 'conversations':
        // Texts off (Sms.textsOff): Android's list is not asked for; these alone.
        return [if (!Sms.textsOff) ...?(await inner.invokeMethod<List>('conversations', a)), for (final t in chats.sorted()) chats.conversation(t)];
      case 'conversationsPage':
        final page = Sms.textsOff ? <String, Object?>{'items': const [], 'next': null} : Map<String, Object?>.from((await inner.invokeMethod<Map>('conversationsPage', a)) ?? const {});
        // On the first lot: they are few, and the list sorts them in by date.
        if (((a['offset'] as num?)?.toInt() ?? 0) == 0) {
          page['items'] = [...((page['items'] as List?) ?? const []), for (final t in chats.sorted(archived: a['archived'] == true)) chats.conversation(t)];
        }
        return page;
      case 'archivedCount':
        return (Sms.textsOff ? 0 : (((await inner.invokeMethod('archivedCount', a)) as num?)?.toInt() ?? 0)) + chats.sorted(archived: true).length;

      // A conversation kept here.
      case 'conversation' when ours:
        return chats.conversation(chats.threads[thread]!);
      case 'messages' when ours:
        return chats.messages(thread, (a['limit'] as num?)?.toInt() ?? 0);
      case 'people' when ours:
        return [chats.person(chats.threads[thread]!.address)];
      case 'markRead' when ours:
        chats.markRead(thread);
        unawaited(inner.invokeMethod('cancelChat', {'thread': thread}).catchError((_) => null));
        return null;
      case 'archive' when ours:
        chats.archive(thread, a['archived'] == true);
        return null;
      case 'threadFlag' when ours:
        chats.flag('${a['name']}', thread, a['on'] == true);
        return null;
      case 'draft' when ours:
        return chats.draft(thread);
      case 'setDraft' when ours:
        chats.setDraft(thread, '${a['text'] ?? ''}');
        return null;
      case 'deleteThread' when ours:
        chats.delete([thread]);
        return null;
      case 'deleteThreads':
        final ids = [for (final id in (a['threads'] as List? ?? const [])) (id as num).toInt()];
        chats.delete(ids.where(chats.ownsThread));
        final theirs = ids.where((id) => !chats.ownsThread(id)).toList();
        if (theirs.isNotEmpty) await inner.invokeMethod('deleteThreads', {...a, 'threads': theirs});
        return null;
      case 'setOpenThread':
        chats.open = thread ?? -1;
        return _pass;
      case 'threadFor':
        final addresses = ((a['addresses'] as List?) ?? const []).map((x) => '$x').toList();
        if (addresses.length == 1 && _isName(addresses.first)) {
          final t = chats.threadWith(addresses.first);
          _save();
          return t.id;
        }
        // A number, with texts off: said why, not Android's refusal.
        if (Sms.textsOff) throw StateError(textsOffWords);
        return _pass;
      case 'send':
        final addresses = ((a['addresses'] as List?) ?? const []).map((x) => '$x').toList();
        if (addresses.any(_isName)) {
          if (addresses.length != 1) throw StateError('A friend by username can only be written to on their own yet');
          return chats.send(addresses.first, '${a['body'] ?? ''}');
        }
        if (Sms.textsOff) throw StateError(textsOffWords);
        return _pass;
    }
    return _pass;
  }
}

/// What is said where a text to a number is asked for with texts off (Sms.textsOff).
const textsOffWords = 'Texts are off. Turn them on in Settings › Texts to text a number.';

/// Sets the phone up to keep its friends by username in Dart, before anything is drawn.
Future<void> overlaySetup({File? file}) async {
  if (Sms.calls is PhoneSide) return;
  final calls = OverlayCalls(Sms.calls, file ?? OverlayCalls.defaultFile());
  await calls.load();
  Sms.calls = calls;
}
