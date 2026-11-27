/// Smart embeds: a link in a message drawn as a card under it, its picture, its title and who made it, named by the
/// service it goes to (Matt, 2026-11-14: "I also want smart embeds added to expand spotify links, youtube, etc").
///
/// YouTube, Spotify, SoundCloud, Vimeo, TikTok, X and Reddit say what a link is through their oEmbed addresses; any
/// other web address (Apple Music, a news story, a shop) through the Open Graph lines in its page. The service is
/// asked as the message is shown, by this phone, with the link and nothing else; what it answers is kept while the
/// app is open. Settings › Link previews can leave every other site unasked, or the plugin can be switched off.
/// A tap on the card opens the link.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../art/app_icon.dart';
import '../art/lucide.g.dart';
import '../art/svg_path.dart';
import '../kit/settings_type.dart';
import '../links.dart';
import '../sms.dart';
import 'embed_marks.g.dart';
import 'plugin.dart';

/// A service a link can go to: its id (its mark in embed_marks.g.dart), its name and colour, and where it says what
/// a link is.
class EmbedService {
  const EmbedService(this.id, this.name, this.color, {this.hosts = const [], this.oembed, this.square = false, this.video = false});
  final String id;
  final String name;
  final int color;

  /// The hosts its links are on, without `www.`.
  final List<String> hosts;

  /// Its oEmbed address for a link, or null where its page's Open Graph lines are read.
  final Uri Function(String url)? oembed;

  /// Its pictures are square (album covers), not wide (a video's frame): [EmbedView] shows the middle of one, 1.6 to 1,
  /// a little taller than a video's frame, so a cover doesn't make the card as tall as it is wide.
  final bool square;

  /// What it links to plays: the picture wears a play mark.
  final bool video;

  /// The service [url] goes to, or null for any other site.
  static EmbedService? of(String url) {
    final host = Uri.tryParse(url)?.host.toLowerCase().replaceFirst(RegExp(r'^(?:www|m|mobile)\.'), '');
    if (host == null || host.isEmpty) return null;
    for (final s in embedServices) {
      if (s.hosts.any((h) => host == h || host.endsWith('.$h'))) return s;
    }
    return null;
  }
}

/// An oEmbed address: [endpoint] asked about [url], for JSON.
Uri _o(String endpoint, String url, [Map<String, String> more = const {}]) => Uri.parse(endpoint).replace(queryParameters: {'url': url, 'format': 'json', ...more});

