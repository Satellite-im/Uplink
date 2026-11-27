/// A circle's own pictures: the one in its icon's place (Matt, 2026-11-17: "use iconography and color where possible")
/// and the banner behind the top of its sidebar (Matt, 2026-11-19: "make circles have a background image for the header
/// like discord does").
///
/// Each is chosen from the phone's or computer's pictures, positioned under a window (lib/ui/picture_crop.dart: drag,
/// and pinch or scroll to make it larger), and kept as two things (Matt, 2026-11-27: "uploading the pictures for
/// banners and the circle profile picture should use a cropping / zooming tool and upload at full resolution, right
/// now they're super low resolution"):
/// - a stand-in, small enough to ride in the circle's manifest, which goes round in one packet on the hub
///   ([circlePictureMax], [circleBannerMax]): a JPEG, [circleFaceSide] or [circleBannerSide] pixels across at its
///   largest. It was a PNG, and a PNG of a photo that small is 72 pixels across;
/// - the part chosen, cut at the picture's own resolution (lib/me/picture_make.dart, cutPictureOf), which goes up
///   sealed to the relay under the circle's own seed and is named in the manifest beside the stand-in
///   (Circle.bannerFile, Circle.pictureFile). It is drawn wherever it is here and the stand-in would not be sharp.
///
/// **The picture chosen is never touched.** What goes up is a file the app made (the cut), in its own temporary
/// folder. Until 0.12.52 a banner sent the chosen file itself as one of the app's own copies, which a phone's pick is
/// and a computer's is not: set from a Mac, the upload moved the person's own picture out of its folder into the
/// app's cache.
///
/// **A picture that can't be used says why** (Matt, 2026-11-27: "uploading the banner from my desktop to AlphaTesters
/// circle says 'cannot use image'"): each step that can fail has its own words, with what the device or the relay
/// said, where every one used to end in "Couldn't use that picture."
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../../circles/circles.dart';
import '../../files/files_store.dart';
import '../../l10n/words.dart';
import '../../me/picture_make.dart';
import '../../me/pictures.dart';
import '../../platform_info.dart';
import '../../voice/hangout.dart' show OutgoingFile;
import '../../sms.dart';
import '../common.dart';
import '../picture_crop.dart';

/// A circle's picture is square and its banner three wide to one high.
const circleBannerShape = 3.0;

/// The stand-ins' largest sizes, in pixels across: what a face is sharp at (256 is 85 points on a phone that draws
/// three pixels to the point, and the largest face drawn is 76), and a banner until its full picture is here.
const circleFaceSide = 256, circleBannerSide = 480;

/// The most a picture's and a banner's full cut are across, in pixels: beyond any screen they are drawn on (a banner
/// fills a sidebar at most 400 points wide), and a few megabytes at most.
const circleFaceMost = 2048, circleBannerMost = 3840;

/// What choosing a picture for a circle came to: [small], its stand-in for the manifest (base64), and [cut], the part
/// chosen at full size, to go up as a file. [cut] is null where it couldn't be made (the stand-in is then all there is).
///
/// [lighter] is the stand-in again in a third of the room, for a circle whose manifest has no room left for [small]
/// (a circle of many spaces and roles, with a picture and a banner both: all of it goes round in one packet).
class CirclePick {
  const CirclePick({required this.small, this.lighter, this.cut});
  final String small;
  final String? lighter;
  final CutPicture? cut;
}

/// [bytes] as a circle's picture's stand-in: the part chosen ([crop]: the middle square where none is), base64, at
/// most [most] characters ([circlePictureMax] where not said). Null where it can't be read.
Future<String?> circlePictureOf(Uint8List bytes, {ui.Rect? crop, int most = circlePictureMax}) =>
    pictureStandIn(bytes, crop: crop, shape: 1, widths: const [circleFaceSide, 224, 192, 160, 128, 96, 72, 56, 40], most: most);

/// [bytes] as a circle's banner's stand-in: the band chosen ([crop]: the middle band where none is), base64, at most
/// [most] characters ([circleBannerMax] where not said). Null where it can't be read.
Future<String?> circleBannerOf(Uint8List bytes, {ui.Rect? crop, int most = circleBannerMax}) =>
    pictureStandIn(bytes, crop: crop, shape: circleBannerShape, widths: const [circleBannerSide, 420, 360, 300, 240, 192, 150, 120], most: most);

