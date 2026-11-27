import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../logic/command_palette.dart';
import '../motion/motion.dart';
import '../tokens/css_value.dart';
import '../tokens/exact_lines.dart';
import '../tokens/theme.dart';
import '../tokens/tokens.dart';
import 'field_core.dart';
import 'kbd.dart';
import 'pressable.dart';
import 'search_field.dart';

export '../logic/command_palette.dart';

// The palette's own words, from `kitMessages` (packages/react/src/i18n/messages.ts), in its eight languages. The page
// read its language from the kit's LocaleProvider; here it is the ambient Localizations', English where there is none.

/// `kitMessages.commandPaletteLabel`: the dialog, the field and the list are all named this.
const Map<String, String> _label = {
  'en': 'Command palette',
  'es': 'Paleta de comandos',
  'fr': 'Palette de commandes',
  'de': 'Befehlspalette',
  'ja': 'コマンドパレット',
  'pt': 'Paleta de comandos',
  'zh': '命令面板',
  'ar': 'لوحة الأوامر',
};

/// `kitMessages.commandPalettePlaceholder`: the field, empty.
const Map<String, String> _placeholder = {
  'en': 'Type a command or search…',
  'es': 'Escribe un comando o busca…',
  'fr': 'Tapez une commande ou recherchez…',
  'de': 'Befehl eingeben oder suchen…',
  'ja': 'コマンドを入力または検索…',
  'pt': 'Digite um comando ou pesquise…',
  'zh': '输入命令或搜索…',
  'ar': 'اكتب أمرًا أو ابحث…',
};

/// `kitMessages.commandPaletteEmpty`: in place of the list when nothing matches.
const Map<String, String> _empty = {
  'en': 'No matching commands',
  'es': 'No hay comandos coincidentes',
  'fr': 'Aucune commande correspondante',
  'de': 'Keine passenden Befehle',
  'ja': '一致するコマンドはありません',
  'pt': 'Nenhum comando correspondente',
  'zh': '没有匹配的命令',
  'ar': 'لا توجد أوامر مطابقة',
};

/// `kitMessages.commandPaletteHint`: the key-hint strip.
const Map<String, String> _hint = {
  'en': '↑↓ to navigate · ↵ to run · esc to close',
  'es': '↑↓ para navegar · ↵ para ejecutar · esc para cerrar',
  'fr': '↑↓ pour naviguer · ↵ pour exécuter · échap pour fermer',
  'de': '↑↓ navigieren · ↵ ausführen · esc schließen',
  'ja': '↑↓ 移動 · ↵ 実行 · esc 閉じる',
  'pt': '↑↓ para navegar · ↵ para executar · esc para fechar',
  'zh': '↑↓ 导航 · ↵ 运行 · esc 关闭',
  'ar': '↑↓ للتنقل · ↵ للتنفيذ · esc للإغلاق',
};

String _say(BuildContext context, Map<String, String> message) => message[Localizations.maybeLocaleOf(context)?.languageCode] ?? message['en']!;

/// `size` of the palette: how wide the panel may grow (`.sm`, `.md`, `.lg`: 24, 32 and 40rem).
enum GlacierCommandPaletteSize {
  sm('24rem'),
  md('32rem'),
  lg('40rem');

  const GlacierCommandPaletteSize(this.maxWidth);
  final String maxWidth;
}

/// The palette's own key-hint strip, "↑↓ to navigate · ↵ to run · esc to close" in the reader's language: what
/// [GlacierCommandPalette.footer] is unless something else, or null, is passed.
class GlacierCommandPaletteHint extends StatelessWidget {
  const GlacierCommandPaletteHint({super.key});

  @override
  Widget build(BuildContext context) {
    final t = GlacierTheme.of(context);
    return Text(_say(context, _hint), style: t.text('xs', color: t.color('glacier-text-subtle')));
  }
}