/// The services known, asked in this order: one whose host is under another's comes first (music.youtube.com before
/// youtube.com, which would take it).
final List<EmbedService> embedServices = [
  EmbedService('youtubemusic', 'YouTube Music', 0xFFFF0000, hosts: ['music.youtube.com'], oembed: (u) => _o('https://www.youtube.com/oembed', u), square: true, video: true),
  EmbedService('youtube', 'YouTube', 0xFFFF0000, hosts: ['youtube.com', 'youtu.be'], oembed: (u) => _o('https://www.youtube.com/oembed', u), video: true),
  EmbedService('spotify', 'Spotify', 0xFF1DB954, hosts: ['open.spotify.com', 'spotify.link'], oembed: (u) => _o('https://open.spotify.com/oembed', u), square: true),
  const EmbedService('applemusic', 'Apple Music', 0xFFFA243C, hosts: ['music.apple.com'], square: true),
  const EmbedService('applepodcasts', 'Apple Podcasts', 0xFF9933CC, hosts: ['podcasts.apple.com'], square: true),
  EmbedService('soundcloud', 'SoundCloud', 0xFFFF5500, hosts: ['soundcloud.com', 'on.soundcloud.com'], oembed: (u) => _o('https://soundcloud.com/oembed', u), square: true),
  EmbedService('vimeo', 'Vimeo', 0xFF1AB7EA, hosts: ['vimeo.com'], oembed: (u) => _o('https://vimeo.com/api/oembed.json', u), video: true),
  EmbedService('tiktok', 'TikTok', 0xFF111111, hosts: ['tiktok.com', 'vm.tiktok.com'], oembed: (u) => _o('https://www.tiktok.com/oembed', u), video: true),
  EmbedService('x', 'X', 0xFF111111, hosts: ['x.com', 'twitter.com'], oembed: (u) => _o('https://publish.twitter.com/oembed', u, {'omit_script': '1'})),
  EmbedService('reddit', 'Reddit', 0xFFFF4500, hosts: ['reddit.com', 'redd.it'], oembed: (u) => _o('https://www.reddit.com/oembed', u)),
  const EmbedService('instagram', 'Instagram', 0xFFE4405F, hosts: ['instagram.com']),
  const EmbedService('twitch', 'Twitch', 0xFF9146FF, hosts: ['twitch.tv'], video: true),
  const EmbedService('bandcamp', 'Bandcamp', 0xFF408294, hosts: ['bandcamp.com'], square: true),
  const EmbedService('pinterest', 'Pinterest', 0xFFBD081C, hosts: ['pinterest.com', 'pin.it']),
  // Where GIFs are kept (Matt, 2026-11-25: "klippy links to gifs are not expanding into gif previews"): a link to one
  // of their pictures is drawn as the picture, moving ([Embed.picture]).
  const EmbedService('klipy', 'KLIPY', 0xFF6E56F8, hosts: ['klipy.com']),
  const EmbedService('tenor', 'Tenor', 0xFF5B6EF5, hosts: ['tenor.com']),
  const EmbedService('giphy', 'GIPHY', 0xFF111111, hosts: ['giphy.com']),
];

/// Whether [url] is itself a picture a chat can draw, by how its address ends: a GIF, a WebP, a PNG or a JPEG.
bool linksAPicture(String url) {
  final u = Uri.tryParse(url);
  if (u == null || u.scheme != 'https' || u.host.isEmpty) return false;
  return RegExp(r'\.(?:gif|webp|png|jpe?g)$', caseSensitive: false).hasMatch(u.path);
}

/// What a link is, as its service or its page says.
@immutable
class Embed {
  const Embed({required this.url, this.service, this.site, this.title, this.author, this.image, this.picture = false});

  /// The link is to a picture itself, or to a GIF's page: drawn as the picture alone, whole and moving, where a card
  /// would crop it under a title that says nothing.
  final bool picture;
  final String url;
  final EmbedService? service;

  /// The site's own name where it is not a known service ("The Verge").
  final String? site;
  final String? title;
  final String? author;
  final String? image;

  /// There is a title or a picture: without either a card would say nothing the link doesn't.
  bool get worthShowing => (title ?? '').trim().isNotEmpty || (image ?? '').isNotEmpty;

  /// Where it goes, in words: the service's name, the site's own, or its host.
  String get source => service?.name ?? site ?? (Uri.tryParse(url)?.host.replaceFirst(RegExp(r'^www\.'), '') ?? '');
}

/// An answer from a web address.
typedef Fetched = ({int status, String body});

/// How a page or an oEmbed answer is fetched: over the network in the app, stood in for in a test.
typedef EmbedFetch = Future<Fetched> Function(Uri url);

/// Asks the services and pages what links are, and keeps the answers while the app is open.
abstract final class Embeds {
  static EmbedFetch fetch = _http;
  static final Map<String, Future<Embed?>> _kept = {};

  /// Forgets what was kept (a test).
  static void forget() => _kept.clear();

  /// What [url] is, or null where nothing worth a card was said (or [others] is false and it is no known service).
  static Future<Embed?> of(String url, {bool others = true}) {
    final service = EmbedService.of(url);
    if (service == null && !others) return Future.value(null);
    return _kept[url] ??= _find(url, service).catchError((_) => null);
  }

  /// The service's oEmbed answer where it has one and it says enough; else the page itself, read for what it says.
  /// KLIPY's app key for this build (`--dart-define=KLIPY_APP_KEY=…`, tool/telegram-defines.mjs reads it from
  /// ~/.config/ghostmessaging/klipy.env); empty where the build has none, and then a link to one of KLIPY's pages has no
  /// preview. Set by a test.
  static String klipyKey = const String.fromEnvironment('KLIPY_APP_KEY');

