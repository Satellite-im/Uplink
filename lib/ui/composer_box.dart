import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart' show TextCapitalization, TextInputAction, TextInputType;
import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../kit/settings_type.dart';
import '../backgrounds.dart' show lookCorner, lookRim;
import 'dialup/dialup.dart';
import '../art/app_icon.dart' show LucideIcon;
import '../art/lucide.g.dart';
import '../art/lucide_more.dart';
import 'common.dart' show IconTap;
import 'nav_bar.dart' show NavPill;
import 'shell.dart' show pillScrolledScale;
import '../sms.dart' show Sms;
import '../platform_info.dart';

/// The box a message is written in, everywhere one is: a conversation of texts (lib/ui/thread.dart) and a chat on
/// Telegram or Bluesky (lib/ui/inbox_ui.dart), so the two read and work the same (Matt, 2026-11-15: "Also use the
/// same composer for telegram").
///
/// Empty, [plus] sits at its start and [ends] at its end, on the words' line; once there are words ([typing]) they
/// take the whole width and the buttons go to a row under them: [plus] at its start, [below] at its end (Matt,
/// 2026-11-15: "Put the plus symbol inside thr compose input and animate them below when typijg just like this
/// screenshot").
///
/// The buttons are held to the box's bottom corners, and the box grows by a row under the words, so they travel
/// straight down with it and back up (Matt, 2026-11-15: "the buttons don't slide straight down they move out
/// first"); the words' room widens to the box's edges as they go. [field] keeps its place in the tree throughout,
/// so the keyboard stays up.
class ComposerBox extends StatefulWidget {
  const ComposerBox({super.key, required this.field, required this.typing, this.plus, this.ends = const [], this.below = const [], this.ground, this.flush = false});
  final Widget field;

  /// The box's colour where it stands on something already the composer's grey (a profile card's drawer); the
  /// look's composer colour where null.
  final Color? ground;

  /// Without the small room it keeps at its sides, for a box set in a column whose edges it should meet (a profile
  /// card's, lined up with the choices under it).
  final bool flush;
  final bool typing;
  final Widget? plus;
  final List<Widget> ends;
  final List<Widget> below;

  static const move = Duration(milliseconds: 220);
  static const curve = Curves.easeOutCubic;

  @override
  State<ComposerBox> createState() => _ComposerBoxState();
}

class _ComposerBoxState extends State<ComposerBox> {
  /// How wide the buttons beside the words are, as last laid out: the room the words leave them on one line.
  double _plusWidth = 0, _endsWidth = 0;

  /// Keeps the width just measured of the + ([plus]) or of the buttons at the end, and draws again where it changed.
  void _measured(bool plus, Size size) {
    final w = size.width;
    if (plus ? _plusWidth == w : _endsWidth == w) return;
    // Told during layout: taken up for the next frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() => plus ? _plusWidth = w : _endsWidth = w);
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    if (isBevelChrome(t)) return _dialup(context, t);
    final typing = widget.typing;
    final plus = widget.plus;
    final row = t.lenOf('2.25rem');
    final gap = t.space(1);
    final words = t.space(3);
    return _whole(Padding(
      padding: EdgeInsets.symmetric(horizontal: widget.flush ? 0 : t.space(1)),
      child: Container(
        constraints: BoxConstraints(minHeight: t.lenOf('2.75rem')),
        padding: EdgeInsets.all(t.lenOf('0.25rem')),
        // Its corners under the look's radius scale, and a rule round it where the look draws them (Sharp's paper-2
        // field on white was 1.2:1 and all but vanished beside its ruled search field).
        decoration: BoxDecoration(color: widget.ground ?? t.color('app-paper-2'), border: lookRim(t), borderRadius: BorderRadius.circular(lookCorner(t, '1.375rem', most: 1))),
        child: Stack(children: [
          Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            AnimatedPadding(
              duration: ComposerBox.move,
              curve: ComposerBox.curve,
              padding: EdgeInsetsDirectional.only(
                start: typing || plus == null ? words : _plusWidth + gap,
                end: typing || widget.ends.isEmpty ? words : _endsWidth,
              ),
              child: _inOrder(0, widget.field),
            ),
            // The row the buttons come down into.
            AnimatedContainer(duration: ComposerBox.move, curve: ComposerBox.curve, height: typing ? row + gap : 0),
          ]),
          if (plus != null) PositionedDirectional(start: 0, bottom: 0, child: _inOrder(1, _Measure(onSize: (s) => _measured(true, s), child: plus))),
          PositionedDirectional(
            end: 0,
            bottom: 0,
            child: _inOrder(2, AnimatedSwitcher(
              duration: ComposerBox.move,
              // The buttons going fade out in the first half and the ones coming in fade in over the second, so the
              // two sets are never drawn over each other.
              switchInCurve: const Interval(0.5, 1, curve: Curves.easeOut),
              switchOutCurve: const Interval(0.5, 1, curve: Curves.easeIn),
              layoutBuilder: (current, previous) => Stack(alignment: AlignmentDirectional.bottomEnd, children: [...previous, ?current]),
              child: typing
                  ? Row(key: const ValueKey('below'), mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.end, children: widget.below)
                  : _Measure(
                      key: const ValueKey('ends'),
                      onSize: (s) => _measured(false, s),
                      child: Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.end, children: widget.ends),
                    ),
            )),
          ),
        ]),
      ),
    ));
  }

  // In a browser (lib/web) the page's tree for screen readers keeps its nodes in the order they are read, which Flutter
  // works out from where each one is, and the words go from beside the buttons to above them at the first letter
  // typed: the field's node then came before the + where it had come after, Flutter's engine moved the field's element
  // in the page to match, and moving it took the keyboard from it, a letter or two in. So there the composer is a part
  // of the tree of its own whose three parts are read in one order wherever they stand: the words, the +, the buttons.
  // Elsewhere nothing is added.
  static Widget _whole(Widget box) => PlatformInfo.isWeb ? Semantics(container: true, child: box) : box;
  static Widget _inOrder(double order, Widget part) => PlatformInfo.isWeb ? Semantics(container: true, sortKey: OrdinalSortKey(order), child: part) : part;
}