/// A ⌘K overlay that searches every action in the app: a port of `CommandPalette`
/// (packages/react/src/organisms/CommandPalette/CommandPalette.tsx and CommandPalette.module.css), with the modal
/// layer of internal/useDialogLayer.ts and the matching, grouping and cursor of `@glacier/logic`
/// (lib/src/logic/command_palette.dart).
///
/// One text field drives the whole surface: typing narrows the list, the arrow keys move a cursor through it, and
/// Enter runs what the cursor is on. Focus never leaves the field; the active row is marked selected rather than
/// focused. The widget itself takes no room where it is mounted: while [open] it draws on the root [Overlay], as the
/// original portals to the body.
///
/// The parameters are the React props under the same names.
///
/// What differs from the original:
/// - **Android's back** closes it, by a [PopScope] where it is mounted inside a route and by the binding's own
///   pop-route call where the app has no Navigator. The page left back to the app. One place this cannot reach:
///   mounted *above* a Navigator, the Navigator's routes answer back before the palette is asked, and the app
///   should close the palette from its own back handling.
/// - **The cursor's row is kept in view** when the keys move it. The original does not scroll: a cursor moved past
///   the fold goes out of sight.
/// - **Opening always seats the cursor on the first runnable row.** The original re-seats it when the list's
///   identity changes, which in practice is every open, but with the same array and the same query it would come
///   back where it was left.
/// - **[commands] are compared by what they say**, so a parent that builds the same list again does not unseat the
///   cursor; React compared the array's identity and asked for `useMemo`.
/// - **A mouse press runs a row on the way down**, as `mousedown` did; a finger runs it on the tap, which is when a
///   phone's browser sent that `mousedown`.
/// - **A press inside the panel leaves the focus in the field.** On the page a click on a heading or the footer
///   took it to the panel, and the keys went dead until Tab.
/// - **The soft keyboard**: its action key runs the cursor's row, as its Enter did on the page, and the panel and
///   its `vh` measure what the keyboard leaves of the window, as a page resized by the keyboard does.
/// - **The entrance** is the original's (the scrim fades in over 150ms as the panel springs in from 8px above at
///   0.97), but glass cannot fade as a layer here: the blur and the paint come up by their own strength instead.
///   There is no exit animation in the original and none here.
/// - **The panel's glass** is drawn as Chromium draws the stylesheet, which is as the specification has it: a
///   backdrop-filter sees no further back than the nearest element with one, here the scrim, so under the panel is
///   the scrim's colour a second time and no second blur of the page. (WebKit, on the Mac, lets the blurred page
///   through; measured, the two differ by five levels in 255 of the panel's ground in the light theme.)
/// - **The semantics** are a dialog that scopes and names a route, a text field that says it is expanded and names
///   the list it controls, and rows marked selected and enabled. Flutter has no `listbox`/`option` roles and no
///   `aria-activedescendant`.
/// - **Where it is mounted matters** in two ways a portal to the body did not. Design tokens are read there (a
///   portal read them at the root), so keep it outside any inverse or hued scope. And it is drawn on the root
///   overlay over the entry it is mounted in, not over entries added to that overlay later: where a Navigator owns
///   the root overlay, a route pushed over the palette's own covers it. Under an Overlay of the app's own above any
///   Navigator, as the kit's test harness has one, nothing does. The app's shell is the place for it.
/// - [kbdStyle] is laid over the shortcut hints' text; see [GlacierKbd.style].
///
/// The original does not use the kit's ScrollArea: the list is a plain `overflow-y: auto`, and is a plain scroll
/// view here.
class GlacierCommandPalette extends StatefulWidget {
  const GlacierCommandPalette({
    super.key,
    required this.open,
    required this.onOpenChange,
    required this.commands,
    required this.onRun,
    this.query,
    this.defaultQuery = '',
    this.onQueryChange,
    this.placeholder,
    this.emptyLabel,
    this.footer = const GlacierCommandPaletteHint(),
    this.size = GlacierCommandPaletteSize.md,
    this.shortcut = true,
    this.kbdStyle,
  });

  final bool open;

  /// Called with false when the user dismisses, or runs a command.
  final ValueChanged<bool> onOpenChange;

  /// Every command the palette can run, in the order they should be offered. Priority is the caller's to decide:
  /// the palette filters and groups but never reorders.
  final List<CommandDescriptor> commands;

  /// Called with the chosen command's id, after the palette has been told to close.
  final ValueChanged<String> onRun;

  /// Controlled query text.
  final String? query;

  /// Initial query when uncontrolled; the palette resets to it on each open.
  final String defaultQuery;
  final ValueChanged<String>? onQueryChange;
  final String? placeholder;

  /// Shown in place of the list when nothing matches. It inherits the kit's small, subtle, centred text.
  final Widget? emptyLabel;

  /// Replaces the default key-hint strip. Pass null to drop it.
  final Widget? footer;
  final GlacierCommandPaletteSize size;

  /// Binds ⌘K / Ctrl+K globally. Turn it off to own the chord yourself.
  final bool shortcut;

  /// Laid over the shortcut key caps' text style; null leaves the kit's.
  final TextStyle? kbdStyle;

  /// How many times a palette opening has taken the page behind it to blur once, for a test.
  @visibleForTesting
  static int debugBehindTaken = 0;

