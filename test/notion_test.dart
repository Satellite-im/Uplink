import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/notion/notion.dart';

// Matt, 2026-11-25: "add a notion integration to ghost messaging through a plugin that allows sharing notion boards
// and stuff with auto expansions in circles and only requires the circle to have the plugin configured".
// lib/notion/notion.dart: the links, and what is made of Notion's answers. Nothing here reaches Notion.

const _page = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';
const _db = '11111111-2222-3333-4444-555555555555';

Map<String, Object?> _row(String title, String? status, {String? emoji}) => {
      'object': 'page',
      'url': 'https://www.notion.so/${title.replaceAll(' ', '-')}',
      'icon': emoji == null ? null : {'type': 'emoji', 'emoji': emoji},
      'properties': {
        'Task': {'type': 'title', 'title': [{'plain_text': title}]},
        'Status': {'type': 'status', 'status': status == null ? null : {'name': status, 'color': 'blue'}},
        'Owner': {'type': 'people', 'people': [{'name': 'Maya Chen'}]},
        'Due': {'type': 'date', 'date': {'start': '2026-12-01T09:00:00.000Z'}},
        'Notes': {'type': 'rich_text', 'rich_text': [{'plain_text': 'long words a card has no room for'}]},
      },
    };

/// Notion, answering as its API does for one page and one database; every request is kept in [asked].
NotionSend _notion(List<String> asked, {int? fail}) => (method, url, headers, body) async {
      asked.add('$method ${url.path}${url.hasQuery ? '?${url.query}' : ''}');
      expect(headers['Authorization'], 'Bearer secret_abcdefghijklmnopqrstuvwxyz');
      expect(headers['Notion-Version'], Notion.version);
      if (fail != null) return (status: fail, body: '{}');
      final path = url.path.replaceFirst('/v1/', '');
      if (path == 'users/me') return (status: 200, body: jsonEncode({'name': 'Uplink circle'}));
      if (path == 'pages/$_page') return (status: 200, body: jsonEncode(_row('Ship the widgets', 'In progress', emoji: '🚀')));
      if (path == 'blocks/$_page/children') {
        return (status: 200, body: jsonEncode({
          'results': [
            {'type': 'heading_2', 'heading_2': {'rich_text': [{'plain_text': 'Plan'}]}},
            {'type': 'image', 'image': {}},
            {'type': 'paragraph', 'paragraph': {'rich_text': [{'plain_text': 'Three widgets, '}, {'plain_text': 'each at several sizes.'}]}},
          ],
        }));
      }
      if (path == 'databases/$_db' && method == 'GET') {
        return (status: 200, body: jsonEncode({
          'title': [{'plain_text': 'Launch board'}],
          'icon': {'type': 'emoji', 'emoji': '📋'},
          'url': 'https://www.notion.so/board',
          'properties': {
            'Task': {'type': 'title', 'title': {}},
            'Kind': {'type': 'select', 'select': {'options': [{'name': 'Bug'}]}},
            'Status': {'type': 'status', 'status': {'options': [{'name': 'Not started', 'color': 'gray'}, {'name': 'In progress', 'color': 'blue'}, {'name': 'Done', 'color': 'green'}]}},
          },
        }));
      }
      if (path == 'databases/$_db/query' && method == 'POST') {
        expect(jsonDecode(body!), {'page_size': Notion.rowsRead});
        return (status: 200, body: jsonEncode({
          'has_more': true,
          'results': [_row('Write the notes', 'Done'), _row('Ship the widgets', 'In progress'), _row('Try it on the Fold', 'In progress'), _row('Something unsorted', null)],
        }));
      }
      return (status: 404, body: '{"object":"error"}');
    };

Notion _reader(List<String> asked, {int? fail, DateTime Function()? now}) => Notion('secret_abcdefghijklmnopqrstuvwxyz', send: _notion(asked, fail: fail), now: now);

