/// A circle's own picture in its icon's place (Matt, 2026-11-17: "use iconography and color where possible"): chosen
/// from the phone's or computer's pictures, cut square from the middle and made small enough to ride in the circle's
/// manifest (circlePictureMax), which goes round in one packet on the hub.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../../circles/circles.dart';
import '../../files/files_store.dart';
import '../../me/picture_make.dart';
import '../../me/pictures.dart';
import '../../voice/hangout.dart' show OutgoingFile;
import '../../sms.dart';
import '../common.dart';
import '../picture_crop.dart';

/// Asks for a picture and gives it back as base64 PNG, square and small; null where none was chosen or it couldn't
/// be read (said in a toast).
Future<String?> pickCirclePicture(BuildContext context) async {
  try {
    final picked = await Sms.instance.pickImages();
    if (picked.isEmpty) return null;
    final path = await Sms.instance.cacheCopy(picked.first);
    final bytes = await File(path).readAsBytes();
    final small = await circlePictureOf(bytes);
    if (small == null && context.mounted) toast(context, 'Couldn\'t use that picture.', tone: GlacierToastTone.danger);
    return small;
  } catch (e) {
    if (context.mounted) toast(context, 'Couldn\'t use that picture: $e', tone: GlacierToastTone.danger);
    return null;
  }
}

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

/// [bytes] (any picture Flutter decodes) as a square base64 PNG of at most [circlePictureMax] characters: the middle
/// square, at the largest of a few sizes that fits. A photo's detail costs bytes, so a busy one ends up smaller.
Future<String?> circlePictureOf(Uint8List bytes) async {
  ui.Image? image;
  try {
    final codec = await ui.instantiateImageCodec(bytes);
    image = (await codec.getNextFrame()).image;
    final side = image.width < image.height ? image.width : image.height;
    final from = Rect.fromLTWH((image.width - side) / 2, (image.height - side) / 2, side.toDouble(), side.toDouble());
    for (final size in const [160, 128, 96, 72, 56, 40]) {
      final recorder = ui.PictureRecorder();
      ui.Canvas(recorder).drawImageRect(image, from, Rect.fromLTWH(0, 0, size.toDouble(), size.toDouble()), Paint()..filterQuality = FilterQuality.medium);
      final small = await recorder.endRecording().toImage(size, size);
      final png = await small.toByteData(format: ui.ImageByteFormat.png);
      small.dispose();
      if (png == null) continue;
      final b64 = base64.encode(png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes));
      if (b64.length <= circlePictureMax) return b64;
    }
    return null;
  } catch (_) {
    return null;
  } finally {
    image?.dispose();
  }
}

/// Asks for a picture and sets it as [c]'s banner (Matt, 2026-11-19: "when uploading a banner from camera roll it's not
/// uploading the full resolution image"): the picture as it was chosen goes up sealed to the relay under the circle's
/// own seed, and the circle names it beside a small stand-in of it ([circleBannerOf], at most [circleBannerMax]) that
/// shows at once and wherever the full one hasn't come yet. False where none was chosen or it couldn't be set (said).
Future<bool> chooseCircleBanner(BuildContext context, Circle c) async {
  try {
    final picked = await Sms.instance.pickImages();
    if (picked.isEmpty) return false;
    final path = await Sms.instance.cacheCopy(picked.first);
    final file = File(path);
    final small = await circleBannerOf(await file.readAsBytes());
    if (small == null) {
      if (context.mounted) toast(context, 'Couldn\'t use that picture.', tone: GlacierToastTone.danger);
      return false;
    }
    if (context.mounted) toast(context, 'Uploading the banner…');
    final name = 'banner${path.contains('.') ? path.substring(path.lastIndexOf('.')).toLowerCase() : '.jpg'}';
    final full = await FilesStore.instance.uploadForChat(c.bannerChannel, OutgoingFile(path: path, name: name, size: file.lengthSync(), mime: FileKind.mimeOf(name), owned: true), byName: c.name, thumbMost: 0, moved: () {});
    final ok = await Circles.instance.edit(c, banner: small, bannerFile: full.withoutThumb().toJson());
    if (context.mounted) toast(context, ok ? 'Banner set' : 'Couldn\'t set the banner.', tone: ok ? GlacierToastTone.neutral : GlacierToastTone.danger);
    return ok;
  } catch (e) {
    if (context.mounted) toast(context, 'Couldn\'t use that picture: $e', tone: GlacierToastTone.danger);
    return false;
  }
}

/// [bytes] as a banner: the middle band of three to one, at the largest of a few widths that fits [circleBannerMax].
Future<String?> circleBannerOf(Uint8List bytes) async {
  ui.Image? image;
  try {
    final codec = await ui.instantiateImageCodec(bytes);
    image = (await codec.getNextFrame()).image;
    final w = image.width.toDouble(), h = image.height.toDouble();
    final from = w / h > 3 ? Rect.fromLTWH((w - h * 3) / 2, 0, h * 3, h) : Rect.fromLTWH(0, (h - w / 3) / 2, w, w / 3);
    for (final width in const [360, 300, 240, 192, 150, 120]) {
      final height = (width / 3).round();
      final recorder = ui.PictureRecorder();
      ui.Canvas(recorder).drawImageRect(image, from, Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()), Paint()..filterQuality = FilterQuality.medium);
      final small = await recorder.endRecording().toImage(width, height);
      final png = await small.toByteData(format: ui.ImageByteFormat.png);
      small.dispose();
      if (png == null) continue;
      final b64 = base64.encode(png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes));
      if (b64.length <= circleBannerMax) return b64;
    }
    return null;
  } catch (_) {
    return null;
  } finally {
    image?.dispose();
  }
}