  /// The name of the GIF, sticker, clip or meme a link to one of KLIPY's pages is for: `klipy.com/gifs/baby-eats-lemon`
  /// is (gifs, baby-eats-lemon). Null for any other address.
  static ({String kind, String slug})? klipyItem(String url) {
    final u = Uri.tryParse(url);
    if (u == null || u.scheme != 'https' || !(u.host == 'klipy.com' || u.host == 'www.klipy.com')) return null;
    final parts = u.pathSegments.where((p) => p.isNotEmpty).toList();
    if (parts.length != 2 || !const {'gifs', 'stickers', 'clips', 'memes'}.contains(parts[0])) return null;
    return RegExp(r'^[A-Za-z0-9_-]{1,120}$').hasMatch(parts[1]) ? (kind: parts[0], slug: parts[1]) : null;
  }

  /// A link to one of KLIPY's pages, asked of KLIPY's API by its name (docs.klipy.com: `gifs/items?slugs=`), which is
  /// how KLIPY has an app ask: its pages refuse anything that is not a browser a person is using (Matt, 2026-11-25:
  /// "klippy links to gifs are not expanding into gif previews"; asked which, "Page links"). Asked from this device and
  /// the picture loaded from the address KLIPY gives, as its integration rules say. Null without a key, or where KLIPY
  /// has no such item.
  static Future<Embed?> _klipy(String url, EmbedService? service) async {
    final item = klipyItem(url);
    if (item == null || klipyKey.isEmpty) return null;
    final got = await fetch(Uri.parse('https://api.klipy.com/api/v1/$klipyKey/${item.kind}/items').replace(queryParameters: {'slugs': item.slug}));
    if (got.status != 200) return null;
    final j = jsonDecode(got.body);
    final list = j is Map && j['data'] is Map ? (j['data'] as Map)['data'] : null;
    final first = list is List && list.isNotEmpty ? list.first : null;
    final file = first is Map ? first['file'] : null;
    if (file is! Map) return null;
    // A size a chat draws, moving, in the lightest form there is: WebP before GIF, the middle size before the largest.
    for (final size in const ['md', 'hd', 'sm', 'xs']) {
      for (final form in const ['webp', 'gif']) {
        final f = file[size] is Map ? (file[size] as Map)[form] : null;
        final address = f is Map ? f['url'] : null;
        if (address is String && linksAPicture(address)) return Embed(url: url, service: service, title: _clean((first as Map)['title'] as String?), image: address, picture: true);
      }
    }
    return null;
  }

  static Future<Embed?> _find(String url, EmbedService? service) async {
    // A link to a picture is the picture: nothing is asked of its page, which it has none of.
    if (linksAPicture(url)) return Embed(url: url, service: service, image: url, picture: true);
    if (service?.id == 'klipy' && klipyItem(url) != null) {
      final e = await _klipy(url, service);
      if (e != null) return e;
    }
    final oembed = service?.oembed;
    if (oembed != null) {
      final got = await fetch(oembed(url));
      if (got.status == 200) {
        final m = jsonDecode(got.body);
        if (m is Map) {
          final e = Embed(
            url: url,
            service: service,
            title: _clean(m['title'] as String?) ?? _textOf(m['html'] as String?),
            author: _clean(m['author_name'] as String?),
            image: m['thumbnail_url'] as String?,
          );
          if (e.worthShowing) return e;
        }
      }
    }
    final page = await fetch(Uri.parse(url));
    if (page.status != 200) return null;
    final e = fromPage(url, page.body, service: service);
    // A GIF's page (KLIPY's, Tenor's, GIPHY's) names the GIF as its picture: that is what the link is for.
    if (_gifs.contains(service?.id) && e.image != null && linksAPicture(e.image!)) return Embed(url: url, service: service, image: e.image, picture: true);
    return e.worthShowing ? e : null;
  }

