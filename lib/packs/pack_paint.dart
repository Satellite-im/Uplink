import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import 'resource_pack.dart';

/// Drawing with a resource pack's pictures (lib/packs/resource_pack.dart; Matt, 2026-11-27: "bring in the pixelated
/// looks"): each a small picture of the game's, drawn large with its pixels kept square (no smoothing), stretched as
/// a nine-patch where it is a frame or a button, and laid side by side where it is a ground.

/// The pack the chrome draws with under [t], or null: only a look whose rules ask for one (`--app-chrome-sprites:
/// pack`, Runestone's alone) and only once one is read. Everything that draws with one draws flat without.
ResourcePack? packOf(Tokens t) => t.raw('app-chrome-sprites')?.trim() == 'pack' ? ResourcePacks.instance.current : null;

/// How many logical pixels one pixel of a pack's picture is drawn as: two on a phone, where the game's 22-pixel
/// button is then a finger's 44, and one and a half on a computer.
double packScale(Tokens t) => t.attrs['platform'] == 'desktop' ? 1.5 : 2;

final _plain = Paint()..filterQuality = FilterQuality.none;

/// [image] as a nine-patch over [dst]: its corners ([inset] of its own pixels square) kept whole at [scale], its
/// edges and middle stretched between them. Where [dst] is too small for two corners at [scale] they are drawn
/// smaller, so a frame never folds over itself. [src] is the part of the picture drawn, all of it where null.
void paintNine(Canvas canvas, ui.Image image, Rect dst, {required double inset, required double scale, Rect? src}) {
  final from = src ?? Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble());
  final fits = math.min(dst.width, dst.height) / (2 * inset + 1);
  final s = math.max(0.5, math.min(scale, fits));
  final center = Rect.fromLTRB(from.left + inset, from.top + inset, from.right - inset, from.bottom - inset);
  canvas.save();
  canvas.translate(dst.left, dst.top);
  canvas.scale(s);
  if (src == null) {
    canvas.drawImageNine(image, center, Rect.fromLTWH(0, 0, dst.width / s, dst.height / s), _plain);
  } else {
    // A part of a picture: the nine pieces by hand, since a nine-patch is of a whole one.
    final w = dst.width / s, h = dst.height / s;
    final xs = [0.0, inset, w - inset, w], ys = [0.0, inset, h - inset, h];
    final sx = [from.left, from.left + inset, from.right - inset, from.right], sy = [from.top, from.top + inset, from.bottom - inset, from.bottom];
    for (var r = 0; r < 3; r++) {
      for (var c = 0; c < 3; c++) {
        canvas.drawImageRect(image, Rect.fromLTRB(sx[c], sy[r], sx[c + 1], sy[r + 1]), Rect.fromLTRB(xs[c], ys[r], xs[c + 1], ys[r + 1]), _plain);
      }
    }
  }
  canvas.restore();
}

/// [image] laid side by side over [dst] from its top left, each pixel [scale] across.
void paintTiled(Canvas canvas, ui.Image image, Rect dst, {required double scale}) {
  final matrix = Matrix4.identity()
    ..translateByDouble(dst.left, dst.top, 0, 1)
    ..scaleByDouble(scale, scale, 1, 1);
  canvas.drawRect(dst, Paint()..shader = ui.ImageShader(image, TileMode.repeated, TileMode.repeated, matrix.storage, filterQuality: FilterQuality.none));
}

/// [image] whole, fitted inside [dst] and centred there, its pixels kept square: at a whole number of logical pixels
/// each where it fits so, smaller where it does not.
void paintWhole(Canvas canvas, ui.Image image, Rect dst) {
  final fit = math.min(dst.width / image.width, dst.height / image.height);
  final s = fit >= 1 ? fit.floorToDouble() : fit;
  final w = image.width * s, h = image.height * s;
  final at = Rect.fromLTWH(dst.left + ((dst.width - w) / 2).roundToDouble(), dst.top + ((dst.height - h) / 2).roundToDouble(), w, h);
  canvas.drawImageRect(image, Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()), at, _plain);
}
