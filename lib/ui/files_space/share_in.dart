/// Files brought in from outside a Files space: shared in from another app on a phone (Android's share sheet), or
/// dropped on a Mac's window while no Files space is showing. Either way an "Add … to" sheet names the files, with
/// each one's kind, size and their total, and lists the Files spaces this device can add to, its own and every
/// circle's; nothing is copied until one is chosen (Matt, 2026-11-17: "add full functionality for filesharing in a
/// space when the space is designated a Files Space", then "Finish the missing pieces that went unfinished").
library;

import 'dart:async';
import 'dart:io';
import '../../platform_info.dart';

import 'package:flutter/foundation.dart' show Uint8List;
import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../../app_state.dart';
import '../../art/app_icon.dart';
import '../../art/lucide.g.dart';
import '../../circles/circles.dart';
import '../../files/file_platform.dart';
import '../../files/files_store.dart';
import '../../kit/settings_kit.dart';
import '../../kit/settings_type.dart';
import '../../plugins/pack/pack.dart' show InstalledPlugins, packExtension;
import '../../sms.dart';
import '../../voice/channels.dart';
import '../../voice/voice.dart';
import '../circles/circle_face.dart';
import '../circles/circle_screen.dart' show openCircleSpace;
import '../common.dart';
import '../dialup/bevel.dart';
import '../market/dev_plugins.dart' show loadSharedPlugin;
import '../shell.dart';
import 'file_badge.dart';
import 'files_screen.dart';

/// A file offered to a Files space, as far as it is known before anything is copied: where it is ([source], another
/// app's content address on a phone, a path on a computer), its name, its size (-1 where the app sharing it doesn't
/// say) and its type.
@immutable
class IncomingFile {
  const IncomingFile({required this.source, required this.name, this.size = -1, this.mime = ''});
  final String source;
  final String name;
  final int size;
  final String mime;

  FileKind get kind => FileKind.of(name, mime);

  /// One that came by a content address alone: named from the address, its size unknown.
  factory IncomingFile.ofUri(String uri) {
    final last = Uri.tryParse(uri)?.pathSegments.lastOrNull ?? '';
    var decoded = last;
    try {
      decoded = Uri.decodeComponent(last);
    } catch (_) {}
    final name = SpaceFile.cleanName(decoded.split('/').last);
    return IncomingFile(source: uri, name: name.isEmpty ? 'File' : name);
  }

  /// The files at [paths] on this computer, read for their sizes; folders and anything gone are left out (a Files
  /// space holds files, and a folder's files are dropped as themselves).
  static List<IncomingFile> ofPaths(List<String> paths) {
    final out = <IncomingFile>[];
    for (final p in paths) {
      final f = File(p);
      if (!f.existsSync()) continue;
      final name = SpaceFile.cleanName(p.split(PlatformInfo.pathSeparator).last.split('/').last);
      out.add(IncomingFile(source: p, name: name.isEmpty ? 'File' : name, size: f.lengthSync(), mime: FileKind.mimeOf(name)));
    }
    return out;
  }
}

/// How many files and how big, in words: "3 files · 5.4 MB", or "over 5.4 MB" where some sizes aren't known.
String incomingTotal(List<IncomingFile> files) {
  final count = files.length == 1 ? '1 file' : '${files.length} files';
  final known = files.where((f) => f.size >= 0);
  if (known.isEmpty) return count;
  final bytes = known.fold(0, (n, f) => n + f.size);
  return '$count · ${known.length < files.length ? 'over ' : ''}${fileSize(bytes)}';
}

/// The sheet's title: the file by name where there is one, else how many.
String incomingTitle(List<IncomingFile> files) => files.length == 1 ? 'Add “${files.single.name}” to' : 'Add ${files.length} files to';

/// The Files spaces this device can add to: its own first, then each circle's, circle by circle in name order.
List<VoiceChannel> addableFilesSpaces({Iterable<VoiceChannel>? from, bool Function(VoiceChannel c)? may, Circle? Function(VoiceChannel c)? circleOf}) {
  final allowed = may ?? FilesStore.instance.canUpload;
  final circleFor = circleOf ?? Circles.instance.circleOf;
  final spaces = [for (final c in from ?? Voice.instance.channels) if (c.kind == SpaceKind.files && allowed(c)) c];
  // What a space is sorted by: the device's own first, then each circle's by the circle's name.
  String key(VoiceChannel c) => c.circle == null ? '' : '1${(circleFor(c)?.name ?? '').toLowerCase()}\u0000${c.circle}';
  // A stable sort: within one circle the spaces keep the circle's own order.
  final order = {for (final (i, c) in spaces.indexed) c.seed: i};
  spaces.sort((a, b) {
    final k = key(a).compareTo(key(b));
    return k != 0 ? k : order[a.seed]!.compareTo(order[b.seed]!);
  });
  return spaces;
}