void main() {
  group('links', () {
    test('a page, by the id its address ends with', () {
      final l = NotionLink.of('https://www.notion.so/acme/Ship-the-widgets-aaaaaaaabbbbccccddddeeeeeeeeeeee')!;
      expect(l.id, _page);
      expect(l.board, isFalse);
      expect(NotionLink.of('https://notion.so/aaaaaaaabbbbccccddddeeeeeeeeeeee')!.id, _page);
      expect(NotionLink.of('https://acme.notion.site/Roadmap-AAAAAAAABBBBCCCCDDDDEEEEEEEEEEEE')!.id, _page);
      expect(NotionLink.of('https://app.notion.com/p/$_page')!.id, _page);
    });

    test('a database by its view, and a row opened over it as the row', () {
      final board = NotionLink.of('https://www.notion.so/acme/11111111222233334444555555555555?v=99999999888877776666555555555555')!;
      expect(board.id, _db);
      expect(board.board, isTrue);
      final row = NotionLink.of('https://www.notion.so/acme/11111111222233334444555555555555?v=9999&p=aaaaaaaabbbbccccddddeeeeeeeeeeee&pm=s')!;
      expect(row.id, _page);
      expect(row.board, isFalse);
    });

    test('nothing else is one', () {
      expect(NotionLink.of('https://www.notion.so/help'), isNull);
      expect(NotionLink.of('https://www.notion.so/'), isNull);
      expect(NotionLink.of('http://www.notion.so/aaaaaaaabbbbccccddddeeeeeeeeeeee'), isNull, reason: 'not https');
      expect(NotionLink.of('https://notion.so.example.com/aaaaaaaabbbbccccddddeeeeeeeeeeee'), isNull, reason: 'not Notion\'s');
      expect(NotionLink.of('https://evilnotion.so/aaaaaaaabbbbccccddddeeeeeeeeeeee'), isNull);
      expect(NotionLink.of('not a link'), isNull);
    });

    test('the links in a message, each thing once, without the sentence\'s full stop', () {
      final found = NotionLink.allIn('see https://notion.so/aaaaaaaabbbbccccddddeeeeeeeeeeee. and (https://www.notion.so/x/Again-aaaaaaaabbbbccccddddeeeeeeeeeeee) and https://example.com/a and https://notion.so/11111111222233334444555555555555?v=1');
      expect(found.map((l) => l.id), [_page, _db]);
      expect(found.first.url, 'https://notion.so/aaaaaaaabbbbccccddddeeeeeeeeeeee');
      expect(NotionLink.allIn('no links here'), isEmpty);
    });
  });

  group('what is read', () {
    test('a page: its title, icon, what it says first and what its database says of it, status first', () async {
      final asked = <String>[];
      final card = await _reader(asked).card(NotionLink.of('https://notion.so/Ship-aaaaaaaabbbbccccddddeeeeeeeeeeee')!);
      expect(card.isBoard, isFalse);
      expect(card.title, 'Ship the widgets');
      expect(card.icon, '🚀');
      expect(card.excerpt, 'Plan Three widgets, each at several sizes.');
      expect(card.facts.map((f) => '${f.name}=${f.value}'), ['Status=In progress', 'Owner=Maya Chen', 'Due=2026-12-01']);
      expect(card.facts.first.colour, 'blue');
      expect(asked, ['GET /v1/pages/$_page', 'GET /v1/blocks/$_page/children?page_size=12']);
    });

    test('a database: a board, its rows under its status in Notion\'s order, the unsorted last', () async {
      final asked = <String>[];
      final card = await _reader(asked).card(NotionLink.of('https://notion.so/11111111222233334444555555555555?v=1')!);
      expect(card.isBoard, isTrue);
      expect(card.title, 'Launch board');
      expect(card.icon, '📋');
      expect(card.by, 'Status', reason: 'its status, not the choice that comes before it');
      expect(card.columns!.map((c) => '${c.name}:${c.rows.length}'), ['In progress:2', 'Done:1', 'No status:1']);
      expect(card.columns!.first.colour, 'blue');
      expect(card.columns!.first.rows.first.title, 'Ship the widgets');
      expect(card.count, 4);
      expect(card.more, isTrue);
      expect(asked.first, 'GET /v1/databases/$_db', reason: 'a link with a view is asked for as a database first');
    });

    test('a link that does not say which it is: asked for as a page, then as a database', () async {
      final asked = <String>[];
      final card = await _reader(asked).card(NotionLink.of('https://notion.so/11111111222233334444555555555555')!);
      expect(card.isBoard, isTrue);
      expect(asked.take(2), ['GET /v1/pages/$_db', 'GET /v1/databases/$_db']);
    });

    test('read once, and again only when it has been kept long enough', () async {
      final asked = <String>[];
      var now = DateTime(2026, 11, 25, 12);
      final n = _reader(asked, now: () => now);
      final link = NotionLink.of('https://notion.so/aaaaaaaabbbbccccddddeeeeeeeeeeee')!;
      expect(n.kept(link), isNull);
      final both = await Future.wait([n.card(link), n.card(link)]);
      expect(identical(both[0], both[1]), isTrue, reason: 'two asking at once are one request');
      expect(asked, hasLength(2));
      await n.card(link);
      expect(asked, hasLength(2));
      expect(n.kept(link), isNotNull);
      now = now.add(Notion.keep + const Duration(seconds: 1));
      expect(n.kept(link), isNull);
      await n.card(link);
      expect(asked, hasLength(4));
    });

    test('what cannot be read says why', () async {
      final link = NotionLink.of('https://notion.so/aaaaaaaabbbbccccddddeeeeeeeeeeee')!;
      Future<NotionProblem> problem(int status) async {
        try {
          await _reader([], fail: status).card(link);
        } on NotionError catch (e) {
          return e.problem;
        }
        fail('read');
      }

      expect(await problem(401), NotionProblem.token);
      expect(await problem(404), NotionProblem.notShared);
      expect(await problem(429), NotionProblem.busy);
      expect(await problem(500), NotionProblem.other);
      final down = Notion('secret_abcdefghijklmnopqrstuvwxyz', send: (_, _, _, _) async => throw StateError('offline'));
      await expectLater(down.card(link), throwsA(isA<NotionError>().having((e) => e.problem, 'problem', NotionProblem.other)));
      expect(const NotionError(NotionProblem.notShared).words, contains('Connections'));
    });

    test('the token is checked by asking who it is, and only something shaped like one is a token', () async {
      expect(await _reader([]).check(), 'Uplink circle');
      expect(Notion.looksLikeToken('secret_abcdefghijklmnopqrstuvwxyz'), isTrue);
      expect(Notion.looksLikeToken(' ntn_1234567890abcdefghijABCDEFGHIJ '), isTrue);
      expect(Notion.looksLikeToken('my notion password'), isFalse);
      expect(Notion.looksLikeToken('https://notion.so/aaaaaaaabbbbccccddddeeeeeeeeeeee'), isFalse);
    });
  });
}
