import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';

import '../app_state.dart';
import '../desktop/store.dart' show DeskStore;
import '../looks.dart';
import '../platform_info.dart';

/// Resource packs for the look Runestone (lib/looks.dart; Matt, 2026-11-27: "see how we can get the dark vanilla
/// texture pack", then "let's try the duckscape theme instead and bring in the pixelated looks").
///
/// The game the look is modelled on has a hub of packs its players draw for its interface: each a folder of small
/// pictures under fixed names (`chatbox/button.png`, `dialog/background.png`), one branch a pack of
/// github.com/melkypie/resource-packs, listed with the commit each stands at in `manifest.js` on its `github-actions`
/// branch. The look draws its windows, buttons, wells and chat parchment from a pack's own pictures where one is
/// here (lib/packs/pack_paint.dart), pixel for pixel, and from flat stone where none is.
///
/// A pack is its artist's own work, and behind most is the game's: none is in the app or its source. This device
/// fetches one from the hub, as the game's own client does: the archive of the commit the hub lists, kept whole in
/// the app's folder ([packsRoot]) and read as data (pictures and nothing else are taken from it; nothing in it is
/// run). Not in a browser, which speaks to its own address alone.
///
/// **The look has a usual pack** ([ResourcePacks.usual], Duckscape; Matt, 2026-11-27, of the look in flat stone on his
/// phone: "I see the runestone theme but I wanted it to use the duckscape look"). Until the person chooses another, or
/// plain stone, that is the pack chosen, and it is fetched by itself the first time Runestone is the look: as the app
/// starts in it, or as it is chosen. Nobody who never uses the look fetches anything, and Settings › Appearance ›
/// Textures says where it comes from, shows it arriving, and has plain stone a press away.
class PackEntry {
  const PackEntry({required this.id, required this.name, required this.author, required this.commit, this.tags = const []});

  /// The pack's branch in the hub ("pack-duckscape"): its name on disk and in the choice kept.
  final String id;
  final String name, author;

  /// The commit the hub lists it at: what is fetched, so a pack is what the hub's keepers passed and no later push.
  final String commit;
  final List<String> tags;

  /// One of the hub's list, or null where it is not a pack this can take (no branch or commit, or names with more in
  /// them than a branch's and a commit's letters, which go into an address and a file's name).
  static PackEntry? from(Object? j) {
    if (j is! Map) return null;
    final id = '${j['internalName'] ?? j['id'] ?? ''}', commit = '${j['commit'] ?? ''}';
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$').hasMatch(id) || !RegExp(r'^[0-9a-f]{40}$').hasMatch(commit)) return null;
    final name = '${j['displayName'] ?? j['name'] ?? id}'.trim();
    return PackEntry(
      id: id,
      name: name.isEmpty ? id : (name.length > 60 ? name.substring(0, 60) : name),
      author: '${j['author'] ?? ''}'.trim(),
      commit: commit,
      tags: [for (final t in (j['tags'] as List? ?? const [])) '$t'],
    );
  }

  Map<String, Object?> toJson() => {'internalName': id, 'displayName': name, 'author': author, 'commit': commit, 'tags': tags};
}

/// The colours a pack's pictures are, read off them, so what the look fills flat (a page behind its windows, a row)
/// is the colour of the picture beside it.
class PackColours {
  const PackColours({required this.window, required this.panel, required this.parchment, required this.band, required this.button, required this.line});

  /// A window's face (`dialog/background`), a well's (`side_panel_background`), the chatbox's parchment, the strip a
  /// heading stands on, a button's face, and the darkest line round a button.
  final ui.Color window, panel, parchment, band, button, line;
}

/// A pack read into memory: its pictures by their names without `.png` (`chatbox/button`), and its colours.
class ResourcePack {
  ResourcePack({required this.entry, required this.sprites, required this.colours, this.parchmentEdge = 6});
  final PackEntry entry;
  final Map<String, ui.Image> sprites;
  final PackColours colours;

  /// How many of its own pixels the chatbox's frame is across, measured off its picture: what is written on the
  /// parchment starts inside it.
  final int parchmentEdge;

