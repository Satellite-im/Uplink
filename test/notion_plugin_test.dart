import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/circles/circles.dart';
import 'package:ghost_messaging/notion/notion.dart';
import 'package:ghost_messaging/plugins/notion.dart';
import 'package:ghost_messaging/plugins/pack/format.dart';
import 'package:ghost_messaging/plugins/plugin.dart';
import 'package:ghost_messaging/plugins/registry.dart';
import 'package:ghost_messaging/ui/notion_card.dart';
import 'package:ghost_messaging/voice/voice.dart';

import 'support/list_harness.dart';

// Matt, 2026-11-25: "add a notion integration to ghost messaging through a plugin that allows sharing notion boards
// and stuff with auto expansions in circles and only requires the circle to have the plugin configured".
// lib/plugins/notion.dart, lib/ui/notion_card.dart. Run with --update-goldens, the pictures are build/notion/*.png.

const _token = 'ntn_1234567890abcdefghijABCDEFGHIJ';
const _board = 'https://www.notion.so/acme/11111111222233334444555555555555?v=1';
const _page = 'https://www.notion.so/acme/Ship-aaaaaaaabbbbccccddddeeeeeeeeeeee';

Circle _circle(String d, {bool? on, String? token}) {
  final base = CircleManifest(owner: '', version: 1, name: 'OnlyGhosts', hue: 'indigo', icon: 'sparkles', spaces: [
    CircleSpace(seed: '${d}a' * 32, name: 'General', kind: SpaceKind.text),
  ]);
  return Circle(
    seed: d * 64,
    owner: '',
    manifest: on == null ? base : base.next(extra: base.withPlugin(NotionPlugin.pluginId, on: on, choices: {if (token != null) 'tok': token})),
  );
}

Map<String, Object?> _row(String title, String status) => {
      'url': 'https://www.notion.so/x',
      'properties': {
        'Task': {'type': 'title', 'title': [{'plain_text': title}]},
        'Status': {'type': 'status', 'status': {'name': status, 'color': 'blue'}},
      },
    };

Future<({int status, String body})> _notion(String method, Uri url, Map<String, String> headers, String? body) async {
  final path = url.path.replaceFirst('/v1/', '');
  if (headers['Authorization'] != 'Bearer $_token') return (status: 401, body: '{}');
  if (path.startsWith('databases/') && method == 'GET') {
    return (status: 200, body: jsonEncode({
      'title': [{'plain_text': 'Launch board'}],
      'properties': {'Status': {'type': 'status', 'status': {'options': [{'name': 'In progress', 'color': 'blue'}, {'name': 'Done', 'color': 'green'}]}}},
    }));
  }
  if (path.endsWith('/query')) {
    return (status: 200, body: jsonEncode({'results': [_row('Write the notes', 'Done'), _row('Ship the widgets', 'In progress'), _row('Try it on the Fold', 'In progress')]}));
  }
  if (path == 'pages/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee') return (status: 200, body: jsonEncode(_row('Ship the widgets', 'In progress')));
  if (path.startsWith('blocks/')) return (status: 200, body: jsonEncode({'results': [{'type': 'paragraph', 'paragraph': {'rich_text': [{'plain_text': 'Three widgets, each at several sizes.'}]}}]}));
  return (status: 404, body: '{}');
}

