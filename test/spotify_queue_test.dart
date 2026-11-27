import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/voice/spotify_app.dart';
import 'package:ghost_messaging/voice/spotify_deck.dart';
import 'package:ghost_messaging/voice/spotify_lookup.dart';
import 'package:ghost_messaging/voice/spotify_queue.dart';

/// The songs of a call's queue (lib/voice/spotify_queue.dart), what the DJ's device does with Spotify
/// (lib/voice/spotify_deck.dart), and what is asked of Spotify about a pasted song (lib/voice/spotify_lookup.dart).
const a = '4cOdK2wGLETKBW3PvgPWqT', b = '11dFghVXANMlKmJXsNCbNl', c = '3n3Ppam7vgaVa1iaRUc9Lp', d = '0VjIjW4GlUZAMYd2vXMi3b';
const cover = 'ab67616d00001e02baf89eb11ec7c657805d2da0';
Song song(String id, [String title = '']) => Song(track: id, title: title);

void main() {
  group('a pasted link', () {
    test('a song\'s link in each of its forms is its id', () {
      for (final s in [
        'https://open.spotify.com/track/$a',
        'https://open.spotify.com/track/$a?si=abcdef0123456789',
        'https://open.spotify.com/intl-de/track/$a',
        'https://open.spotify.com/intl-pt-br/track/$a?si=1&context=x#y',
        'http://open.spotify.com/track/$a/',
        'open.spotify.com/track/$a',
        '  spotify:track:$a\n',
      ]) {
        expect(songIn(s).id, a, reason: s);
        expect(songIn(s).why, isNull);
      }
    });

    test('anything else says to paste a song\'s link', () {
      for (final s in [
        '',
        'https://open.spotify.com/album/$a',
        'https://open.spotify.com/playlist/$a',
        'https://open.spotify.com/episode/$a',
        'https://open.spotify.com/artist/$a',
        'spotify:album:$a',
        'spotify:track:${a}x',
        'spotify:track:$a" & (do shell script "x") & "',
        'https://open.spotify.com/track/${a.substring(1)}',
        'https://open.spotify.com/track/$a/extra',
        'https://open.spotify.com.evil.example/track/$a',
        'https://evil.example/open.spotify.com/track/$a',
        'https://user@open.spotify.com/track/$a',
        'javascript:open.spotify.com/track/$a',
        'https://spotify.link/abcdef',
        'https://open.spotify.com/track/${'%22' * 8}',
        'never gonna give you up',
        'x' * 4000,
      ]) {
        expect(songIn(s).id, isNull, reason: s);
        expect(songIn(s).why, startsWith('Paste a song\'s link'));
      }
    });

    test('only 22 letters and digits are ever an id', () {
      expect(isTrackId(a), isTrue);
      for (final s in [null, 7, '', '$a ', '$a\n', '${a.substring(1)}"', '${a.substring(1)}é', '${a.substring(2)}""', '$a$a']) {
        expect(isTrackId(s), isFalse, reason: '$s');
      }
    });

    test('a cover is only ever 40 digits from Spotify\'s own picture servers', () {
      expect(coverOf('https://i.scdn.co/image/$cover'), cover);
      expect(coverOf('https://image-cdn-ak.spotifycdn.com/image/$cover'), cover);
      for (final s in [
        null,
        7,
        'http://i.scdn.co/image/$cover',
        'https://i.scdn.co.evil.example/image/$cover',
        'https://evil.example/image/$cover',
        'https://i.scdn.co/image/$cover?x=1',
        'https://i.scdn.co/image/../$cover',
        'https://i.scdn.co/image/${cover}0',
        'https://me@i.scdn.co/image/$cover',
        'https://i.scdn.co:8443/image/$cover',
        'data:image/png;base64,AAAA',
      ]) {
        expect(coverOf(s), '', reason: '$s');
      }
      expect(const Song(track: a, cover: cover).coverUrl, 'https://i.scdn.co/image/$cover');
      expect(const Song(track: a, cover: 'https://evil.example/').coverUrl, isNull);
    });
  });

  group('the queue', () {
    test('in order, no more than a hundred, and no more than twenty of one person\'s', () {
      final q = SongQueue();
      for (var i = 0; i < songsEachMost; i++) {
        expect(q.add(song(a), 'maya'), isNull);
      }
      expect(q.add(song(a), 'maya'), contains('20 songs from you'));
      for (var p = 0; p < 4; p++) {
        for (var i = 0; i < songsEachMost; i++) {
          expect(q.add(song(b), 'p$p'), isNull);
        }
      }
      expect(q.songs, hasLength(songsMost));
      expect(q.add(song(a), 'late'), contains('full'));
      expect({for (final s in q.songs) s.id}, hasLength(songsMost), reason: 'each has its own mark');
      expect(q.take()!.song.track, a);
      expect(q.add(song(a), 'late'), isNull);
      expect(SongQueue().add(const Song(track: 'nope'), 'x'), isNotNull);
    });

    test('someone takes away what they added, the DJ anything; moving keeps the rest in order', () {
      final q = SongQueue()
        ..add(song(a), 'maya')
        ..add(song(b), 'sam')
        ..add(song(c), 'maya');
      final ids = [for (final s in q.songs) s.id];
      expect(q.remove(ids[1], by: 'maya', dj: false), isFalse);
      expect(q.remove(99, by: 'maya', dj: true), isFalse);
      expect(q.remove(ids[0], by: 'maya', dj: false), isTrue);
      expect(q.remove(ids[1], by: 'dj', dj: true), isTrue);
      expect([for (final s in q.songs) s.song.track], [c]);
      q
        ..add(song(a), 'x')
        ..add(song(b), 'x');
      final last = q.songs.last.id;
      expect(q.move(last, 0), isTrue);
      expect([for (final s in q.songs) s.song.track], [b, c, a]);
      expect(q.move(last, -5), isFalse, reason: 'already first');
      expect(q.move(last, 1 << 30), isTrue);
      expect([for (final s in q.songs) s.song.track], [c, a, b]);
      expect(q.move(12345, 0), isFalse);
    });
  });

  group('on the wire', () {
    MusicState? read(Object? j) => MusicState.fromWire((jsonDecode(jsonEncode(j)) as Map).cast<String, dynamic>(), at: DateTime(2026));

    test('a state goes there and back', () {
      final q = SongQueue()
        ..add(const Song(track: a, title: 'Never Gonna Give You Up', artist: 'Rick Astley', cover: cover, length: Duration(seconds: 213)), 'maya-id')
        ..add(song(b), 'sam-id');
      final now = q.take();
      final s = MusicState(now: now, position: const Duration(seconds: 5), playing: true, next: q.songs, at: DateTime(2026), trouble: 'silent');
      final back = read(s.toWire())!;
      expect(back.now, now);
      expect(back.next, q.songs);
      expect(back.playing, isTrue);
      expect(back.trouble, 'silent');
      expect(back.where(DateTime(2026).add(const Duration(seconds: 10))), const Duration(seconds: 15));
      expect(back.where(DateTime(2027)), const Duration(seconds: 213), reason: 'never past its end');
    });

    test('a hundred songs of the longest names stay under what the relay carries', () {
      final q = SongQueue();
      for (var i = 0; i < songsMost; i++) {
        q.add(Song(track: a, title: '\u{6f22}' * Song.titleMost, artist: '"' * Song.artistMost, cover: cover, length: const Duration(hours: 1)), 'p${i ~/ 20}${'f' * 60}');
      }
      final s = MusicState(now: q.byHand(song(b), 'dj'), next: q.songs, at: DateTime(2026));
      expect(utf8.encode(jsonEncode({'t': 'mu', 'k': 'state', ...s.toWire()})).length, lessThan(60 * 1024));
      expect(read(s.toWire())!.next, hasLength(songsMost));
      // And so do a hundred in the widest script there is, with covers and artists left out where they don't fit.
      final wide = SongQueue();
      for (var i = 0; i < songsMost; i++) {
        wide.add(Song(track: a, title: '\u{6f22}' * Song.titleMost, artist: '\u{6f22}' * Song.artistMost, cover: cover, length: const Duration(hours: 1)), 'p${i ~/ 20}');
      }
      final w = MusicState(next: wide.songs, at: DateTime(2026));
      expect(utf8.encode(jsonEncode(w.toWire())).length, lessThan(60 * 1024));
      expect(read(w.toWire())!.next.last.song.title, '\u{6f22}' * Song.titleMost);
    });

    test('what is not as it should be is left out', () {
      expect(read({}), isNull);
      expect(read({'q': 'no', 'by': []}), isNull);
      expect(read({'q': [], 'by': 'no'}), isNull);
      final hostile = read({
        'q': [
          null,
          7,
          {'t': a},
          {'t': a, 'i': 1, 'b': 5},
          {'t': a, 'i': -1, 'b': 0},
          {'t': a, 'i': 1.5, 'b': 0},
          {'t': '$a" & do shell script "rm', 'i': 2, 'b': 0},
          {'t': ['x'], 'i': 3, 'b': 0},
          {'i': 4, 'b': 0, 'n': 'a name and no id'},
          {'t': b, 'i': 5, 'b': 0, 'n': 'x\u202e\u0000y\n\nz' + 'n' * 5000, 'a': 12, 'c': 'https://evil.example/x.png', 'l': double.maxFinite},
          {'t': b, 'i': 5, 'b': 0},
          {'t': c, 'i': 6, 'b': 1},
        ],
        'by': ['maya-id', 'has "quotes" in it', 9],
        'now': {'t': c, 'i': 'x', 'b': 0},
        'g': true,
        'p': -5,
        'w': '<b>made up</b>',
      })!;
      expect([for (final s in hostile.next) s.id], [5, 6]);
      final s = hostile.next.first.song;
      expect(s.title.length, Song.titleMost);
      expect(s.title, startsWith('x y z'));
      expect(s.artist, '');
      expect(s.cover, '');
      expect(s.length, const Duration(hours: 12));
      expect(hostile.next.last.by, '', reason: 'a person is an id or nobody');
      expect(hostile.now, isNull);
      expect(hostile.playing, isFalse);
      expect(hostile.position, Duration.zero);
      expect(hostile.trouble, '');
      // Huge lists are read no further than a queue holds.
      final huge = read({'q': [for (var i = 1; i < 5000; i++) {'t': a, 'i': i, 'b': 0}], 'by': [for (var i = 0; i < 5000; i++) 'p$i']})!;
      expect(huge.next, hasLength(songsMost));
      // A name cut short is never cut inside a character.
      expect(songWords('${'x' * 69}\u{1f600}', 70), 'x' * 69);
    });
  });

  group('asking Spotify what a song is', () {
    tearDown(() => SpotifyLookup.fetch = (_) async => null);
    test('its title and cover; "Song" where it can\'t be read', () async {
      Uri? asked;
      SpotifyLookup.fetch = (u) async {
        asked = u;
        return jsonEncode({'title': 'Cut To The Feeling', 'thumbnail_url': 'https://image-cdn-fa.spotifycdn.com/image/$cover'});
      };
      final s = await SpotifyLookup.of(b);
      expect(asked!.host, 'open.spotify.com');
      expect(asked!.queryParameters['url'], 'https://open.spotify.com/track/$b');
      expect(s.title, 'Cut To The Feeling');
      expect(s.cover, cover);
      for (final bad in <Future<String?> Function(Uri)>[
        (_) async => null,
        (_) async => 'not json',
        (_) async => '[]',
        (_) async => jsonEncode({'title': 7, 'thumbnail_url': 'https://evil.example/x.png'}),
        (_) async => throw StateError('no network'),
      ]) {
        SpotifyLookup.fetch = bad;
        final s = await SpotifyLookup.of(b);
        expect(s, const Song(track: b));
        expect(s.shown, 'Song');
      }
      var called = false;
      SpotifyLookup.fetch = (_) async {
        called = true;
        return null;
      };
      await SpotifyLookup.of('nope');
      expect(called, isFalse);
    });
  });

  // --- the deck ----------------------------------------------------------------------------------------------------------

  group('a Mac\'s deck', () {
    var t = DateTime(2026, 11, 25, 20);
    late SpotifyDeck k;
    setUp(() {
      t = DateTime(2026, 11, 25, 20);
      k = SpotifyDeck(me: 'dj');
    });
    SpotifyNow at(String id, int seconds, {int length = 200, String state = 'playing', String title = 'A song'}) =>
        SpotifyNow(state: state, uri: 'spotify:track:$id', title: title, artist: 'Someone', length: Duration(seconds: length), position: Duration(seconds: seconds));
    DeckDo? hear(SpotifyNow s, {int after = 1}) {
      t = t.add(Duration(seconds: after));
      return k.heard(s, t);
    }

    void add(String id) => k.queue.add(song(id), 'maya');

    test('the first added plays; at its end the next, and after the last Spotify is paused', () {
      hear(const SpotifyNow());
      add(a);
      expect((k.added(t) as DeckPlay).track, a);
      add(b);
      expect(k.added(t), isNull, reason: 'one plays already');
      expect(hear(at(a, 0)), isNull);
      expect(hear(at(a, 1)), isNull);
      expect(k.now!.song.artist, 'Someone', reason: 'Spotify itself said');
      expect(k.now!.song.length, const Duration(seconds: 200));
      hear(at(a, 198), after: 197);
      // Spotify goes on to something of its own: the next of the queue plays in its place.
      expect((hear(at(d, 0)) as DeckPlay).track, b);
      expect(hear(at(d, 1)), isNull, reason: 'until it is there, what Spotify says is of the one before');
      expect(hear(at(b, 0)), isNull);
      hear(at(b, 199), after: 199);
      // Nothing after it: Spotify's own next is paused, and held to it twice, not for ever.
      expect(hear(at(d, 0)), isA<DeckPause>());
      expect(k.now, isNull);
      expect(hear(at(d, 1)), isA<DeckPause>());
      expect(hear(at(d, 2)), isA<DeckPause>());
      expect(hear(at(d, 3)), isNull, reason: 'the DJ wants it');
      expect(k.now!.song.track, d);
      expect(k.now!.by, 'dj');
    });

    test('a song that just stops at its end, or begins again (repeat), is over too', () {
      add(a);
      k.advance(t);
      hear(at(a, 0));
      hear(at(a, 199), after: 199);
      expect(hear(at(a, 0, state: 'paused')), isNull, reason: 'already quiet');
      expect(k.now, isNull);
      add(a);
      add(b);
      k.advance(t);
      hear(at(a, 0));
      hear(at(a, 199), after: 199);
      expect((hear(at(a, 1)) as DeckPlay).track, b, reason: 'repeat was on');
    });

    test('the DJ choosing a song in Spotify in the middle is not fought', () {
      add(a);
      add(b);
      k.advance(t);
      hear(at(a, 0));
      hear(at(a, 60), after: 60);
      expect(hear(at(d, 0)), isNull);
      expect(k.now!.song.track, d);
      expect(k.now!.by, 'dj');
      for (var i = 1; i < 30; i++) {
        expect(hear(at(d, i)), isNull, reason: 'no loop');
      }
      hear(at(d, 199), after: 170);
      expect((hear(at(c, 0)) as DeckPlay).track, b, reason: 'the queue goes on after it');
    });

    test('a podcast of the DJ\'s own stops the queue until they press play here', () {
      add(a);
      add(b);
      k.advance(t);
      hear(at(a, 0));
      hear(at(a, 50), after: 50);
      expect(hear(const SpotifyNow(state: 'playing', uri: 'spotify:episode:xyz', title: 'A podcast', length: Duration(hours: 1))), isNull);
      expect(k.now, isNull);
      expect((k.resume(t) as DeckPlay).track, b);
    });

    test('pausing and seeking in Spotify are only said', () {
      add(a);
      k.advance(t);
      hear(at(a, 0));
      expect(hear(at(a, 40, state: 'paused'), after: 40), isNull);
      expect(k.playing, isFalse);
      expect(k.resume(t), isA<DeckResume>());
      expect(hear(at(a, 90)), isNull);
      expect(k.position, const Duration(seconds: 90));
      expect(hear(at(a, 5)), isNull, reason: 'back near its start by hand is not its end');
      expect(k.now!.song.track, a);
      expect(k.pause(), isA<DeckPause>());
      expect(k.pause(), isNull);
    });

    test('the same song twice running plays twice', () {
      add(a);
      add(a);
      k.advance(t);
      hear(at(a, 0));
      final first = k.now!.id;
      hear(at(a, 199), after: 199);
      expect((hear(at(d, 0)) as DeckPlay).track, a);
      expect(k.now!.id, isNot(first));
      expect(hear(at(a, 199)), isNull, reason: 'still of the one before');
      expect(hear(at(a, 1)), isNull);
      expect(k.now!.song.track, a);
    });

    test('a song kept under another id counts; one that can\'t be had is passed over, and after three it stops', () {
      add(a);
      k.advance(t);
      hear(at(d, 0, title: 'The same song'));
      hear(at(d, 3));
      expect(k.now!.song.track, a, reason: 'it is the song asked for, under another id');
      hear(at(d, 199), after: 195);
      for (final id in [a, b, c, d]) {
        add(id);
      }
      // Spotify is paused on the old one and never moves.
      expect((k.advance(t) as DeckPlay).track, a);
      final still = at(d, 199, state: 'paused');
      expect(hear(still, after: 2), isNull);
      expect((hear(still, after: 5) as DeckPlay).track, b);
      expect(k.couldnt, isTrue);
      expect((hear(still, after: 7) as DeckPlay).track, c);
      expect(hear(still, after: 7), isNull);
      expect(k.now, isNull, reason: 'it stops trying');
      expect(k.queue.songs, hasLength(1));
    });

    test('an advertisement is waited out', () {
      add(a);
      hear(at(d, 10));
      k.advance(t);
      for (var i = 0; i < 30; i++) {
        expect(hear(const SpotifyNow(state: 'playing', uri: 'spotify:ad:000', length: Duration(seconds: 30))), isNull);
      }
      expect(k.now!.song.track, a);
      expect(hear(at(a, 0)), isNull);
      expect(k.couldnt, isFalse);
    });

    test('skip with nothing after it pauses; with nothing at all does nothing', () {
      expect(k.skip(t), isNull);
      add(a);
      k.advance(t);
      hear(at(a, 0));
      expect(k.skip(t), isA<DeckPause>());
      expect(k.now, isNull);
      expect(k.pause(), isNull);
      expect(k.resume(t), isNull);
    });
  });

  // A PC's Spotify says a title, an artist and a length, and no id; and opening a song may only show it.
  group('a PC\'s deck', () {
    var t = DateTime(2026, 11, 25, 20);
    late SpotifyDeck k;
    setUp(() {
      t = DateTime(2026, 11, 25, 20);
      k = SpotifyDeck(me: 'dj', opens: true);
    });
    SpotifyNow at(String title, int seconds, {int length = 200, String state = 'playing', String artist = 'Someone'}) => SpotifyNow(state: state, title: title, artist: artist, length: Duration(seconds: length), position: Duration(seconds: seconds));
    DeckDo? hear(SpotifyNow s, {int after = 1}) {
      t = t.add(Duration(seconds: after));
      return k.heard(s, t);
    }

    void add(String id, [String title = '']) => k.queue.add(song(id, title), 'maya');

    test('a song asked for is known by its title; its end is followed by the next', () {
      hear(at('Before', 30));
      expect(k.now!.song.title, 'Before', reason: 'what was playing is what the call hears');
      expect(k.now!.song.track, '', reason: 'and no id is made up for it');
      add(a, 'Never Gonna Give You Up');
      add(b, 'Cut To The Feeling');
      expect((k.skip(t) as DeckPlay).track, a);
      expect(hear(at('Before', 31)), isNull);
      expect(hear(at('Never Gonna Give You Up - Remastered', 0)), isNull, reason: 'the same song, as Spotify writes it there');
      expect(hear(at('Never Gonna Give You Up - Remastered', 2)), isNull);
      expect(k.playing, isTrue);
      hear(at('Never Gonna Give You Up - Remastered', 199), after: 197);
      expect((hear(at('Something of its own', 0)) as DeckPlay).track, b);
      hear(at('Cut To The Feeling', 0));
      expect(k.now!.song.track, b);
      expect(k.unstarted, isFalse);
    });

    test('a song only shown is asked to play once; then the DJ is told, and pressing play there goes on', () {
      hear(at('Before', 30, state: 'paused'));
      add(a, 'The One');
      k.advance(t);
      expect(hear(at('Before', 30, state: 'paused')), isNull);
      expect(hear(at('Before', 30, state: 'paused'), after: 2), isA<DeckResume>(), reason: 'opened, not started');
      expect(hear(at('The One', 0, state: 'paused')), isNull, reason: 'asked once, not over and over');
      expect(hear(at('The One', 0, state: 'paused'), after: 6), isNull);
      expect(k.unstarted, isTrue);
      expect(k.state(t).trouble, MusicTrouble.unstarted);
      expect(k.playing, isFalse);
      expect(hear(at('The One', 1)), isNull, reason: 'the DJ pressed play there');
      expect(k.unstarted, isFalse);
      expect(k.playing, isTrue);
      expect(k.state(t).trouble, '');
    });

    test('something else playing in its place is paused and said, never passed off as it', () {
      hear(at('Before', 30, state: 'paused'));
      add(a, 'The One');
      k.advance(t);
      hear(at('Before', 30, state: 'paused'), after: 3);
      // Asked to play, Spotify played what it had.
      for (var i = 0; i < 5; i++) {
        hear(at('Before', 31 + i));
      }
      expect(k.now!.song.title, 'The One');
      expect(hear(at('Before', 40), after: 4), isA<DeckPause>());
      expect(k.unstarted, isTrue);
      expect(hear(at('Before', 40, state: 'paused')), isNull);
      // Play in the app asks for the song again.
      expect((k.resume(t) as DeckPlay).track, a);
      expect(k.unstarted, isFalse);
    });

    test('the DJ going on with something else after that is what plays', () {
      hear(at('Before', 30, state: 'paused'));
      add(a, 'The One');
      k.advance(t);
      hear(at('Wrong', 1), after: 10);
      expect(k.unstarted, isTrue);
      hear(at('Wrong', 2), after: 1);
      hear(at('Chosen', 5), after: 20);
      expect(k.now!.song.title, 'Chosen');
      expect(k.unstarted, isFalse);
    });

    test('a song whose title isn\'t known is taken on the change', () {
      hear(at('Before', 30));
      add(a);
      k.skip(t);
      expect(hear(at('Before', 31)), isNull);
      hear(at('Whatever it is', 0));
      expect(k.now!.song.title, 'Whatever it is');
      expect(k.now!.song.track, a);
    });

    test('two songs of one title running are told apart by the second beginning again', () {
      hear(const SpotifyNow());
      add(a, 'Intro');
      add(b, 'Intro');
      k.advance(t);
      hear(at('Intro', 0, length: 100));
      hear(at('Intro', 99, length: 100), after: 99);
      expect((hear(at('Elsewhere', 0)) as DeckPlay).track, b);
      final second = k.now!.id;
      expect(hear(at('Intro', 99, length: 100)), isNull, reason: 'the first, still said');
      expect(k.now!.id, second);
      hear(at('Intro', 1, length: 100));
      hear(at('Intro', 2, length: 100));
      expect(k.now!.id, second);
      expect(k.position, const Duration(seconds: 2));
      // The same name, and Spotify straight into it with no other between.
      add(c, 'Intro');
      hear(at('Intro', 98, length: 100), after: 96);
      expect((hear(at('Intro', 0, length: 100)) as DeckPlay).track, c);
      hear(at('Intro', 0, length: 100));
      hear(at('Intro', 3, length: 100));
      expect(k.now!.song.track, c);
    });

    test('where no length is said, a song that has played a while and changes is over; sooner, it was the DJ', () {
      hear(const SpotifyNow());
      add(a, 'One');
      add(b, 'Two');
      k.advance(t);
      hear(at('One', 0, length: 0));
      hear(at('One', 0, length: 0), after: 10);
      expect(k.position, const Duration(seconds: 10), reason: 'counted here');
      expect(hear(at('By hand', 0, length: 0)), isNull);
      expect(k.now!.song.title, 'By hand');
      hear(at('By hand', 0, length: 0), after: 60);
      expect((hear(at('Its own next', 0, length: 0)) as DeckPlay).track, b);
    });

    test('Spotify closed in the middle of a song is not a song ending over and over', () {
      hear(const SpotifyNow());
      add(a, 'One');
      k.advance(t);
      hear(at('One', 0));
      hear(at('One', 60), after: 60);
      expect(hear(const SpotifyNow()), isNull, reason: 'nothing to press in what is not there');
      expect(k.now, isNull);
    });

    test('titles, as far as they tell', () {
      expect(sameTitle('Never Gonna Give You Up', 'never gonna give you up (2022 Remaster)'), isTrue);
      expect(sameTitle('Señorita', 'Señorita'), isTrue);
      expect(sameTitle('One - Live', 'One'), isTrue);
      expect(sameTitle('One', 'Two'), isFalse);
      expect(sameTitle('!!!', '!!!'), isTrue);
      expect(sameTitle('!!!', '???'), isFalse);
      expect(sameTitle('漢字', '漢字'), isTrue);
    });
  });

  test('only Spotify\'s own media session is ever looked at on a PC', () {
    for (final id in ['Spotify.exe', 'SPOTIFY.EXE', 'SpotifyAB.SpotifyMusic_zpdnekdrzrea0!Spotify']) {
      expect(isSpotifyAppId(id), isTrue, reason: id);
    }
    for (final id in [null, 7, '', 'chrome.exe', 'notspotify.exe', 'spotify.exe.evil', 'C:\\evil\\spotify.exe.exe', 'SpotifyAB.SpotifyMusic_zpdnekdrzrea0!Other', 'Microsoft.ZuneMusic_8wekyb3d8bbwe!Microsoft.ZuneMusic']) {
      expect(isSpotifyAppId(id), isFalse, reason: '$id');
    }
  });
}