  ui.Image? operator [](String name) => sprites[name];

  /// The pictures the look draws with, and no others are read from a pack.
  static const wanted = [
    'chatbox/button', 'chatbox/button_hovered', 'chatbox/button_selected', 'chatbox/button_new_messages', //
    'chatbox/background', 'chatbox/buttons_background_stones', //
    'dialog/background', 'dialog/background_brighter', //
    'button/corner_top_left', 'button/corner_top_right', 'button/corner_bottom_left', 'button/corner_bottom_right', //
    'button/edge_top', 'button/edge_bottom', 'button/edge_left', 'button/edge_right', 'button/middle', //
    'button/options_square', 'other/window_close_button', 'other/window_close_button_hovered', //
    'resizeable_mode/side_panel_background', 'resizeable_mode/tab_stone_middle', 'other/minimap_orb_frame_small', 'icon',
  ];

  /// The most a pack's archive and one of its pictures may be: the hub's are half a megabyte to two, a picture a few
  /// kilobytes and at most the chatbox's 519 across.
  static const mostArchive = 16 * 1024 * 1024, mostPicture = 1024 * 1024, mostSide = 1024;

  /// Reads [zip], a pack's archive as the hub serves one (every file under one folder named for the commit).
  /// Throws a [FormatException] where it is not one: no picture of [wanted] in it at all.
  static Future<ResourcePack> read(PackEntry entry, Uint8List zip) async {
    if (zip.length > mostArchive) throw const FormatException('The pack is larger than a pack should be.');
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(zip);
    } catch (_) {
      throw const FormatException('The pack could not be opened.');
    }
    final sprites = <String, ui.Image>{};
    final names = wanted.toSet();
    for (final file in archive.files) {
      if (!file.isFile || !file.name.endsWith('.png')) continue;
      // Under the archive's one folder: "resource-packs-<commit>/chatbox/button.png".
      final slash = file.name.indexOf('/');
      final name = file.name.substring(slash + 1, file.name.length - 4);
      if (!names.contains(name) || file.size > mostPicture) continue;
      try {
        final codec = await ui.instantiateImageCodec(file.content);
        final image = (await codec.getNextFrame()).image;
        if (image.width <= mostSide && image.height <= mostSide) sprites[name] = image;
      } catch (_) {
        // A picture that is not one is left out: that piece is drawn flat.
      }
    }
    if (sprites.isEmpty) throw const FormatException('This is not a resource pack: none of its pictures are in it.');
    final frame = await _frameOf(sprites);
    if (frame != null) sprites['button/frame'] = frame;
    final colours = await _coloursOf(sprites);
    final edge = await _edgeOf(sprites['chatbox/background'], colours.parchment);
    // The parchment inside the chatbox's frame, as a picture of its own: laid side by side over a well of any size,
    // where stretching the whole chatbox to it would draw the paper's grain out into streaks.
    final box = sprites['chatbox/background'];
    if (box != null && box.width > 2 * (edge + 3) + 16 && box.height > 2 * (edge + 3) + 16) {
      final inset = edge + 3.0;
      final recorder = ui.PictureRecorder();
      final w = box.width - 2 * inset, h = box.height - 2 * inset;
      ui.Canvas(recorder).drawImageRect(box, ui.Rect.fromLTWH(inset, inset, w, h), ui.Rect.fromLTWH(0, 0, w, h), ui.Paint()..filterQuality = ui.FilterQuality.none);
      sprites['chatbox/ground'] = await recorder.endRecording().toImage(w.round(), h.round());
    }
    return ResourcePack(entry: entry, sprites: sprites, colours: colours, parchmentEdge: edge);
  }

  /// How far in from [image]'s left edge, along its middle row, its ground ([ground], within a little) begins.
  static Future<int> _edgeOf(ui.Image? image, ui.Color ground) async {
    final data = await image?.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (image == null || data == null) return 6;
    final y = image.height ~/ 2;
    final r = (ground.r * 255).round(), g = (ground.g * 255).round(), b = (ground.b * 255).round();
    for (var x = 0; x < image.width ~/ 4; x++) {
      final i = (y * image.width + x) * 4;
      final off = (data.getUint8(i) - r).abs() + (data.getUint8(i + 1) - g).abs() + (data.getUint8(i + 2) - b).abs();
      if (data.getUint8(i + 3) > 200 && off < 48) return x.clamp(2, 12);
    }
    return 6;
  }

  /// The box the game draws from nine pieces (a corner each, an edge each, a middle), put together as one picture
  /// that is drawn as a nine-patch: corners 6 across, 12 between them. Null where the pack has not all nine.
  static Future<ui.Image?> _frameOf(Map<String, ui.Image> s) async {
    final tl = s['button/corner_top_left'], tr = s['button/corner_top_right'], bl = s['button/corner_bottom_left'], br = s['button/corner_bottom_right'];
    final top = s['button/edge_top'], bottom = s['button/edge_bottom'], left = s['button/edge_left'], right = s['button/edge_right'], middle = s['button/middle'];
    if ([tl, tr, bl, br, top, bottom, left, right, middle].contains(null)) return null;
    final c = tl!.width.toDouble(), m = middle!.width.toDouble();
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    final paint = ui.Paint()..filterQuality = ui.FilterQuality.none;
    void put(ui.Image image, double x, double y, double w, double h) =>
        canvas.drawImageRect(image, ui.Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()), ui.Rect.fromLTWH(x, y, w, h), paint);
    put(middle, c, c, m, m);
    put(top!, c, 0, m, c);
    put(bottom!, c, c + m, m, c);
    put(left!, 0, c, c, m);
    put(right!, c + m, c, c, m);
    put(tl, 0, 0, c, c);
    put(tr!, c + m, 0, c, c);
    put(bl!, 0, c + m, c, c);
    put(br!, c + m, c + m, c, c);
    final side = (2 * c + m).round();
    return recorder.endRecording().toImage(side, side);
  }

  static Future<PackColours> _coloursOf(Map<String, ui.Image> s) async {
    // The mean of a picture's middle half, where its face is and its frame is not.
    Future<ui.Color?> mean(String name) async {
      final image = s[name];
      if (image == null) return null;
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (data == null) return null;
      final w = image.width, h = image.height;
      var r = 0, g = 0, b = 0, n = 0;
      for (var y = h ~/ 4; y < h - h ~/ 4; y++) {
        for (var x = w ~/ 4; x < w - w ~/ 4; x++) {
          final i = (y * w + x) * 4;
          if (data.getUint8(i + 3) < 200) continue;
          r += data.getUint8(i);
          g += data.getUint8(i + 1);
          b += data.getUint8(i + 2);
          n++;
        }
      }
      return n == 0 ? null : ui.Color.fromARGB(255, r ~/ n, g ~/ n, b ~/ n);
    }

    // The darkest opaque pixel along a picture's middle row: the line round it.
    Future<ui.Color?> darkest(String name) async {
      final image = s[name];
      final data = await image?.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (image == null || data == null) return null;
      ui.Color? found;
      var least = 1 << 30;
      final y = image.height ~/ 2;
      for (var x = 0; x < image.width; x++) {
        final i = (y * image.width + x) * 4;
        if (data.getUint8(i + 3) < 200) continue;
        final sum = data.getUint8(i) + data.getUint8(i + 1) + data.getUint8(i + 2);
        if (sum < least) {
          least = sum;
          found = ui.Color.fromARGB(255, data.getUint8(i), data.getUint8(i + 1), data.getUint8(i + 2));
        }
      }
      return found;
    }

    final window = await mean('dialog/background') ?? await mean('button/middle') ?? const ui.Color(0xFF2E2E2E);
    return PackColours(
      window: window,
      panel: await mean('resizeable_mode/side_panel_background') ?? window,
      parchment: await mean('chatbox/background') ?? const ui.Color(0xFFBEBEBE),
      band: await mean('chatbox/buttons_background_stones') ?? window,
      button: await mean('chatbox/button') ?? window,
      line: await darkest('chatbox/button') ?? const ui.Color(0xFF000000),
    );
  }

  /// The look's flat colours as this pack's pictures have them: rules laid over the stylesheets after Runestone's own
  /// (lib/accent.dart), so a page behind a window is the window's colour, a row in a well the well's, and what is
  /// written on the parchment reads on this pack's parchment, light or dark.
  String get css {
    String hex(ui.Color c) => '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';
    ui.Color toward(ui.Color c, ui.Color to, double by) => ui.Color.lerp(c, to, by)!;
    const white = ui.Color(0xFFFFFFFF), black = ui.Color(0xFF000000);
    final panel = colours.panel, window = colours.window, paper = colours.parchment;
    final b = StringBuffer();
    b.writeln(":root:root:root:root:root[data-theme-preset='runestone'] {");
    b.writeln('  --glacier-gray-1: ${hex(panel)};');
    b.writeln('  --glacier-gray-2: ${hex(toward(panel, white, 0.02))};');
    b.writeln('  --glacier-gray-3: ${hex(toward(panel, white, 0.05))};');
    b.writeln('  --glacier-gray-4: ${hex(toward(panel, white, 0.14))};');
    b.writeln('  --glacier-gray-5: ${hex(toward(panel, white, 0.09))};');
    b.writeln('  --glacier-gray-6: ${hex(toward(panel, white, 0.22))};');
    b.writeln('  --app-chrome: ${hex(window)};');
    b.writeln('  --app-bevel-hi: ${hex(toward(window, white, 0.22))};');
    b.writeln('  --app-bevel-lo: ${hex(toward(window, white, 0.11))};');
    b.writeln('  --app-bevel-shadow: ${hex(toward(window, black, 0.45))};');
    b.writeln('  --app-bevel-dark: ${hex(colours.line)};');
    b.writeln('  --app-titlebar: ${hex(colours.band)};');
    b.writeln('  --app-titlebar-end: ${hex(colours.band)};');
    b.writeln('  --app-titlebar-inactive: ${hex(toward(colours.band, white, 0.04))};');
    b.writeln('  --app-highlight: ${hex(toward(window, white, 0.16))};');
    for (final glass in const ['glacier-glass-thin', 'glacier-glass-regular', 'glacier-glass-thick', 'glacier-surface-raised', 'glacier-segment-track']) {
      b.writeln('  --$glass: ${hex(window)};');
    }
    b.writeln('  --glacier-glass-border: ${hex(toward(window, white, 0.14))};');
    b.writeln('}');
    // The parchment: its own colour and shades of it. Where a pack's chatbox is dark its words are the look's light
    // ones again (white names, the game's pale blue), each over its shadow; where light, the stylesheet's dark inks.
    final light = paper.computeLuminance() > 0.3;
    final ink = light ? black : white;
    b.writeln("[data-theme-preset='runestone'] .parchment, [data-theme-preset='runestone'] .dialup-well {");
    b.writeln('  --app-paper: ${hex(paper)}; --glacier-bg: ${hex(paper)}; --app-gray-1: ${hex(paper)};');
    b.writeln('  --app-paper-2: ${hex(toward(paper, ink, 0.07))}; --glacier-surface: ${hex(toward(paper, ink, 0.07))}; --glacier-hover: ${hex(toward(paper, ink, 0.07))}; --app-raised: ${hex(toward(paper, ink, 0.07))};');
    b.writeln('  --app-paper-3: ${hex(toward(paper, ink, 0.13))}; --glacier-active: ${hex(toward(paper, ink, 0.13))};');
    b.writeln('  --glacier-surface-raised: ${hex(toward(paper, ink, 0.07))}; --glacier-surface-sunken: ${hex(toward(paper, ink, 0.03))};');
    b.writeln('  --app-rule: ${hex(toward(paper, ink, 0.28))}; --glacier-border: ${hex(toward(paper, ink, 0.28))}; --glacier-border-subtle: ${hex(toward(paper, ink, 0.2))};');
    b.writeln('  --app-bubble-theirs: ${hex(toward(paper, ink, 0.13))}; --app-bubble-rim: ${hex(toward(paper, ink, 0.28))};');
    if (!light) {
      b.writeln('  --app-ink: #FFFFFF; --app-ink-2: #D8D8D8; --app-ink-3: #B4B4B4; --app-ink-4: #8A8A8A;');
      b.writeln('  --app-gray-12: #FFFFFF; --app-gray-11: #D8D8D8; --app-gray-9: #B4B4B4; --app-gray-7: #8A8A8A;');
      b.writeln('  --glacier-text: #FFFFFF; --glacier-text-muted: #D8D8D8; --glacier-text-subtle: #B4B4B4; --glacier-text-disabled: #8A8A8A;');
      b.writeln('  --glacier-border-strong: #FFFFFF; --glacier-focus-ring: #FFFFFF; --glacier-text-shadow: 1px 1px 0 #000000;');
      b.writeln('  --app-name-mine: #FFFFFF; --app-name-theirs: #FFFFFF; --app-name-1: #00FFFF; --app-name-2: #FFFF00; --app-name-3: #00FF00; --app-name-4: #FF981F; --app-name-5: #FF80FF; --app-name-6: #80C0FF;');
      b.writeln('  --app-line-mine: #9090FF; --app-line-theirs: #FFFFFF;');
      b.writeln('  --app-danger: #FF6060; --app-unread: #00FF00; --app-chosen: #FFFFFF; --app-info: #00FFFF; --app-online: #00FF00; --app-warn: #FF981F; --app-pinned: #FF981F;');
    }
    b.writeln('}');
    // A field's ground is the parchment itself (the rule above gave every field's the shade a surface is).
    b.writeln("[data-theme-preset='runestone'] .dialup-well { --glacier-surface: ${hex(paper)}; }");
    return b.toString();
  }
}

