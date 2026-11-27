/// A Files space (Matt, 2026-11-17: "add full functionality for filesharing in a space when the space is designated a
/// Files Space ... use iconography and color where possible"): its files, sealed end to end and kept on the relay
/// (lib/files/files_store.dart), with the space's chat a press away.
///
/// At the top, the space's name with how many files it holds and how much, and its chat, invite and settings. Under
/// it: search, sort (newest, oldest, name, size, type), list or grid, and Upload; then where in the space's folders it
/// is, as a path of chips from the top (with a new folder at its end); files going up with their progress and a way to
/// stop each; the folders in the folder shown, then its files, each with its kind's icon and colour, size, who added it
/// and when; and at the foot how much of the space's room is used. A press opens a file (pictures zoom, videos and
/// sound play, words are read; anything else opens in the app that reads it) or goes into a folder; a long press (or a
/// right click, or the … on a computer) has Save, Share, Rename, Move to folder and Delete, for whoever may, and a
/// folder's has Open, New folder, Rename, Move and Delete. On a Mac, files dropped anywhere on it go up, into the
/// folder shown.
///
/// Folders nest (Matt, 2026-11-18: "allow root level folders in the file sharing tab and nested folders"): up to
/// eight deep, empty ones kept, each a path from the top (SpaceFile.cleanFolder). Back goes up a folder before it leaves
/// the space, and a search looks through the folder shown and every folder in it.
library;

import 'dart:async';

import 'package:flutter/gestures.dart' show kSecondaryMouseButton;
import 'package:flutter/services.dart' show TextCapitalization;
import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../../app_state.dart';
import '../../art/app_icon.dart';
import '../../art/lucide.g.dart';
import '../../art/lucide_more.dart';
import '../../backgrounds.dart' show strongFill;
import '../../files/browser_files.dart';
import '../../files/drive.dart';
import '../../files/file_platform.dart';
import '../../files/files_store.dart';
import '../../files/folder_sync.dart';
import '../../plugins/watch_together.dart';
import '../../voice/watch_together.dart';
import '../../kit/semantic_colors.dart';
import '../../kit/settings_kit.dart';
import '../../kit/settings_type.dart';
import '../../voice/channels.dart';
import '../../voice/hangout.dart';
import '../../voice/roles.dart';
import '../../voice/voice.dart';
import '../circles/circle_face.dart' show TitleBarMark;
import '../common.dart';
import '../skeleton.dart';
import '../dialup/bevel.dart';
import '../dialup/parts.dart' show DialupWell;
import '../dialup/retro_button.dart';
import '../hangout_screen.dart' show HangoutChat, RolesScreen;
import '../space_invite.dart';
import 'file_badge.dart';
import 'file_preview.dart';
import 'folder_sync_entry.dart';
import 'send_to_chat.dart';
import '../../l10n/words.dart';

/// The page of the Files space [channel]. It holds the space's room open while it shows, for its chat.
///
/// An account's own drive (My files; lib/files/drive.dart, GMFB-37) is shown by this same page: it has no room, so no
/// chat, invite or roles, and its words say whose it is.
class FilesSpaceScreen extends StatefulWidget {
  const FilesSpaceScreen({super.key, required this.channel, this.store, this.above});
  final VoiceChannel channel;

  /// Shown over the files, under the folders' row: My files' "Sync a folder" on a computer (GMFB-38).
  final Widget? above;

  /// The files store to show, the app's where null (a test gives its own).
  final FilesStore? store;

  @override
  State<FilesSpaceScreen> createState() => _FilesSpaceScreenState();
}

class _FilesSpaceScreenState extends State<FilesSpaceScreen> {
  FilesStore get _store => widget.store ?? FilesStore.instance;
  VoiceChannel get _c => widget.channel;

  /// An account's own drive: no room is held or made for it.
  bool get _mine => Drive.isDrive(_c);

  /// "Sync a folder" for a Files space on a computer, as My files has (GMFB-38: "a Files space or the personal
  /// drive"): for someone who may add files here, or who chose a folder before and may want to stop. The app's own
  /// store only (a test's shows none), and never a chat's files.
  Widget? _spaceSync(bool canUpload) {
    if (_mine || widget.store != null || !FolderSync.here || _c.kind != SpaceKind.files) return null;
    final sync = FolderSync.forSpace(_c)..load();
    return canUpload || sync.root != null ? FolderSyncEntry(sync: sync) : null;
  }

  HangoutRoom? _room;
  bool _chat = false;
  String _query = '';

  /// On a phone the search is a magnifier in the controls' row until pressed (Matt asked for the space to be "simpler
  /// and easier to digest": three stacked rows of controls took about 470 px before the first file).
  bool _searching = false;

  /// The folder shown, as its path; null for the space's top.
  String? _folder;
  StreamSubscription<List<String>>? _drops;

  /// Files dropped on the page, in a browser (lib/files/browser_files.dart).
  StreamSubscription<List<FileSource>>? _pageDrops;

  /// Whether this page is a browser's (FilesStore.browser): files come as [FileSource]s there, never as paths.
  bool get _inBrowser => _store.browser;

  /// True while files are dragged over the window or the page.
  ValueNotifier<bool> get _over => _inBrowser ? BrowserFiles.over : FilePlatform.over;

  @override
  void initState() {
    super.initState();
    unawaited(_store.open(_c));
    if (!_mine) {
      unawaited(Voice.instance.hold(_c).then((r) {
        if (mounted) setState(() => _room = r);
      }));
    }
    if (_inBrowser && FilePlatform.canDrop) {
      BrowserFiles.dropTarget(true);
      _pageDrops = BrowserFiles.dropped.listen(_addSources);
    } else if (FilePlatform.canDrop) {
      FilePlatform.dropTarget(true);
      _drops = FilePlatform.dropped.listen((paths) => _add([for (final p in paths) (path: p, owned: false)]));
    }
  }

  @override
  void dispose() {
    _store.close(_c);
    if (!_mine) unawaited(Voice.instance.release(_c));
    if (_inBrowser && FilePlatform.canDrop) {
      BrowserFiles.dropTarget(false);
    } else if (FilePlatform.canDrop) {
      FilePlatform.dropTarget(false);
    }
    _drops?.cancel();
    _pageDrops?.cancel();
    super.dispose();
  }

  // List or grid, and the order: kept among the app's choices, the same for every Files space.
  String _view(AppState? app) => app?.choice('files_view', 'list') ?? 'list';
  FilesSort _sort(AppState? app) => FilesSort.of(app?.choice('files_sort', 'newest'));

  /// Upload: files chosen in the device's picker go up into the folder shown.
  Future<void> _pick() async {
    if (!_store.canUpload(_c)) {
      toast(context, 'Your role here can\'t add files.', tone: GlacierToastTone.danger);
      return;
    }
    if (!FilePlatform.canPick) {
      toast(context, 'Files can\'t be chosen on this device yet.');
      return;
    }
    try {
      if (_inBrowser) {
        _addSources(await BrowserFiles.pick());
      } else {
        _add(await FilePlatform.pick());
      }
    } catch (e) {
      if (mounted) toast(context, 'Couldn\'t add that: $e', tone: GlacierToastTone.danger);
    }
  }

  /// Sends files picked or dropped up into the folder shown, where this person's role may add. The app's own copies
  /// ([PickedFile.owned]) and the person's own files go up apart, so the store knows which it was handed.
  void _add(List<PickedFile> picked) {
    if (picked.isEmpty || !mounted) return;
    if (!_store.canUpload(_c)) {
      toast(context, 'Your role here can\'t add files.', tone: GlacierToastTone.danger);
      return;
    }
    for (final owned in [true, false]) {
      final paths = [for (final p in picked) if (p.owned == owned) p.path];
      if (paths.isNotEmpty) _store.upload(_c, paths, folder: _folder, owned: owned);
    }
  }

  /// A browser's files picked or dropped, up into the folder shown, where this person's role may add.
  void _addSources(List<FileSource> picked) {
    if (picked.isEmpty || !mounted) return;
    if (!_store.canUpload(_c)) {
      toast(context, 'Your role here can\'t add files.', tone: GlacierToastTone.danger);
      return;
    }
    _store.uploadSources(_c, picked, folder: _folder);
  }

