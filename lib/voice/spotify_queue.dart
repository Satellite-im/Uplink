/// The songs a call is played from Spotify, and what is said of them in the call (lib/voice/spotify.dart; Matt,
/// 2026-11-25: "add a spotify plugin for circles that allows a user to add songs to a queue and play them from
/// spotify"). No Spotify and no call here: the queue and its rules, a pasted link read, and what came from the room
/// checked before it is believed.
///
/// Nothing from the room is a link or goes into one as it came: a song is its track's id, 22 letters and digits, and a
/// picture is 40 hexadecimal digits put on the end of Spotify's own picture address.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';

/// The most songs waiting, and the most of them one person's.
const songsMost = 100;
const songsEachMost = 20;

/// A track's id on Spotify.
final _track = RegExp(r'^[A-Za-z0-9]{22}$');
bool isTrackId(Object? id) => id is String && _track.hasMatch(id);

/// A cover's id on Spotify's picture server.
final _cover = RegExp(r'^[0-9a-f]{40}$');
bool isCoverId(Object? id) => id is String && _cover.hasMatch(id);

/// [address] as a cover's id, where it is a picture on one of Spotify's own picture servers; '' for anything else.
String coverOf(Object? address) {
  if (address is! String || address.length > 200) return '';
  final u = Uri.tryParse(address);
  if (u == null || u.scheme != 'https' || u.hasQuery || u.hasFragment || u.userInfo.isNotEmpty || u.hasPort) return '';
  if (u.host != 'i.scdn.co' && !RegExp(r'^image-cdn-[a-z]{1,4}\.spotifycdn\.com$').hasMatch(u.host)) return '';
  final at = u.pathSegments;
  return at.length == 2 && at.first == 'image' && isCoverId(at.last) ? at.last : '';
}

