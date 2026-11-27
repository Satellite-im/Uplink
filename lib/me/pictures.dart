import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:pointycastle/export.dart' show SHA256Digest;

/// Profile pictures of people on Uplink, by their id on the hub (Matt, 2026-11-19: "build a profile section in the app
/// that allows us to set profile pictures and status messages"): a friend's comes with their profile; someone in a
/// space says only their picture's [hashOf] when they come in, and the picture itself is asked of them when someone
/// looks at their profile (lib/voice/hangout.dart, `pic?`), so a space's greetings stay small.
///
/// Each picture is a square base64 JPEG (or, from before 0.10.4, PNG) of at most [most] characters
/// (lib/me/picture_make.dart makes them).
class ProfilePictures extends ChangeNotifier {
  ProfilePictures._();
  static final ProfilePictures instance = ProfilePictures._();

  /// The longest a picture may be, as base64: a sharp one ([sharpMost]) with room to spare. A friend's profile
  /// carries the sharp one (`pp`) and the small (`p`) together in one packet of the hub's 60 KB.
  static const most = 48000;

  /// The longest builds from before 0.10.4 take (`p`); what a picture was made at until then.
  static const oldMost = 24000;

  /// What this person's own pictures are made at most: the one shown, and the stand-in for builds from before.
  static const sharpMost = 40000;
  static const smallMost = 14000;
  // The sharp one's side in pixels, at its largest.
  static const sharpSide = 256;

  /// This person's own picture as it is kept for their own screens alone (never sent): large enough for a profile's
  /// big face on a sharp screen (Matt, 2026-11-25: "the profile picture itself is still very blurry on the profile
  /// popup"; the one sent is at most [sharpSide] across and squeezed under [sharpMost]).
  static const fullSide = 640;
  static const fullMost = 280000;

  /// A profile's banner picture (GMFB-34: a banner of your own, where there were ten ready-made ones): three wide to
  /// one high, [bannerWide] pixels across at its largest, a base64 JPEG of at most [bannerMost] characters. It rides in
  /// the same packet as the pictures above where there is room (lib/friends/buddies.dart), so it is kept small: drawn
  /// some 90 points high under a face and a name, it needs no more.
  static const bannerWide = 480;
  static const bannerShape = 3.0;
  static const bannerMost = 12000;

  /// Whether [picture] can be a banner as sent or kept: base64, and no longer than [bannerMost].
  static bool goodBanner(String picture) => picture.isNotEmpty && picture.length <= bannerMost && _b64.hasMatch(picture);
  static final _b64 = RegExp(r'^[A-Za-z0-9+/=]+$');

  // Each person's picture here, by their id, with the mark a greeting would name it by.
  final Map<String, ({String hash, String picture})> _by = {};

  /// A short mark of [picture]: what a greeting carries in its place. '' for none.
  static String hashOf(String picture) {
    if (picture.isEmpty) return '';
    final d = SHA256Digest().process(Uint8List.fromList(utf8.encode(picture)));
    return [for (final b in d.take(6)) b.toRadixString(16).padLeft(2, '0')].join();
  }

  /// [id]'s picture where it is here (and, given [hash], only that one); null where not.
  String? of(String id, {String? hash}) {
    final had = _by[id];
    if (had == null || (hash != null && hash.isNotEmpty && had.hash != hash)) return null;
    return had.picture;
  }

  /// Keeps [picture] as [id]'s, marked as [markOf] (the small one a space's greeting names by [hashOf]) where given.
  /// An empty one forgets theirs; one too long, or not base64, is not kept.
  void keep(String id, String picture, {String? markOf}) {
    if (id.isEmpty) return;
    if (picture.isEmpty) {
      if (_by.remove(id) != null) notifyListeners();
      return;
    }
    if (picture.length > most || !RegExp(r'^[A-Za-z0-9+/=]+$').hasMatch(picture)) return;
    final hash = hashOf(markOf != null && markOf.isNotEmpty ? markOf : picture);
    if (_by[id]?.hash == hash && _by[id]?.picture == picture) return;
    _by[id] = (hash: hash, picture: picture);
    notifyListeners();
  }
}