/// This device's packs folder: on Android the app's own files, on a computer or an iPhone the folder everything else
/// of the app's is kept in (lib/plugins/pack/installed.dart's `pluginsRoot` beside it). Under flutter test, a fresh
/// folder in the system's temp, never the installed app's.
Directory packsRoot() {
  if (PlatformInfo.environment.containsKey('FLUTTER_TEST')) return Directory.systemTemp.createTempSync('ghost-packs-');
  if (PlatformInfo.isAndroid) return Directory('${Directory.systemTemp.parent.path}/files/resource-packs');
  final dir = PlatformInfo.environment['GHOST_DESK_DIR'];
  final base = dir == null || dir.isEmpty ? DeskStore.defaultDir() : Directory(dir);
  return Directory('${base.path}${PlatformInfo.pathSeparator}resource-packs');
}

/// The packs on this device, the one in use, and the hub they come from.
class ResourcePacks extends ChangeNotifier {
  ResourcePacks({Directory? root, HttpClient Function()? http, this.listUrl = hubList, String Function(PackEntry e)? archiveUrl})
      : _root = root,
        _http = http ?? HttpClient.new,
        _archiveUrl = archiveUrl ?? archiveOf;

  /// Where the hub's list and a pack's archive are asked for: the hub's own, unless a test stands in for it.
  final String listUrl;
  final String Function(PackEntry e) _archiveUrl;