void _say(BuildContext context, String words, {bool wrong = true}) => toast(context, words, tone: wrong ? GlacierToastTone.danger : GlacierToastTone.neutral);

/// What went wrong, in the device's or the relay's own words, without the type's name before them.
String _why(Object e) {
  final words = switch (e) {
    FileSystemException(:final message, :final osError) => osError?.message.isNotEmpty == true ? osError!.message : message,
    _ => '$e',
  };
  // Without its own last stop: it is put into a sentence that has one.
  final plain = words.replaceFirst(RegExp(r'^(Exception|Bad state|StateError|FilesError): '), '').replaceFirst(RegExp(r'[.\s]+$'), '');
  return plain.isEmpty ? 'no reason given'.t : plain;
}

String _nameOf(String path) => path.substring(path.lastIndexOf(RegExp(r'[/\\]')) + 1);

/// Asks for a picture and which part of it, [shape] wide to one high, and makes its stand-in and its full cut. Null
/// where none was chosen, the person thought better of it, or it couldn't be used, which is said with why.
Future<CirclePick?> _pick(
  BuildContext context, {
  required double shape,
  required Future<String?> Function(Uint8List bytes, ui.Rect crop, int most) small,
  required int most,
  required int mostAcross,
  Future<List<String>> Function()? choose,
}) async {
  final List<String> picked;
  try {
    picked = await (choose ?? Sms.instance.pickImages)();
  } catch (e) {
    if (context.mounted) _say(context, 'The pictures couldn\'t be opened: {why}'.tf({'why': _why(e)}));
    return null;
  }
  if (picked.isEmpty) return null;
  // A phone's pick is copied into the app's cache to be read (a content: address is no file); a computer's is read
  // where it lies and left there.
  String? copy;
  try {
    final Uint8List bytes;
    try {
      final path = await Sms.instance.cacheCopy(picked.first);
      if (path != picked.first) copy = path;
      bytes = await File(path).readAsBytes();
    } catch (e) {
      if (context.mounted) _say(context, 'That picture couldn\'t be opened: {why}'.tf({'why': _why(e)}));
      return null;
    }
    if (await pictureSizeOf(bytes) == null) {
      if (context.mounted) _say(context, '{name} isn\'t a picture this device can read. Try a JPEG or a PNG.'.tf({'name': _nameOf(picked.first)}));
      return null;
    }
    if (!context.mounted) return null;
    // Which part of it: nothing is changed where the person thinks better of it.
    final crop = await showPictureCrop(context, bytes, shape: shape);
    if (crop == null) return null;
    final standIn = await small(bytes, crop, most);
    if (standIn == null) {
      if (context.mounted) _say(context, 'That picture couldn\'t be made ready. Try another one.'.t);
      return null;
    }
    return CirclePick(small: standIn, lighter: await small(bytes, crop, most ~/ 3), cut: await cutPictureOf(bytes, crop: crop, shape: shape, mostAcross: mostAcross));
  } finally {
    if (copy != null) {
      try {
        File(copy).deleteSync();
      } catch (_) {}
    }
  }
}

/// Asks for a picture for a circle's face, and which part of it (a round window): its stand-in and its full cut. For
/// a circle being made (lib/ui/circles/new_circle.dart), which sends the cut up once it exists ([sendCirclePicture]).
Future<CirclePick?> pickCirclePicture(BuildContext context, {Future<List<String>> Function()? choose}) =>
    _pick(context, shape: 1, small: (bytes, crop, most) => circlePictureOf(bytes, crop: crop, most: most), most: circlePictureMax, mostAcross: circleFaceMost, choose: choose);

/// What sends a circle's own file up and what changes the circle: FilesStore's and Circles' own, unless a test says.
typedef CircleFileUp = Future<Map<String, Object?>> Function(Circle c, File file, String name);
typedef CircleChange = Future<bool> Function(Circle c, {String? picture, Map<String, Object?>? pictureFile, String? banner, Map<String, Object?>? bannerFile});

/// How long a circle's picture is given to go up: a few megabytes at most, on any connection that is one.
const _upWait = Duration(minutes: 2);