  void _openFile(SpaceFile f) => openSpaceFile(context, _c, f, store: widget.store);

  void _menu(SpaceFile f) => showFileMenu(context, _c, f, store: _store, onOpen: () => _openFile(f), here: _folder);

  /// Shows [folder] (null for the top), and puts any search away.
  void _go(String? folder) => setState(() {
        _folder = folder;
        _query = '';
        _searching = false;
      });

  /// A new folder in [parent] (the one shown where none is given), opened once it is made.
  void _newFolder([String? parent]) {
    final into = parent ?? _folder;
    if (SpaceFile.folderNames(into).length >= SpaceFile.maxDepth) {
      toast(context, 'Folders go at most ${SpaceFile.maxDepth} deep.');
      return;
    }
    askFileWords(context, title: 'New folder', hint: into == null ? 'At the top of the space.' : 'In ${SpaceFile.folderName(into)}.', then: (name) async {
      final ok = await _store.newFolder(_c, name, parent: into);
      if (!mounted) return;
      if (ok) {
        _go(SpaceFile.joinFolder(into, name));
      } else {
        toast(context, 'Couldn\'t make that folder.', tone: GlacierToastTone.danger);
      }
    });
  }

  /// What [path] holds, in words: "3 files · 1 folder", or "Empty".
  String _holds(FilesSpace space, String path) {
    final n = space.filesUnder(path).length, m = space.foldersUnder(path).length;
    if (n == 0 && m == 0) return 'Empty';
    return [if (n > 0) '$n ${n == 1 ? 'file' : 'files'}', if (m > 0) '$m ${m == 1 ? 'folder' : 'folders'}'].join(' · ');
  }

  /// A folder's menu: open it, a folder in it, and rename, move and delete it, for whoever may.
  void _folderMenu(String path) {
    final space = _store.of(_c);
    final may = _store.canFolder(_c);
    final name = SpaceFile.folderName(path);
    showChoices(context, title: '$name\n${_holds(space, path)}', choices: [
      if (_folder != path) Choice('Open', Lucide.folderOpen, () => _go(path)),
      if (may && SpaceFile.folderNames(path).length < SpaceFile.maxDepth) Choice('New folder in it', Lucide.folderPlus, () => _newFolder(path)),
      if (may)
        Choice('Rename', Lucide.pencil, () => askFileWords(context, title: 'Rename folder', initial: name, then: (n) async {
              final to = SpaceFile.joinFolder(SpaceFile.folderParent(path), n);
              if (to == null || to == path) return;
              final why = _store.whyNotMoveFolder(_c, path, to);
              if (why != null) return _say(why);
              if (await _store.renameFolder(_c, path, n) && mounted) _follow(path, to);
            })),
      if (may) Choice('Move to folder', Lucide.folderInput, () => _moveFolder(path)),
      if (may) Choice('Delete', Lucide.trash2, () => _deleteFolder(path), danger: true),
    ]);
  }

  /// Asks before letting an unfinished upload go, saying what it holds.
  void _removePart(FilesPart p) {
    final by = _store.unfinishedBy(_c, p);
    showChoices(context, title: 'Unfinished upload · ${fileSize(p.have)} of ${fileSize(p.size)}${by == null ? '' : ', started by $by'}\nIt can\'t go on from here. Removing it frees its ${fileSize(p.size)}; add the file again to send it.', choices: [
      Choice('Remove it', Lucide.trash2, () async {
        if (!await _store.removeUnfinished(_c, p)) _say('It couldn\'t be removed just now. Try again in a moment.');
      }, danger: true),
    ]);
  }

  void _say(String words) {
    if (mounted) toast(context, words, tone: GlacierToastTone.danger);
  }

  /// After [from] moved to [to]: the folder shown follows it, where it was in it.
  void _follow(String from, String? to) {
    final f = _folder;
    if (f == null || !SpaceFile.inFolder(f, from)) return;
    final rest = f == from ? '' : f.substring(from.length + 1);
    _go(rest.isEmpty ? to : (to == null ? rest : '$to/$rest'));
  }

  /// Where [path] may go: the top, and every folder not in it (nor the one it is in already).
  void _moveFolder(String path) {
    final space = _store.of(_c);
    final parent = SpaceFile.folderParent(path);
    final name = SpaceFile.folderName(path);
    final places = [for (final d in space.folders) if (d != parent && !SpaceFile.inFolder(d, path)) d]..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    Future<void> to(String? into) async {
      final dest = SpaceFile.joinFolder(into, name);
      final why = dest == null ? 'Couldn\'t move it there.' : _store.whyNotMoveFolder(_c, path, dest);
      if (why != null) return _say(why);
      if (await _store.moveFolder(_c, path, dest) && mounted) _follow(path, dest);
    }

    showChoices(context, title: 'Move $name to', choices: [
      if (parent != null) Choice('The top of the space', Lucide.layoutGrid, () => to(null)),
      for (final d in places) Choice(SpaceFile.folderName(d), Lucide.folder, () => to(d), hint: folderWhere(d)),
    ]);
  }