  static ResourcePacks instance = ResourcePacks();

  /// The choice the pack in use is kept under, by its id; plain stone where empty, and [usual] where nothing was ever
  /// chosen ([chosen]).
  static const pref = 'resource_pack';

  /// The pack Runestone is drawn with unless another is chosen: its branch in the hub, and its name for a row in
  /// Settings before the hub has been asked.
  static const usual = 'pack-duckscape', usualName = 'Duckscape';

  /// The pack [app] has chosen, by its id: [usual] until something is chosen, empty for plain stone.
  static String chosen(AppState app) => app.choice(pref, usual);

  /// What [entry] is called where the app names it: the hub's own name for it, and [usualName] for the usual pack,
  /// which the app has named before the hub was ever asked (the hub writes it "duckscape").
  static String nameOf(PackEntry entry) => entry.id == usual ? usualName : entry.name;

  /// The hub: its list, and a pack's archive at the commit the list names.
  static const hubList = 'https://raw.githubusercontent.com/melkypie/resource-packs/github-actions/manifest.js';
  static String archiveOf(PackEntry e) => 'https://github.com/melkypie/resource-packs/archive/${e.commit}.zip';
  static String pageOf(PackEntry e) => 'https://github.com/melkypie/resource-packs/tree/${e.id}';

  /// Whether this device can have packs: everywhere but a browser, which may speak to its own address alone.
  static bool get here => !PlatformInfo.isWeb;

