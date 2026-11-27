/// What the DJ's device does with Spotify as the queue and Spotify itself change (lib/voice/spotify.dart): given what
/// Spotify says it is doing, about once a second, what button to press next, if any. No Spotify, no clock and no call
/// of its own, so each case can be tried.
///
/// The rules:
/// - A song of the queue's that ends is followed by the next; with none, Spotify is paused, so that what Spotify would
///   play of its own (similar songs) is not played to the call.
/// - The DJ's own hand in Spotify is never fought: a song they choose there in the middle of another is what is playing
///   now, and the queue goes on after it. Pausing and seeking in Spotify are simply what is said.
/// - A song Spotify can't play is passed over, and after three in a row it stops trying. Where asking for a song may
///   only show it ([opens]: a PC), it is asked to play once more, and if it still doesn't the DJ is told to press play
///   there: nothing else is played in its place.
///
/// **How sure it is of what is playing.** The Mac's Spotify says the track's id, so a song is known by that. A PC's says
/// a title, an artist and (where it gives them) a length and a place, and never an id: there a song asked for is taken
/// to be playing once what is said differs from what was said before it was asked for, or begins again from its start,
/// and where the song's title is known (Spotify's oEmbed) the title must be it, give or take capitals, marks and what
/// follows a dash or a bracket. A song asked for whose title could not be read is taken on the change alone, and two
/// songs of the same title, artist and length told apart only by the second starting from its beginning.
library;

import 'package:flutter/foundation.dart';

import 'spotify_queue.dart';

/// What Spotify says it is doing.
@immutable
class SpotifyNow {
  const SpotifyNow({this.state = 'stopped', this.uri = '', this.title = '', this.artist = '', this.cover = '', this.length = Duration.zero, this.position = Duration.zero});

  /// `playing`, `paused` or `stopped`.
  final String state;

  /// What is loaded, as Spotify names it: `spotify:track:…`, or an advertisement, a local file or an episode. Empty
  /// where Spotify does not say (a PC).
  final String uri;
  final String title, artist, cover;

  /// Zero where it is not said.
  final Duration length, position;

  bool get playing => state == 'playing';

  /// The track's id; null where it is not a track of Spotify's, or it does not say.
  String? get track {
    const head = 'spotify:track:';
    final id = uri.startsWith(head) ? uri.substring(head.length) : '';
    return isTrackId(id) ? id : null;
  }

  /// Between songs on a free account: waited out, never skipped. A PC says only a title for one.
  bool get ad => uri.isEmpty ? (title == 'Advertisement' || (title == 'Spotify' && artist.isEmpty) || (title.isNotEmpty && artist == 'Spotify')) : uri.startsWith('spotify:ad:');

  /// Something the call can be played: a track, or, where no id is said, anything with a title.
  bool get isSong => uri.isEmpty ? title.isNotEmpty : track != null;

  /// What tells one thing playing from another: its address, or its title, artist and length.
  String get key => uri.isNotEmpty ? uri : (title.isEmpty ? '' : '$title\u0000$artist\u0000${length.inSeconds}');

  Song song(String track) => Song(track: track, title: songWords(title, Song.titleMost), artist: songWords(artist, Song.artistMost), cover: cover, length: length);

  static SpotifyNow from(Map<Object?, Object?> m) {
    Duration ms(Object? n) => n is num && n.isFinite && n > 0 ? Duration(milliseconds: n > 86400000 ? 86400000 : n.toInt()) : Duration.zero;
    final state = m['state'];
    return SpotifyNow(
      state: state == 'playing' || state == 'paused' ? state as String : 'stopped',
      uri: m['id'] is String && (m['id'] as String).length < 400 ? m['id'] as String : '',
      title: songWords(m['name'], Song.titleMost),
      artist: songWords(m['artist'], Song.artistMost),
      cover: coverOf(m['art']),
      length: ms(m['length']),
      position: ms(m['position']),
    );
  }
}

/// Whether two titles are the same song's, as far as titles tell: capitals, marks and what follows a dash or a bracket
/// (remastered, feat.) left out.
bool sameTitle(String a, String b) {
  String plain(String s) => s.toLowerCase().replaceAll(RegExp(r'\s+[-–—]\s.*$|[(\[].*$'), '').replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), '');
  // One made of marks alone, or cut short here, is compared as it is.
  final x = plain(a), y = plain(b);
  if (x.isEmpty || y.isEmpty) return a.trim().toLowerCase() == b.trim().toLowerCase();
  return x == y || (x.length > 50 && y.startsWith(x)) || (y.length > 50 && x.startsWith(y));
}

/// A button to press in Spotify.
sealed class DeckDo {
  const DeckDo();
}

final class DeckPlay extends DeckDo {
  const DeckPlay(this.track);
  final String track;
}

final class DeckPause extends DeckDo {
  const DeckPause();
}

final class DeckResume extends DeckDo {
  const DeckResume();
}