  /// Deleting a folder: one with nothing in it goes at once; one with files or folders in it asks whether what it holds
  /// moves up a level or goes for everyone.
  void _deleteFolder(String path) {
    final space = _store.of(_c);
    final name = SpaceFile.folderName(path);
    final parent = SpaceFile.folderParent(path);
    final inside = space.filesUnder(path).toList();
    Future<void> remove({bool deleteFiles = false}) async {
      final ok = await _store.removeFolder(_c, path, deleteFiles: deleteFiles);
      if (!mounted) return;
      if (!ok) return _say('Couldn\'t delete $name.');
      if (_folder != null && SpaceFile.inFolder(_folder, path)) _go(parent);
    }

    if (inside.isEmpty && space.foldersUnder(path).isEmpty) {
      showChoices(context, title: 'Delete the folder $name? It holds nothing.', choices: [Choice('Delete folder', Lucide.trash2, () => remove(), danger: true)]);
      return;
    }
    final mayAll = inside.every((f) => _store.canChange(_c, f));
    final up = parent == null ? 'the top of the space' : SpaceFile.folderName(parent);
    showChoices(
      context,
      title: '$name holds ${_holds(space, path)}.${mayAll ? '' : ' Some of the files are someone else\'s, and only they or someone who manages files can move or delete them.'}',
      choices: [
        if (mayAll) Choice('Delete the folder, keep what\'s in it', Lucide.folderInput, () => remove(), hint: 'It all moves up to $up'),
        if (mayAll)
          Choice('Delete it and everything in it', Lucide.trash2, () {
            showChoices(context, title: 'Delete $name and ${inside.length} ${inside.length == 1 ? 'file' : 'files'} in it? ${_mine ? 'They go from every device of your account.' : 'They go for everyone in the space.'}', choices: [
              Choice('Delete everything', Lucide.trash2, () => remove(deleteFiles: true), danger: true),
            ]);
          }, danger: true),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final app = AppState.maybeOf(context);
    return ListenableBuilder(
      listenable: Listenable.merge([_store, Voice.instance, ?_room, if (FilePlatform.canDrop) _over]),
      builder: (context, _) {
        final room = _mine ? null : (_room ?? Voice.instance.hangoutFor(_c));
        final space = _store.of(_c);
        final count = space.files.length;
        final line = count == 0 ? 'No files yet' : '$count ${count == 1 ? 'file' : 'files'} · ${fileSize(space.bytes)}';
        final actions = _mine ? const <Widget>[] : [
          IconTap(key: const ValueKey('files-chat'), icon: _chat ? Lucide.folder : LucideMore.messageCircle, label: _chat ? 'Show the files' : 'Chat', onPressed: () => setState(() => _chat = !_chat)),
          if (room == null || room.can(Perm.invite)) IconTap(icon: Lucide.userPlus, label: 'Invite people', onPressed: () => showSpaceInvite(context, _c)),
          if (room != null) IconTap(icon: Lucide.shieldCheck, label: 'Space settings', onPressed: () => push(context, (_) => RolesScreen(room: room, settings: true))),
        ];
        if (room?.putOut != null) {
          return GhostPage(title: _c.name, body: Padding(padding: EdgeInsets.all(t.space(4)), child: SettingsCallout(child: Text(room!.putOut!))));
        }
        // Back goes up a folder first, as a file browser's does; from the top it leaves the space.
        final up = !_chat && _folder != null;
        return PopScope(
          canPop: !up,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop && _folder != null) _go(SpaceFile.folderParent(_folder!));
          },
          child: GhostPage(
            title: _c.name,
            subtitle: _chat ? 'Chat' : line,
            titleLeading: const TitleBarMark(icon: Lucide.folder, child: _SpaceMark(size: 18)),
            titleWidget: Row(children: [
              _SpaceMark(size: 32),
              SizedBox(width: t.space(2) + 2),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                  Text(_c.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('lg'), weight: 'bold')),
                  Text(_chat ? 'Chat' : line, key: const ValueKey('files-line'), maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('xs'), color: t.color('app-ink-3'))),
                ]),
              ),
            ]),
            actions: actions,
            body: _chat
                ? (room == null ? const SizedBox.shrink() : HangoutChat(room: room))
                : Stack(children: [
                    _body(context, t, app, space),
                    if (_over.value) const Positioned.fill(child: _DropHint()),
                  ]),
          ),
        );
      },
    );
  }

  Widget _body(BuildContext context, Tokens t, AppState? app, FilesSpace space) {
    final bevel = isBevelChrome(t);
    final d = bevel ? DialupColors.of(t) : null;
    final narrow = MediaQuery.sizeOf(context).width < 520;
    final view = _view(app);
    final sort = _sort(app);
    final q = _query.trim().toLowerCase();
    final all = space.files.values;
    // The folder shown, where it is still there (someone else may have moved or deleted it): else the nearest one it
    // was in that is.
    var here = _folder;
    while (here != null && !space.folders.contains(here)) {
      here = SpaceFile.folderParent(here);
    }
    _folder = here;
    // The folders in the one shown, then its files; a search looks through it and every folder in it, and lists the
    // folders whose names match with the files.
    final searching = q.isNotEmpty;
    final List<String> subs;
    final List<SpaceFile> shown;
    if (searching) {
      subs = [for (final d in space.folders) if (d != here && (here == null || SpaceFile.inFolder(d, here)) && SpaceFile.folderName(d).toLowerCase().contains(q)) d]..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
      shown = sort.apply(all.where((f) => (here == null || SpaceFile.inFolder(f.folder, here)) && (f.name.toLowerCase().contains(q) || f.byName.toLowerCase().contains(q))));
    } else {
      subs = space.subfolders(here);
      shown = sort.apply(space.filesIn(here));
    }
    final going = [for (final x in _store.transfers) if (x.space.seed == _c.seed && x.up && !x.chat) x];
    // Uploads the relay holds part of that nothing here is sending (FilesStore.unfinished): shown at the top of the space
    // wherever its list is, each holding its room until removed.
    final parts = _store.unfinished(_c);
    final canFolder = _store.canFolder(_c);
    final canUpload = _store.canUpload(_c);

    final search = GlacierSearchField(key: const ValueKey('files-search'), placeholder: 'Search files'.t, size: GlacierFieldSize.md, autoFocus: narrow && _searching && _query.isEmpty, onValueChange: (v) => setState(() => _query = v));
    final field = bevel ? DialupWell(child: search) : search;
    // A phone: one row (a magnifier, the sort, list or grid, Upload), the search field over it only once the magnifier
    // is pressed. A wider window has room for all of it in one row.
    final searchOpen = _searching || _query.isNotEmpty;
    final toolbar = Padding(
      padding: EdgeInsetsDirectional.fromSTEB(t.space(3), t.space(1), t.space(3), t.space(2)),
      child: narrow
          ? Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (searchOpen) ...[
                Row(children: [
                  Expanded(child: field),
                  SizedBox(width: t.space(1)),
                  IconTap(
                    key: const ValueKey('files-search-close'),
                    icon: Lucide.x,
                    label: 'Close the search',
                    size: 18,
                    onPressed: () => setState(() {
                      _searching = false;
                      _query = '';
                    }),
                  ),
                ]),
                SizedBox(height: t.space(2)),
              ],
              // The sort gives way first where the row is tight (a long word, a large font); Upload keeps to the end.
              Row(children: [
                if (!searchOpen) ...[IconTap(key: const ValueKey('files-search-open'), icon: Lucide.search, label: 'Search files', size: 18, onPressed: () => setState(() => _searching = true)), SizedBox(width: t.space(1))],
                // The sort as its icon alone here (its order is said in its menu and its label), so the row fits a
                // narrow phone at a large font.
                _sortButton(t, app, sort, compact: true),
                SizedBox(width: t.space(1)),
                _viewToggle(t, app, view),
                const Spacer(),
                SizedBox(width: t.space(2)),
                _UploadButton(onPressed: canUpload ? _pick : null),
              ]),
            ])
          : Row(children: [
              Expanded(child: field),
              SizedBox(width: t.space(2)),
              _sortButton(t, app, sort),
              SizedBox(width: t.space(2)),
              _viewToggle(t, app, view),
              SizedBox(width: t.space(2)),
              _UploadButton(onPressed: canUpload ? _pick : null),
            ]),
    );

    // An empty space shows only what can be done in it: its Upload (in the body) and a new folder, not search, sort, list
    // or grid and an "All files 0" over nothing.
    final empty = all.isEmpty && going.isEmpty && parts.isEmpty && space.folders.isEmpty && (space.ready || !space.loading);
    // Where the folder shown is, from the top: a chip for the top and one for each folder down to it (pressed, it is
    // shown; long pressed, its menu), then a new folder in it.
    final line = here == null ? const <String>[] : SpaceFile.folderLine(here);
    final mayDeeper = SpaceFile.folderNames(here).length < SpaceFile.maxDepth;
    final chips = (empty && !canFolder)
        ? null
        : SizedBox(
            height: t.lenOf('2.5rem'),
            // Faded at its right edge, so a row of folders running off the screen reads as one that scrolls.
            child: ShaderMask(
              blendMode: BlendMode.dstIn,
              shaderCallback: (r) => LinearGradient(colors: const [Color(0xFFFFFFFF), Color(0xFFFFFFFF), Color(0x00FFFFFF)], stops: [0, r.width <= 48 ? 0 : 1 - 48 / r.width, 1]).createShader(r),
              child: ListView(
              scrollDirection: Axis.horizontal,
              padding: EdgeInsetsDirectional.fromSTEB(t.space(3), 0, t.space(8), 0),
              children: [
                if (!empty) _FolderChip(key: const ValueKey('folder-all'), label: 'Files', count: all.length, chosen: here == null, icon: Lucide.layoutGrid, onPressed: () => _go(null)),
                for (final p in line) ...[
                  Padding(padding: EdgeInsetsDirectional.only(end: t.space(2)), child: Center(child: AppIcon(Lucide.chevronRight, size: 14, color: t.color('app-ink-3'), wash: false))),
                  _FolderChip(
                    key: ValueKey('crumb-$p'),
                    label: SpaceFile.folderName(p),
                    chosen: p == here,
                    icon: p == here ? Lucide.folderOpen : Lucide.folder,
                    onPressed: () => _go(p),
                    onLongPress: () => _folderMenu(p),
                  ),
                ],
                if (canFolder && mayDeeper) _FolderChip(key: const ValueKey('folder-new'), label: 'Folder', icon: Lucide.folderPlus, chosen: false, onPressed: _newFolder, quiet: true),
              ],
              ),
            ),
          );

    final err = space.error;
    final bottom = MediaQuery.paddingOf(context).bottom + t.space(2);
    Widget content;
    if (!space.ready && space.loading) {
      content = const SkeletonFiles(label: 'Loading files…');
    } else if (empty) {
      content = _Empty(canUpload: canUpload, onUpload: _pick, drop: FilePlatform.canDrop, mine: _mine);
    } else if (shown.isEmpty && subs.isEmpty && going.isEmpty && parts.isEmpty) {
      content = Center(
        child: Padding(
          padding: EdgeInsets.all(t.space(6)),
          child: Text(
            q.isNotEmpty ? 'Nothing here matches "$_query".' : (here == null ? 'No files at the top of the space. Add files while it is shown and they go here.' : 'This folder is empty. Add files or folders while it is open and they go in it.'),
            textAlign: TextAlign.center,
            style: pageText(t, t.fontSize('sm'), color: t.color('app-ink-3')),
          ),
        ),
      );
    } else {
      final head = [
        for (final x in going) _TransferRow(key: ValueKey('transfer-${x.id}'), transfer: x, onCancel: () => _store.cancel(x), onRetry: () => _store.retry(x)),
        for (final p in parts) _PartRow(key: ValueKey('part-${p.id}'), part: p, by: _store.unfinishedBy(_c, p), onRemove: _store.canRemoveUnfinished(_c, p) ? () => _removePart(p) : null),
      ];
      content = view == 'grid' ? _grid(t, space, subs, shown, head, bottom, searching) : _list(t, space, subs, shown, head, bottom, searching);
    }
    if (d != null) content = ColoredBox(color: d.paper, child: content);

    final quota = space.info;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (!empty) d == null ? toolbar : ColoredBox(color: d.chrome, child: toolbar),
      if (chips != null) d == null ? chips : ColoredBox(color: d.chrome, child: Padding(padding: EdgeInsets.only(bottom: t.space(1)), child: chips)),
      ?(widget.above ?? _spaceSync(canUpload)),
      if (err != null)
        Padding(
          padding: EdgeInsetsDirectional.fromSTEB(t.space(3), t.space(1), t.space(3), t.space(2)),
          child: SettingsCallout(
            icon: AppIcon(err.offline ? Lucide.wifiOff : Lucide.circleAlert, size: 18),
            action: IconTap(icon: Lucide.refreshCw, label: 'Try again', size: 18, onPressed: () => unawaited(space.refresh())),
            child: Text(err.offline ? '${space.ready ? 'Showing what this device has. ' : ''}${err.message}' : err.message),
          ),
        ),
      Expanded(child: content),
      if (quota != null && quota.quota > 0) _QuotaLine(used: quota.used, quota: quota.quota, bottom: MediaQuery.paddingOf(context).bottom),
    ]);
  }

  /// The list; at 700 and wider (a Fold open, a computer) each row lays its size, who, when and folder out as columns
  /// under a header, where one name and a menu stretched across the window looked unfinished.
  ///
  /// The folders in the one shown come first, each a row of its own ([FolderRow]); a search's files say which folder
  /// each is in, since they come from more than one.
  Widget _list(Tokens t, FilesSpace space, List<String> subs, List<SpaceFile> files, List<Widget> head, double bottom, bool searching) => LayoutBuilder(builder: (context, box) {
        final columns = box.maxWidth >= 700;
        return ListView(
          key: const ValueKey('files-list'),
          padding: EdgeInsets.only(top: t.space(1), bottom: bottom),
          children: [
            ...head,
            if (columns && (files.isNotEmpty || subs.isNotEmpty)) FileColumnsHeader(showFolder: searching),
            for (final d in subs)
              FolderRow(
                key: ValueKey('folder-$d'),
                name: SpaceFile.folderName(d),
                holds: _holds(space, d),
                where: searching ? folderWhere(d) : null,
                onPressed: () => _go(d),
                onMenu: () => _folderMenu(d),
              ),
            for (final f in files)
              FileRow(
                key: ValueKey('file-${f.id}'),
                file: f,
                store: _store,
                showFolder: searching,
                columns: columns,
                onPressed: () => _openFile(f),
                onMenu: () => _menu(f),
              ),
          ],
        );
      });

  /// The grid view: [head] scrolling with it, then a tile for each folder and after them each file.
  Widget _grid(Tokens t, FilesSpace space, List<String> subs, List<SpaceFile> files, List<Widget> head, double bottom, bool searching) => CustomScrollView(
        key: const ValueKey('files-grid'),
        slivers: [
          SliverToBoxAdapter(child: Column(children: head)),
          SliverPadding(
            padding: EdgeInsetsDirectional.fromSTEB(t.space(3), t.space(2), t.space(3), bottom),
            sliver: SliverGrid(
              gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 172, mainAxisSpacing: t.space(3), crossAxisSpacing: t.space(3), childAspectRatio: 0.78),
              delegate: SliverChildBuilderDelegate(
                (context, i) {
                  if (i < subs.length) {
                    final d = subs[i];
                    return FolderTile(key: ValueKey('folder-tile-$d'), name: SpaceFile.folderName(d), holds: _holds(space, d), onPressed: () => _go(d), onMenu: () => _folderMenu(d));
                  }
                  final f = files[i - subs.length];
                  return FileTile(key: ValueKey('tile-${f.id}'), file: f, store: _store, onPressed: () => _openFile(f), onMenu: () => _menu(f));
                },
                childCount: subs.length + files.length,
              ),
            ),
          ),
        ],
      );

  /// The sort control, which opens the orders to choose from: a button with the order's name, or [compact], an icon.
  Widget _sortButton(Tokens t, AppState? app, FilesSort sort, {bool compact = false}) {
    void pick() => showChoices(context, title: 'Sort files by', choices: [
          for (final s in FilesSort.values)
            Choice(s.label, s == sort ? Lucide.check : _sortIcon(s), () {
              app?.set('files_sort', s.name);
              setState(() {});
            }),
        ]);
    if (compact) return IconTap(key: const ValueKey('files-sort'), icon: Lucide.listFilter, label: 'Sort by ${sort.label.toLowerCase()}', size: 18, onPressed: pick);
    return _ToolButton(key: const ValueKey('files-sort'), icon: Lucide.listFilter, label: sort.label, semanticLabel: 'Sort by ${sort.label.toLowerCase()}', onPressed: pick);
  }

  static LucideIcon _sortIcon(FilesSort s) => switch (s) {
        FilesSort.newest => Lucide.arrowDown,
        FilesSort.oldest => Lucide.arrowUp,
        FilesSort.name => Lucide.baseline,
        FilesSort.size => Lucide.hardDrive,
        FilesSort.type => Lucide.shapes,
      };

  Widget _viewToggle(Tokens t, AppState? app, String view) => GlacierSegmentedControl(
        size: GlacierSegmentedSize.md,
        ariaLabel: 'List or grid',
        value: view,
        onValueChange: (v) {
          app?.set('files_view', v);
          setState(() {});
        },
        options: [
          GlacierSegmentedOption(value: 'list', label: Semantics(label: 'List', child: AppIcon(Lucide.layoutList, size: 16, wash: false))),
          GlacierSegmentedOption(value: 'grid', label: Semantics(label: 'Grid', child: AppIcon(Lucide.layoutGrid, size: 16, wash: false))),
        ],
      );
}