  Directory? _root;
  final HttpClient Function() _http;
  Directory get root => _root ??= packsRoot();

  /// The pack read into memory, drawn with while the look is Runestone; null where none is chosen or it is not read
  /// yet (the look is flat stone until it is).
  ResourcePack? current;

  /// The pack being fetched for the look by itself ([fetch]), by its id, and the one whose fetching last failed: what
  /// Settings › Appearance › Textures says of the pack chosen while it is not on this device.
  String? fetching, failed;

  /// The choices followed ([start]), and whether Runestone was their look when last looked at.
  AppState? _app;
  bool _runestone = false;

  /// The pack whose pictures [app]'s look draws with now, and whose colours are laid over its stylesheet.
  ResourcePack? usedBy(AppState app) => app.look == Look.runestone ? current : null;

  File _zip(String id) => File('${root.path}${PlatformInfo.pathSeparator}$id.zip');
  File _about(String id) => File('${root.path}${PlatformInfo.pathSeparator}$id.json');

  /// The packs kept on this device, by name.
  List<PackEntry> installed() {
    if (!here) return const [];
    try {
      if (!root.existsSync()) return const [];
      final found = <PackEntry>[];
      for (final f in root.listSync().whereType<File>()) {
        if (!f.path.endsWith('.json')) continue;
        try {
          final e = PackEntry.from(jsonDecode(f.readAsStringSync()));
          if (e != null && _zip(e.id).existsSync()) found.add(e);
        } catch (_) {}
      }
      return found..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    } catch (_) {
      return const [];
    }
  }

