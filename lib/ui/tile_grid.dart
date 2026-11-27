import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// The shape of a person's video tile on a wide screen, width over height (Matt, 2026-11-23: "please make the video
/// chats more square right now they're too wide and narrow make them like 4:3"). A camera's picture is cropped to fill
/// it; a shared screen keeps its own shape inside. A phone's tiles take each picture's own shape ([VideoShapes]).
const double tileAspect = 4 / 3;

/// The shape of each picture in a call as it arrives, width over height, by its stream's id (GMFB-71, Matt: "Videos
/// are still rectangular on mobile and don't show the whole camera resolution"): a phone held upright films 9:16, a
/// computer's camera 16:9 or 4:3, and a tile on a phone takes the picture's own shape ([wholeTile]). Said by whatever
/// draws the stream, once its first frame gives a size and again when the phone filming is turned (StreamView).
abstract final class VideoShapes {
  static final ValueNotifier<Map<String, double>> changes = ValueNotifier(const {});

  /// The shape of the picture of the stream [id]; null until a frame of it has come.
  static double? of(String? id) => id == null ? null : changes.value[id];

  static void say(String id, double shape) {
    if (!shape.isFinite || shape <= 0) return;
    final had = changes.value[id];
    if (had != null && (had - shape).abs() < 0.01) return;
    final next = {...changes.value}..remove(id);
    // A long evening's calls leave only the latest few behind.
    while (next.length >= 32) {
      next.remove(next.keys.first);
    }
    changes.value = {...next, id: shape};
  }
}

/// The size of a tile that shows the whole of a picture shaped [shape] (width over height), nothing cut off: as wide
/// as [width] where that is no taller than [most], else [most] tall and as narrow as the picture is then (GMFB-71).
Size wholeTile({required double width, required double shape, required double most}) {
  final h = math.min(width / shape, most);
  return Size(h * shape, h);
}

/// [n] tiles of [aspect] in a grid as large as fits in [room], [gap] between them: every number across is tried and
/// the one giving the biggest tiles kept. The size is the same for every tile; a short last row is the caller's to
/// centre.
({int cols, int rows, Size size}) fitTiles(Size room, int n, {double gap = 0, double aspect = tileAspect}) {
  var best = (cols: 1, rows: n < 1 ? 0 : 1, size: Size.zero);
  for (var cols = 1; cols <= n; cols++) {
    final rows = (n / cols).ceil();
    var w = (room.width - gap * (cols - 1)) / cols;
    var h = (room.height - gap * (rows - 1)) / rows;
    if (w <= 0 || h <= 0) continue;
    if (w / h > aspect) {
      w = h * aspect;
    } else {
      h = w / aspect;
    }
    if (w * h > best.size.width * best.size.height) best = (cols: cols, rows: rows, size: Size(w, h));
  }
  return best;
}

/// [count] tiles from [tile], 4:3 and as large as fit in the room given, the grid centred and a short last row centred
/// under the rest.
class TileGrid extends StatelessWidget {
  const TileGrid({super.key, required this.count, required this.tile, this.gap = 8});
  final int count;
  final Widget Function(int i) tile;
  final double gap;

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, box) {
        final fit = fitTiles(box.biggest, count, gap: gap);
        return Center(
          child: Column(mainAxisSize: MainAxisSize.min, spacing: gap, children: [
            for (var r = 0; r < fit.rows; r++)
              Row(mainAxisSize: MainAxisSize.min, spacing: gap, children: [
                for (var i = r * fit.cols; i < count && i < (r + 1) * fit.cols; i++) SizedBox(width: fit.size.width, height: fit.size.height, child: tile(i)),
              ]),
          ]),
        );
      });
}