Future<Map<String, Object?>> _up(Circle c, File file, String name) async {
  // The app's own copy ([_fileOf]): moved into the files' cache once it is up, so the full picture is here at once.
  final out = OutgoingFile(path: file.path, name: name, size: file.lengthSync(), mime: FileKind.mimeOf(name), owned: true);
  try {
    final full = await FilesStore.instance.uploadForChat(c.bannerChannel, out, byName: c.name, thumbMost: 0, moved: () {}).timeout(_upWait);
    return full.withoutThumb().toJson();
  } on TimeoutException {
    // Still waiting on the relay (no connection, or it is away): let go of, with what it was waiting for.
    final waiting = out.waiting;
    FilesStore.instance.drop(out);
    throw StateError(waiting ?? 'the relay didn\'t answer in time'.t);
  }
}

Future<bool> _change(Circle c, {String? picture, Map<String, Object?>? pictureFile, String? banner, Map<String, Object?>? bannerFile}) =>
    Circles.instance.edit(c, picture: picture, pictureFile: pictureFile, banner: banner, bannerFile: bannerFile);

/// Why [c] couldn't be changed, as far as this device can tell: its role here doesn't sign the circle, or the circle
/// holds as much as one packet carries.
String _whyNot(Circle c) => Circles.instance.can(c, CirclePerm.circle)
    ? '{circle} has no room left for it'.tf({'circle': c.name})
    : 'your role in {circle} can\'t change it'.tf({'circle': c.name});

/// [cut] as a file of the app's own, in a folder of its own under the system's temporary one.
File _fileOf(CutPicture cut, String name) {
  final dir = Directory.systemTemp.createTempSync('circle-picture-');
  return File('${dir.path}${PlatformInfo.pathSeparator}$name')..writeAsBytesSync(cut.bytes, flush: true);
}

/// Sends [pick]'s full cut up for [c] as [name] (without its ending) and gives back how the manifest names it; null
/// with [why] told where there is none or it didn't go up. The temporary folder is let go either way.
Future<Map<String, Object?>?> _sendCut(Circle c, CirclePick pick, String name, CircleFileUp up, void Function(String why) why) async {
  final cut = pick.cut;
  if (cut == null) {
    why('it couldn\'t be cut out of the picture'.t);
    return null;
  }
  File? file;
  try {
    file = _fileOf(cut, '$name.${cut.kind}');
    return await up(c, file, '$name.${cut.kind}');
  } catch (e) {
    why(_why(e));
    return null;
  } finally {
    try {
      file?.parent.deleteSync(recursive: true);
    } catch (_) {}
  }
}

/// Makes [pick] the picture of [c]: its full cut goes up, then the circle is changed to the stand-in and the file
/// together. Where the cut doesn't go up the stand-in is still set, and why is said; where the circle can't be
/// changed nothing is. False where it was not set. [quiet]: nothing is said (a circle just made, whose picture is
/// already its stand-in).
Future<bool> sendCirclePicture(BuildContext context, Circle c, CirclePick pick, {bool quiet = false, CircleFileUp? up, CircleChange? change}) async {
  String? failed;
  final file = await _sendCut(c, pick, 'picture', up ?? _up, (w) => failed = w);
  final set = change ?? _change;
  // In the lighter stand-in where the circle's manifest has no room for the other: its full copy is what is drawn large.
  final ok = await set(c, picture: pick.small, pictureFile: file) || (pick.lighter != null && await set(c, picture: pick.lighter, pictureFile: file));
  if (quiet || !context.mounted) return ok;
  if (!ok) {
    _say(context, 'The picture couldn\'t be set: {why}.'.tf({'why': _whyNot(c)}));
  } else if (file == null) {
    _say(context, 'The picture is set, but its full-size copy didn\'t go up: {why}. Choose it again to try once more.'.tf({'why': failed ?? ''}));
  } else {
    _say(context, 'Picture set'.t, wrong: false);
  }
  return ok;
}

