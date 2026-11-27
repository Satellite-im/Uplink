import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/circles/circle.dart';
import 'package:ghost_messaging/circles/circles.dart' show CircleRoom;
import 'package:ghost_messaging/circles/welcome.dart' show readOnlyRoomOf;
import 'package:ghost_messaging/files/files_api.dart' show FilesApi;
import 'package:ghost_messaging/files/files_http.dart' show IoFilesHttp;
import 'package:ghost_messaging/files/files_store.dart';
import 'package:ghost_messaging/mentions.dart';
import 'package:ghost_messaging/net/carrier.dart';
import 'package:ghost_messaging/net/crypto.dart';
import 'package:ghost_messaging/net/hub_carrier.dart';
import 'package:ghost_messaging/voice/hangout.dart';
import 'package:ghost_messaging/voice/voice.dart';

/// "Uplink Bugfixes": an identity of its own that posts the progress of bug fixes in the Alpha testers circle's Updates
/// space (Matt, 2026-11-21: "add a updates channel only admins can post to in the alpha testers and post progerss of
/// bugfixes there", then "A bot identity"). Run as the live relay checks are:
///
///     flutter test tool/net/updates_bot.dart --dart-define=DO=whoami
///     flutter test tool/net/updates_bot.dart --dart-define=DO=join --dart-define=LINK='https://gogho.st/join/#c.…'
///     flutter test tool/net/updates_bot.dart --dart-define=DO=read    (the last few messages in SPACE, as the relay keeps them)
///     flutter test tool/net/updates_bot.dart --dart-define=DO=check   (whether SPACE is read-only and the bot an admin)
///     flutter test tool/net/updates_bot.dart --dart-define=DO=post --dart-define=SPACE=Updates --dart-define=TEXT_FILE=/path/words.txt
///     flutter test tool/net/updates_bot.dart --dart-define=DO=post --dart-define=TEXT_FILE=/path/words.txt --dart-define=PICTURES=/abs/a.png,/abs/b.png
///     flutter test tool/net/updates_bot.dart --dart-define=DO=post … --dart-define=DRY=1   (reads and checks everything, says what would go, connects to nothing)
///     flutter test tool/net/updates_bot.dart --dart-define=DO=edit --dart-define=MATCH='Round two' --dart-define=TEXT_FILE=/path/words.txt
///     flutter test tool/net/updates_bot.dart --dart-define=DO=delete --dart-define=MATCH='Round two'   (its newest that begins so)
///
/// `edit` changes the bot's own newest message in SPACE whose words begin with MATCH (Matt, 2026-11-21: "Edit or re post
/// your messages to credit each person with an @mention"). WHO='kevin=<ghost id>,jerbo=<ghost id>' makes each "@kevin"
/// in the words a mention of that id, in a post or an edit; an edit changes the words but notifies nobody.
///
/// PICTURES (Matt, 2026-11-25: screenshots in the updates) sends a post with up to [picturesMost] pictures, as the app
/// sends a picture in a space's chat ([postWithPictures]): each file sealed and put in the space's own storage on the
/// relay by the app's FilesStore, and the message carrying each one's description (`a`) with its small picture.
///
/// Its key and the circle it is in are kept in ~/.config/mattssoftware/ghost-updates-bot.json, readable by this Mac's
/// user alone, never in the repository (which is public). `join` comes into the circle from an invite link and says it
/// joined, so it is in Members, where the owner makes it an admin; `post` writes in the read-only space named SPACE,
/// which the relay takes from the owner and admins alone.
const doing = String.fromEnvironment('DO', defaultValue: 'whoami');
const link = String.fromEnvironment('LINK');
const spaceName = String.fromEnvironment('SPACE', defaultValue: 'Updates');
const textFile = String.fromEnvironment('TEXT_FILE');
const match = String.fromEnvironment('MATCH');
const who = String.fromEnvironment('WHO');
const pictures = String.fromEnvironment('PICTURES');
const dry = String.fromEnvironment('DRY');
const hub = String.fromEnvironment('HUB', defaultValue: 'wss://gogho.st/hub');
const botName = 'Uplink Bugfixes';