extension on _ComposerBoxState {
  /// Dial-Up's composer, on the silver panel along the page's foot (GhostPage): one raised + at the left in place of
  /// a toolbar row (the design's critique: "Drop the toolbar row by default and put one '+' RetroButton left of the
  /// field"), a white box sunk into the panel that is never under 44 high and grows with the words, and the buttons
  /// at its right, raised, Send among them with its word on it (IconTap draws it so). Nothing moves: what is at the
  /// right is what [ComposerBox.ends] or, once there are words, [ComposerBox.below] holds, at once. The field keeps
  /// its place by its key, so the keyboard stays up as the buttons change.
  Widget _dialup(BuildContext context, Tokens t) {
    final gap = SizedBox(width: t.space(1));
    final plus = widget.plus;
    final end = widget.typing ? widget.below : widget.ends;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: t.space(1)),
      child: RetroIcons(
        child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          if (plus != null) ...[plus, gap],
          Expanded(
            key: const ValueKey('composer-field'),
            child: Padding(
              // On the buttons' line: they are 48 to the finger, their faces 40 inside that, the box 44.
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 44),
                // Where the look writes its chat on a ground of its own (Runestone's parchment, `.parchment` in
                // assets/css/app.css), what is typed is written on it too, as the game's own line is.
                child: GlacierScope(
                  classes: const {'parchment'},
                  child: Sunken(
                    small: true,
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    child: Align(alignment: AlignmentDirectional.centerStart, child: widget.field),
                  ),
                ),
              ),
            ),
          ),
          for (final b in end) ...[if (b is! SizedBox) gap, b],
        ]),
      ),
    );
  }
}

/// Says the size its child was laid out at.
class _Measure extends SingleChildRenderObjectWidget {
  const _Measure({super.key, required this.onSize, super.child});
  final ValueChanged<Size> onSize;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderMeasure(onSize);

  @override
  void updateRenderObject(BuildContext context, _RenderMeasure renderObject) => renderObject.onSize = onSize;
}

/// Lays its child out as usual and calls [onSize] with the size, on every layout.
class _RenderMeasure extends RenderProxyBox {
  _RenderMeasure(this.onSize);
  ValueChanged<Size> onSize;

  @override
  void performLayout() {
    super.performLayout();
    onSize(size);
  }
}

/// The tokens what is typed in a [ComposerBox]'s field is written in, for a page that makes the field's words itself
/// from its own ([t]): the page's, but under the bevelled chrome the field's own ground's, which a look may set apart
/// from its pages' (`.parchment`, as the box wraps its field in: Runestone types in dark ink on parchment). Made
/// once for each page's tokens.
Tokens composerTokens(Tokens t) => !isBevelChrome(t) || t.classes.contains('parchment') ? t : (_fieldTokens[t] ??= t.child(classes: const {'parchment'}));
final _fieldTokens = Expando<Tokens>('a composer field\'s tokens');