void main() {
  setUp(() {
    NotionCircle.send = _notion;
    NotionCircle.forget();
  });
  tearDown(() async {
    await Circles.instance.clear();
  });

  test('a plugin for a circle and nothing else, off until a circle turns it on, and no pack may take its name', () {
    const p = NotionPlugin();
    expect(p.scopes, {PluginScope.circle});
    expect(p.onByDefault, isFalse);
    expect(shippedPlugins.whereType<NotionPlugin>(), hasLength(1));
    expect(PluginRegistry.instance.circlePlugins.map((x) => x.id), contains('notion'));
    expect(reservedPackIds, contains('notion'));
  });

  test('a space reads Notion only where its circle has it on and holds a token', () {
    VoiceChannel space(Circle c) {
      Circles.instance.join(c);
      return c.channels.first;
    }

    expect(NotionCircle.readerFor(space(_circle('1'))), isNull, reason: 'never set up');
    expect(NotionCircle.readerFor(space(_circle('2', on: true))), isNull, reason: 'on, with no token');
    expect(NotionCircle.readerFor(space(_circle('3', on: false, token: _token))), isNull, reason: 'a token, switched off');
    final on = _circle('4', on: true, token: _token);
    final reader = NotionCircle.readerFor(space(on));
    expect(reader, isNotNull);
    expect(reader!.token, _token);
    expect(identical(NotionCircle.readerFor(on.channels.first), reader), isTrue, reason: 'one reader a token, so what was read is kept');
    expect(NotionCircle.tokenOf(on), _token);
    expect(NotionCircle.endOf(_token), 'GHIJ');
    // The token is in the circle's own page, and comes back from it as it was written.
    expect(NotionCircle.tokenOf(Circle(seed: on.seed, owner: '', manifest: CircleManifest.fromJson(on.manifest.toJson())!)), _token);
    // A chat that is no circle's.
    expect(NotionCircle.readerFor(VoiceChannel(seed: 'ee' * 32, name: 'Friends')), isNull);
  });

  group('under a message', () {
    Future<void> show(WidgetTester tester, Circle c, String text) async {
      Circles.instance.join(c);
      final sheet = await loadSheet(tester);
      await pumpScreen(
        tester,
        sheet,
        Builder(builder: (context) => ListView(padding: const EdgeInsets.all(16), children: [Text(text), ...notionCardsUnder(context, c.channels.first, text)])),
        AppState(),
        size: const Size(520, 640),
        platform: 'desktop',
      );
      await settle(tester);
    }

    testWidgets('a board link opens out as its columns, and a page link as its title and what it says', (tester) async {
      await show(tester, _circle('5', on: true, token: _token), 'the board $_board and the page $_page');
      expect(find.byKey(const ValueKey('notion-card')), findsNWidgets(2));
      expect(find.text('Launch board'), findsOneWidget);
      expect(find.text('3 pages'), findsOneWidget);
      expect(find.byKey(const ValueKey('notion-column-In progress')), findsOneWidget);
      expect(find.byKey(const ValueKey('notion-column-Done')), findsOneWidget);
      expect(find.text('Try it on the Fold'), findsOneWidget);
      expect(find.text('Three widgets, each at several sizes.'), findsOneWidget);
      if (autoUpdateGoldenFiles) await expectLater(find.byType(WidgetsApp), matchesGoldenFile('../build/notion/cards.png'));
    });

    testWidgets('nothing where the circle has no Notion, and nothing for other links', (tester) async {
      await show(tester, _circle('6'), 'the board $_board');
      expect(find.byKey(const ValueKey('notion-card')), findsNothing);
      await show(tester, _circle('7', on: true, token: _token), 'see https://example.com/aaaaaaaabbbbccccddddeeeeeeeeeeee');
      expect(find.byKey(const ValueKey('notion-card')), findsNothing);
    });

    testWidgets('a page the integration was not shared says so, and a refused token says that', (tester) async {
      NotionCircle.send = (method, url, headers, body) async => (status: 404, body: '{}');
      await show(tester, _circle('9', on: true, token: _token), 'https://notion.so/00000000888877776666555555555555');
      expect(find.textContaining('Not shared with this circle\'s Notion'), findsOneWidget);
      NotionCircle.forget();
      NotionCircle.send = (method, url, headers, body) async => (status: 401, body: '{}');
      await show(tester, _circle('0', on: true, token: _token), 'https://notion.so/00000000888877776666555555555555');
      expect(find.textContaining('token was refused'), findsOneWidget);
    });
  });
}