/// Where the bot's key and its circle are kept, and that file read (empty where there is none yet) and written
/// (readable by this user alone).
File get _saved => File('${Platform.environment['HOME']}/.config/mattssoftware/ghost-updates-bot.json');

Map<String, dynamic> _read() => _saved.existsSync() ? (jsonDecode(_saved.readAsStringSync()) as Map).cast<String, dynamic>() : {};

void _write(Map<String, dynamic> m) {
  _saved.parent.createSync(recursive: true);
  _saved.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(m));
  Process.runSync('chmod', ['600', _saved.path]);
}

/// The most pictures a post carries (the app's own most is HangoutMessage.mostFiles, ten; four draw two across, twice).
const picturesMost = 4;

/// The largest picture a post carries: what the app brings down by itself as it draws a chat (autoFetchMost in
/// lib/ui/space_chat_files.dart). A bigger one would show only its small picture until pressed.
const pictureMostBytes = 12 << 20;

/// A picture to post: where it is, the name it goes under, and its size.
typedef BotPicture = ({String path, String name, int size});

/// The pictures [list] names (absolute paths, commas between), each checked as the app's composer would take it and as
/// every released app draws it; throws a [StateError] saying which and why otherwise. The files go as they are: the
/// app sends a picked picture's own bytes, never a copy made smaller.
List<BotPicture> picturesOf(String list) {
  final paths = [for (final p in list.split(',')) if (p.trim().isNotEmpty) p.trim()];
  if (paths.length > picturesMost) throw StateError('PICTURES names ${paths.length} pictures: $picturesMost at most');
  final out = <BotPicture>[];
  for (final p in paths) {
    if (!p.startsWith('/')) throw StateError('PICTURES: "$p" is not an absolute path');
    final f = File(p);
    if (!f.existsSync()) throw StateError('PICTURES: no file at $p');
    final cleaned = SpaceFile.cleanName(p.split('/').last);
    final name = cleaned.isEmpty ? 'File' : cleaned;
    final ending = FileKind.endingOf(name);
    // A HEIC is a picture on a phone and a Mac alone, and an SVG nowhere: a chip elsewhere, not a picture.
    if (!FileKind.drawsAsPicture(name, FileKind.mimeOf(name)) || ending == 'heic' || ending == 'heif') {
      throw StateError('PICTURES: $name is not a picture every app draws (a PNG, a JPEG, a GIF or a WebP is)');
    }
    final size = f.lengthSync();
    if (size == 0) throw StateError('PICTURES: $name is empty');
    if (size > pictureMostBytes) throw StateError('PICTURES: $name is ${fileSize(size)}: ${fileSize(pictureMostBytes)} at most, or it is not drawn until pressed');
    out.add((path: p, name: name, size: size));
  }
  return out;
}

/// The most of a small picture each of [n] files' descriptions carries, as HangoutRoom shares a message's out.
int thumbMostOf(int n) => math.min(SpaceFile.maxThumb, (24 * 1024) ~/ math.max(1, n));

class _RealHttp extends HttpOverrides {}

/// The app's files store for the bot, on the files routes of the relay whose hub is [hubUrl] (as the app finds them:
/// FilesApi.baseFor), signing with [keys], keeping its queue in [dir]. `flutter test` answers every HttpClient with a
/// 400 of its own: this one is the real one.
// ignore: invalid_use_of_visible_for_testing_member
FilesStore botFiles(String hubUrl, NetKeys keys, Directory dir, VoiceRoute route) => FilesStore.forTest(
      base: FilesApi.baseFor(hubUrl),
      signer: KeysSigner(keys),
      data: dir,
      route: route,
      name: botName,
      http: () => HttpOverrides.runWithHttpOverrides(() => IoFilesHttp(), _RealHttp()),
    );

