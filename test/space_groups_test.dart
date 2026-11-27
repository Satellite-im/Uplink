import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/ui/space_designs/space_design.dart';
import 'package:ghost_messaging/ui/space_designs/telegram.dart';
import 'package:ghost_messaging/ui/space_groups_ui.dart';
import 'package:ghost_messaging/ui/voice_screen.dart';
import 'package:ghost_messaging/voice/discord.dart';
import 'package:ghost_messaging/voice/space_groups.dart';
import 'package:ghost_messaging/voice/voice.dart';

import 'support/space_call_harness.dart';

/// Spaces' groups and Discord servers linked into Spaces (lib/voice/space_groups.dart, lib/voice/discord.dart,
/// lib/ui/space_groups_ui.dart). Matt, 2026-11-16: "add grouping options to spaces so we can group all of a servers
/// spaces under one group and show members that are in a space proxied from discord".
///
/// The Discord bot (messaging/discord/) is stood in for by a server on this machine answering its contract.
class _Bot {
  late HttpServer server;
  final codes = <String, Map<String, Object?>>{'ABC234': {'id': '111', 'name': 'Night Owls', 'icon': null}};
  final tokens = <String, String>{};
  String? unlinked;

  String get base => 'http://127.0.0.1:${server.port}/discord';

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      final res = req.response..headers.contentType = ContentType.json;
      if (req.method == 'POST' && req.uri.path == '/discord/claim') {
        final body = jsonDecode(await utf8.decoder.bind(req).join()) as Map;
        final guild = codes.remove(body['code']);
        if (guild == null) {
          res.statusCode = 404;
          res.write(jsonEncode({'error': 'unknown code'}));
        } else {
          tokens['tok${tokens.length}'] = guild['id'] as String;
          res.write(jsonEncode({'token': 'tok${tokens.length - 1}', 'guild': guild}));
        }
      } else if (req.uri.path == '/discord/state') {
        final t = req.uri.queryParameters['token'];
        if (t == unlinked || !tokens.containsKey(t)) {
          res.statusCode = 401;
          res.write(jsonEncode({'error': 'not linked'}));
        } else {
          res.write(jsonEncode({
            'guild': {'id': '111', 'name': 'Night Owls', 'icon': null},
            'channels': [
              {'id': 'c2', 'name': 'Movie night', 'kind': 'voice', 'position': 2, 'members': []},
              {
                'id': 'c1',
                'name': 'General',
                'kind': 'voice',
                'position': 1,
                'members': [
                  {'id': 'u1', 'name': 'Alex', 'avatar': null, 'muted': false, 'deafened': false, 'video': true, 'streaming': false, 'bot': false},
                  {'id': 'u2', 'name': 'Sam', 'avatar': null, 'muted': true, 'deafened': false, 'video': false, 'streaming': true, 'bot': false},
                ],
              },
              {'id': 'c3', 'name': 'Town hall', 'kind': 'stage', 'position': 3, 'members': []},
            ],
            'at': 1,
          }));
        }
      } else if (req.method == 'POST' && req.uri.path == '/discord/voice/join') {
        final body = jsonDecode(await utf8.decoder.bind(req).join()) as Map;
        if (!tokens.containsKey(body['token'])) {
          res.statusCode = 401;
          res.write(jsonEncode({'error': 'not linked'}));
        } else if (body['channel'] == 'c3') {
          res.statusCode = 403;
          res.write(jsonEncode({'error': 'no permission', 'missing': ['Connect', 'Speak']}));
        } else if (body['channel'] != 'c1') {
          res.statusCode = 404;
          res.write(jsonEncode({'error': 'unknown channel'}));
        } else {
          res.write(jsonEncode({'seed': 'ab' * 32, 'name': 'General', 'guild': '111', 'channel': 'c1', 'bridge': 'cd' * 16}));
        }
      } else if (req.uri.path == '/discord/invite') {
        res.write(jsonEncode({'url': 'https://discord.com/oauth2/authorize?client_id=9&scope=bot%20applications.commands&permissions=1024'}));
      } else {
        res.statusCode = 404;
      }
      await res.close();
    });
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    // The device's choices are written through the phone's channel; nothing answers it here.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('ghost_messaging/sms'), (call) async => null);
  });
  tearDown(() {
    SpaceGroups.instance.reset();
    DiscordServers.instance.reset();
  });

  group('groups', () {
    test('make, move, rename, fold and delete, kept with the device\'s choices', () {
      final app = AppState();
      final g = SpaceGroups.instance..start(app);
      final a = VoiceChannel.make('Friday hang'), b = VoiceChannel.make('Study room'), c = VoiceChannel.make('Gym');
      final id = g.make('Weekend');
      g.move(a.seed, id);
      g.move(b.seed, id);
      expect(spaceRows([a, b, c]).map((r) => r is VoiceChannel ? r.name : (r as SpaceGroupHeading).name), ['Gym', 'Weekend', 'Friday hang', 'Study room']);
      g.fold(id, true);
      expect(spaceRows([a, b, c]).whereType<VoiceChannel>().map((c) => c.name), ['Gym'], reason: 'a folded group hides its spaces');
      expect((spaceRows([a, b, c])[1] as SpaceGroupHeading).count, 2, reason: 'its heading still counts them');
      g.rename(id, 'Weekends');
      // Read back as a fresh start would.
      SpaceGroups.instance.reset();
      final again = SpaceGroups.instance..start(app);
      expect(again.groups.single.name, 'Weekends');
      expect(again.groupOf(a.seed), id);
      expect(again.folded(id), isTrue);
      again.delete(id);
      expect(again.groupOf(a.seed), isNull, reason: 'its spaces go back to the top');
      expect(spaceRows([a, b, c]).whereType<VoiceChannel>().length, 3);
    });
  });

  group('Discord', () {
    late _Bot bot;
    HttpOverrides? prior;
    setUp(() async {
      // Flutter's tests answer every web request with an error; the stand-in bot is a real server on this machine.
      prior = HttpOverrides.current;
      HttpOverrides.global = null;
      bot = _Bot();
      await bot.start();
      DiscordServers.instance
        ..base = bot.base
        ..start(AppState());
    });
    tearDown(() async {
      await bot.server.close(force: true);
      HttpOverrides.global = prior;
    });

    test('a code links the server; its voice channels come in order with who is in them', () async {
      final d = DiscordServers.instance;
      expect(await d.inviteUrl(), contains('permissions=1024'));
      await expectLater(d.claim('nope'), throwsA(isA<DiscordProblem>().having((p) => p.words, 'words', contains('6 letters'))));
      await expectLater(d.claim('ZZZ999'), throwsA(isA<DiscordProblem>().having((p) => p.words, 'words', contains('run out'))));
      // A "not found" from something other than the bot (the web server, before it passes /discord on) is not a
      // wrong code.
      final real = d.base;
      d.base = 'http://127.0.0.1:${bot.server.port}/elsewhere';
      await expectLater(d.claim('ABC234'), throwsA(isA<DiscordProblem>().having((p) => p.words, 'words', contains('couldn\'t be reached'))));
      d.base = real;
      expect(await d.claim(' abc-234 '), 'Night Owls', reason: 'spaces, dashes and case forgiven');
      await d.refresh();
      final link = d.links.single;
      final state = d.stateOf(link);
      expect(state.channels.map((c) => c.name), ['General', 'Movie night', 'Town hall']);
      expect(state.channels.first.members.map((m) => m.name), ['Alex', 'Sam']);
      expect(state.channels.first.members.last.muted, isTrue);
      expect(state.channels.first.members.last.streaming, isTrue);
      expect(state.channels.last.stage, isTrue);
      expect(state.channels.first.link, 'https://discord.com/channels/111/c1');
      // The server is a group of its own, and folds like any.
      final rows = spaceRows(const []);
      expect((rows.first as SpaceGroupHeading).discord, isNotNull);
      expect((rows.first as SpaceGroupHeading).live, 2);
      expect(rows.whereType<DiscordChannel>().length, 3);
      SpaceGroups.instance.start(AppState());
      SpaceGroups.instance.fold(link.group, true);
      expect(spaceRows(const []).whereType<DiscordChannel>(), isEmpty);
    });

    test('joining a channel asks the bridge in and gives back its space; each refusal is said in words', () async {
      final d = DiscordServers.instance;
      await d.claim('ABC234');
      await d.refresh();
      final channels = d.stateOf(d.links.single).channels;
      final space = await d.joinVoice(channels.firstWhere((c) => c.id == 'c1'));
      expect(space.seed, 'ab' * 32);
      expect(space.name, 'General');
      expect(space.discord, '111/c1', reason: 'marked as bridged');
      expect(space.hangout, isTrue, reason: 'it has a chat, which the bridge mirrors');
      await expectLater(d.joinVoice(channels.firstWhere((c) => c.id == 'c3')), throwsA(isA<DiscordProblem>().having((p) => p.words, 'words', contains('Connect, Speak'))));
      await expectLater(d.joinVoice(channels.firstWhere((c) => c.id == 'c2')), throwsA(isA<DiscordProblem>().having((p) => p.words, 'words', contains('isn\'t there'))));
    });

    test('unlinked on the server, the group says so and keeps what it last knew; removing it takes it away', () async {
      final d = DiscordServers.instance;
      await d.claim('ABC234');
      await d.refresh();
      bot.unlinked = d.links.single.token;
      await d.refresh();
      expect(d.stateOf(d.links.single).problem, 'not linked');
      expect(d.stateOf(d.links.single).channels, isNotEmpty);
      d.remove(d.links.single);
      expect(d.links, isEmpty);
      expect(spaceRows(const []), isEmpty);
    });
  });

  testWidgets('pictures: the Spaces tab with a group and a Discord server, and adding a server', (tester) async {
    final h = await SpaceHarness.load(tester);
    addTearDown(tester.view.reset);
    final app = AppState();
    SpaceGroups.instance.start(app);
    final a = VoiceChannel.make('Friday hang'), b = VoiceChannel.make('Study room'), c = VoiceChannel.make('Gym');
    final id = SpaceGroups.instance.make('Weekend');
    SpaceGroups.instance.move(a.seed, id);
    SpaceGroups.instance.move(b.seed, id);
    const link = DiscordLink(token: 't', guildId: '111', name: 'Night Owls');
    DiscordServers.instance.put([link], {
      't': const DiscordState(channels: [
        DiscordChannel(guildId: '111', id: 'c1', name: 'General', position: 1, members: [
          DiscordMember(id: 'u1', name: 'Alex', video: true),
          DiscordMember(id: 'u2', name: 'Sam', muted: true, streaming: true),
          DiscordMember(id: 'u3', name: 'Jordan', deafened: true),
        ]),
        DiscordChannel(guildId: '111', id: 'c2', name: 'Movie night', position: 2),
        DiscordChannel(guildId: '111', id: 'c3', name: 'Town hall', stage: true, position: 3),
      ]),
    });
    Widget list() => ListView(children: [
          for (final r in spaceRows([a, b, c]))
            if (r is SpaceGroupHeading) SpaceGroupRow(heading: r) else if (r is DiscordChannel) DiscordChannelRow(channel: r) else VoiceRow(channel: r as VoiceChannel, onPress: () {}),
        ]);
    for (final dark in [false, true]) {
      await h.shoot(tester, list(), 'space-groups', dark: dark);
      expect(find.text('WEEKEND'), findsOneWidget);
      expect(find.text('NIGHT OWLS'), findsOneWidget);
      expect(find.text('Discord · 3 in voice'), findsOneWidget);
      expect(find.text('Alex'), findsOneWidget);
      expect(find.text('LIVE'), findsOneWidget);
      await h.shoot(tester, const AddDiscordScreen(), 'space-add-discord', dark: dark);
      expect(find.text('Add the bot to your server'), findsOneWidget);
      expect(find.text('Link the server'), findsOneWidget);
    }
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a bridged call: the Discord people with their tag and talking, the bridge itself hidden, and the warning', (tester) async {
    final h = await SpaceHarness.load(tester);
    addTearDown(tester.view.reset);
    final base = h.call(people: 1, video: const {});
    final discord = ValueNotifier<Map<String, double>>(const {'dc:u1': 0.5});
    final call = SpaceCall(
      channel: const VoiceChannel(seed: 'ab', name: 'General', discord: '111/c1'),
      people: [
        ...base.people,
        const SpacePerson(id: 'dc:u1', name: 'Alex', tag: 'Discord'),
        const SpacePerson(id: 'dc:u2', name: 'Sam', muted: true, tag: 'Discord'),
      ],
      levels: MergedLevels(base.levels, discord),
      changes: base.changes,
      room: base.room,
      chatBuilder: base.chatBuilder,
      bridged: true,
    );
    for (final dark in [false, true]) {
      await h.shoot(tester, TelegramCall(call: call), 'space-discord-bridged', dark: dark);
      expect(find.text('Bridged to Discord · not end-to-end encrypted'), findsOneWidget);
      expect(find.text('Discord'), findsNWidgets(2));
      expect(find.text('Alex'), findsOneWidget);
    }
    expect(call.isTalking(call.people.firstWhere((p) => p.name == 'Alex'), call.levels.value), isTrue);
    await tester.pumpWidget(const SizedBox());
  });
}