/// Shows the "Add … to" sheet: [files] named at its head, then [spaces] to choose from, [onChoose] given the one
/// chosen. Nothing is copied or sent until then.
Future<void> showAddToSheet(
  BuildContext context, {
  required List<IncomingFile> files,
  required List<VoiceChannel> spaces,
  required void Function(VoiceChannel c) onChoose,
  Circle? Function(VoiceChannel c)? circleOf,
}) {
  final circleFor = circleOf ?? Circles.instance.circleOf;
  Choice choice(VoiceChannel c) {
    final circle = c.circle == null ? null : circleFor(c);
    return Choice(
      c.name,
      Lucide.folder,
      () => onChoose(c),
      // A circle's spaces wear the circle's face, so two spaces of one name in two circles are told apart; one of the
      // device's own, the Files space's amber folder. Both one size, so every name starts at the same place.
      mark: circle == null ? const _FolderMark(size: _markSize) : CircleFace.of(circle, size: _markSize),
      hint: c.circle == null ? 'Files space' : 'Files space in ${circle?.name ?? 'a circle'}',
    );
  }

  return showChoices(context, title: incomingTitle(files), header: IncomingFilesList(files: files), choices: [for (final c in spaces) choice(c)]);
}

const double _markSize = 26;

/// A Files space of the device's own, in the sheet: its folder in amber, as the space's own page heads it.
class _FolderMark extends StatelessWidget {
  const _FolderMark({required this.size});
  final double size;

  @override
  Widget build(BuildContext context) => GlacierScope(
        attrs: const {'hue': 'amber'},
        child: Builder(builder: (context) {
          final t = context.tokens;
          final bevel = isBevelChrome(t);
          return Container(
            width: size,
            height: size,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: settingsHueWash(t), borderRadius: BorderRadius.circular(bevel ? 0 : size * 0.32)),
            child: AppIcon(Lucide.folder, size: size * 0.6, color: settingsHue(t)),
          );
        }),
      );
}

/// The files at the head of the "Add … to" sheet: each one's kind (its icon and colour), name and size, the first
/// few of a long list and how many more, and their total.
class IncomingFilesList extends StatelessWidget {
  const IncomingFilesList({super.key, required this.files, this.most = 5});
  final List<IncomingFile> files;

  /// How many rows at most: past it, one fewer is named and the last row says how many more.
  final int most;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final bevel = isBevelChrome(t);
    final dial = bevel ? DialupColors.of(t) : null;
    final ink = dial?.onChrome ?? t.color('app-ink');
    final soft = dial?.inkSoft ?? t.color('app-ink-3');
    final side = bevel ? 10.0 : t.space(4);
    final gap = bevel ? 3.0 : t.space(1);
    final shown = files.length > most ? files.take(most - 1).toList() : files;
    final more = files.length - shown.length;
    return Padding(
      padding: EdgeInsets.only(top: bevel ? 6 : t.space(1)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        for (final f in shown)
          Padding(
            key: ValueKey('incoming-${f.source}'),
            padding: EdgeInsetsDirectional.fromSTEB(side, gap, side, gap),
            child: Row(children: [
              FileBadge(kind: f.kind, size: 32),
              SizedBox(width: bevel ? 10 : t.space(3)),
              Expanded(child: Text(f.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, bevel ? 15 : t.fontSize('sm'), weight: 'medium', color: ink))),
              if (f.size >= 0) ...[
                SizedBox(width: t.space(2)),
                Text(fileSize(f.size), style: pageText(t, bevel ? 13 : t.fontSize('xs'), color: soft)),
              ],
            ]),
          ),
        if (more > 0)
          Padding(
            padding: EdgeInsetsDirectional.fromSTEB(side, gap, side, gap),
            child: Row(children: [
              SizedBox(width: 32, child: Center(child: AppIcon(Lucide.ellipsis, size: 16, color: soft, wash: false))),
              SizedBox(width: bevel ? 10 : t.space(3)),
              Text('and $more more', style: pageText(t, bevel ? 14 : t.fontSize('sm'), color: soft)),
            ]),
          ),
        Padding(
          padding: EdgeInsetsDirectional.fromSTEB(side, bevel ? 6 : t.space(2), side, bevel ? 6 : t.space(2)),
          child: Text(incomingTotal(files), key: const ValueKey('incoming-total'), style: pageText(t, bevel ? 13 : t.fontSize('xs'), weight: 'medium', color: soft)),
        ),
        // Between the files and the spaces to put them in: the era's etched line under Dial-Up, a rule elsewhere.
        if (dial != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 2),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [SizedBox(height: 1, child: ColoredBox(color: dial.shadow)), SizedBox(height: 1, child: ColoredBox(color: dial.hi))]),
          )
        else
          Padding(
            padding: EdgeInsets.symmetric(horizontal: t.space(4)),
            child: SizedBox(height: 1, child: ColoredBox(color: t.color('app-rule'))),
          ),
      ]),
    );
  }
}