/// Asks for a picture and sets it as [c]'s, in its icon's place. False where none was chosen or it couldn't be set (said).
Future<bool> chooseCirclePicture(BuildContext context, Circle c, {Future<List<String>> Function()? choose, CircleFileUp? up, CircleChange? change}) async {
  final pick = await pickCirclePicture(context, choose: choose);
  if (pick == null || !context.mounted) return false;
  _say(context, 'Uploading the picture…'.t, wrong: false);
  return sendCirclePicture(context, c, pick, up: up, change: change);
}

/// Asks for a picture and sets it as [c]'s banner (Matt, 2026-11-19: "when uploading a banner from camera roll it's not
/// uploading the full resolution image"): the band chosen, cut at the picture's own resolution, goes up sealed to the
/// relay under the circle's own seed, and the circle names it beside its stand-in ([circleBannerOf]), which shows at
/// once and wherever the full one hasn't come yet. False where none was chosen or it couldn't be set (said, with why).
Future<bool> chooseCircleBanner(BuildContext context, Circle c, {Future<List<String>> Function()? choose, CircleFileUp? up, CircleChange? change}) async {
  final pick = await _pick(context, shape: circleBannerShape, small: (bytes, crop, most) => circleBannerOf(bytes, crop: crop, most: most), most: circleBannerMax, mostAcross: circleBannerMost, choose: choose);
  if (pick == null || !context.mounted) return false;
  _say(context, 'Uploading the banner…'.t, wrong: false);
  String? failed;
  final file = await _sendCut(c, pick, 'banner', up ?? _up, (w) => failed = w);
  final set = change ?? _change;
  final ok = await set(c, banner: pick.small, bannerFile: file) || (pick.lighter != null && await set(c, banner: pick.lighter, bannerFile: file));
  if (!context.mounted) return ok;
  if (!ok) {
    _say(context, 'The banner couldn\'t be set: {why}.'.tf({'why': _whyNot(c)}));
  } else if (file == null) {
    _say(context, 'The banner is set, but its full-size copy didn\'t go up: {why}. Choose it again to try once more.'.tf({'why': failed ?? ''}));
  } else {
    _say(context, 'Banner set'.t, wrong: false);
  }
  return ok;
}

// --- a person's own picture and banner (lib/ui/profile.dart), which are chosen the same way ---------------------------

/// Asks for a picture and which part of it, and gives it back as a profile picture (lib/me/picture_make.dart); null
/// where none was chosen or it couldn't be read (said in a toast).
Future<ProfilePicture?> pickProfilePicture(BuildContext context) async {
  try {
    final picked = await Sms.instance.pickImages();
    if (picked.isEmpty) return null;
    final path = await Sms.instance.cacheCopy(picked.first);
    final bytes = await File(path).readAsBytes();
    if (!context.mounted) return null;
    // Which part of it (lib/ui/picture_crop.dart); nothing is changed where the person thinks better of it.
    final crop = await showPictureCrop(context, bytes);
    if (crop == null) return null;
    final made = await profilePictureOf(bytes, crop: crop);
    if (made == null && context.mounted) toast(context, 'Couldn\'t use that picture.', tone: GlacierToastTone.danger);
    return made;
  } catch (e) {
    if (context.mounted) toast(context, 'Couldn\'t use that picture: $e', tone: GlacierToastTone.danger);
    return null;
  }
}

/// Asks for a picture and which band of it, and gives it back as a profile's banner picture (GMFB-34;
/// lib/me/picture_make.dart, bannerPictureOf): the cropper a profile picture has, with a window three wide to one
/// high. Null where none was chosen or it couldn't be read (said in a toast).
Future<String?> pickBannerPicture(BuildContext context) async {
  try {
    final picked = await Sms.instance.pickImages();
    if (picked.isEmpty) return null;
    final path = await Sms.instance.cacheCopy(picked.first);
    final bytes = await File(path).readAsBytes();
    if (!context.mounted) return null;
    final crop = await showPictureCrop(context, bytes, shape: ProfilePictures.bannerShape);
    if (crop == null) return null;
    final made = await bannerPictureOf(bytes, crop: crop);
    if (made == null && context.mounted) toast(context, 'Couldn\'t use that picture.', tone: GlacierToastTone.danger);
    return made;
  } catch (e) {
    if (context.mounted) toast(context, 'Couldn\'t use that picture: $e', tone: GlacierToastTone.danger);
    return null;
  }
}