/// [words] with [pics] in [chat], as the app sends them from a space's composer (HangoutRoom.sendFiles): each file up,
/// sealed, under the chat space's own seed ([FilesStore.uploadForChat]), then one message with every file's
/// description, its small picture and its shape among them. The store here makes no small pictures of its own (a
/// test's doesn't), so each is made as the app's store makes it ([FilesStore.thumbnailOf]) and put in the description.
/// False where the room would not take the message; throws where a file didn't go up, what did go up let go of.
Future<bool> postWithPictures(HangoutRoom chat, FilesStore store, String words, List<BotPicture> pics, {List<Mention> mentions = const [], Duration within = const Duration(seconds: 150)}) async {
  if (words.trim().length > HangoutMessage.mostWordsWith) throw StateError('${words.trim().length} characters: a message with pictures carries ${HangoutMessage.mostWordsWith} at most');
  final most = thumbMostOf(pics.length);
  final out = [for (final p in pics) OutgoingFile(path: p.path, name: p.name, size: p.size, mime: FileKind.mimeOf(p.name))];
  final files = <SpaceFile>[];
  try {
    final up = await Future.wait([for (final f in out) store.uploadForChat(chat.channel, f, byName: chat.name, thumbMost: most, moved: () {})]).timeout(within);
    for (var i = 0; i < up.length; i++) {
      final f = up[i];
      final small = await FilesStore.thumbnailOf(File(pics[i].path).readAsBytesSync(), most: most);
      files.add(SpaceFile(id: f.id, name: f.name, size: f.size, mime: f.mime, sha: f.sha, key: f.key, prefix: f.prefix, by: f.by, byName: f.byName, at: f.at, chunk: f.chunk, thumb: small?.png, width: small?.width ?? 0, height: small?.height ?? 0));
      stdout.writeln('ghost-updates-bot: up ${f.name} (${fileSize(f.size)}${small == null ? ', no small picture' : ', ${small.width}×${small.height}, small picture ${small.png.length} bytes'})');
    }
  } catch (e) {
    for (final f in out) {
      store.drop(f);
    }
    if (e is TimeoutException) throw StateError('the pictures did not go up in ${within.inSeconds} s (${out.map((f) => '${f.name}: ${f.waiting ?? f.error ?? '${(f.progress * 100).round()}%'}').join('; ')})');
    rethrow;
  }
  return chat.sendWith(text: words, files: files, mentions: mentions);
}

/// Each "@name" in [words] whose name WHO gives an id for, as a mention of that id.
List<Mention> _mentions(String words) {
  final ids = {
    for (final pair in who.split(',').where((x) => x.contains('=')))
      pair.split('=').first.trim().replaceFirst('@', '').toLowerCase(): pair.split('=').last.trim(),
  };
  return [
    for (final m in RegExp(r'@([A-Za-z0-9_.]+)').allMatches(words))
      if (ids[m.group(1)!.toLowerCase()] case final id?) Mention(m.start, m.end - m.start, id),
  ];
}

/// The bot's identity: the key that was saved, or one made now and saved.
NetKeys _keys() {
  final saved = _read();
  if (saved['key'] is String) return NetKeys.fromScalar(NetCrypto.unhex(saved['key'] as String));
  final keys = NetKeys.generate();
  _write({...saved, 'key': NetCrypto.hex(keys.scalar)});
  return keys;
}