/// The Files space's own mark: a folder on amber, the colour a Files space wears everywhere (circle_face.dart).
class _SpaceMark extends StatelessWidget {
  const _SpaceMark({required this.size});
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
            decoration: BoxDecoration(color: bevel ? null : settingsHueWash(t), borderRadius: BorderRadius.circular(bevel ? 0 : size * 0.32)),
            child: AppIcon(Lucide.folder, size: size * 0.56, color: settingsHue(t)),
          );
        }),
      );
}

/// Who added a file, in words: "You", their name, or someone.
String fileWho(SpaceFile f) {
  final me = Voice.instance.me;
  if (me != null && f.by == me) return 'You';
  if (f.byName.isNotEmpty) return f.byName;
  final named = Voice.instance.nameOf(f.by);
  return named == 'You' ? 'You' : named;
}

/// A file's row: its face, name, then size, who and when (and its folder, where every file is shown), and whether it is
/// on this device or on its way.
class FileRow extends StatelessWidget {
  const FileRow({super.key, required this.file, required this.store, required this.onPressed, required this.onMenu, this.showFolder = false, this.columns = false});
  final SpaceFile file;
  final FilesStore store;
  final VoidCallback onPressed;
  final VoidCallback onMenu;
  final bool showFolder;

  /// A wide window: size, who, when and folder in columns ([FileColumnsHeader]), not joined in a line under the name.
  final bool columns;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final bevel = isBevelChrome(t);
    final coming = store.downloading(file);
    final here = coming == null && store.cached(file) != null;
    final sub = [fileSize(file.size), fileWho(file), listWhen(file.when), if (showFolder && file.folder != null) folderWhere(file.folder!)].join(' · ');
    return _Secondary(
      onSecondary: onMenu,
      child: GlacierPressable(
        onPressed: onPressed,
        onLongPress: onMenu,
        semanticLabel: '${file.name}, ${file.kind.label}, $sub${here ? ', on this device' : ''}',
        builder: (context, state) => Container(
          margin: bevel ? EdgeInsets.zero : EdgeInsets.symmetric(horizontal: t.space(2), vertical: 1),
          padding: EdgeInsetsDirectional.fromSTEB(t.space(2), t.space(2), t.space(1), t.space(2)),
          decoration: BoxDecoration(
            color: bevel ? null : (state.pressed || state.hovered ? t.color('app-paper-2') : null),
            borderRadius: bevel ? null : BorderRadius.circular(t.radius('md')),
          ),
          child: Row(children: [
            FileFace(file: file, size: 40),
            SizedBox(width: t.space(3)),
            Expanded(
              flex: columns ? 5 : 1,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                Text(file.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('md'), weight: 'medium', color: t.color('app-ink'))),
                if (coming != null)
                  Padding(padding: const EdgeInsetsDirectional.only(top: 6, end: 8), child: GlacierProgressBar(value: coming.progress * 100, size: GlacierProgressBarSize.sm, ariaLabel: 'Coming down'))
                else if (!columns) ...[
                  SizedBox(height: 2),
                  Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('xs'), color: t.color('app-ink-3'))),
                ],
              ]),
            ),
            if (columns) ..._fileColumns(t, [fileSize(file.size), fileWho(file), listWhen(file.when), if (showFolder) file.folder == null ? '' : folderWhere(file.folder!)]),
            if (here)
              Padding(padding: EdgeInsets.symmetric(horizontal: t.space(1)), child: AppIcon(Lucide.circleCheck, size: 16, color: t.color('app-ink-3'), semanticLabel: 'On this device'))
            // In columns the tick's room is kept either way, so every row's columns line up under the header.
            else if (columns)
              SizedBox(width: 16 + t.space(1) * 2),
            IconTap(icon: Lucide.ellipsisVertical, label: 'More for ${file.name}', size: 18, onPressed: onMenu),
          ]),
        ),
      ),
    );
  }
}

