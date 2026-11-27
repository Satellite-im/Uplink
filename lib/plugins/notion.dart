/// Notion: a link to a Notion page or board written in a circle's space is drawn under its message as what it links
/// to (Matt, 2026-11-25: "add a notion integration to ghost messaging through a plugin that allows sharing notion
/// boards and stuff with auto expansions in circles and only requires the circle to have the plugin configured").
/// The reading is lib/notion/notion.dart's and the card is lib/ui/notion_card.dart; this is the plugin a circle turns
/// on, and where the circle's token is kept and read.
///
/// A plugin for a whole circle and nothing else: it does nothing in a chat that is not a circle's space. Whoever may
/// change the circle turns it on and gives it one Notion integration token (Circle settings › Plugins). The token is
/// kept in the circle's signed page beside the plugin's switch (CircleManifest.plugins), which every member's device
/// has, so each reads Notion itself and nobody else sets anything up. That also means everyone in the circle, and
/// anyone given its invite, holds the token and can read whatever the integration was shared in Notion: the settings
/// say so, and say to share with it only what the whole circle may see.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data' show BytesBuilder;

import '../art/app_icon.dart' show LucideIcon;
import '../art/lucide.g.dart';
import '../circles/circle.dart';
import '../circles/circles.dart';
import '../notion/notion.dart';
import '../platform_info.dart';
import '../voice/voice.dart' show VoiceChannel;
import 'plugin.dart';

class NotionPlugin extends GhostPlugin {
  const NotionPlugin();

  static const pluginId = 'notion';

  @override
  String get id => pluginId;

  @override
  String get name => 'Notion';

  @override
  String get description => 'Links to Notion pages and boards open out under the message in a circle\'s spaces, for everyone in the circle, once the circle is given a Notion token.';

  @override
  LucideIcon get icon => Lucide.fileText;

  @override
  bool get onByDefault => false;

  @override
  String get hue => 'slate';

  @override
  PluginShelf get shelf => PluginShelf.messages;

  @override
  String get tagline => 'Notion pages and boards, opened out in a circle\'s chats.';

  @override
  String get pitch => 'Paste a Notion link in a circle and everyone sees the page or the board under it. One person sets it up for the circle.';

  @override
  List<String> get adds => const [
        'A page\'s title, what it says first, and its status, people and dates',
        'A database as a board: its rows under the columns of its status',
        'For everyone in the circle, with nothing for them to set up',
      ];

  @override
  List<PluginReach> get reaches => const [
        PluginReach(Lucide.globe, 'Notion\'s servers, from each member\'s device', 'Each device asks api.notion.com for the pages linked in the circle. The relay is not asked and sees none of it.'),
        PluginReach(Lucide.keyRound, 'The circle\'s Notion token, held by every member', 'Kept in the circle\'s own page. Anyone in the circle, or given its invite, can read what the integration was shared in Notion.'),
      ];

  @override
  Set<PluginScope> get scopes => const {PluginScope.circle};
}

/// The circle's side of Notion: whether it is on in a space, the circle's token, and what reads Notion with it.
abstract final class NotionCircle {
  /// Sends a request to Notion; replaced by a test.
  static NotionSend send = _http;

  /// The token [c] holds; null where it has none.
  static String? tokenOf(Circle c) {
    final t = c.manifest.plugins[NotionPlugin.pluginId]?['tok'];
    return t is String && t.trim().isNotEmpty ? t.trim() : null;
  }

  /// The end of a token, for a row that says which one is kept without showing it.
  static String endOf(String token) => token.length <= 4 ? token : token.substring(token.length - 4);

  /// What reads Notion for [space]: there where it is a circle's space, the circle has Notion on and holds a token,
  /// and this is not a browser (Notion's API answers no page of another site's). Null otherwise.
  static Notion? readerFor(VoiceChannel space) {
    if (PlatformInfo.isWeb) return null;
    final c = Circles.instance.circleOf(space);
    if (c == null || c.manifest.pluginOn(NotionPlugin.pluginId) != true) return null;
    final token = tokenOf(c);
    return token == null ? null : readerOf(token);
  }

  // One reader a token, so what one chat read of a page is there for the next.
  static final Map<String, Notion> _readers = {};
  static Notion readerOf(String token) => _readers.putIfAbsent(token, () => Notion(token, send: (method, url, headers, body) => send(method, url, headers, body)));

  /// Forgets what was read (a test's; and a token changed).
  static void forget() => _readers.clear();

  /// Keeps [token] for [c] and turns Notion on there, once Notion has taken it: the integration's name where it was
  /// kept. Throws a [NotionError] where Notion refuses it, and a [StateError] where this device may not change the
  /// circle.
  static Future<String> keep(Circle c, String token) async {
    final t = token.trim();
    final name = await Notion(t, send: (method, url, headers, body) => send(method, url, headers, body)).check();
    if (!await Circles.instance.setPlugin(c, NotionPlugin.pluginId, on: true, choices: {'tok': t})) throw StateError('Your role in ${c.name} can\'t change its plugins.');
    forget();
    return name;
  }

  /// Takes the circle's token away and turns Notion off there.
  static Future<bool> remove(Circle c) async {
    final ok = await Circles.instance.setPlugin(c, NotionPlugin.pluginId, on: false, choices: {'tok': ''});
    if (ok) forget();
    return ok;
  }

  /// The app's own way to Notion: 15 s to connect, and no more than 2 MB read of an answer.
  static Future<({int status, String body})> _http(String method, Uri url, Map<String, String> headers, String? body) async {
    const most = 2 << 20;
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final req = await client.openUrl(method, url);
      headers.forEach(req.headers.set);
      if (body != null) {
        final bytes = utf8.encode(body);
        req.contentLength = bytes.length;
        req.add(bytes);
      }
      final res = await req.close();
      final read = BytesBuilder(copy: false);
      await for (final piece in res) {
        read.add(piece);
        if (read.length > most) throw const NotionError(NotionProblem.other, 'an answer too long to read');
      }
      return (status: res.statusCode, body: utf8.decode(read.takeBytes(), allowMalformed: true));
    } finally {
      client.close(force: true);
    }
  }
}