/// The DJ's device's side of the music: what plays, and what it asks of Spotify.
class SpotifyDeck {
  SpotifyDeck({required this.me, this.opens = false});

  /// This device's id on the hub: whose a song chosen by hand is.
  final String me;

  /// Asking for a song may only show it in Spotify, not play it (a PC, where it is opened as a link).
  final bool opens;
  final SongQueue queue = SongQueue();

  QueuedSong? now;
  Duration position = Duration.zero;
  bool playing = false;

  /// A song could not be played ([MusicTrouble.song]); taken away when one plays.
  bool couldnt = false;

  /// Spotify showed the song and didn't start it ([MusicTrouble.unstarted]): the DJ is asked to press play there.
  bool unstarted = false;

  // A song was asked of Spotify at this moment, and Spotify had this loaded then: until it is playing, or long enough
  // has gone by, what Spotify says is still of the one before.
  DateTime? _askedAt;
  String _before = '';

  /// Where what was loaded before it was asked for had got to: what begins again from its start is told by this.
  Duration _beforeAt = Duration.zero;
  bool _nudged = false, _hushed = false;

  /// What Spotify calls [now] ([SpotifyNow.key]): on a Mac usually its own id; another where Spotify keeps the same song
  /// under two.
  String? _as;

  /// The last thing said of [now], to tell an end from a hand on it, and when it was first heard playing.
  Duration _lastAt = Duration.zero;
  DateTime? _since;

  /// Spotify was paused because the queue had ended, at this moment.
  DateTime? _endedAt;
  int _held = 0;
  int _failed = 0;

  static const settles = Duration(seconds: 6), endsWithin = Duration(seconds: 3), holds = Duration(seconds: 6);

  /// Where asking may only show a song: asked to play after this, and given up on after that.
  static const nudgesAfter = Duration(seconds: 3), unstartedAfter = Duration(seconds: 9);

  /// Where no length is said, something else playing after this long is the song over; sooner, the DJ's own hand.
  static const untimed = Duration(seconds: 30);
  static const failuresMost = 3, holdsMost = 2;

  /// Whether a song of the queue's is playing: then stopping pauses Spotify.
  bool get oursPlaying => now != null && playing && !_byHand;
  bool _byHand = false;

  /// The next of the queue played; with none, Spotify paused.
  DeckDo? advance(DateTime at) {
    final q = queue.take();
    _since = null;
    _beforeAt = _lastAt;
    _lastAt = Duration.zero;
    position = Duration.zero;
    _as = null;
    _byHand = false;
    _nudged = _hushed = false;
    unstarted = false;
    now = q;
    if (q == null) {
      playing = false;
      _askedAt = null;
      _endedAt = at;
      _held = 0;
      return const DeckPause();
    }
    _endedAt = null;
    playing = true;
    _askedAt = at;
    return DeckPlay(q.song.track);
  }

  /// A song was added: played at once where nothing is.
  DeckDo? added(DateTime at) => now == null ? advance(at) : null;

  DeckDo? skip(DateTime at) => now == null && queue.isEmpty ? null : advance(at);

  DeckDo? pause() {
    if (now == null || !playing) return null;
    playing = false;
    return const DeckPause();
  }

  /// On again: the song paused, or the next of the queue where none is.
  DeckDo? resume(DateTime at) {
    if (now == null) return queue.isEmpty ? null : advance(at);
    // One that was shown and never started is asked for again.
    if (unstarted) {
      _askedAt = at;
      _nudged = _hushed = false;
      unstarted = false;
      playing = true;
      return DeckPlay(now!.song.track);
    }
    if (playing) return null;
    playing = true;
    return const DeckResume();
  }

  /// Whether what Spotify says, [s], is the song asked for, [n].
  bool _isAsked(SpotifyNow s, QueuedSong n) {
    if (s.state == 'stopped' || !s.isSong) return false;
    // It must be near its start: the one before, under the same name, is not.
    if (s.position >= const Duration(seconds: 12)) return false;
    final id = s.track;
    // On a Mac: its own id, or the same song under another (Spotify keeps some twice, and plays the one it may).
    if (id != null) return id == n.song.track || s.key != _before;
    // On a PC: its title where that is known, and something other than before, or that begun again.
    if (n.song.title.isNotEmpty && !sameTitle(n.song.title, s.title)) return false;
    return s.key != _before || s.position < _beforeAt || (s.playing && _beforeAt == Duration.zero && n.song.title.isNotEmpty);
  }