/// A folder's path in words, from the top down: "Trip › Day 2".
String folderWhere(String path) => SpaceFile.folderNames(path).join(' › ');

/// A folder's row, over the files in the folder shown: the Files space's folder mark, its name and what it holds (and,
/// in a search, where it is), laid out as a file's row is ([FileRow]) so the two line up.
class FolderRow extends StatelessWidget {
  const FolderRow({super.key, required this.name, required this.holds, required this.onPressed, required this.onMenu, this.where});
  final String name;
  final String holds;
  final String? where;
  final VoidCallback onPressed;
  final VoidCallback onMenu;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final bevel = isBevelChrome(t);
    final sub = [holds, ?where].join(' · ');
    return _Secondary(
      onSecondary: onMenu,
      child: GlacierPressable(
        onPressed: onPressed,
        onLongPress: onMenu,
        semanticLabel: 'Folder $name, $sub',
        builder: (context, state) => Container(
          margin: bevel ? EdgeInsets.zero : EdgeInsets.symmetric(horizontal: t.space(2), vertical: 1),
          padding: EdgeInsetsDirectional.fromSTEB(t.space(2), t.space(2), t.space(1), t.space(2)),
          decoration: BoxDecoration(
            color: bevel ? null : (state.pressed || state.hovered ? t.color('app-paper-2') : null),
            borderRadius: bevel ? null : BorderRadius.circular(t.radius('md')),
          ),
          child: Row(children: [
            const _SpaceMark(size: 40),
            SizedBox(width: t.space(3)),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('md'), weight: 'medium', color: t.color('app-ink'))),
                SizedBox(height: 2),
                Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('xs'), color: t.color('app-ink-3'))),
              ]),
            ),
            IconTap(icon: Lucide.ellipsisVertical, label: 'More for $name', size: 18, onPressed: onMenu),
          ]),
        ),
      ),
    );
  }
}

/// A folder's tile in the grid, before the files: its mark large on the Files space's amber, its name and what it holds.
class FolderTile extends StatelessWidget {
  const FolderTile({super.key, required this.name, required this.holds, required this.onPressed, required this.onMenu});
  final String name;
  final String holds;
  final VoidCallback onPressed;
  final VoidCallback onMenu;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final bevel = isBevelChrome(t);
    final d = bevel ? DialupColors.of(t) : null;
    return _Secondary(
      onSecondary: onMenu,
      child: GlacierPressable(
        onPressed: onPressed,
        onLongPress: onMenu,
        semanticLabel: 'Folder $name, $holds',
        builder: (context, state) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Expanded(
            child: Container(
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(bevel ? 0 : t.radius('lg')),
                border: Border.all(color: d?.shadow ?? t.color(state.hovered ? 'app-ink-4' : 'app-rule'), width: bevel ? 1 : t.len('glacier-hairline')),
              ),
              child: Stack(fit: StackFit.expand, children: [
                GlacierScope(
                  attrs: const {'hue': 'amber'},
                  child: Builder(builder: (context) {
                    final t = context.tokens;
                    return ColoredBox(color: bevel ? const Color(0x00000000) : settingsHueWash(t), child: Center(child: AppIcon(Lucide.folder, size: 44, color: settingsHue(t))));
                  }),
                ),
                if (state.hovered) PositionedDirectional(top: 4, end: 4, child: _Corner(child: IconTap(icon: Lucide.ellipsisVertical, label: 'More for $name', size: 16, box: 28, onPressed: onMenu))),
              ]),
            ),
          ),
          SizedBox(height: t.space(1) + 2),
          Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('sm'), weight: 'medium', color: t.color('app-ink'))),
          Text(holds, maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('xs'), color: t.color('app-ink-3'))),
        ]),
      ),
    );
  }
}

/// The widths of a wide list's columns after the name: size, who, when, folder.
const _columnFlex = [2, 3, 2, 2];

/// A wide list's cells after the name, one for each of [words], at the columns' widths: a row's, or the header's.
List<Widget> _fileColumns(Tokens t, List<String> words, {bool header = false}) => [
      for (final (i, w) in words.indexed)
        Expanded(
          flex: _columnFlex[i],
          child: Padding(
            padding: EdgeInsetsDirectional.only(start: t.space(3)),
            child: Text(w, maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('xs'), weight: header ? 'semibold' : 'regular', color: t.color('app-ink-3'), tracking: header ? 0.4 : 0)),
          ),
        ),
    ];

/// A wide list's header over its columns: Name, Size, Added by, When, Folder.
class FileColumnsHeader extends StatelessWidget {
  const FileColumnsHeader({super.key, this.showFolder = true});
  final bool showFolder;

  // Laid out as a file's row is (FileRow: its margin, padding, face, tick and menu), so the words sit over the columns.
  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final bevel = isBevelChrome(t);
    return Container(
      margin: bevel ? EdgeInsets.zero : EdgeInsets.symmetric(horizontal: t.space(2)),
      padding: EdgeInsetsDirectional.fromSTEB(t.space(2), t.space(1), t.space(1), 0),
      child: Row(children: [
        SizedBox(width: 40 + t.space(3)),
        Expanded(flex: 5, child: Text('NAME', style: pageText(t, t.fontSize('xs'), weight: 'semibold', color: t.color('app-ink-3'), tracking: 0.4))),
        ..._fileColumns(t, ['SIZE', 'ADDED BY', 'WHEN', if (showFolder) 'FOLDER'], header: true),
        SizedBox(width: 16 + t.space(1) * 2 + t.lenOf('2.75rem')),
      ]),
    );
  }
}