  /// Reads the pack [app] chose, as the app starts and whenever the choice changes; tells [app] once it is drawn with.
  /// One that is not on this device is fetched for the look ([fetch]), which this does not wait for: the look is flat
  /// stone until it is here. From here on [app]'s look is followed, so the same is done as Runestone is chosen.
  Future<void> start(AppState app) async {
    if (!here) return;
    if (!identical(_app, app)) {
      _app?.removeListener(_looked);
      _app = app..addListener(_looked);
    }
    _runestone = app.look == Look.runestone;
    await _read(app);
  }

  /// [_app]'s choices changed: where Runestone has just become the look, its pack is read, and fetched if need be.
  void _looked() {
    final app = _app;
    if (app == null) return;
    final now = app.look == Look.runestone;
    if (now == _runestone) return;
    _runestone = now;
    if (now) unawaited(_read(app));
  }

  Future<void> _read(AppState app) async {
    final id = chosen(app);
    if (id == current?.entry.id) return;
    if (id.isEmpty) {
      current = null;
      notifyListeners();
      app.changed();
      return;
    }
    ResourcePack? pack;
    try {
      final entry = PackEntry.from(jsonDecode(await _about(id).readAsString()));
      if (entry != null) pack = await ResourcePack.read(entry, await _zip(id).readAsBytes());
    } catch (_) {
      // Never fetched, gone from the disk, or not a pack any more.
    }
    // Another was chosen while this one was being read: that one is the one drawn with.
    if (chosen(app) != id) return;
    if (pack != null) {
      current = pack;
      notifyListeners();
      app.changed();
    } else if (app.look == Look.runestone) {
      // Not on this device: the choice stays, and where Runestone is the look in use it is fetched, and drawn with
      // once it is here. Until then the look is drawn as it was (flat stone, as the app starts).
      unawaited(fetch(app, id));
    }
  }

