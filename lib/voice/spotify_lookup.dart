import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'spotify_queue.dart';

/// What Spotify says a song is, for a link pasted into a call's queue: its title and its cover, from Spotify's oEmbed
/// (the address made for saying what a link is; no key, no account). Asked by the device that adds the song. Where it
/// can't be read (no network, a browser, whose page may speak to no other site) the song is added as "Song", and what it
/// is is said once it plays.
abstract final class SpotifyLookup {
  /// Asks the address; replaced by a test.
  static Future<String?> Function(Uri url) fetch = _http;

  /// How long it may take altogether, and the most of an answer that is read.
  static const within = Duration(seconds: 6);
  static const bytesMost = 64 * 1024;

  static Future<Song> of(String track) async {
    final plain = Song(track: track);
    if (!isTrackId(track)) return plain;
    try {
      final body = await fetch(Uri.https('open.spotify.com', '/oembed', {'url': 'https://open.spotify.com/track/$track'})).timeout(within);
      final m = body == null ? null : jsonDecode(body);
      if (m is! Map) return plain;
      return Song(track: track, title: songWords(m['title'], Song.titleMost), cover: coverOf(m['thumbnail_url']));
    } catch (_) {
      return plain;
    }
  }

  static Future<String?> _http(Uri url) async {
    if (kIsWeb) return null;
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      final request = await client.getUrl(url);
      // https to Spotify and nowhere it would send us on to.
      request.followRedirects = false;
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final response = await request.close();
      if (response.statusCode != 200) return null;
      final bytes = <int>[];
      await for (final piece in response) {
        bytes.addAll(piece);
        if (bytes.length > bytesMost) return null;
      }
      return utf8.decode(bytes, allowMalformed: true);
    } finally {
      client.close(force: true);
    }
  }
}
