import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/plugins/embeds.dart';
import 'package:ghost_messaging/plugins/registry.dart';

import 'support/list_harness.dart';

/// Smart embeds (lib/plugins/embeds.dart; Matt, 2026-11-14: "I also want smart embeds added to expand spotify
/// links, youtube, etc").
void main() {
  late List<Uri> asked;
  setUp(() {
    asked = [];
    Embeds.forget();
    Embeds.fetch = (url) async {
      asked.add(url);
      if (url.host == 'www.youtube.com' && url.path == '/oembed') {
        return (status: 200, body: jsonEncode({'title': 'Never Gonna Give You Up', 'author_name': 'Rick Astley', 'thumbnail_url': 'https://i.ytimg.com/vi/x/hq.jpg'}));
      }
      if (url.host == 'open.spotify.com' && url.path == '/oembed') {
        return (status: 200, body: jsonEncode({'title': 'Blinding Lights', 'thumbnail_url': 'https://i.scdn.co/image/abc'}));
      }
      if (url.host == 'publish.twitter.com') {
        return (status: 200, body: jsonEncode({'author_name': 'Uplink', 'html': '<blockquote><p lang="en">Hello &amp; welcome</p>&mdash; Uplink</blockquote>'}));
      }
      if (url.host == 'music.apple.com' || url.host == 'news.example') {
        return (
          status: 200,
          body: '<html><head><title>Fallback</title><meta property="og:title" content="Midnights &amp; more"><meta property="og:site_name" content="Apple Music">'
              '<meta property="og:image" content="/art.jpg"></head></html>'
        );
      }
      return (status: 404, body: '');
    };
  });

  test('a link is known by its service, else it is any site', () {
    expect(EmbedService.of('https://www.youtube.com/watch?v=dQw4w9WgXcQ')?.id, 'youtube');
    expect(EmbedService.of('https://youtu.be/dQw4w9WgXcQ')?.id, 'youtube');
    expect(EmbedService.of('https://music.youtube.com/watch?v=1')?.id, 'youtubemusic');
    expect(EmbedService.of('https://open.spotify.com/track/0VjIjW4GlUZAMYd2vXMi3b')?.id, 'spotify');
    expect(EmbedService.of('https://music.apple.com/us/album/x/1')?.id, 'applemusic');
    expect(EmbedService.of('https://m.tiktok.com/@a/video/1')?.id, 'tiktok');
    expect(EmbedService.of('https://twitter.com/a/status/1')?.id, 'x');
    expect(EmbedService.of('https://news.example/story'), isNull);
  });

  test('YouTube and Spotify say what a link is by oEmbed; X by its post\'s words', () async {
    final yt = (await Embeds.of('https://youtu.be/dQw4w9WgXcQ'))!;
    expect(yt.title, 'Never Gonna Give You Up');
    expect(yt.author, 'Rick Astley');
    expect(yt.image, 'https://i.ytimg.com/vi/x/hq.jpg');
    expect(yt.source, 'YouTube');
    expect(asked.single.queryParameters['url'], 'https://youtu.be/dQw4w9WgXcQ');
    expect((await Embeds.of('https://open.spotify.com/track/1'))!.title, 'Blinding Lights');
    expect((await Embeds.of('https://x.com/ghost/status/1'))!.title, 'Hello & welcome');
    // Asked once: kept while the app is open.
    await Embeds.of('https://youtu.be/dQw4w9WgXcQ');
    expect(asked.where((u) => u.host == 'www.youtube.com'), hasLength(1));
  });

  test('any other page by its Open Graph lines; nothing asked of it where only known services are wanted', () async {
    final apple = (await Embeds.of('https://music.apple.com/us/album/midnights/1'))!;
    expect(apple.title, 'Midnights & more');
    expect(apple.image, 'https://music.apple.com/art.jpg', reason: 'a picture given from the site\'s root');
    expect(apple.source, 'Apple Music');
    expect((await Embeds.of('https://news.example/story'))!.site, 'Apple Music');
    asked.clear();
    expect(await Embeds.of('https://other.example/page', others: false), isNull);
    expect(asked, isEmpty);
    expect(await Embeds.of('https://gone.example/404'), isNull, reason: 'a site that did not answer gets no card');
  });

  testWidgets('the card: the service\'s name, the title, who made it', (tester) async {
    final sheet = await loadSheet(tester);
    await pumpScreen(tester, sheet, const Center(child: EmbedCard(url: 'https://youtu.be/dQw4w9WgXcQ')), AppState());
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await settle(tester);
    expect(find.text('YouTube'), findsOneWidget);
    expect(find.text('Never Gonna Give You Up'), findsOneWidget);
    expect(find.text('Rick Astley'), findsOneWidget);
    expect(shippedPlugins.whereType<EmbedsPlugin>(), hasLength(1));
  });

  // Matt, 2026-11-25: "klippy links to gifs are not expanding into gif previews".
  group('GIFs and pictures', () {
    test('a link that is a picture is the picture, with nothing asked of any page', () async {
      const gif = 'https://static2.klipy.com/ii/d7aec6f6f171607374b2065c836f92f4/e3/ae/6HDt3HVy.gif';
      final e = (await Embeds.of(gif, others: false))!;
      expect(e.picture, isTrue);
      expect(e.image, gif);
      expect(e.service?.id, 'klipy');
      expect(asked, isEmpty);
      expect(linksAPicture('https://media.tenor.com/abc/cat.GIF'), isTrue);
      expect(linksAPicture('https://example.com/photo.webp?size=2'), isTrue);
      expect(linksAPicture('http://example.com/photo.gif'), isFalse, reason: 'not https');
      expect(linksAPicture('https://example.com/gifs/a-page'), isFalse);
      expect(linksAPicture('https://example.com/clip.mp4'), isFalse);
      expect(EmbedService.of('https://tenor.com/view/x-123')?.id, 'tenor');
      expect(EmbedService.of('https://media.giphy.com/media/x/giphy.gif')?.id, 'giphy');
    });

    test('a picture on a site that is no known service only where other sites are asked', () async {
      expect(await Embeds.of('https://example.com/cat.gif', others: false), isNull);
      expect((await Embeds.of('https://example.com/cat.gif'))!.picture, isTrue);
    });

    test('a GIF\'s page is its GIF, the moving one of the pictures it names; a page that refuses is nothing', () async {
      Embeds.fetch = (url) async {
        asked.add(url);
        if (url.host == 'klipy.com' && url.path == '/gifs/baby-eats-lemon') {
          return (
            status: 200,
            body: '<head><meta property="og:title" content="KLIPY: Baby Eats Lemon GIF"/>'
                '<meta property="og:image" content="https://static2.klipy.com/ii/d7/e3/ae/HKEJ1BsV.webp"/>'
                '<meta property="og:image" content="https://static2.klipy.com/ii/d7/e3/ae/6HDt3HVy.gif"/></head>'
          );
        }
        return (status: 403, body: 'no');
      };
      final e = (await Embeds.of('https://klipy.com/gifs/baby-eats-lemon', others: false))!;
      expect(e.picture, isTrue);
      expect(e.image, 'https://static2.klipy.com/ii/d7/e3/ae/6HDt3HVy.gif');
      expect(await Embeds.of('https://klipy.com/gifs/refused', others: false), isNull);
    });

    test('a link to one of KLIPY\'s pages is asked of KLIPY\'s API by its name, where this build has a key', () async {
      addTearDown(() => Embeds.klipyKey = '');
      expect(Embeds.klipyItem('https://klipy.com/gifs/baby-eats-lemon'), (kind: 'gifs', slug: 'baby-eats-lemon'));
      expect(Embeds.klipyItem('https://www.klipy.com/stickers/wave-2')?.kind, 'stickers');
      expect(Embeds.klipyItem('https://klipy.com/gifs'), isNull);
      expect(Embeds.klipyItem('https://klipy.com/developers/keys'), isNull);
      expect(Embeds.klipyItem('https://evil.example/gifs/baby-eats-lemon'), isNull);
      Embeds.fetch = (url) async {
        asked.add(url);
        if (url.host == 'api.klipy.com' && url.path == '/api/v1/test-key/gifs/items' && url.queryParameters['slugs'] == 'baby-eats-lemon') {
          return (status: 200, body: jsonEncode({
            'result': true,
            'data': {
              'data': [
                {
                  'slug': 'baby-eats-lemon',
                  'title': 'Baby Eats Lemon',
                  'file': {
                    'hd': {'gif': {'url': 'https://static.klipy.com/ii/a/hd.gif'}, 'webp': {'url': 'https://static.klipy.com/ii/a/hd.webp'}},
                    'md': {'gif': {'url': 'https://static.klipy.com/ii/a/md.gif'}, 'webp': {'url': 'https://static.klipy.com/ii/a/md.webp'}},
                  },
                },
              ],
            },
          }));
        }
        return (status: 403, body: 'no');
      };
      // No key in this build: the page is asked, refuses, and there is no preview.
      Embeds.klipyKey = '';
      expect(await Embeds.of('https://klipy.com/gifs/baby-eats-lemon', others: false), isNull);
      expect(asked.any((u) => u.host == 'api.klipy.com'), isFalse);
      Embeds.forget();
      Embeds.klipyKey = 'test-key';
      final e = (await Embeds.of('https://klipy.com/gifs/baby-eats-lemon', others: false))!;
      expect(e.picture, isTrue);
      expect(e.image, 'https://static.klipy.com/ii/a/md.webp', reason: 'the middle size, as WebP');
      expect(e.title, 'Baby Eats Lemon');
      expect(e.url, 'https://klipy.com/gifs/baby-eats-lemon', reason: 'a press still opens the page');
    });
  });
}