  /// Fetches the pack [id] for the look by itself: the hub's list, for the commit it stands at, then its archive,
  /// kept as [install] keeps one. One at a time. Where it can't be fetched (no connection, the hub away, no such
  /// pack) nothing throws: [failed] says so, the look stays flat stone, and it is tried again as the app next starts
  /// in the look, as the look is next chosen, or from Settings.
  Future<void> fetch(AppState app, String id) async {
    if (!here || id.isEmpty || fetching != null) return;
    fetching = id;
    failed = null;
    notifyListeners();
    app.changed();
    try {
      PackEntry? entry;
      for (final e in await hub()) {
        if (e.id == id) entry = e;
      }
      if (entry == null) throw const FormatException('The hub has no pack by that name.');
      final pack = await _keep(entry);
      // Still the one chosen: plain stone, or another pack, may have been pressed while it was on its way.
      if (chosen(app) == id) current = pack;
    } catch (_) {
      failed = id;
    } finally {
      fetching = null;
      notifyListeners();
      app.changed();
    }
  }

  /// The hub's packs, by name. Throws where the hub can't be reached or its list is not one.
  Future<List<PackEntry>> hub() async {
    final list = jsonDecode(utf8.decode(await _get(listUrl, most: 4 * 1024 * 1024)));
    if (list is! List) throw const FormatException('The list of packs was not a list.');
    return [for (final j in list) ?PackEntry.from(j)]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  }

  /// Fetches [entry] from the hub, keeps it, and makes it the pack [app] draws with. Throws where it can't be fetched
  /// or is not a pack; what was in use stays in use then.
  Future<void> install(AppState app, PackEntry entry) async {
    final pack = await _keep(entry);
    current = pack;
    failed = null;
    app.set(pref, entry.id);
    notifyListeners();
  }

  /// [entry]'s archive from the hub, read and, being a pack, kept on this device: the archive whole and what it is.
  Future<ResourcePack> _keep(PackEntry entry) async {
    final zip = await _get(_archiveUrl(entry), most: ResourcePack.mostArchive);
    final pack = await ResourcePack.read(entry, zip);
    root.createSync(recursive: true);
    await _zip(entry.id).writeAsBytes(zip, flush: true);
    await _about(entry.id).writeAsString(jsonEncode(entry.toJson()), flush: true);
    return pack;
  }

  /// Draws with the pack [id], or with none where it is empty (plain stone, which then stays until another is
  /// chosen). One of those kept here is read; one that is not here is fetched ([fetch]).
  Future<void> use(AppState app, String id) async {
    if (!here) return;
    failed = null;
    app.set(pref, id);
    await _read(app);
  }

  /// Takes the pack [id] off this device; the look is flat stone again where it was the one in use.
  Future<void> remove(AppState app, String id) async {
    for (final f in [_zip(id), _about(id)]) {
      try {
        if (f.existsSync()) f.deleteSync();
      } catch (_) {}
    }
    // Plain stone, said outright: the usual pack taken off is not fetched again behind the person's back.
    if (chosen(app) == id) await use(app, '');
    notifyListeners();
  }

  Future<Uint8List> _get(String url, {required int most}) async {
    final client = _http();
    try {
      final request = await client.getUrl(Uri.parse(url)).timeout(const Duration(seconds: 20));
      final response = await request.close().timeout(const Duration(seconds: 30));
      if (response.statusCode != 200) throw HttpException('The hub answered ${response.statusCode}.', uri: Uri.parse(url));
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response.timeout(const Duration(seconds: 30))) {
        bytes.add(chunk);
        if (bytes.length > most) throw const FormatException('The hub sent more than a pack should be.');
      }
      return bytes.takeBytes();
    } finally {
      client.close(force: true);
    }
  }

  /// A pack read from an archive on this disk and drawn with, for tests and for trying one in development.
  @visibleForTesting
  Future<void> debugUse(PackEntry entry, Uint8List zip) async {
    current = await ResourcePack.read(entry, zip);
    notifyListeners();
  }
}