  @override
  State<GlacierCommandPalette> createState() => _GlacierCommandPaletteState();
}

class _GlacierCommandPaletteState extends State<GlacierCommandPalette> with TickerProviderStateMixin, WidgetsBindingObserver {
  final OverlayPortalController _portal = OverlayPortalController(debugLabel: 'GlacierCommandPalette');
  final FocusScopeNode _scope = FocusScopeNode(debugLabel: 'GlacierCommandPalette');
  final FocusNode _field = FocusNode(debugLabel: 'GlacierCommandPalette query');
  final ScrollController _scroll = ScrollController();

  /// `transition={{ duration: 0.15 }}` on the scrim's opacity, which motion eases out.
  late final AnimationController _fade = AnimationController(vsync: this, duration: const Duration(milliseconds: 150));

  /// `springTransition(Spring.Snappy)` on the panel's opacity, scale and y: one spring from 0 to 1 drives all three.
  late final AnimationController _spring = AnimationController.unbounded(vsync: this);

  /// `useId()`: what the field says it controls.
  late final String _listId = 'glacier-command-palette-${shortHash(this)}';

  /// The query where the palette keeps its own (no `query` given).
  late String _ownQuery = widget.defaultQuery;

  /// The commands the query leaves, best first; the same under their group headings; and a key a row, in the
  /// order of [_matches], by which the cursor's row is found and scrolled to.
  List<CommandMatch<CommandDescriptor>> _matches = const [];
  List<CommandGroup<CommandDescriptor>> _groups = const [];
  List<GlobalKey> _rows = const [];

  /// Each row's key by the command it is, so a row still offered after a letter is the row it was: a key made anew
  /// for every row at every letter took every row out of the tree and made it again, its words laid out from
  /// nothing, whether or not the letter had changed it.
  Map<String, GlobalKey> _keyOf = const {};

  /// The highlighted row, as an index into [_matches]; -1 where there is none to run.
  int _cursor = -1;

  /// The page behind the palette as it was when the palette opened, blurred once: what the scrim fades in while it
  /// opens ([_takeBehind]). Null where there is none to be had, and once the scrim is all there.
  ui.Image? _behind;

  /// What had the focus when the palette opened, to hand it back on closing.
  FocusNode? _opener;
  bool _started = false;
  bool _watchingBack = false;
  bool _watchingKeys = false;
  bool _ranOnPress = false;

  String get _query => widget.query ?? _ownQuery;