/// Takes files as they are brought in from outside and asks which Files space they go to. All static: one for the
/// app.
class FilesShareIn {
  FilesShareIn._();
  static StreamSubscription<List<String>>? _sub;
  static StreamSubscription<List<String>>? _drops;
  static GlobalKey<NavigatorState>? _navigator;

  /// The navigator files brought in are asked about on, from here on: a computer's app hands over its own as it
  /// mounts (lib/desktop/main.dart), each copy of it a key of its own. One key shared by every copy moved the first
  /// copy's whole Navigator, pages and their State, into the next one mounted in the same frame.
  static void navigateWith(GlobalKey<NavigatorState> navigator) => _navigator = navigator;

  /// Listens for files brought in, asking on [navigator]'s page which Files space they go to: files shared in on a
  /// phone, and files dropped on a Mac's window while no Files space is showing (one that is showing takes them
  /// itself, lib/ui/files_space/files_screen.dart). A computer gives no [navigator] here: its app hands one over as it
  /// mounts ([navigateWith]).
  static void attach([GlobalKey<NavigatorState>? navigator]) {
    if (navigator != null) _navigator = navigator;
    _sub ??= FilePlatform.sharedIn().listen((uris) {
      if (uris.isEmpty) return;
      // The app's first frame may not be up yet when it was opened by the share.
      WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_shared(uris)));
    });
    if (FilePlatform.canDrop && _drops == null) {
      _drops = FilePlatform.dropped.listen(_dropped);
      FilePlatform.over.addListener(_hint);
      Voice.instance.addListener(_followSpaces);
      _followSpaces();
    }
  }

  // --- a phone: shared in from another app -------------------------------------------------------------------------

  /// Files another app shared, by their content addresses: described (name, size, type) and offered to a Files
  /// space, each copied into the app's own folder once one is chosen.
  static Future<void> _shared(List<String> uris) async {
    List<IncomingFile> files;
    try {
      files = [for (final d in await Sms.instance.describeFiles(uris)) IncomingFile(source: d.uri, name: d.name, size: d.size, mime: d.mime)];
    } catch (_) {
      // Where they can't be described: named from their addresses, which is all that is known of them.
      files = [for (final u in uris) IncomingFile.ofUri(u)];
    }
    final context = _navigator?.currentContext;
    if (files.isEmpty || context == null || !context.mounted) return;
    // A plugin being made, shared from a computer or a file manager (Matt, 2026-11-20: "a developer setting for users
    // to be able to manually upload plugins for development testing"): loaded in development, not put in a Files space.
    if (PlatformInfo.isAndroid) files = await takePlugins(context, files);
    if (files.isEmpty || !context.mounted) return;
    await offer(context, files, keep: FilePlatform.keep, owned: true);
  }

  /// Of [files] shared in, each .ghostplugin is loaded in development where developer mode is on (with its toast), and
  /// the rest are what is left to offer a Files space. [read] gives a file's bytes (a test's); where developer mode is
  /// off, or this build has no plugins in development, every file is left.
  static Future<List<IncomingFile>> takePlugins(BuildContext context, List<IncomingFile> files, {Future<Uint8List?> Function(String source)? read}) async {
    final plugins = [for (final f in files) if (f.name.toLowerCase().endsWith(packExtension)) f];
    if (plugins.isEmpty || !InstalledPlugins.instance.devAllowed || !AppState.of(context).flag('dev_mode', fallback: false)) return files;
    for (final f in plugins) {
      if (!context.mounted) break;
      await loadSharedPlugin(context, f.source, f.name, read: read);
    }
    return [for (final f in files) if (!plugins.contains(f)) f];
  }

  // --- a Mac: dropped on the window --------------------------------------------------------------------------------

  /// Whether the window takes drops for this sheet: while any Files space is held, so dragging over the window means
  /// nothing where there is nowhere to put them. FilePlatform counts takers, so a Files screen's own coming and going
  /// is unaffected.
  static bool _taking = false;

  /// Turns the window's taking of drops on or off as the first Files space comes or the last goes.
  static void _followSpaces() {
    final want = Voice.instance.channels.any((c) => c.kind == SpaceKind.files);
    if (want == _taking) return;
    _taking = want;
    FilePlatform.dropTarget(want);
  }

  static void _dropped(List<String> paths) => takeDrop(paths);

  /// Files dropped on the window at [paths]: asked about, unless a Files space is showing. The rest are for tests, as
  /// [offer]'s are.
  @visibleForTesting
  static void takeDrop(List<String> paths, {List<VoiceChannel>? spaces, void Function(VoiceChannel c, List<String> paths, bool owned)? upload, void Function(BuildContext context, VoiceChannel c)? open}) {
    // A Files space anywhere in the app (in a pane, or a page under another) adds them itself.
    if (paths.isEmpty || filesShowing()) return;
    final context = _navigator?.currentContext;
    if (context == null || !context.mounted) return;
    final files = IncomingFile.ofPaths(paths);
    if (files.isEmpty) {
      toast(context, paths.length == 1 ? 'A folder can\'t be added. Drop the files in it instead.' : 'Folders can\'t be added. Drop the files in them instead.');
      return;
    }
    if (files.length < paths.length) toast(context, 'Folders are left out. Drop the files in them to add those too.');
    unawaited(offer(context, files, spaces: spaces, upload: upload, open: open));
  }

  static OverlayEntry? _hinting;

  /// While files are dragged over the window with no Files space showing: a hint that dropping them asks where.
  static void _hint() {
    final want = FilePlatform.over.value && !filesShowing();
    if (want == (_hinting != null)) return;
    if (!want) {
      _hinting?.remove();
      _hinting = null;
      return;
    }
    final overlay = _navigator?.currentState?.overlay;
    if (overlay == null) return;
    _hinting = OverlayEntry(builder: (_) => const IncomingDropHint());
    overlay.insert(_hinting!);
  }

  /// Whether a Files space's screen is anywhere in the app now, which takes a drop itself.
  @visibleForTesting
  static bool Function() filesShowing = _filesShowing;

  /// Walks the whole widget tree for a FilesSpaceScreen.
  static bool _filesShowing() {
    var found = false;
    void visit(Element e) {
      if (found) return;
      if (e.widget is FilesSpaceScreen) {
        found = true;
        return;
      }
      e.visitChildren(visit);
    }

    WidgetsBinding.instance.rootElement?.visitChildren(visit);
    return found;
  }

  // --- both ----------------------------------------------------------------------------------------------------------

  /// Asks on [context] which Files space [files] go to, then adds them there and opens it. [keep] copies a file into
  /// the app's own folder first, once a space is chosen (a phone's share, whose permission ends with the app; [owned]
  /// then marks the copies to go once up); without it the files are sent from where they are (a computer's). The rest
  /// are for tests.
  static Future<void> offer(
    BuildContext context,
    List<IncomingFile> files, {
    Future<String?> Function(String source)? keep,
    bool owned = false,
    List<VoiceChannel>? spaces,
    Circle? Function(VoiceChannel c)? circleOf,
    void Function(VoiceChannel c, List<String> paths, bool owned)? upload,
    void Function(BuildContext context, VoiceChannel c)? open,
  }) async {
    if (files.isEmpty) return;
    final to = spaces ?? addableFilesSpaces(circleOf: circleOf);
    if (to.isEmpty) {
      final what = files.length == 1 ? 'this file' : 'these ${files.length} files';
      await showChoices(context, title: 'There is no Files space to add $what to yet. Make one in a circle, or as a space of its own, then try again.', header: IncomingFilesList(files: files), choices: [
        Choice('OK', Lucide.check, () {}),
      ]);
      return;
    }
    await showAddToSheet(context, files: files, spaces: to, circleOf: circleOf, onChoose: (c) => unawaited(_add(context, c, files, keep: keep, owned: owned, upload: upload, open: open)));
  }

  /// Adds [files] to [c], the space chosen: each kept first where [keep] is given (a copy in the app's folder), the
  /// ones that could be read uploaded, the count said, and the space opened.
  static Future<void> _add(
    BuildContext context,
    VoiceChannel c,
    List<IncomingFile> files, {
    Future<String?> Function(String source)? keep,
    bool owned = false,
    void Function(VoiceChannel c, List<String> paths, bool owned)? upload,
    void Function(BuildContext context, VoiceChannel c)? open,
  }) async {
    final paths = <String>[];
    for (final f in files) {
      final p = keep == null ? f.source : await keep(f.source);
      if (p != null) paths.add(p);
    }
    final send = upload ?? (c, paths, owned) => FilesStore.instance.upload(c, paths, owned: owned);
    // The sheet's page gone while the copies were made (many shared at once take a while): they still go up, which
    // needs no page, rather than staying in the app's folder with nothing to send or delete them (Matt, 2026-11-17:
    // "Finish the missing pieces that went unfinished").
    if (!context.mounted) {
      if (paths.isNotEmpty) send(c, paths, owned);
      return;
    }
    if (paths.isEmpty) {
      toast(context, files.length == 1 ? 'That file couldn\'t be read.' : 'Those files couldn\'t be read.', tone: GlacierToastTone.danger);
      return;
    }
    send(c, paths, owned);
    final missed = files.length - paths.length;
    toast(
      context,
      'Adding ${paths.length == 1 ? '1 file' : '${paths.length} files'} to ${c.name}${missed == 0 ? '' : '. ${missed == 1 ? '1 file' : '$missed files'} couldn\'t be read.'}',
      tone: missed == 0 ? GlacierToastTone.neutral : GlacierToastTone.danger,
    );
    (open ?? _open)(context, c);
  }

  /// Opens [c] where a space opens: in the shell's pane (beside the list in a wide window), else as a page.
  static void _open(BuildContext context, VoiceChannel c) {
    final inside = _insideShell();
    if (inside != null && c.circle != null) return openCircleSpace(inside, c);
    final shell = inside == null ? null : AppShell.maybeOf(inside);
    final page = FilesSpaceScreen(key: ValueKey('files-space-${c.seed}'), channel: c);
    if (shell != null) return shell.show(page, showing: 'files:${c.seed}');
    unawaited(push<void>(context, (_) => page));
  }

  /// A place inside the app's shell (the list and its pane), where the shell is up: the navigator the sheet was asked
  /// on stands over it, so it is looked for.
  static BuildContext? _insideShell() {
    BuildContext? found;
    var past = false;
    void visit(Element e) {
      if (found != null) return;
      if (past && AppShell.maybeOf(e) != null) {
        found = e;
        return;
      }
      final was = past;
      if (e is StatefulElement && e.state is AppShellState) past = true;
      e.visitChildren(visit);
      past = was;
    }

    WidgetsBinding.instance.rootElement?.visitChildren(visit);
    return found;
  }
}

/// Over the whole window while files are dragged onto it with no Files space showing: dropping them asks which Files
/// space they go to.
class IncomingDropHint extends StatelessWidget {
  const IncomingDropHint({super.key});

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return IgnorePointer(
      child: Container(
        margin: EdgeInsets.all(t.space(3)),
        decoration: BoxDecoration(
          color: t.color('glacier-bg').withValues(alpha: 0.88),
          borderRadius: BorderRadius.circular(isBevelChrome(t) ? 0 : t.radius('xl')),
          border: Border.all(color: t.color('app-accent'), width: 2),
        ),
        alignment: Alignment.center,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          AppIcon(Lucide.hardDriveUpload, size: 40, color: t.color('app-accent')),
          SizedBox(height: t.space(2)),
          Text('Drop to add them to a Files space', style: pageText(t, t.fontSize('lg'), weight: 'semibold', color: t.color('app-ink'))),
          SizedBox(height: t.space(1)),
          Text('You\'ll choose which one.', style: pageText(t, t.fontSize('sm'), color: t.color('app-ink-3'))),
        ]),
      ),
    );
  }
}