/// A file's tile in the grid: its picture or its kind's mark, its name and its size.
class FileTile extends StatelessWidget {
  const FileTile({super.key, required this.file, required this.store, required this.onPressed, required this.onMenu});
  final SpaceFile file;
  final FilesStore store;
  final VoidCallback onPressed;
  final VoidCallback onMenu;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final bevel = isBevelChrome(t);
    final d = bevel ? DialupColors.of(t) : null;
    final coming = store.downloading(file);
    return _Secondary(
      onSecondary: onMenu,
      child: GlacierPressable(
        onPressed: onPressed,
        onLongPress: onMenu,
        semanticLabel: '${file.name}, ${file.kind.label}, ${fileSize(file.size)}',
        builder: (context, state) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Expanded(
            child: Container(
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(bevel ? 0 : t.radius('lg')),
                border: Border.all(color: d?.shadow ?? t.color(state.hovered ? 'app-ink-4' : 'app-rule'), width: bevel ? 1 : t.len('glacier-hairline')),
              ),
              child: Stack(fit: StackFit.expand, children: [
                FileTilePicture(file: file),
                if (coming != null)
                  PositionedDirectional(start: t.space(2), end: t.space(2), bottom: t.space(2), child: GlacierProgressBar(value: coming.progress * 100, size: GlacierProgressBarSize.sm, ariaLabel: 'Coming down')),
                // What the list says by its tick, the grid says in a corner: on this device. Under a pointer the corner
                // is the file's menu instead, as the … is in the list (a long press or a right click open it too).
                if (state.hovered)
                  PositionedDirectional(top: 4, end: 4, child: _Corner(child: IconTap(icon: Lucide.ellipsisVertical, label: 'More for ${file.name}', size: 16, box: 28, onPressed: onMenu)))
                else if (coming == null && store.cached(file) != null)
                  PositionedDirectional(top: 6, end: 6, child: _Corner(child: Padding(padding: const EdgeInsets.all(3), child: AppIcon(Lucide.circleCheck, size: 14, color: t.color('app-ink-2'), wash: false, semanticLabel: 'On this device')))),
              ]),
            ),
          ),
          SizedBox(height: t.space(1) + 2),
          Text(file.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('sm'), weight: 'medium', color: t.color('app-ink'))),
          Text('${fileSize(file.size)} · ${fileWho(file)}', maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('xs'), color: t.color('app-ink-3'))),
        ]),
      ),
    );
  }
}

/// A small mark over a tile's corner, on the page's paper (a square under Dial-Up), so it reads over any picture.
class _Corner extends StatelessWidget {
  const _Corner({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final bevel = isBevelChrome(t);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: bevel ? DialupColors.of(t).paper : t.color('app-paper'),
        shape: bevel ? BoxShape.rectangle : BoxShape.circle,
        border: bevel ? Border.all(color: DialupColors.of(t).shadow) : null,
      ),
      child: child,
    );
  }
}

/// A right click opens what a long press does.
class _Secondary extends StatelessWidget {
  const _Secondary({required this.onSecondary, required this.child});
  final VoidCallback onSecondary;
  final Widget child;

  @override
  Widget build(BuildContext context) => Listener(
        onPointerDown: (e) {
          if (e.buttons == kSecondaryMouseButton) onSecondary();
        },
        child: child,
      );
}

/// A file going up: its kind's mark, its name, how far it has got, and a way to stop it (or try again).
class _TransferRow extends StatelessWidget {
  const _TransferRow({super.key, required this.transfer, required this.onCancel, required this.onRetry});
  final Transfer transfer;
  final VoidCallback onCancel;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final x = transfer;
    final failed = x.state == TransferState.failed;
    final done = x.state == TransferState.done;
    final words = switch (x.state) {
      TransferState.queued => 'Waiting its turn',
      TransferState.running => x.status ?? '${fileSize(x.done)} of ${fileSize(x.size)}',
      TransferState.waiting => x.error ?? 'Waiting for the connection',
      TransferState.failed => x.error ?? 'Couldn\'t add it',
      TransferState.done => 'Added',
    };
    // The same margin and padding as a file's row (FileRow), so the face, name and buttons line up with the files under
    // it in every look: none under Dial-Up, whose rows run flat across the well.
    final bevel = isBevelChrome(t);
    final glyph = done ? Lucide.check : (failed ? Lucide.circleAlert : Lucide.arrowUpToLine);
    return Container(
      margin: bevel ? EdgeInsets.zero : EdgeInsets.symmetric(horizontal: t.space(2), vertical: 1),
      padding: EdgeInsetsDirectional.fromSTEB(t.space(2), t.space(2), t.space(1), t.space(2)),
      child: Row(children: [
        Stack(clipBehavior: Clip.none, children: [
          FileBadge(kind: FileKind.of(x.name, x.mime), size: 40),
          // Its state at a glance: the accent's disc with the glyph in the paper (danger's for a failure, green when
          // done); under Dial-Up a small square of the window's face in a line, not a disc cutting the tile's corner.
          bevel
              ? PositionedDirectional(
                  end: -2,
                  bottom: -2,
                  child: Container(
                    padding: const EdgeInsets.all(1),
                    decoration: BoxDecoration(color: DialupColors.of(t).chrome, border: Border.all(color: DialupColors.of(t).shadow)),
                    child: AppIcon(glyph, size: 12, color: failed ? t.danger : DialupColors.of(t).ink, wash: false),
                  ),
                )
              : PositionedDirectional(
                  end: -4,
                  bottom: -4,
                  child: Container(
                    padding: const EdgeInsets.all(3),
                    decoration: BoxDecoration(
                      color: failed ? t.danger : (done ? t.online : t.color('app-accent')),
                      shape: BoxShape.circle,
                      border: Border.all(color: t.color('glacier-bg'), width: 2),
                    ),
                    child: AppIcon(glyph, size: 11, strokeWidth: 2.6, color: failed || done ? const Color(0xFFFFFFFF) : t.color('app-on-accent'), wash: false),
                  ),
                ),
        ]),
        SizedBox(width: t.space(3)),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text(x.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('md'), weight: 'medium', color: t.color('app-ink'))),
            if (x.state == TransferState.running && x.status == null)
              Padding(padding: const EdgeInsetsDirectional.only(top: 6, bottom: 4, end: 8), child: GlacierProgressBar(value: x.progress * 100, size: GlacierProgressBarSize.sm, ariaLabel: 'Going up')),
            Text(words, maxLines: 2, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('xs'), color: failed ? t.danger : t.color('app-ink-3'))),
          ]),
        ),
        // No Try again where trying again can never mend it (a file over the limit, a space without the room).
        if (failed && x.retryable) IconTap(icon: Lucide.rotateCw, label: 'Try again', size: 18, onPressed: onRetry),
        if (!done) IconTap(key: ValueKey('cancel-${x.id}'), icon: Lucide.x, label: 'Stop adding ${x.name}', size: 18, onPressed: onCancel),
      ]),
    );
  }
}

/// An upload the relay holds part of that nothing on this device is sending (FilesStore.unfinished): how far it got,
/// who started it, when it last moved, and Remove where this device may let it go.
class _PartRow extends StatelessWidget {
  const _PartRow({super.key, required this.part, required this.by, required this.onRemove});
  final FilesPart part;
  final String? by;
  final VoidCallback? onRemove;

  /// How long ago [at] was, in words, to the minute, the hour or the day.
  static String _ago(DateTime at) {
    final d = DateTime.now().difference(at);
    if (d.inMinutes < 1) return 'just now';
    if (d.inMinutes < 60) return '${d.inMinutes} min ago';
    if (d.inHours < 24) return d.inHours == 1 ? 'an hour ago' : '${d.inHours} hours ago';
    return d.inDays == 1 ? 'a day ago' : '${d.inDays} days ago';
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final bevel = isBevelChrome(t);
    final p = part;
    final words = '${fileSize(p.have)} of ${fileSize(p.size)} · stopped ${_ago(p.at)}${by == null ? '' : ' · ${by == 'you' ? 'yours' : 'by $by'}'}';
    return Container(
      margin: bevel ? EdgeInsets.zero : EdgeInsets.symmetric(horizontal: t.space(2), vertical: 1),
      padding: EdgeInsetsDirectional.fromSTEB(t.space(2), t.space(2), t.space(1), t.space(2)),
      child: Row(children: [
        const FileBadge(kind: FileKind.other, size: 40),
        SizedBox(width: t.space(3)),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text('Unfinished upload', maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('md'), weight: 'medium', color: t.color('app-ink'))),
            Padding(
              padding: const EdgeInsetsDirectional.only(top: 6, bottom: 4, end: 8),
              child: GlacierProgressBar(value: p.size <= 0 ? 0 : (p.have / p.size * 100).clamp(0, 100).toDouble(), size: GlacierProgressBarSize.sm, ariaLabel: 'How much of it is up'),
            ),
            Text(words, maxLines: 2, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('xs'), color: t.color('app-ink-3'))),
          ]),
        ),
        if (onRemove != null) IconTap(key: ValueKey('remove-part-${p.id}'), icon: Lucide.trash2, label: 'Remove the unfinished upload', size: 18, onPressed: onRemove!),
      ]),
    );
  }
}