/// Signs in to the relay's hub as the bot, giving it ten seconds to come up.
Future<HubCarrier> _connect(NetKeys keys) async {
  final c = HubCarrier(url: hub, signer: KeysSigner(keys));
  await c.start();
  for (var i = 0; i < 400 && c.state.value != CarrierState.up; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
  if (c.state.value != CarrierState.up) throw StateError(c.problem ?? 'the relay did not answer');
  return c;
}

/// The circle as its room says it now: the newest manifest any member hands over, or what the saved link said.
Future<(Circle, CircleRoom)> _circle(HubVoiceRoute route, Circle from) async {
  var circle = from;
  final got = Completer<void>();
  late final CircleRoom room;
  room = CircleRoom(
    circle: circle,
    route: route,
    onManifest: (c, m) {
      final next = c.merged(m);
      if (next != null) {
        circle = next;
        room.circle = next;
      }
      if (!got.isCompleted) got.complete();
    },
  );
  await room.open();
  await got.future.timeout(const Duration(seconds: 12), onTimeout: () {});
  // Every device with a newer one may answer, the lowest id first: listen a while longer and keep the newest.
  await Future<void>.delayed(const Duration(seconds: 5));
  stdout.writeln('ghost-updates-bot: circle at version ${circle.manifest.version}, admin list ${circle.manifest.grantsVersion} (${circle.manifest.adminGrants.length} admins)');
  return (circle, room);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // A store of the app's that asks the phone: no phone here.
  setUpAll(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('ghost_messaging/sms'), (_) async => null));

  test('Uplink Bugfixes: $doing', () async {
    final pics = doing == 'post' ? picturesOf(pictures) : const <BotPicture>[];
    if (doing == 'post' && dry.isNotEmpty && dry != '0') {
      // Everything a post does but the relay: the words and each picture read and checked, and what would go said.
      final words = textFile.isEmpty ? '' : File(textFile).readAsStringSync().trim();
      if (words.isEmpty) fail('TEXT_FILE says nothing');
      final most = pics.isEmpty ? 4000 : HangoutMessage.mostWordsWith;
      if (words.length > most) fail('${words.length} characters: a message${pics.isEmpty ? '' : ' with pictures'} carries $most at most');
      stdout.writeln('ghost-updates-bot: DRY, nothing connected to. Would post to "$spaceName" by ${FilesApi.baseFor(hub)} and $hub:');
      stdout.writeln('ghost-updates-bot: ${words.length} characters, ${_mentions(words).length} mentions, beginning "${words.split('\n').first}"');
      for (final p in pics) {
        final small = await FilesStore.thumbnailOf(File(p.path).readAsBytesSync(), most: thumbMostOf(pics.length));
        if (small == null) fail('${p.path} does not open as a picture');
        stdout.writeln('ghost-updates-bot: picture ${p.name}, ${fileSize(p.size)} (${p.size} bytes), ${small.width}×${small.height}, ${FileKind.mimeOf(p.name)}, small picture ${small.png.length} of ${thumbMostOf(pics.length)} bytes');
      }
      return;
    }
    final keys = _keys();
    stdout.writeln('ghost-updates-bot: id ${keys.id}');
    if (doing == 'whoami') return;

    final saved = _read();
    final carrier = await _connect(keys);
    final route = HubVoiceRoute(carrier);
    try {
      if (doing == 'join') {
        final c = Circle.fromLink(link);
        if (c == null) fail('LINK is not a circle\'s invite link');
        final (circle, room) = await _circle(route, c);
        room.sayJoined(botName, DateTime.now().millisecondsSinceEpoch);
        await Future<void>.delayed(const Duration(seconds: 2));
        await room.close();
        _write({...saved, 'link': link});
        stdout.writeln('ghost-updates-bot: joined "${circle.manifest.name}" (${circle.spaces.length} spaces: ${circle.spaces.map((s) => s.name).join(', ')})');
        return;
      }
      if (doing == 'post' || doing == 'check' || doing == 'read' || doing == 'edit' || doing == 'delete') {
        final words = textFile.isEmpty ? '' : File(textFile).readAsStringSync().trim();
        if (words.isEmpty && (doing == 'post' || doing == 'edit')) fail('TEXT_FILE says nothing');
        if ((doing == 'edit' || doing == 'delete') && match.isEmpty) fail('MATCH names nothing to $doing');
        final from = Circle.fromLink(saved['link'] as String? ?? '');
        if (from == null) fail('not in a circle yet: DO=join first');
        final (circle, room) = await _circle(route, from);
        await room.close();
        final space = circle.spaces.where((s) => s.name.toLowerCase() == spaceName.toLowerCase()).firstOrNull;
        if (space == null) fail('no space "$spaceName" in ${circle.manifest.name}: ${circle.spaces.map((s) => s.name).join(', ')}');
        final ro = readOnlyRoomOf(circle.manifest, space);
        final isAdmin = circle.manifest.adminGrants.containsKey(keys.id) || circle.manifest.owner == NetCrypto.hex(keys.public);
        stdout.writeln('ghost-updates-bot: "${space.name}" is ${ro == null ? 'not read-only' : 'read-only'}; this bot is ${isAdmin ? 'an admin' : 'NOT an admin'}');
        stdout.writeln('ghost-updates-bot: its roles here: ${circle.manifest.rolesOf(keys.id).map((r) => r.name).join(', ')}${circle.manifest.removed.contains(keys.id) ? ' (removed from the circle)' : ''}');
        if (doing == 'check') return;
        if (doing == 'read') {
          final look = HangoutRoom(channel: circle.channelOf(space), route: route, name: botName, signer: KeysSigner(keys), store: MemoryHangoutStore());
          await look.setReadOnly(ro);
          await look.open();
          await Future<void>.delayed(const Duration(seconds: 6));
          for (final m in look.messages.reversed.take(5).toList().reversed) {
            stdout.writeln('ghost-updates-bot: read [${DateTime.fromMillisecondsSinceEpoch(m.at).toUtc().toIso8601String()}] ${m.name}: ${m.text.split('\n').first}');
          }
          stdout.writeln('ghost-updates-bot: ${look.messages.length} messages in "${space.name}"');
          await look.close();
          return;
        }
        // A read-only space takes the owner's and admins' words alone: anything else the relay drops without a word.
        if (ro != null && !isAdmin) fail('not an admin of ${circle.manifest.name} yet, so "${space.name}" would drop it');
        final chat = HangoutRoom(channel: circle.channelOf(space), route: route, name: botName, signer: KeysSigner(keys), store: MemoryHangoutStore());
        await chat.setReadOnly(ro);
        await chat.open();
        await Future<void>.delayed(const Duration(seconds: 1));
        if (doing == 'delete') {
          // The newest of its messages that begins MATCH goes: a post sent twice by mistake (2026-11-22, the screen
          // sharing post went up twice).
          HangoutMessage? mine;
          for (var i = 0; i < 40 && mine == null; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 500));
            mine = chat.messages.reversed.where((m) => m.from == chat.me && m.text.startsWith(match)).firstOrNull;
          }
          if (mine == null) fail('no message of this bot\'s in "${space.name}" begins "$match" (${chat.messages.length} held)');
          chat.delete(mine);
          await Future<void>.delayed(const Duration(seconds: 2));
          await chat.close();
          stdout.writeln('ghost-updates-bot: deleted "${mine.text.split('\n').first}" of ${DateTime.fromMillisecondsSinceEpoch(mine.at).toUtc().toIso8601String()}');
          return;
        }
        if (doing == 'edit') {
          // Its history comes from whoever is in the room, and from what the hub kept: give it a while.
          HangoutMessage? mine;
          for (var i = 0; i < 40 && mine == null; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 500));
            mine = chat.messages.reversed.where((m) => m.from == chat.me && m.text.startsWith(match)).firstOrNull;
          }
          if (mine == null) fail('no message of this bot\'s in "${space.name}" begins "$match" (${chat.messages.length} held)');
          final edited = chat.edit(mine, words, mentions: _mentions(words));
          await Future<void>.delayed(const Duration(seconds: 2));
          await chat.close();
          expect(edited, isTrue, reason: 'the room would not take the edit (nothing changed, or this identity may not)');
          stdout.writeln('ghost-updates-bot: edited "${mine.text.split('\n').first}" (${_mentions(words).length} mentions)');
          return;
        }
        var ok = false;
        if (pics.isEmpty) {
          ok = chat.send(words, mentions: _mentions(words));
        } else {
          final dir = Directory.systemTemp.createTempSync('ghost-updates-bot');
          final store = botFiles(hub, keys, dir, route);
          try {
            ok = await postWithPictures(chat, store, words, pics, mentions: _mentions(words));
          } finally {
            // ignore: invalid_use_of_visible_for_testing_member
            await store.clear();
            dir.deleteSync(recursive: true);
          }
        }
        await Future<void>.delayed(const Duration(seconds: 2));
        await chat.close();
        expect(ok, isTrue, reason: 'the room would not take it here (may this identity write in "${space.name}"?)');
        stdout.writeln('ghost-updates-bot: posted ${words.length} characters${pics.isEmpty ? '' : ' and ${pics.length} pictures'} to "${space.name}"');
      }
    } finally {
      await carrier.stop();
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}