  @override
  void initState() {
    super.initState();
    _rematch();
    _watchKeys(widget.shortcut);
    // The scrim all there: the picture it was fading in is let go, and the blur itself is drawn from here on.
    _fade.addStatusListener((status) {
      if (status == AnimationStatus.completed) _letBehindGo();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (widget.open) _opened();
  }

  @override
  void didUpdateWidget(GlacierCommandPalette oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.shortcut != oldWidget.shortcut) _watchKeys(widget.shortcut);
    final opening = widget.open && !oldWidget.open;
    // Every keystroke rebuilds the list, so the cursor has to be re-seated on the new top row: otherwise it keeps an
    // index that now points at a different command, and Enter runs something the user never looked at.
    if (widget.query != oldWidget.query || !listEquals(widget.commands, oldWidget.commands)) _rematch();
    if (opening) {
      _opened();
    } else if (!widget.open && oldWidget.open) {
      _closed();
    }
  }

  @override
  void dispose() {
    _watchKeys(false);
    _watchBack(false);
    _fade.dispose();
    _spring.dispose();
    _behind?.dispose();
    _scope.dispose();
    _field.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// Works the list out again for the query and the commands as they stand, and puts the cursor on the first row
  /// that can be run.
  void _rematch() {
    _matches = matchCommands(widget.commands, _query);
    _groups = groupCommands(_matches);
    final had = _keyOf;
    final next = <String, GlobalKey>{};
    _rows = [
      for (final match in _matches)
        // Two rows of one id cannot wear one key: the second has a key of its own, kept for nothing.
        next.containsKey(match.item.id) ? GlobalKey() : (next[match.item.id] = had[match.item.id] ?? GlobalKey()),
    ];
    _keyOf = next;
    _cursor = firstCommandCursor(_matches);
  }

  /// `useControlled`'s setter: the palette keeps the text where it owns it, and the listener hears either way.
  void _setQuery(String next) {
    if (widget.query == null && next != _ownQuery) {
      setState(() {
        _ownQuery = next;
        _rematch();
      });
    }
    widget.onQueryChange?.call(next);
  }

  // --- the dialog layer (internal/useDialogLayer.ts) ---

  /// The palette has been opened: the query and cursor start over, the entrance plays, back is watched, and the
  /// field takes the focus.
  void _opened() {
    // Opening is the palette's reset point: a stale query from last time would hide most of the list behind a
    // search the user has already forgotten.
    if (widget.query == null) {
      _ownQuery = widget.defaultQuery;
      _rematch();
      final told = widget.defaultQuery;
      // As the effect did: once this build is done, not in the middle of it.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onQueryChange?.call(told);
      });
    }
    _cursor = firstCommandCursor(_matches);
    _ranOnPress = false;
    _opener = FocusManager.instance.primaryFocus;
    if (GlacierTheme.of(context).reducedMotion) {
      _fade.value = 1;
      _spring.value = 1;
    } else {
      _fade.forward(from: 0);
      // Once this frame is drawn: the page as it stands under a palette of which nothing shows yet.
      WidgetsBinding.instance.addPostFrameCallback((_) => _takeBehind());
      _spring.value = 0;
      _spring.animateWith(SpringSimulation(springDescription(Spring.snappy), 0, 1, 0, tolerance: const Tolerance(distance: 0.01, velocity: 0.01))).whenCompleteOrCancel(() {
        if (mounted && widget.open && !_spring.isAnimating) _spring.value = 1;
      });
    }
    // The portal is out of the tree while the palette is closed, so this is a note for when it is built, a moment
    // from now: a portal in the tree may not be shown or hidden in the middle of a build.
    _portal.show();
    _watchBack(true);
    // `initialFocusRef`: the field, as soon as it is there.
    _field.requestFocus();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.open && !_field.hasFocus) _field.requestFocus();
    });
  }

  /// `.overlay { backdrop-filter: blur(sm) }` under an opacity that eases in: the page's engine blurs what is behind
  /// and fades the blurred picture in over the page. A backdrop filter cannot be faded here, so its blur came up by
  /// its own strength instead, another blur of the whole window at each frame of the entrance, and a weak blur of a
  /// whole window is the dearest thing a phone's engine is asked for. So while the palette opens the scrim is what
  /// the page's is: the page behind, taken once at half its size and blurred once, faded in over the page as it
  /// goes on being drawn. Once the scrim is all there it is the backdrop filter at its full strength, as it was.
  ///
  /// The page behind is the outermost layer of its own between the palette's place in the page and the overlay the
  /// palette is drawn in (a route's page is one); where there is none that fills the window, nothing is taken and
  /// the blur comes up by its strength as before.
  void _takeBehind() {
    if (!mounted || !widget.open || _fade.value >= 1) return;
    final theater = Overlay.maybeOf(context, rootOverlay: true)?.context.findRenderObject();
    RenderRepaintBoundary? page;
    for (RenderObject? at = context.findRenderObject(); at != null && !identical(at, theater); at = at.parent) {
      if (at is RenderRepaintBoundary) page = at;
    }
    if (page == null || theater is! RenderBox || !page.attached || page.size != theater.size || page.size.isEmpty) return;
    final t = GlacierTheme.of(context);
    final by = MediaQuery.devicePixelRatioOf(context) / 2;
    final sharp = page.toImageSync(pixelRatio: by);
    final recorder = ui.PictureRecorder();
    final sigma = t.len('glacier-blur-sm') * by;
    Canvas(recorder).drawImage(sharp, Offset.zero, Paint()..imageFilter = ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma, tileMode: TileMode.clamp));
    final drawn = recorder.endRecording();
    final blurred = drawn.toImageSync(sharp.width, sharp.height);
    drawn.dispose();
    sharp.dispose();
    GlacierCommandPalette.debugBehindTaken += 1;
    setState(() {
      _behind?.dispose();
      _behind = blurred;
    });
  }

  /// Drops the blurred picture of the page, once the real backdrop blur has taken over or the palette has closed.
  void _letBehindGo() {
    final behind = _behind;
    if (behind == null) return;
    _behind = null;
    // After the frame: the last drawing of it may still be on its way to the screen.
    WidgetsBinding.instance.addPostFrameCallback((_) => behind.dispose());
  }

  /// The palette has been closed: its animations stop and the focus goes back where it came from.
  void _closed() {
    _letBehindGo();
    _fade.stop();
    _spring.stop();
    _watchBack(false);
    // `opener?.focus()`: back to whatever had the focus before, unless what was run has already taken it elsewhere.
    final opener = _opener;
    _opener = null;
    final stillOurs = _scope.hasFocus || FocusManager.instance.primaryFocus == null;
    if (stillOurs && opener != null && opener.context != null && opener.canRequestFocus) opener.requestFocus();
  }

  void _close() => widget.onOpenChange(false);

  /// Listens for the system's back gesture while the palette is open ([didPopRoute]).
  void _watchBack(bool on) {
    if (on == _watchingBack) return;
    _watchingBack = on;
    on ? WidgetsBinding.instance.addObserver(this) : WidgetsBinding.instance.removeObserver(this);
  }

  /// The system's back, where no route's [PopScope] took it first.
  @override
  Future<bool> didPopRoute() async {
    if (!widget.open) return false;
    _close();
    return true;
  }

  /// Listens to every key of the hardware keyboard for the opening chord, where the palette has one.
  void _watchKeys(bool on) {
    if (on == _watchingKeys) return;
    _watchingKeys = on;
    on ? HardwareKeyboard.instance.addHandler(_onAnyKey) : HardwareKeyboard.instance.removeHandler(_onAnyKey);
  }

  /// ⌘K from anywhere. Bound whenever the palette is mounted rather than only while closed, so the chord is a no-op
  /// on an open palette instead of reaching whatever is under it.
  bool _onAnyKey(KeyEvent event) {
    if (event is KeyUpEvent) return false;
    final keys = HardwareKeyboard.instance;
    if (!isCommandShortcut(key: event.logicalKey.keyLabel, metaKey: keys.isMetaPressed, ctrlKey: keys.isControlPressed)) return false;
    widget.onOpenChange(true);
    return true;
  }

  /// Escape, and the Tab trap: the keys the layer answers whatever inside it has the focus.
  KeyEventResult _onLayerKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      _close();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.tab) {
      final from = FocusManager.instance.primaryFocus;
      if (from == null || from == _scope) {
        _field.requestFocus();
      } else if (HardwareKeyboard.instance.isShiftPressed) {
        from.previousFocus();
      } else {
        from.nextFocus();
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  // --- the cursor ---

  /// Moves the highlight; [reveal] (the keyboard, not the pointer) also scrolls its row into view.
  void _setCursor(int next, {bool reveal = false}) {
    if (next != _cursor) setState(() => _cursor = next);
    if (reveal) _reveal();
  }

  /// Brings the cursor's row into the list's view by the shortest way, as `scrollIntoView({ block: 'nearest' })`
  /// would. At once: the keys repeat, and a row that eased into place would trail them.
  void _reveal({bool again = true}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients || _cursor < 0 || _cursor >= _rows.length) return;
      final row = _rows[_cursor].currentContext?.findRenderObject();
      if (row == null || !row.attached) {
        // A row far from the list's window is not built (End, from the top): the list goes to about where the row
        // is, by its place among the rows, and once it is built there it is brought in exactly.
        if (!again || _rows.length < 2) return;
        final position = _scroll.position;
        position.jumpTo(position.minScrollExtent + (position.maxScrollExtent - position.minScrollExtent) * _cursor / (_rows.length - 1));
        _reveal(again: false);
        WidgetsBinding.instance.scheduleFrame();
        return;
      }
      final viewport = RenderAbstractViewport.of(row);
      final position = _scroll.position;
      final top = viewport.getOffsetToReveal(row, 0).offset;
      final bottom = viewport.getOffsetToReveal(row, 1).offset;
      if (position.pixels > top) {
        position.jumpTo(top.clamp(position.minScrollExtent, position.maxScrollExtent));
      } else if (position.pixels < bottom) {
        position.jumpTo(bottom.clamp(position.minScrollExtent, position.maxScrollExtent));
      }
    });
  }

  /// Runs the command at [index] of the list, unless it is disabled: asks to close, then tells the listener its id.
  void _run(int index) {
    if (index < 0 || index >= _matches.length) return;
    final match = _matches[index];
    if (match.item.disabled) return;
    // Close first: a command that opens a dialog of its own should not have to race this overlay's teardown for
    // the focus.
    widget.onOpenChange(false);
    widget.onRun(match.item.id);
  }

  /// The list's keys, heard on the field, which keeps the focus: arrows, Home and End move the cursor, Enter runs.
  KeyEventResult _onFieldKey(KeyEvent event) {
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowDown || key == LogicalKeyboardKey.arrowUp) {
      _setCursor(moveCommandCursor(_matches, _cursor, key == LogicalKeyboardKey.arrowDown ? 1 : -1), reveal: true);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.home) {
      _setCursor(firstCommandCursor(_matches), reveal: true);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.end) {
      // step backwards from the top to land on the last runnable row
      _setCursor(moveCommandCursor(_matches, 0, -1), reveal: true);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.numpadEnter) {
      _run(_cursor);
      return KeyEventResult.handled;
    }
    // Escape is left to the layer, so the palette closes on the same key path as every other dialog in the kit.
    return KeyEventResult.ignored;
  }

  // --- drawing ---

  @override
  Widget build(BuildContext context) {
    return PopScope<Object?>(
      canPop: !widget.open,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && widget.open) _close();
      },
      // `if (!open) return null`: closed, there is nothing of it anywhere.
      child: widget.open ? OverlayPortal(controller: _portal, overlayLocation: OverlayChildLocation.rootOverlay, overlayChildBuilder: (context) => GlacierRootScope(child: Builder(builder: _layer)), child: const SizedBox.shrink()) : const SizedBox.shrink(),
    );
  }

  /// A colour at a share of its own alpha: how the scrim and the panel's paint come in, in place of an [Opacity].
  static Color _faded(Color color, double by) => color.withValues(alpha: color.a * by);

  Widget _layer(BuildContext context) {
    final t = GlacierTheme.of(context);
    final media = MediaQuery.of(context);
    // The page's viewport is what the soft keyboard leaves of the window, and `vh` is a hundredth of that.
    final keyboard = media.viewInsets.bottom;
    final css = CssContext(rem: t.css.rem, em: t.css.em, vw: t.css.vw, vh: media.size.height - keyboard, dpr: t.css.dpr, lineDpr: t.css.lineDpr);
    double len(String expression) => evalNumber(t.resolve(expression), css);

    final pad = t.space(6);
    final hairline = t.len('glacier-hairline');
    final radius = t.radius('2xl');
    final label = _say(context, _label);
    final panel = _panel(context, t, label);

    return BlockSemantics(
      child: AnimatedBuilder(
        animation: Listenable.merge([_fade, _spring]),
        child: panel,
        builder: (context, panel) {
          final shown = Curves.easeOut.transform(_fade.value.clamp(0.0, 1.0));
          final sprung = _spring.value;
          final solid = shown * sprung.clamp(0.0, 1.0);
          return Stack(
            fit: StackFit.expand,
            children: [
              // .overlay: the scrim, and a press on it dismisses.
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _close,
                child: ExcludeSemantics(
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      // Opening, the page behind blurred once and faded in; all there, the blur itself.
                      if (_behind != null && shown < 1)
                        RawImage(image: _behind, fit: BoxFit.fill, opacity: AlwaysStoppedAnimation<double>(shown), filterQuality: FilterQuality.low)
                      else
                        GlassBackdrop(blur: t.len('glacier-blur-sm'), amount: shown),
                      ColoredBox(color: _faded(t.color('glacier-overlay'), shown)),
                    ],
                  ),
                ),
              ),
              // `place-items: start center` inside the scrim's padding, 12vh of headroom at the top.
              Padding(
                padding: EdgeInsets.fromLTRB(pad, len('12vh'), pad, pad + keyboard),
                child: Align(
                  alignment: Alignment.topCenter,
                  child: ConstrainedBox(
                    // the list scrolls, not the panel, so the field stays put as results change
                    constraints: BoxConstraints(maxWidth: len(widget.size.maxWidth), maxHeight: len('min(28rem, 70vh)')),
                    child: Transform.translate(
                      offset: Offset(0, -8 * (1 - sprung)),
                      child: Transform.scale(
                        scale: 1 - 0.03 * (1 - sprung),
                        child: Stack(
                          children: [
                            // .panel's own `backdrop-filter: blur(lg) saturate(...)` reaches no further back than its
                            // backdrop root, and the scrim, having a backdrop-filter itself, is one. So what the
                            // panel filters is the scrim's flat colour and nothing of the page: the scrim, saturated,
                            // laid once more under the glass. (Chromium draws it so, and the phone's WebView is one;
                            // WebKit has no backdrop roots yet and lets the scrim's blurred page through instead.)
                            Positioned.fill(
                              child: CustomPaint(
                                painter: KitBoxPainter(radius: radius, fill: _faded(saturated(t.color('glacier-overlay'), t.len('glacier-glass-saturate')), solid)),
                              ),
                            ),
                            Positioned.fill(
                              child: CustomPaint(
                                painter: KitBoxPainter(
                                  radius: radius,
                                  fill: _faded(t.color('glacier-glass-thick'), solid),
                                  border: _faded(t.color('glacier-glass-border'), solid),
                                  borderWidth: hairline,
                                  shadows: [
                                    for (final s in t.shadow('glacier-shadow-5')) BoxShadow(color: _faded(s.color, solid), offset: s.offset, blurRadius: s.blurRadius, spreadRadius: s.spreadRadius),
                                  ],
                                  highlight: _faded(t.color('glacier-glass-highlight'), solid),
                                  highlightHeight: hairline,
                                ),
                              ),
                            ),
                            Opacity(opacity: solid, child: panel),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  /// `.panel` and what is in it: the field, the list or the empty line, the footer.
  Widget _panel(BuildContext context, Tokens t, String label) {
    final gap = t.space(2);
    final hairline = t.len('glacier-hairline');
    final subtle = t.color('glacier-text-subtle');
    final footer = widget.footer;

    final column = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GlacierSearchField(
          focusNode: _field,
          value: _query,
          onValueChange: _setQuery,
          onKeyDown: _onFieldKey,
          // A soft keyboard's action key is its Enter, and the field keeps the focus after it.
          onSubmitted: (_) => _run(_cursor),
          onEditingComplete: () {},
          placeholder: widget.placeholder ?? _say(context, _placeholder),
          ariaLabel: label,
          ariaExpanded: true,
          ariaControls: _matches.isEmpty ? null : _listId,
        ),
        SizedBox(height: gap),
        if (_matches.isEmpty)
          Padding(
            padding: EdgeInsets.symmetric(vertical: t.space(6), horizontal: t.space(3)),
            child: DefaultTextStyle(
              style: t.text('sm', color: subtle),
              textAlign: TextAlign.center,
              child: widget.emptyLabel ?? Text(_say(context, _empty)),
            ),
          )
        else
          Flexible(
            child: Semantics(
              container: true,
              explicitChildNodes: true,
              label: label,
              identifier: _listId,
              // The rows near the list's window are the ones built: every row offered was built and laid out at
              // each letter typed, forty notes and the commands, of which the panel shows ten (a letter cost a
              // phone 18 ms of its frame). The list is as tall as its rows up to the room it is given, as it was:
              // where it is the shorter, every row is in its window and is built, and its height is theirs.
              child: CustomScrollView(
                controller: _scroll,
                shrinkWrap: true,
                slivers: [
                  for (final group in _groups) ...[
                    // Presentational: the option order already carries the grouping for anyone reading top to
                    // bottom.
                    if (group.group != null && group.group!.isNotEmpty)
                      SliverToBoxAdapter(
                        child: ExcludeSemantics(
                          child: Padding(
                            padding: EdgeInsets.fromLTRB(t.space(3), t.space(2), t.space(3), t.space(1)),
                            // headings are signposts, not rows: they should never be mistaken for something Enter
                            // would run
                            // On the page's own line (`line-height: normal`, in the phone's pixels): a whole
                            // pixel a heading and a row put a list of seven most of a pixel a row long.
                            child: ExactLines.of(
                              Text(
                                group.group!.toUpperCase(),
                                style: kitFont(t, fontSize: t.fontSize('xs'), weight: 'medium', color: subtle, letterSpacing: 0.04 * t.fontSize('xs')),
                              ),
                              normal: true,
                              dpr: t.css.lineDpr,
                            ),
                          ),
                        ),
                      ),
                    SliverList(
                      delegate: SliverChildBuilderDelegate(
                        (context, i) => _row(t, group.matches[i]),
                        childCount: group.matches.length,
                        // As the rows were in their column: no layer of a row's own, nothing kept alive past the
                        // window, and no place in the list added to what a screen reader hears of a row.
                        addAutomaticKeepAlives: false,
                        addRepaintBoundaries: false,
                        addSemanticIndexes: false,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        if (footer != null) ...[
          SizedBox(height: gap),
          DecoratedBox(
            decoration: BoxDecoration(
              border: Border(
                top: BorderSide(color: t.color('glacier-border'), width: hairline),
              ),
            ),
            child: Padding(padding: EdgeInsets.fromLTRB(t.space(3), hairline + t.space(2), t.space(3), t.space(1)), child: footer),
          ),
        ],
      ],
    );

    return Semantics(
      scopesRoute: true,
      namesRoute: true,
      explicitChildNodes: true,
      role: SemanticsRole.dialog,
      label: label,
      // A press anywhere in the panel is the field's own as far as its focus goes, and never reaches the scrim.
      child: TextFieldTapRegion(
        child: Listener(
          behavior: HitTestBehavior.opaque,
          child: FocusScope(
            node: _scope,
            onKeyEvent: _onLayerKey,
            child: FocusTraversalGroup(
              // .panel { color: text; font-family: sans }, at the body's own size: a portal inherits from the root.
              child: DefaultTextStyle(
                style: kitFont(t, fontSize: t.css.rem, color: t.color('glacier-text')),
                child: Padding(padding: EdgeInsets.all(hairline + t.space(2)), child: column),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Marks the characters that answered the query. The split itself is shared with the logic, so every binding marks
  /// the same runs; this only paints them.
  List<InlineSpan> _highlight(String text, TextStyle mark) => [for (final segment in highlightSegments(text, _query)) TextSpan(text: segment.text, style: segment.match ? mark : null)];

  /// `.option`: one row. The highlight is not eased: a palette is driven by held-down arrow keys, and a fill that
  /// faded would leave the cursor visibly trailing the key.
  Widget _row(Tokens t, CommandMatch<CommandDescriptor> match) {
    final item = match.item;
    final active = match.index == _cursor;
    final disabled = item.disabled;
    final subtle = t.color('glacier-text-subtle');
    final base = kitFont(t, fontSize: t.fontSize('sm'), color: disabled ? subtle : t.color('glacier-text'));
    // .mark: accent and semibold; the brighter solid on the active row's fill; weight alone on a disabled row.
    final mark = TextStyle(
      color: disabled ? null : t.color(active ? 'glacier-accent-solid' : 'glacier-accent-text'),
      fontWeight: t.weight('semibold'),
      fontVariations: [FontVariation('wght', t.len('glacier-font-weight-semibold'))],
    );
    final keyword = match.matchedKeyword;
    final shortcut = item.shortcut;
    final detail = item.detail;

    // One node for a screen reader: the row's words, whether it is the selected one, and its tap.
    return MergeSemantics(
      child: MouseRegion(
        // Hover moves the cursor rather than adding a second highlight, so there is only ever one row that Enter and
        // a click agree on.
        onHover: disabled ? null : (_) => _setCursor(match.index),
        child: Listener(
          // mousedown, not click, for a mouse.
          onPointerDown: (event) {
            _ranOnPress = event.kind == PointerDeviceKind.mouse && event.buttons == kPrimaryButton;
            if (_ranOnPress) _run(match.index);
          },
          child: GlacierPressable(
            key: _rows[match.index],
            onPressed: disabled
                ? null
                : () {
                    if (_ranOnPress) {
                      _ranOnPress = false;
                      return;
                    }
                    _setCursor(match.index);
                    _run(match.index);
                  },
            canRequestFocus: false,
            button: false,
            selected: active,
            builder: (context, state) => DecoratedBox(
              decoration: BoxDecoration(color: active ? t.color('glacier-hover') : null, borderRadius: BorderRadius.circular(t.radius('md'))),
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: t.space(2), horizontal: t.space(3)),
                child: Row(
                  children: [
                    Expanded(
                      child: ExactLines.of(
                        Text.rich(
                          TextSpan(
                            children: [
                              // When the query hit a keyword rather than the label, the keyword leads and the real
                              // label trails as context, so the row explains why it matched.
                              ..._highlight(keyword ?? item.label, mark),
                              if (keyword != null)
                                TextSpan(
                                  style: TextStyle(color: subtle),
                                  children: [
                                    const TextSpan(text: ' · '),
                                    ..._highlight(item.label, mark),
                                  ],
                                ),
                            ],
                          ),
                          style: base,
                          maxLines: 1,
                          softWrap: false,
                          overflow: TextOverflow.ellipsis,
                        ),
                        normal: true,
                        dpr: t.css.lineDpr,
                      ),
                    ),
                    // The port's own: where the thing is, or how it stands, small and quiet, and never more than
                    // 9rem of the row, so the label keeps the rest.
                    if (detail != null && detail.isNotEmpty) ...[
                      SizedBox(width: t.space(3)),
                      ConstrainedBox(
                        constraints: BoxConstraints(maxWidth: t.lenOf('9rem')),
                        child: ExactLines.of(
                          Text(detail, style: kitFont(t, fontSize: t.fontSize('xs'), color: subtle), maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis),
                          normal: true,
                          dpr: t.css.lineDpr,
                        ),
                      ),
                    ],
                    if (shortcut != null && shortcut.isNotEmpty) ...[
                      SizedBox(width: t.space(3)),
                      DefaultTextStyle(
                        style: base,
                        child: GlacierKbd(style: widget.kbdStyle, child: Text(shortcut)),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