/// What the words' line of a [ComposerBox] is set in (type, strut, leading), shared by every field put in one, so the
/// words sit centred on the buttons' middle.
TextStyle composerTextStyle(Tokens page) {
  final t = composerTokens(page);
  return pageText(t, t.fontSize('md'), color: t.color('app-ink'), height: 1.3);
}
StrutStyle composerStrutStyle(Tokens t) => StrutStyle.fromTextStyle(composerTextStyle(t), forceStrutHeight: true, leadingDistribution: TextLeadingDistribution.even);
const composerLeading = TextHeightBehavior(leadingDistribution: TextLeadingDistribution.even);

/// A composer's words field as a screen reader finds it in a browser (lib/web), where an element of the page stands for
/// it: named by [hint], said to be enabled, and focused by what that element passes on when it is pressed or given the
/// keyboard, as a finger's press focuses it. A bare EditableText says none of the three, and Flutter's engine makes the
/// element of a field not said to be enabled a disabled one: with the page's tree for screen readers on, the field could
/// be read and never written in, and had no name. Elsewhere the tree is left as it has been.
Widget composerSemantics({required String hint, required VoidCallback onPress, required Widget child}) =>
    PlatformInfo.isWeb ? Semantics(container: true, enabled: true, label: hint, onTap: onPress, onFocus: onPress, child: child) : child;

/// The words drawn in an empty composer ([hint]): left out of a browser's tree, where [composerSemantics] names the field
/// by them; as they were elsewhere.
Widget composerHint(Widget hint) => PlatformInfo.isWeb ? ExcludeSemantics(child: hint) : hint;

/// The words' line of a [ComposerBox] where nothing more is wanted of it (a Telegram chat, a space's chat): the words,
/// [hint] while there are none, and Enter as Settings › Messages › Enter sends says. A conversation of texts has its
/// own, with more in it (lib/ui/thread.dart).
class ComposerField extends StatefulWidget {
  const ComposerField({super.key, required this.controller, required this.focusNode, required this.hint, required this.onSubmitted, this.enterSends = false});
  final TextEditingController controller;
  final FocusNode focusNode;
  final String hint;
  final VoidCallback onSubmitted;
  final bool enterSends;

  @override
  State<ComposerField> createState() => _ComposerFieldState();
}