  /// What Spotify says, [at] this moment; the button to press for it, or null.
  DeckDo? heard(SpotifyNow s, DateTime at) {
    final n = now;
    if (_askedAt == null) _before = s.key;

    // Nothing of the call's is playing.
    if (n == null) {
      _lastAt = s.position;
      if (!s.playing) return null;
      // Spotify went on by itself just after the queue ended: paused, and not more than twice.
      final ended = _endedAt;
      if (ended != null && at.difference(ended) < holds && _held < holdsMost) {
        _held++;
        return const DeckPause();
      }
      // The DJ pressed play in Spotify: that is what the call hears.
      if (!s.ad && s.isSong) _take(s, at);
      return null;
    }

    // An advertisement between songs: waited out.
    if (s.ad) {
      playing = s.playing;
      if (_askedAt != null) _askedAt = at;
      return null;
    }

    final asked = _askedAt;
    if (asked != null) {
      if (_isAsked(s, n) && (!opens || s.playing)) {
        _began(s, at);
      } else if (opens) {
        return _opened(s, at, at.difference(asked));
      } else if (at.difference(asked) < settles) {
        return null;
      } else if (s.track == n.song.track && s.state != 'stopped') {
        _began(s, at);
      } else {
        // Never came: not to be had on this account, or gone from Spotify.
        couldnt = true;
        _before = s.key;
        if (++_failed >= failuresMost) {
          _failed = 0;
          now = null;
          playing = false;
          _askedAt = null;
          _endedAt = at;
          _held = holdsMost;
          return s.playing ? const DeckPause() : null;
        }
        return advance(at);
      }
    }

    final length = n.song.length > Duration.zero ? n.song.length : s.length;
    final since = _since;
    final ending = since != null && (length > Duration.zero ? _lastAt >= length - endsWithin : at.difference(since) >= untimed);

    if (s.key.isNotEmpty && s.key == _as) {
      // The same song begun again from its end (repeat is on), or stopped at it: it has ended.
      final over = s.state == 'stopped' || (!s.playing && s.position == Duration.zero) || (s.position < const Duration(seconds: 3) && s.position < _lastAt);
      if (ending && length > Duration.zero && over) return _ended(s, at);
      playing = s.playing;
      // Where no place is said it is counted from the start.
      position = s.length == Duration.zero && s.position == Duration.zero && since != null ? (s.playing ? at.difference(since) : position) : s.position;
      _lastAt = s.position;
      _since ??= at;
      final known = s.song(n.song.track);
      now = n.withSong(Song(
        track: n.song.track,
        title: known.title.isEmpty ? n.song.title : known.title,
        artist: known.artist.isEmpty ? n.song.artist : known.artist,
        cover: known.cover.isEmpty ? n.song.cover : known.cover,
        length: known.length == Duration.zero ? n.song.length : known.length,
      ));
      return null;
    }
    // Something else, or nothing, after its end: Spotify going on by itself.
    if (ending || s.state == 'stopped' || s.key.isEmpty) return _ended(s, at);
    // Something else in the middle of it: the DJ's own hand, not to be fought.
    if (s.isSong) {
      _take(s, at);
    } else {
      // A podcast or a file of their own: the call's song is over, and the queue waits until they press play here.
      now = null;
      playing = false;
      _endedAt = null;
    }
    return null;
  }

  /// The song asked for is playing.
  void _began(SpotifyNow s, DateTime at) {
    _askedAt = null;
    _as = s.key;
    _before = s.key;
    _failed = 0;
    couldnt = false;
    unstarted = false;
    _since = at;
    _lastAt = Duration.zero;
  }

  /// A song asked for by opening it, not playing [after] this long: asked to play once, and where that does not do it
  /// the DJ is told, and whatever else Spotify plays in its place is paused once, so that the call is not played one
  /// song under another's name.
  DeckDo? _opened(SpotifyNow s, DateTime at, Duration after) {
    if (after >= unstartedAfter && !unstarted) {
      unstarted = true;
      playing = false;
    }
    if (unstarted) {
      if (s.playing && !_hushed) {
        _hushed = true;
        return const DeckPause();
      }
      // The DJ went on with something else in Spotify: that is what is playing.
      if (s.playing && _hushed && s.isSong && after >= unstartedAfter + holds) {
        _take(s, at);
      }
      return null;
    }
    if (after >= nudgesAfter && !_nudged && !s.playing) {
      _nudged = true;
      return const DeckResume();
    }
    return null;
  }

  DeckDo? _ended(SpotifyNow s, DateTime at) {
    _before = s.key;
    final next = advance(at);
    // Nothing after it and Spotify already quiet: nothing to press.
    if (next is DeckPause && !s.playing) return null;
    return next;
  }

  /// What the DJ chose in Spotify is what is playing.
  void _take(SpotifyNow s, DateTime at) {
    now = queue.byHand(s.song(s.track ?? ''), me);
    _byHand = true;
    _as = s.key;
    _before = s.key;
    _askedAt = null;
    _endedAt = null;
    _since = at;
    _lastAt = s.position;
    position = s.position;
    playing = s.playing;
    couldnt = false;
    unstarted = false;
  }

  MusicState state(DateTime at, {String trouble = ''}) =>
      MusicState(now: now, position: position, playing: playing, next: queue.songs, at: at, trouble: trouble.isNotEmpty ? trouble : (unstarted ? MusicTrouble.unstarted : (couldnt ? MusicTrouble.song : '')));
}