/// [s] on one line with no control characters, at most [most] long; '' for anything that is not words. Never cut in the
/// middle of a pair that makes one character.
String songWords(Object? s, int most) {
  if (s is! String) return '';
  // Nothing is looked at past what could be kept, however long what came is.
  final head = s.length > most * 8 ? s.substring(0, most * 8) : s;
  final clean = head.replaceAll(RegExp(r'[\u0000-\u001f\u007f-\u009f\u2028\u2029\u200e\u200f\u202a-\u202e\u2066-\u2069]'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  if (clean.length <= most) return clean;
  var cut = most;
  final last = clean.codeUnitAt(cut - 1);
  if (last >= 0xd800 && last < 0xdc00) cut--;
  return clean.substring(0, cut).trimRight();
}

int _whole(Object? n, int most) => n is num && n.isFinite && n > 0 ? (n > most ? most : n.toInt()) : 0;

/// What someone pasted: a song's track id, or why it is none.
typedef PastedSong = ({String? id, String? why});

/// A pasted link or address of a song: `https://open.spotify.com/track/<id>`, with or without `intl-xx/` before it and
/// a query after, or `spotify:track:<id>`. An album's, a playlist's, an episode's, or anything else, says so.
PastedSong songIn(String pasted) {
  final s = pasted.trim();
  if (s.isEmpty || s.length > 500) return (id: null, why: pasteASong);
  final uri = RegExp(r'^spotify:track:([A-Za-z0-9]{22})$').firstMatch(s);
  if (uri != null) return (id: uri.group(1), why: null);
  final u = Uri.tryParse(s.startsWith('open.spotify.com/') ? 'https://$s' : s);
  if (u == null || (u.scheme != 'https' && u.scheme != 'http') || u.host != 'open.spotify.com' || u.userInfo.isNotEmpty) return (id: null, why: pasteASong);
  var at = [for (final p in u.pathSegments) if (p.isNotEmpty) p];
  if (at.isNotEmpty && RegExp(r'^intl-[a-z]{2}(?:-[a-z]{2})?$').hasMatch(at.first)) at = at.sublist(1);
  if (at.length != 2 || at.first != 'track' || !isTrackId(at.last)) return (id: null, why: pasteASong);
  return (id: at.last, why: null);
}

/// What is said where what was pasted is not a song's link.
const pasteASong = 'Paste a song\'s link. In Spotify: Share, Copy Song Link.';

/// A song asked for: its id, and what Spotify says of it where that could be read. One the DJ chose in Spotify by hand
/// on a PC has no id (Spotify says none there): [track] is '' and it is only ever what is playing now.
@immutable
class Song {
  const Song({required this.track, this.title = '', this.artist = '', this.cover = '', this.length = Duration.zero});

  final String track;
  final String title, artist;

  /// Its cover's id; '' for none.
  final String cover;

  /// How long it is; zero until Spotify itself says, as it plays.
  final Duration length;

  static const titleMost = 70, artistMost = 50;

  /// Its name, or "Song" where nothing could be read of it.
  String get shown => title.isEmpty ? 'Song' : title;

  /// Where its cover is: built here from the id, never an address from anywhere else.
  String? get coverUrl => isCoverId(cover) ? 'https://i.scdn.co/image/$cover' : null;

  /// The address of the song itself, for whoever wants to open it.
  String? get link => track.isEmpty ? null : 'https://open.spotify.com/track/$track';

  Song copyWith({String? title, String? artist, String? cover, Duration? length}) =>
      Song(track: track, title: title ?? this.title, artist: artist ?? this.artist, cover: cover ?? this.cover, length: length ?? this.length);

  Map<String, Object> toWire() => {if (track.isNotEmpty) 't': track, if (title.isNotEmpty) 'n': title, if (artist.isNotEmpty) 'a': artist, if (cover.isNotEmpty) 'c': cover, if (length > Duration.zero) 'l': length.inMilliseconds};

  /// A song as it came from the room; null where it is not one. [named]: it may be without an id, where it has a title.
  static Song? fromWire(Object? j, {bool named = false}) {
    if (j is! Map) return null;
    final t = j['t'];
    if (!isTrackId(t) && !(named && t == null && songWords(j['n'], titleMost).isNotEmpty)) return null;
    return Song(
      track: t is String ? t : '',
      title: songWords(j['n'], titleMost),
      artist: songWords(j['a'], artistMost),
      cover: isCoverId(j['c']) ? j['c'] as String : '',
      length: Duration(milliseconds: _whole(j['l'], const Duration(hours: 12).inMilliseconds)),
    );
  }

  @override
  bool operator ==(Object other) => other is Song && other.track == track && other.title == title && other.artist == artist && other.cover == cover && other.length == length;

  @override
  int get hashCode => Object.hash(track, title, artist, cover, length);
}

/// A song in the queue: whose it is, and its own mark in it.
@immutable
class QueuedSong {
  const QueuedSong({required this.id, required this.song, required this.by});

  /// Which one it is: a number the DJ's device gives each as it is added, never used twice.
  final int id;
  final Song song;

  /// Who added it: their id on the hub.
  final String by;

  QueuedSong withSong(Song s) => QueuedSong(id: id, song: s, by: by);

  @override
  bool operator ==(Object other) => other is QueuedSong && other.id == id && other.song == song && other.by == by;

  @override
  int get hashCode => Object.hash(id, song, by);
}

/// The songs waiting, and the rules of adding, taking away and moving them. The DJ's device alone holds one.
class SongQueue {
  final List<QueuedSong> _songs = [];
  int _next = 1;

  List<QueuedSong> get songs => List.unmodifiable(_songs);
  bool get isEmpty => _songs.isEmpty;

  /// Adds [song] for [by]. Why not, where it can't be: the queue is full, or they have their share of it.
  String? add(Song song, String by) {
    if (!isTrackId(song.track)) return pasteASong;
    if (_songs.length >= songsMost) return 'The queue is full: $songsMost songs.';
    if (_songs.where((s) => s.by == by).length >= songsEachMost) return 'That is $songsEachMost songs from you in the queue. One more when one of them has played.';
    _songs.add(QueuedSong(id: _next++, song: song, by: by));
    return null;
  }

  QueuedSong? find(int id) {
    for (final s in _songs) {
      if (s.id == id) return s;
    }
    return null;
  }

  /// Takes the song [id] away, asked by [by]: their own, or any where they are the [dj].
  bool remove(int id, {required String by, required bool dj}) {
    final s = find(id);
    if (s == null || (!dj && s.by != by)) return false;
    return _songs.remove(s);
  }

  /// Puts the song [id] at [place] in the queue (0 is next to play).
  bool move(int id, int place) {
    final s = find(id);
    if (s == null) return false;
    final from = _songs.indexOf(s), to = place.clamp(0, _songs.length - 1);
    if (from == to) return false;
    _songs
      ..removeAt(from)
      ..insert(to, s);
    return true;
  }

  /// What is known of the song [id] now, in place of what was.
  bool say(int id, Song song) {
    final i = _songs.indexWhere((s) => s.id == id);
    if (i < 0 || _songs[i].song == song) return false;
    _songs[i] = _songs[i].withSong(song);
    return true;
  }

  /// The next to play, taken out of the queue; null where there is none.
  QueuedSong? take() => _songs.isEmpty ? null : _songs.removeAt(0);

  /// A mark for a song that was never in the queue: one the DJ chose in Spotify itself.
  QueuedSong byHand(Song song, String dj) => QueuedSong(id: _next++, song: song, by: dj);
}

/// What the DJ says is playing and what waits: all of it, every time.
@immutable
class MusicState {
  const MusicState({this.now, this.position = Duration.zero, this.playing = false, this.next = const [], required this.at, this.trouble = ''});

  /// What is playing, or paused; null for nothing.
  final QueuedSong? now;

  /// Where it was, and whether it played, at [at] by this device's own clock.
  final Duration position;
  final bool playing;
  final DateTime at;
  final List<QueuedSong> next;

  /// Why the music is not going, in a word the DJ's device chose ([MusicTrouble]); '' for nothing wrong.
  final String trouble;

  /// Where it is now, no further than its end.
  Duration where(DateTime when) {
    final l = now?.song.length ?? Duration.zero;
    final p = playing ? position + when.difference(at) : position;
    if (p < Duration.zero) return Duration.zero;
    return l > Duration.zero && p > l ? l : p;
  }

  /// The most of a state in one message, well under what the relay carries (relay/lib/hub.dart, maxPacket).
  static const bytesMost = 56 * 1024;

  /// As said in the call. The people are named once each and pointed at, so that a full queue stays small.
  Map<String, Object> toWire() {
    final people = <String>[];
    int person(String id) {
      final i = people.indexOf(id);
      if (i >= 0) return i;
      people.add(id);
      return people.length - 1;
    }

    Map<String, Object> one(QueuedSong q, {bool bare = false}) => {'i': q.id, 'b': person(q.by), ...(bare ? Song(track: q.song.track, title: q.song.title).toWire() : q.song.toWire())};
    Map<String, Object> all({required bool bare}) => {
          if (now != null) 'now': one(now!),
          'p': position.inMilliseconds,
          if (playing) 'g': 1,
          if (trouble.isNotEmpty) 'w': trouble,
          'q': [for (final s in next.take(songsMost)) one(s, bare: bare)],
          'by': people,
        };
    final full = all(bare: false);
    if (utf8.encode(jsonEncode(full)).length <= bytesMost) return full;
    people.clear();
    return all(bare: true);
  }

  /// A state as it came from the room, [at] when it came; null where it is not one. Whatever in it is not as it should
  /// be is left out, and no more is read than a queue can hold.
  static MusicState? fromWire(Map<String, dynamic> m, {required DateTime at}) {
    final q = m['q'], people = m['by'];
    if (q is! List || people is! List) return null;
    final names = [for (final p in people.take(songsMost + 1)) p is String && RegExp(r'^[A-Za-z0-9_-]{1,80}$').hasMatch(p) ? p : ''];
    QueuedSong? one(Object? j, {bool named = false}) {
      if (j is! Map) return null;
      final song = Song.fromWire(j, named: named), i = j['i'], b = j['b'];
      if (song == null || i is! int || i < 1 || i > 0x7fffffff || b is! int || b < 0 || b >= names.length) return null;
      return QueuedSong(id: i, song: song, by: names[b]);
    }

    final seen = <int>{};
    final now = one(m['now'], named: true);
    if (now != null) seen.add(now.id);
    final next = <QueuedSong>[];
    for (final j in q.take(songsMost)) {
      final s = one(j);
      if (s != null && seen.add(s.id)) next.add(s);
    }
    final w = m['w'];
    return MusicState(
      now: now,
      position: Duration(milliseconds: _whole(m['p'], const Duration(hours: 12).inMilliseconds)),
      playing: now != null && m['g'] == 1,
      next: next,
      at: at,
      trouble: w is String && MusicTrouble.words.containsKey(w) ? w : '',
    );
  }
}

/// What can be wrong at the DJ's device, as one short word on the wire and a sentence on the screen.
abstract final class MusicTrouble {
  static const closed = 'closed', denied = 'denied', silent = 'silent', failed = 'failed', song = 'song', sound = 'sound', unstarted = 'unstarted', system = 'system', absent = 'absent';

  /// What the others in the call are told.
  static const words = {
    closed: 'Spotify was closed on their computer.',
    denied: 'Their computer isn\'t letting Uplink press Spotify\'s buttons.',
    silent: 'No sound is coming from Spotify on their computer.',
    failed: 'Spotify isn\'t answering on their computer.',
    song: 'That song couldn\'t be played.',
    sound: 'Spotify\'s sound couldn\'t be taken on their computer.',
    unstarted: 'Spotify didn\'t start the song on their computer.',
    system: 'Their computer\'s system is too old to play Spotify here.',
    absent: 'Spotify isn\'t on their computer.',
  };

  /// What the DJ is told, with what to do about it.
  static String mine(String word, {required bool mac}) => switch (word) {
        closed => 'Spotify isn\'t open. Open Spotify and sign in, then press Start.',
        denied => mac
            ? 'macOS isn\'t letting Uplink press Spotify\'s buttons. Turn it on in System Settings › Privacy & Security › Automation, then press Start again.'
            : 'Windows isn\'t letting Uplink press Spotify\'s buttons.',
        silent => mac
            ? 'No sound is coming from Spotify. Check that it plays on this Mac and not on another device, and that Uplink is on in System Settings › Privacy & Security › Screen & System Audio Recording.'
            : 'No sound is coming from Spotify. Check that it plays on this PC and not on another device, and that it isn\'t muted in the Windows volume mixer.',
        failed => 'Spotify isn\'t answering. Look at the Spotify app, then press Start again.',
        song => 'Spotify couldn\'t play that song here, so the next one plays.',
        sound => 'Spotify\'s sound couldn\'t be taken on this ${mac ? 'Mac' : 'PC'}.',
        unstarted => 'Spotify opened but didn\'t start the song. Press play on it there.',
        system => mac ? 'Playing Spotify to a call needs macOS 14.4 or later.' : 'Playing Spotify to a call needs Windows 10 version 2004 or later.',
        absent => 'The Spotify app isn\'t on this ${mac ? 'Mac' : 'PC'}. Install it and sign in, then press Start.',
        _ => 'The music isn\'t playing.',
      };
}