  static const _gifs = {'klipy', 'tenor', 'giphy'};

  /// What a page says of itself: its Open Graph (or Twitter card) title, picture and site, else its `<title>`.
  static Embed fromPage(String url, String html, {EmbedService? service}) {
    final head = html.length > 200000 ? html.substring(0, 200000) : html;
    String? meta(List<String> names) {
      for (final name in names) {
        for (final tag in RegExp(r'<meta\b[^>]*>', caseSensitive: false).allMatches(head)) {
          final t = tag.group(0)!;
          final key = RegExp(r'''(?:property|name)\s*=\s*["']([^"']+)["']''', caseSensitive: false).firstMatch(t)?.group(1)?.toLowerCase();
          if (key != name) continue;
          final value = RegExp(r'''content\s*=\s*["']([^"']*)["']''', caseSensitive: false).firstMatch(t)?.group(1);
          if (value != null && value.trim().isNotEmpty) return _unescape(value.trim());
        }
      }
      return null;
    }

    final titleTag = RegExp(r'<title[^>]*>([^<]*)</title>', caseSensitive: false).firstMatch(head)?.group(1);
    var image = meta(['og:image', 'og:image:url', 'twitter:image', 'twitter:image:src']);
    // A GIF's page names its still first and the GIF after: the GIF is the one wanted.
    if (_gifs.contains(service?.id)) {
      final moving = RegExp(r'''<meta\b[^>]*property\s*=\s*["']og:image["'][^>]*content\s*=\s*["']([^"']+\.gif)["']''', caseSensitive: false).firstMatch(head)?.group(1);
      if (moving != null) image = _unescape(moving);
    }
    if (image != null && !image.startsWith('http')) image = Uri.parse(url).resolve(image).toString();
    return Embed(
      url: url,
      service: service,
      site: meta(['og:site_name', 'application-name']),
      title: _clean(meta(['og:title', 'twitter:title']) ?? (titleTag == null ? null : _unescape(titleTag))),
      author: _clean(meta(['music:musician_description', 'og:description', 'twitter:description'])),
      image: image,
    );
  }

  /// [s] on one line, its runs of spaces single; null where nothing is left.
  static String? _clean(String? s) {
    final t = s?.replaceAll(RegExp(r'\s+'), ' ').trim();
    return t == null || t.isEmpty ? null : t;
  }

  /// The words of an oEmbed answer's html (X gives its post that way).
  static String? _textOf(String? html) {
    if (html == null) return null;
    final p = RegExp(r'<p[^>]*>(.*?)</p>', dotAll: true).firstMatch(html)?.group(1) ?? html;
    return _clean(_unescape(p.replaceAll(RegExp(r'<[^>]+>'), ' ')));
  }

  /// The few HTML entities a title holds, as their characters.
  static String _unescape(String s) => s
      .replaceAll('&amp;', '&')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&#x27;', "'")
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&nbsp;', ' ');

  /// The app's own fetch: four redirects at most, eight seconds for each step, and a browser-like user agent.
  static Future<Fetched> _http(Uri url) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 6)
      ..userAgent = 'Mozilla/5.0 (Linux; Android 16) GhostMessaging LinkPreview';
    try {
      final request = await client.getUrl(url).timeout(const Duration(seconds: 8));
      request.followRedirects = true;
      request.maxRedirects = 4;
      request.headers.set(HttpHeaders.acceptHeader, 'text/html,application/json;q=0.9,*/*;q=0.5');
      final response = await request.close().timeout(const Duration(seconds: 8));
      // A page's head is near its top: no more than half a megabyte is read.
      final bytes = <int>[];
      await for (final chunk in response.timeout(const Duration(seconds: 8))) {
        bytes.addAll(chunk);
        if (bytes.length > 512 * 1024) break;
      }
      return (status: response.statusCode, body: utf8.decode(bytes, allowMalformed: true));
    } finally {
      client.close(force: true);
    }
  }
}