/// A folder's chip: chosen, it is the one shown.
class _FolderChip extends StatelessWidget {
  const _FolderChip({super.key, required this.label, required this.icon, required this.chosen, required this.onPressed, this.count, this.onLongPress, this.quiet = false});
  final String label;
  final LucideIcon icon;
  final bool chosen;
  final int? count;
  final VoidCallback onPressed;
  final VoidCallback? onLongPress;
  final bool quiet;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final bevel = isBevelChrome(t);
    final d = bevel ? DialupColors.of(t) : null;
    final words = count == null ? label : '$label  $count';
    if (bevel) {
      return Padding(
        padding: EdgeInsetsDirectional.only(end: t.space(1)),
        child: RetroButton(onPressed: onPressed, onLongPress: onLongPress, icon: icon, label: words, toggled: chosen, faceHeight: 32),
      );
    }
    // The chosen chip in the strong fill Upload and the list-or-grid toggle wear (black in Uplink, teal in Mist, amber
    // in Lamplight), so a screen has one kind of chosen, not the accent beside a near-black.
    final (strong, onStrong) = strongFill(t);
    return Padding(
      padding: EdgeInsetsDirectional.only(end: t.space(2), top: t.space(1), bottom: t.space(1)),
      child: GlacierPressable(
        onPressed: onPressed,
        onLongPress: onLongPress,
        semanticLabel: count == null ? label : '$label, $count files',
        builder: (context, state) => Container(
          padding: EdgeInsets.symmetric(horizontal: t.space(3)),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: chosen ? strong : (state.pressed || state.hovered ? t.color('app-paper-3') : (quiet ? null : t.color('app-paper-2'))),
            borderRadius: BorderRadius.circular(t.radius('full')),
            border: quiet ? Border.all(color: d?.shadow ?? t.color('app-rule'), width: t.len('glacier-hairline')) : null,
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            GlacierScope(
              attrs: const {'hue': 'amber'},
              child: Builder(builder: (context) => AppIcon(icon, size: 15, color: chosen ? onStrong : (quiet ? context.tokens.color('app-ink-3') : settingsHue(context.tokens)), wash: false)),
            ),
            SizedBox(width: t.space(1) + 2),
            Text(label, style: pageText(t, t.fontSize('sm'), weight: 'medium', color: chosen ? onStrong : t.color(quiet ? 'app-ink-3' : 'app-ink'))),
            if (count != null) ...[
              SizedBox(width: t.space(1) + 2),
              Text('$count', style: pageText(t, t.fontSize('xs'), weight: 'semibold', color: chosen ? onStrong : t.color('app-ink-3'))),
            ],
          ]),
        ),
      ),
    );
  }
}

/// A small button with an icon and a word: the sort.
class _ToolButton extends StatelessWidget {
  const _ToolButton({super.key, required this.icon, required this.label, required this.onPressed, this.semanticLabel});
  final LucideIcon icon;
  final String label;
  final String? semanticLabel;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    if (isBevelChrome(t)) return RetroButton(onPressed: onPressed, icon: icon, label: label, semanticLabel: semanticLabel, faceHeight: 36);
    return GlacierPressable(
      onPressed: onPressed,
      semanticLabel: semanticLabel ?? label,
      builder: (context, state) => Container(
        height: t.lenOf('2.25rem'),
        padding: EdgeInsets.symmetric(horizontal: t.space(3)),
        decoration: BoxDecoration(
          color: state.pressed || state.hovered ? t.color('app-paper-3') : t.color('app-paper-2'),
          borderRadius: BorderRadius.circular(t.radius('full')),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          AppIcon(icon, size: 15, color: t.color('app-ink-2'), wash: false),
          SizedBox(width: t.space(1) + 2),
          Flexible(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('sm'), weight: 'medium', color: t.color('app-ink')))),
        ]),
      ),
    );
  }
}

/// Upload: the screen's one strong button.
class _UploadButton extends StatelessWidget {
  const _UploadButton({required this.onPressed});
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    if (isBevelChrome(t)) return RetroButton(key: const ValueKey('files-upload'), onPressed: onPressed, icon: Lucide.hardDriveUpload, label: 'Upload', primary: true, faceHeight: 36);
    final (fill, words) = strongFill(t);
    final off = onPressed == null;
    return GlacierPressable(
      key: const ValueKey('files-upload'),
      onPressed: onPressed,
      semanticLabel: 'Upload files',
      builder: (context, state) => Opacity(
        opacity: off ? 0.4 : 1,
        child: Container(
          height: t.lenOf('2.25rem'),
          padding: EdgeInsets.symmetric(horizontal: t.space(3) + 2),
          decoration: BoxDecoration(color: fill.withValues(alpha: state.pressed ? 0.85 : 1), borderRadius: BorderRadius.circular(t.radius('full'))),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            AppIcon(Lucide.hardDriveUpload, size: 16, color: words, wash: false),
            SizedBox(width: t.space(2)),
            Text('Upload', style: pageText(t, t.fontSize('sm'), weight: 'semibold', color: words)),
          ]),
        ),
      ),
    );
  }
}

/// A space with no files yet: what goes here, and how.
class _Empty extends StatelessWidget {
  const _Empty({required this.canUpload, required this.onUpload, required this.drop, this.mine = false});
  final bool canUpload;
  final VoidCallback onUpload;
  final bool drop;

  /// An account's own drive (GMFB-37): it says whose devices see what is put here.
  final bool mine;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final bevel = isBevelChrome(t);
    return Center(
      child: SingleChildScrollView(
        padding: EdgeInsets.all(t.space(6)),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          GlacierScope(
            attrs: const {'hue': 'amber'},
            child: Builder(builder: (context) {
              final t = context.tokens;
              return Container(
                width: 96,
                height: 96,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: bevel ? null : settingsHueWash(t),
                  shape: bevel ? BoxShape.rectangle : BoxShape.circle,
                  border: bevel ? Border.all(color: DialupColors.of(t).shadow) : null,
                ),
                child: AppIcon(Lucide.folderOpen, size: 44, color: settingsHue(t)),
              );
            }),
          ),
          SizedBox(height: t.space(4)),
          Text('No files yet', style: pageText(t, t.fontSize('lg'), weight: 'semibold', color: t.color('app-ink'))),
          SizedBox(height: t.space(1)),
          Text(
            mine
                ? (drop ? 'Upload files, or drop them anywhere here. They show up on every device signed in to your account, and no one else can open them.' : 'Upload files to keep them on every device signed in to your account. No one else can open them.')
                : canUpload
                ? (drop ? 'Upload files, or drop them anywhere here. Everyone in the space can see and open them, and no one else can.' : 'Upload files for everyone in the space. Everyone in it can see and open them, and no one else can.')
                : 'Files added here show up for everyone in the space.',
            textAlign: TextAlign.center,
            style: pageText(t, t.fontSize('sm'), color: t.color('app-ink-3'), height: 1.4),
          ),
          if (canUpload) ...[SizedBox(height: t.space(4)), _UploadButton(onPressed: onUpload)],
          SizedBox(height: t.space(3)),
          Row(mainAxisSize: MainAxisSize.min, children: [
            AppIcon(Lucide.lock, size: 12, color: t.color('app-ink-3'), wash: false),
            SizedBox(width: t.space(1)),
            Text('Sealed end to end', style: pageText(t, t.fontSize('xs'), color: t.color('app-ink-3'))),
          ]),
        ]),
      ),
    );
  }
}

/// Over the space while files are dragged onto the window: where they go.
class _DropHint extends StatelessWidget {
  const _DropHint();

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
          Text('Drop to add them here', style: pageText(t, t.fontSize('lg'), weight: 'semibold', color: t.color('app-ink'))),
        ]),
      ),
    );
  }
}

