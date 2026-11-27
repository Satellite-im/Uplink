import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/net/crypto.dart';
import 'package:ghost_messaging/sms.dart';
import 'package:ghost_messaging/standalone/standalone.dart';

/// An iPhone of its own (lib/standalone; Matt, 2026-11-15: "roll a version of the app that works without sms"): who
/// it is, the friends it reaches and the key each pair seals with, and the conversations it keeps.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    for (final c in ['ghost_desktop/system', 'ghost_messaging/sms']) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(MethodChannel(c), (_) async => null);
    }
  });

  late Directory root;
  setUp(() => root = Directory.systemTemp.createTempSync('standalone'));
  tearDown(() => root.deleteSync(recursive: true));

  Future<StandaloneCalls> install(String name) async {
    final c = StandaloneCalls(Directory('${root.path}/$name'), keychain: false);
    await c.load();
    return c;
  }

  Map<String, Object> buddy(String username, Map me, String state) => {'u': username, 'i': me['id'] as String, 'k': me['key'] as String, 'n': '', 'b': '', 's': state, 'a': 0};

  test('who it is stays who it is', () async {
    final a = await install('a');
    final first = await a.invokeMethod<Map>('netIdentity');
    final again = await (await install('a')).invokeMethod<Map>('netIdentity');
    expect(again, first);
    expect(base64Decode(first!['key'] as String), hasLength(33));
    expect(first['id'], NetCrypto.idOf(base64Decode(first['key'] as String)));
  });

  test('two iPhones who are friends seal with the same key, as each works it out', () async {
    final a = await install('a'), b = await install('b');
    final ida = (await a.invokeMethod<Map>('netIdentity'))!, idb = (await b.invokeMethod<Map>('netIdentity'))!;
    // a asked b; b was asked: each has the other.
    await a.invokeMethod('buddiesKeep', {'json': jsonEncode([buddy('bee', idb, 'asked')])});
    await b.invokeMethod('buddiesKeep', {'json': jsonEncode([buddy('ay', ida, 'invited')])});
    final pa = (await a.invokeMethod<List>('netPeers'))!, pb = (await b.invokeMethod<List>('netPeers'))!;
    expect(pa, hasLength(1));
    expect(pb, hasLength(1));
    expect((pa.single as Map)['id'], idb['id']);
    expect((pb.single as Map)['id'], ida['id']);
    expect((pa.single as Map)['key'] as Uint8List, (pb.single as Map)['key'] as Uint8List);
    // Only a friend who said yes is a conversation.
    expect((pa.single as Map)['address'], '');
    await a.invokeMethod('buddiesKeep', {'json': jsonEncode([buddy('bee', idb, 'yes')])});
    expect(((await a.invokeMethod<List>('netPeers'))!.single as Map)['address'], '@bee');
    await a.flushed();
    await b.flushed();
  });

  test('a friend\'s words, kept and shown as a conversation, newest first; pinned ones come too', () async {
    final a = await install('a');
    await a.invokeMethod('netTextIn', {'address': '@bee', 'body': 'first', 'at': 1000});
    await a.invokeMethod('netTextIn', {'address': '@bee', 'body': 'second', 'at': 2000});
    final out = await a.invokeMethod<int>('netTextOut', {'address': '@cee', 'body': 'to cee'});
    await a.invokeMethod('netTextState', {'id': out, 'state': 'delivered'});
    final page = Map<String, Object?>.from((await a.invokeMethod<Map>('conversationsPage', {'limit': 1, 'offset': 0, 'pinned': true}))!);
    final items = [for (final c in page['items'] as List) Conversation.from(c as Map)];
    expect(items.single.people.single.address, '@cee', reason: 'the newest');
    expect(page['next'], 1);
    final bee = (await a.invokeMethod<int>('threadFor', {'addresses': ['@bee']}))!;
    await a.invokeMethod('threadFlag', {'name': 'pinned', 'thread': bee, 'on': true});
    final again = (await a.invokeMethod<Map>('conversationsPage', {'limit': 1, 'offset': 0, 'pinned': true}))!;
    expect([for (final c in again['items'] as List) (c as Map)['id']], containsAll([bee]), reason: 'a pinned one heads the list however old');
    final messages = [for (final m in (await a.invokeMethod<List>('messages', {'thread': bee, 'limit': 50}))!) Message.from(m as Map)];
    expect(messages.map((m) => m.body), ['second', 'first'], reason: 'newest first, as the phone gives them');
    expect(messages.first.via, 'net');
    final c = Conversation.from((await a.invokeMethod<Map>('conversation', {'thread': bee}))!);
    expect(c.unread, isTrue);
    await a.invokeMethod('markRead', {'thread': bee});
    expect(Conversation.from((await a.invokeMethod<Map>('conversation', {'thread': bee}))!).unread, isFalse);
    // Kept across a restart.
    await a.flushed();
    final back = await install('a');
    expect([for (final m in (await back.invokeMethod<List>('messages', {'thread': bee, 'limit': 50}))!) (m as Map)['body']], ['second', 'first']);
  });

  // lib/account/account.dart: signed out with everything deleted, or removed from the account from another device, an
  // iPhone or a computer of its own deletes everything of it: an honest client stops being the account.
  test('wiped: the conversations, who it is and every secret gone; a note kept for the welcome; nothing written after', () async {
    final a = await install('a');
    final before = (await a.invokeMethod<Map>('netIdentity'))!['id'];
    await a.invokeMethod('netTextIn', {'address': '@bee', 'body': 'a canary nobody else wrote', 'at': 1000});
    await a.invokeMethod('setPref', {'key': 'circles_joined_at', 'value': '{"${'5e' * 32}":1}'});
    await a.invokeMethod('secretKeep', {'name': 'account_words', 'value': 'twelve words'});
    await a.invokeMethod('secretKeep', {'name': 'circle_keys', 'value': 'keys'});
    await a.flushed();
    final dir = Directory('${root.path}/a');
    expect(File('${dir.path}/secret-names.json').readAsStringSync(), allOf(contains('account_words'), contains('circle_keys')));
    // Something else of the app's in the same folder (on an iPhone it is Application Support) is left alone.
    File('${dir.path}/pairing.json').writeAsStringSync('{}');
    await a.invokeMethod('wipeHere', {'note': 'removed'});
    expect(dir.listSync().map((e) => e.uri.pathSegments.last).toSet(), {'standalone.json', 'pairing.json'});
    expect(jsonDecode(File('${dir.path}/standalone.json').readAsStringSync()), {
      'prefs': {StandaloneCalls.noteKey: 'removed'},
    });
    // Nothing asked after it is written: the app is about to start again.
    await a.invokeMethod('netTextIn', {'address': '@bee', 'body': 'after', 'at': 2000});
    await a.invokeMethod('secretKeep', {'name': 'circle_keys', 'value': 'again'});
    await a.flushed();
    expect(File('${dir.path}/secret-circle_keys.key').existsSync(), isFalse);
    expect(File('${dir.path}/standalone.json').readAsStringSync(), isNot(contains('after')));
    // Started again: someone new, nothing of before, the note for the welcome.
    final again = await install('a');
    expect((await again.invokeMethod<Map>('netIdentity'))!['id'], isNot(before));
    expect(await again.invokeMethod<List>('conversations'), isEmpty);
    expect(await again.invokeMethod('secretRead', {'name': 'account_words'}), isNull);
    expect((await again.invokeMethod<Map>('prefs'))!, {StandaloneCalls.noteKey: 'removed'});
  });

  // The second review: a read that failed at start was taken for "nothing kept", and the first write after replaced
  // the real conversations. What can't be read is not started on; what makes no sense is kept aside, never written over.
  test('what can\'t be read just now is not started on, and nothing is written over it', () async {
    final dir = Directory('${root.path}/a')..createSync(recursive: true);
    // The JSON is there, and can't be read just now (here: not readable by this user).
    final json = File('${dir.path}/standalone.json')..writeAsStringSync('{"prefs":{"theme":"dark"},"buddies":"[]"}');
    Process.runSync('chmod', ['000', json.path]);
    addTearDown(() => Process.runSync('chmod', ['644', json.path]));
    final c = StandaloneCalls(dir, keychain: false);
    await expectLater(c.loadAgain(tries: 2, apart: Duration.zero), throwsA(isA<FileSystemException>()));
    Process.runSync('chmod', ['644', json.path]);
    expect(json.readAsStringSync(), '{"prefs":{"theme":"dark"},"buddies":"[]"}', reason: 'left as it was');
    expect(File('${dir.path}/identity.key').existsSync(), isFalse, reason: 'no one new made in its place');
  });

  test('what was read and makes no sense is kept aside, and the app starts without writing over it', () async {
    final a = await install('a');
    await a.invokeMethod('netTextIn', {'address': '@bee', 'body': 'kept', 'at': 1000});
    await a.flushed();
    final dir = Directory('${root.path}/a');
    File('${dir.path}/standalone.json').writeAsStringSync('{"prefs": {"theme": "da');
    final again = await install('a');
    expect(await again.invokeMethod<List>('conversations'), isEmpty);
    final aside = [for (final f in dir.listSync().whereType<File>()) if (f.path.contains('standalone.json.unreadable-')) f];
    expect(aside, hasLength(1));
    expect(aside.single.readAsStringSync(), '{"prefs": {"theme": "da');
    // Written after: the JSON anew, the one kept aside untouched.
    await again.invokeMethod('setPref', {'key': 'theme', 'value': 'dark'});
    await again.flushed();
    expect(aside.single.readAsStringSync(), '{"prefs": {"theme": "da');
    // Who it is was read as ever.
    expect((await again.invokeMethod<Map>('netIdentity'))!['id'], (await a.invokeMethod<Map>('netIdentity'))!['id']);
    // Everything of the person's deleted (signed out, or removed) takes the copy kept aside too (third review); only
    // the welcome's note is written after.
    await again.invokeMethod('wipeHere', {'note': 'signed-out'});
    expect([for (final f in dir.listSync().whereType<File>()) if (f.path.contains('unreadable')) f.uri.pathSegments.last], isEmpty);
  });

  test('where it lives: Application Support beside tmp, not inside it (iOS gives the app no HOME)', () {
    final dir = StandaloneCalls.defaultDir().path;
    expect(dir, endsWith('/Library/Application Support/Ghost Messaging'));
    expect(dir.startsWith(Directory.systemTemp.path) && Platform.environment['HOME'] == null, isFalse);
  });
}