class EmbedsPlugin extends GhostPlugin {
  const EmbedsPlugin();

  @override
  String get id => 'embeds';

  @override
  String get name => 'Link previews';

  @override
  String get description => 'A link to YouTube, Spotify and the like, or any web page, is shown as a card with its picture and title.';

  @override
  LucideIcon get icon => Lucide.link;

  // Its card and page on the Plugins page (Matt, 2026-11-17: "redo how the plugins look with their own dedicated plugins page
  // with a marketplace like look how ghostmd has").
  @override
  PluginShelf get shelf => PluginShelf.messages;

  @override
  String get tagline => 'A link in a message shown as a card, with its picture and title.';

  @override
  List<String> get adds => const ['A card under a message with a link: its picture, its title and who made it'];

  @override
  List<PluginReach> get reaches => const [PluginReach(Lucide.globe, 'The site a link goes to', 'Asked what the link is, given the link and nothing else. What it answers is kept while the app is open.')];

  @override
  List<SlotFill> get slots => [
        Slots.underMessage.fill((context, place, prefs) {
          final links = MessageLink.find(place.facts.text).map((l) => l.address).toSet().take(2);
          return [for (final url in links) EmbedCard(url: url, others: prefs.flag('others'))];
        }),
      ];

  @override
  PluginSettingsPage? get settingsPage => PluginSettingsPage(
        // Magenta, its own: it wore red with the Spam filter, and on the Plugins page the two tiles read as one.
        hue: 'magenta',
        intro: 'Links in messages shown as cards, with their picture and title.',
        summary: (prefs) => prefs.flag('others') ? 'Every link' : 'Known services only',
      );

  @override
  List<PluginSetting> get settings => [
        const PluginSetting.toggle(
          key: 'others',
          label: 'Previews for every site',
          hint: 'Off, only links to YouTube, Spotify, SoundCloud, Vimeo, TikTok, X, Reddit and the like get a card.',
          icon: Lucide.link,
        ),
        const PluginSetting.note(
          label: 'How a preview is made',
          hint: 'As a message with a link is shown, this phone asks the site what the link is, giving it the link and nothing else. What it answers is kept while the app is open.',
          icon: Lucide.lock,
        ),
      ];
}

/// The card under a message for a link: the service's or the site's picture, the title, who made it, and where it
/// goes. Nothing is drawn until the site has answered, and nothing where it said nothing worth a card.
class EmbedCard extends StatefulWidget {
  const EmbedCard({super.key, required this.url, this.others = true});
  final String url;
  final bool others;

  @override
  State<EmbedCard> createState() => _EmbedCardState();
}

class _EmbedCardState extends State<EmbedCard> {
  late Future<Embed?> _embed = Embeds.of(widget.url, others: widget.others);

  @override
  void didUpdateWidget(EmbedCard old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url || old.others != widget.others) _embed = Embeds.of(widget.url, others: widget.others);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Embed?>(
      future: _embed,
      builder: (context, snap) {
        final e = snap.data;
        if (e == null) return const SizedBox.shrink();
        return EmbedView(embed: e);
      },
    );
  }
}