/// How much of the space's room its files take.
class _QuotaLine extends StatelessWidget {
  const _QuotaLine({required this.used, required this.quota, required this.bottom});
  final int used, quota;
  final double bottom;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final bevel = isBevelChrome(t);
    final share = (used / quota).clamp(0.0, 1.0);
    final line = Padding(
      padding: EdgeInsetsDirectional.fromSTEB(t.space(4), t.space(2), t.space(4), bottom + t.space(2)),
      child: Row(children: [
        AppIcon(Lucide.hardDrive, size: 14, color: t.color('app-ink-3'), wash: false),
        SizedBox(width: t.space(2)),
        Text('${fileSize(used)} of ${fileSize(quota)}', key: const ValueKey('files-quota'), style: pageText(t, t.fontSize('xs'), color: t.color('app-ink-3'))),
        SizedBox(width: t.space(3)),
        // Dial-Up: the bar in a sunken white well, so its whole track shows on the grey (at 0 B there was no bar at all).
        Expanded(child: () {
          final bar = GlacierProgressBar(value: share * 100, size: GlacierProgressBarSize.sm, tone: share > 0.9 ? GlacierProgressBarTone.danger : GlacierProgressBarTone.accent, ariaLabel: 'Room used');
          return bevel ? DialupWell(child: Padding(padding: const EdgeInsets.all(2), child: bar)) : bar;
        }()),
      ]),
    );
    return bevel ? ColoredBox(color: DialupColors.of(t).chrome, child: line) : DecoratedBox(decoration: BoxDecoration(border: Border(top: BorderSide(color: t.color('app-rule'), width: t.len('glacier-hairline')))), child: line);
  }
}

// --- a file's menu ----------------------------------------------------------------------------------------------------

/// [f]'s menu: open, save, share; and rename, move and delete where this device may. [here] is the folder the screen
/// shows (where Move's new folder is made).
void showFileMenu(BuildContext context, VoiceChannel c, SpaceFile f, {required FilesStore store, VoidCallback? onOpen, String? here}) {
  final may = store.canChange(c, f);
  final mine = Drive.isDrive(c);
  showChoices(context, title: '${f.name}\n${fileSize(f.size)} · ${fileWho(f)} · ${listWhen(f.when)}', choices: [
    if (onOpen != null) Choice('Open', Lucide.eye, onOpen),
    // From an account's own drive into a chat (GMFB-37): the file is sent there as any file picked on this device is.
    // Not in a browser, where a file that came down is held in the tab and is no path to send from.
    if (mine && !store.browser) Choice('Send to a chat', Lucide.send, () => sendFileToChat(context, c, f, store: store)),
    // In a call with Watch together on: the file played on everyone's device, in step (lib/plugins/watch_together.dart).
    if ((f.kind == FileKind.video || f.kind == FileKind.audio) && WatchTogetherPlugin.onInCall())
      Choice('Watch together in the call', Lucide.film, () {
        WatchTogether.instance.start(f, c);
        watchNow(context);
      }),
    if (FilePlatform.canSave) Choice(_saveWord, LucideMore.download, () => fileAction(context, c, f, store, (path) => FilePlatform.save(path, f.name, f.mime), doneWords: true)),
    if (FilePlatform.canShare) Choice('Share', Lucide.share2, () => fileAction(context, c, f, store, (path) => FilePlatform.share(path, f.name, f.mime))),
    if (may) Choice('Rename', Lucide.pencil, () => askFileWords(context, title: 'Rename', initial: f.name, then: (n) => store.rename(c, f, n))),
    if (may) Choice('Move to folder', Lucide.folderInput, () => _moveTo(context, c, f, store, here: here)),
    if (may)
      Choice('Delete', Lucide.trash2, () {
        showChoices(context, title: mine ? 'Delete ${f.name}? It goes from every device of your account.' : 'Delete ${f.name}? It goes for everyone in the space.', choices: [
          Choice('Delete', Lucide.trash2, () async {
            final ok = await store.delete(c, f);
            if (!ok && context.mounted) toast(context, 'Couldn\'t delete it.', tone: GlacierToastTone.danger);
          }, danger: true),
        ]);
      }, danger: true),
  ]);
}

String get _saveWord => FilePlatform.canShare ? 'Save' : 'Download';

/// Where [f] may go: the top, or any folder at any depth (each by its name, with where it is under it), or a new one in
/// the folder shown.
void _moveTo(BuildContext context, VoiceChannel c, SpaceFile f, FilesStore store, {String? here}) {
  final folders = store.of(c).folders.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  final into = here != null && SpaceFile.folderNames(here).length < SpaceFile.maxDepth ? here : null;
  showChoices(context, title: 'Move ${f.name} to', choices: [
    if (f.folder != null) Choice('The top of the space', Lucide.layoutGrid, () => store.move(c, f, null)),
    for (final d in folders)
      if (d != f.folder) Choice(SpaceFile.folderName(d), Lucide.folder, () => store.move(c, f, d), hint: SpaceFile.folderParent(d) == null ? null : folderWhere(SpaceFile.folderParent(d)!)),
    Choice('New folder', Lucide.folderPlus, () => askFileWords(context, title: 'New folder', hint: into == null ? 'At the top of the space.' : 'In ${SpaceFile.folderName(into)}.', then: (name) async {
          final d = SpaceFile.joinFolder(into, name);
          if (d == null) return;
          await store.newFolder(c, name, parent: into);
          await store.move(c, store.of(c).files[f.id] ?? f, d);
        })),
  ]);
}

/// Brings [f] down where it isn't here yet, then does [then] with its path, saying what went wrong where it did.
Future<void> fileAction(BuildContext context, VoiceChannel c, SpaceFile f, FilesStore store, Future<Object?> Function(String path) then, {bool doneWords = false}) async {
  final toastOf = GlacierToast.of(context);
  if (store.cached(f) == null) toastOf.toast(message: Text('Getting ${f.name}…'));
  try {
    final path = await store.fetch(c, f);
    final said = await then(path);
    if (doneWords && said is String) toastOf.toast(message: Text(said), tone: GlacierToastTone.success);
  } on FilesError catch (e) {
    if (e.status != -1) toastOf.toast(message: Text(e.message), tone: GlacierToastTone.danger);
  } catch (e) {
    toastOf.toast(message: Text('Couldn\'t: $e'), tone: GlacierToastTone.danger);
  }
}

/// Asks for a line of words (a name, a folder), then gives it to [then].
void askFileWords(BuildContext context, {required String title, String initial = '', String? hint, required void Function(String words) then}) {
  push<void>(context, (_) => _WordsPage(title: title, initial: initial, hint: hint, then: then));
}

/// The page [askFileWords] opens: one field and Done. An empty answer is not taken.
class _WordsPage extends StatefulWidget {
  const _WordsPage({required this.title, required this.initial, required this.then, this.hint});
  final String title;
  final String initial;
  final String? hint;
  final void Function(String words) then;

  @override
  State<_WordsPage> createState() => _WordsPageState();
}

class _WordsPageState extends State<_WordsPage> {
  late final _words = TextEditingController(text: widget.initial);

  @override
  void initState() {
    super.initState();
    // A file's name chosen up to its ending, so typing replaces the name and keeps the kind.
    final dot = widget.initial.lastIndexOf('.');
    _words.selection = TextSelection(baseOffset: 0, extentOffset: dot > 0 ? dot : widget.initial.length);
  }

  @override
  void dispose() {
    _words.dispose();
    super.dispose();
  }

  void _done() {
    if (_words.text.trim().isEmpty) return;
    widget.then(_words.text.trim());
    Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return GhostPage(
      title: widget.title,
      body: ListView(
        padding: EdgeInsetsDirectional.fromSTEB(t.space(4), t.space(2), t.space(4), t.space(8)),
        children: [
          PaneSection(
            description: widget.hint == null ? null : Text(widget.hint!),
            children: [
              SettingRowBox(child: GlacierInput(controller: _words, ariaLabel: widget.title, autoFocus: true, autoCapitalize: TextCapitalization.sentences, size: GlacierFieldSize.md, onSubmitted: (_) => _done())),
            ],
          ),
          SizedBox(height: t.space(4)),
          PaneSection(children: [SettingRow(key: const ValueKey('file-words-save'), icon: AppIcon(Lucide.check, size: 18), label: 'Save', onPress: _done)]),
        ],
      ),
    );
  }
}