/// The keyboard is asked for on a press, and again on coming back to the app with the cursor in the field: Android hides
/// it on leaving while the field keeps its focus, and asking for focus it has does nothing (Matt, 2026-11-16: "Tabbing
/// out and into thr app doesnt clear the focus on the signal convo so the keyboard can't be toggled open").
class _ComposerFieldState extends State<ComposerField> with WidgetsBindingObserver {
  final _field = GlobalKey<EditableTextState>();
  // Where a finger went down on the field; lifted close by, it is a press that asks for the keyboard.
  Offset? _down;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && widget.focusNode.hasFocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _field.currentState?.requestKeyboard());
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final style = composerTextStyle(t);
    final strut = composerStrutStyle(t);
    final controller = widget.controller, focusNode = widget.focusNode, hint = widget.hint, enterSends = widget.enterSends;
    // A finger down and up close by (a tap gesture here loses to the field's own).
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (e) => _down = e.position,
      onPointerUp: (e) {
        final down = _down;
        _down = null;
        if (down == null || (e.position - down).distance >= 18) return;
        focusNode.requestFocus();
        _field.currentState?.requestKeyboard();
      },
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: t.lenOf('2.25rem')),
        child: Align(
          alignment: AlignmentDirectional.centerStart,
          child: Padding(
            padding: EdgeInsets.symmetric(vertical: t.lenOf('0.3rem')),
            child: Stack(children: [
              if (controller.text.isEmpty) composerHint(IgnorePointer(child: Text(hint, style: style.copyWith(color: t.color('app-ink-3')), strutStyle: strut, textHeightBehavior: composerLeading))),
              composerSemantics(
                hint: hint,
                onPress: () {
                  focusNode.requestFocus();
                  _field.currentState?.requestKeyboard();
                },
                child: EditableText(
                key: _field,
                controller: controller,
                focusNode: focusNode,
                style: style,
                strutStyle: strut,
                textHeightBehavior: composerLeading,
                cursorColor: t.color('app-ink'),
                backgroundCursorColor: t.color('app-ink-3'),
                minLines: 1,
                maxLines: 6,
                keyboardType: enterSends ? TextInputType.text : TextInputType.multiline,
                textInputAction: enterSends ? TextInputAction.send : TextInputAction.newline,
                onSubmitted: (_) => widget.onSubmitted(),
                onEditingComplete: enterSends ? () {} : null,
                textCapitalization: TextCapitalization.sentences,
              ),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// The room round every conversation's composer, the same for texts, Telegram, Signal and a space's chat, so the box
/// does not move when you go from one to another (Matt, 2026-11-17: "unify the compose layout between sms / rcs chats,
/// telegram and signal chats as well as spaces chats, they should all have the same layout so there is no shift when
/// switching between them"). [bottom] is what the page leaves under it (the screen's foot, where the page does not).
///
/// Under the box, the room the dock keeps under itself (NavPill.inset; at its resting size on a computer, where it
/// rests smaller), so the composer stands as high above the screen's foot as the dock over the list does (Matt,
/// 2026-11-17: "the space below the navbar and the space below the composer input should be the same increase the
/// space below the composer bar just a bit"). On a phone in the ghost look that took it from 25 to 34 points, the
/// dock's own. It was a small step, the same as its sides, and still is under Dial-Up, whose taskbar stands on the
/// screen's foot with no room under it at all. A whole number of points, so the box lands on the same pixel in every
/// conversation whatever sums the pages above it make.
EdgeInsets composerFootPadding(Tokens t, {double bottom = 0}) => EdgeInsets.fromLTRB(
      t.space(2),
      t.space(2),
      t.space(2),
      (isBevelChrome(t) ? t.space(2) : (NavPill.inset(t) * (Sms.computer ? pillScrolledScale : 1)).roundToDouble()) + bottom,
    );

/// The buttons of every conversation's composer, in the same places whatever the conversation is: Add an attachment at
/// its start; emoji (on a computer), stickers and the microphone at its end while nothing is written, Send in the
/// microphone's place once something is; and once words are written, the microphone, emoji and Send in the row under
/// them. One a conversation can't do is still shown, greyed out ([VoidCallback] null), so nothing moves from one
/// conversation to the next ("if it's not avilable on a given chat just disable the button but still show it so the
/// layout doesn't shift"). [send] replaces Send where something else goes there (Save edit). [onSendMenu] is Send
/// pressed and held, or right-clicked: its menu, Send later (lib/ui/schedule_ui.dart).
({Widget plus, List<Widget> ends, List<Widget> below}) composerButtons(
  Tokens t, {
  required bool hasSomething,
  required VoidCallback? onAttach,
  required VoidCallback? onSticker,
  required VoidCallback? onRecord,
  required VoidCallback? onSend,
  VoidCallback? onEmoji,
  bool emoji = false,
  Widget? send,
  VoidCallback? onSendMenu,
}) {
  final box = t.lenOf('2.25rem');
  final ink = t.color('app-ink-2');
  Widget tap(LucideIcon icon, String label, VoidCallback? on, {String? key}) => IconTap(key: key == null ? null : ValueKey(key), icon: icon, label: label, size: 19, box: box, color: ink, onPressed: on);
  final sendTap = send ?? IconTap(key: const ValueKey('composer-send'), icon: Lucide.arrowUp, label: 'Send', filled: true, size: 19, box: box, onPressed: onSend);
  final sendButton = send != null || onSendMenu == null || onSend == null ? sendTap : GestureDetector(key: const ValueKey('composer-send-hold'), onLongPress: onSendMenu, onSecondaryTap: onSendMenu, child: sendTap);
  Widget emojiButton() => tap(LucideMore.smile, 'Emoji', onEmoji, key: 'composer-emoji');
  return (
    plus: tap(Lucide.plus, 'Add an attachment', onAttach, key: 'composer-plus'),
    ends: [
      if (emoji) emojiButton(),
      tap(Lucide.sticker, 'Stickers', onSticker, key: 'composer-stickers'),
      SizedBox(width: t.space(1)),
      // Nothing written: the microphone, but in a browser, which records no voice messages yet (Sms.browser), where
      // Send stands there, waiting for something to send.
      if (hasSomething || Sms.browser) sendButton else tap(Lucide.mic, 'Record a voice message', onRecord, key: 'composer-mic'),
    ],
    below: [
      if (!Sms.browser) tap(Lucide.mic, 'Record a voice message', onRecord, key: 'composer-mic'),
      if (emoji) emojiButton(),
      SizedBox(width: t.space(1)),
      sendButton,
    ],
  );
}