/// An [Embed], drawn.
class EmbedView extends StatelessWidget {
  const EmbedView({super.key, required this.embed});
  final Embed embed;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final e = embed;
    final s = e.service;
    final width = (MediaQuery.sizeOf(context).width * 0.72).clamp(220.0, 320.0);
    final radius = BorderRadius.circular(t.radius('lg'));
    // A picture or a GIF: itself, whole and moving, no wider or taller than a card's picture is wide. A press opens it.
    if (e.picture && (e.image ?? '').isNotEmpty) {
      return Semantics(
        link: true,
        image: true,
        label: '${s?.name ?? 'Picture'}: ${e.url}',
        child: GlacierPressable(
          onPressed: () => Sms.instance.openLink(e.url),
          builder: (context, state) => AnimatedOpacity(
            duration: const Duration(milliseconds: 90),
            opacity: state.pressed ? 0.8 : 1,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
             ConstrainedBox(
              key: const ValueKey('embed-picture'),
              constraints: BoxConstraints(maxWidth: width, maxHeight: width),
              child: ClipRRect(
                borderRadius: radius,
                child: Image.network(
                  e.image!,
                  fit: BoxFit.contain,
                  gaplessPlayback: true,
                  cacheWidth: (width * MediaQuery.devicePixelRatioOf(context)).round(),
                  // Its place while it comes, and nothing at all where it does not.
                  loadingBuilder: (context, child, progress) => progress == null ? child : Container(width: width * 0.6, height: width * 0.45, color: t.color('app-paper-2')),
                  errorBuilder: (_, _, _) => const SizedBox.shrink(),
                ),
              ),
             ),
             // Whose it is, where a GIF service's own page was the link (KLIPY asks that its name be shown).
             if (s != null && !linksAPicture(e.url))
               Padding(
                 padding: EdgeInsetsDirectional.only(top: 3, start: 2),
                 child: Text(s.id == 'klipy' ? 'Powered by KLIPY' : s.name, style: pageText(t, t.fontSize('xs'), color: t.color('app-ink-3'))),
               ),
            ]),
          ),
        ),
      );
    }
    final mark = s == null ? null : embedMarks[s.id];
    final brand = s == null ? t.color('app-ink-2') : Color(s.color);
    final image = (e.image ?? '').isEmpty
        ? null
        : Stack(alignment: Alignment.center, children: [
            AspectRatio(
              aspectRatio: s?.square == true ? 1.6 : 16 / 9,
              child: Image.network(e.image!, fit: BoxFit.cover, width: width, errorBuilder: (_, _, _) => ColoredBox(color: t.color('app-paper-3'))),
            ),
            if (s?.video == true)
              Container(
                width: 44,
                height: 44,
                decoration: const BoxDecoration(color: Color(0x99000000), shape: BoxShape.circle),
                alignment: Alignment.center,
                child: const AppIcon(Lucide.play, size: 20, color: Color(0xFFFFFFFF)),
              ),
          ]);
    return Semantics(
      link: true,
      label: '${e.source}: ${e.title ?? e.url}',
      child: GlacierPressable(
        onPressed: () => Sms.instance.openLink(e.url),
        builder: (context, state) => AnimatedOpacity(
          duration: const Duration(milliseconds: 90),
          opacity: state.pressed ? 0.8 : 1,
          child: ClipRRect(
            borderRadius: radius,
            child: Container(
              width: width,
              decoration: BoxDecoration(color: t.color('app-paper-2'), border: Border.all(color: t.color('app-rule')), borderRadius: radius),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
                ?image,
                Padding(
                  padding: EdgeInsetsDirectional.fromSTEB(t.space(3), t.space(2) + 2, t.space(3), t.space(3)),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                    Row(children: [
                      if (mark != null) ...[CustomPaint(size: const Size.square(13), painter: _MarkPainter(mark, brand)), SizedBox(width: t.space(1) + 2)],
                      Flexible(
                        child: Text(e.source, maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('xs'), weight: 'semibold', color: mark != null ? brand : t.color('app-ink-3'))),
                      ),
                    ]),
                    if (e.title != null) ...[
                      SizedBox(height: t.space(1)),
                      Text(e.title!, maxLines: 2, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('sm'), weight: 'semibold', color: t.color('app-ink'), height: 1.3)),
                    ],
                    if (e.author != null) ...[
                      SizedBox(height: 2),
                      Text(e.author!, maxLines: 2, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('xs'), color: t.color('app-ink-3'), height: 1.3)),
                    ],
                  ]),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

/// A service's mark, an SVG path on a 24 by 24 grid, drawn in one colour at the size given.
class _MarkPainter extends CustomPainter {
  const _MarkPainter(this.mark, this.color);
  final String mark;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 24, size.height / 24);
    canvas.drawPath(svgPath(mark), Paint()..color = color);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_MarkPainter old) => old.mark != mark || old.color != color;
}
