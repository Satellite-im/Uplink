import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/services.dart' show LengthLimitingTextInputFormatter, TextCapitalization, TextInputType;
import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../art/app_icon.dart';
import '../art/lucide.g.dart';
import '../art/lucide_more.dart';
import '../feedback/feedback_api.dart';
import '../files/file_kinds.dart';
import '../kit/semantic_colors.dart';
import '../kit/settings_kit.dart';
import '../kit/settings_type.dart';
import '../me/me.dart';
import '../net/net.dart';
import '../platform_info.dart';
import '../sms.dart';
import '../voice/channels.dart';
import 'circles/members_drawer.dart' show showMembersDrawer;
import 'common.dart';
import 'composer_box.dart' show composerSemantics;
import 'drawer_head.dart' show DrawerHead;
import 'dialup/bevel.dart' show isBevelChrome;
import 'settings_panes.dart' show appVersion;
import '../l10n/words.dart';

/// Share feedback (Matt, 2026-11-19: "add a "share feedback" button hovering in the topbar of the app it should be a
/// simple form which allows the user to upload screenshots and explain a bug, suggest a feature or a few other options
/// from a select dropdown and optionally provide their username automatically so we can give out bug bounties"): the
/// button in the list's top bar, and the page it opens. What is sent goes to the relay (lib/feedback/feedback_api.dart),
/// which files it as a ticket.

/// Sends a report and gives back the ticket's id; the app's own unless a test gives another.
typedef FeedbackSend = Future<String> Function(FeedbackReport report);

/// The app's: signed with the hub key the username is claimed by (Me's hub, Net.instance.hub), else the key spaces
/// are signed with, to the relay the app is on; and where that is a relay of someone's own that takes no feedback, to
/// Uplink's instead ([sendFeedbackOrOurs]).
Future<String> sendFeedbackLive(FeedbackReport report) {
  final hub = Net.instance.hub;
  final signer = hub?.signer ?? Voice.instance.signer;
  if (signer == null) return Future.error(FeedbackError('Couldn\'t reach the server. Try again in a moment.'));
  return sendFeedbackOrOurs(hubUrl: hub?.url ?? Net.instance.hubUrl, ours: Net.defaultHub, mayLeave: !PlatformInfo.isWeb, send: (url) => sendFeedback(report, signer: signer, hubUrl: url));
}

/// Under Send: who the feedback goes to. On a relay of someone's own it goes to that relay's own board where it has one.
String feedbackGoesWords(String hubUrl) => hubUrl == Net.defaultHub || PlatformInfo.isWeb ? 'It goes to the Uplink team.' : 'It goes to your relay\'s own feedback board where it has one, and to the Uplink team where it doesn\'t.';

/// The Share feedback button: a small round button like Mark all read beside it, its words in a tip while a pointer
/// rests on it; under Dial-Up one of the bar's tool buttons.
class FeedbackButton extends StatelessWidget {
  const FeedbackButton({super.key, this.onOpen, this.side});

  /// What a press does where the button stands outside the app's pages (the Mac window's title strip, above the
  /// navigator): opens the form on the given navigator. Where null, [open] from the button's own place.
  final VoidCallback? onOpen;

  /// Its side; the look's control height where not said.
  final double? side;

  /// Whether the form opens in a drawer: on a phone (Android, iPhone), where a page would cover the list it was opened
  /// from; a computer keeps the page beside the list (Matt, 2026-11-20: "make share feedback open in a drawer on
  /// mobile"). Tests say which with [drawerOverride].
  static bool? drawerOverride;
  /// Everywhere since 2026-11-20 (Matt: "the share feedback drawer should open over the whole app not just in the
  /// sidebar"): the drawer is on the app's own navigator, over the whole window with it dimmed behind, where the page was
  /// pushed in the sidebar's.
  static bool get inDrawer => drawerOverride ?? true;

  static void open(BuildContext context) => inDrawer ? unawaited(showFeedbackDrawer(context)) : push<void>(context, (_) => const FeedbackScreen());

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    void press() => onOpen != null ? onOpen!() : open(context);
    if (isBevelChrome(t)) return IconTap(key: const ValueKey('share-feedback'), icon: LucideMore.messageSquareWarning, label: 'Share feedback', onPressed: press);
    final side = this.side ?? t.len('glacier-control-height-md');
    // A pill in the app's primary colour with its words, "Share Feedback" (Matt, 2026-11-19: "add the text "Share
    // Feedback" to the feedback bubble and make it the primary color"), pressed in a little as Send is.
    final ink = t.color('app-on-accent');
    return GlacierPressable(
      key: const ValueKey('share-feedback'),
      onPressed: press,
      semanticLabel: 'Share feedback',
      builder: (context, state) => GlacierFocusRing(
        visible: state.focused,
        radius: t.radius('full'),
        child: AnimatedScale(
          scale: state.pressed ? 0.96 : 1,
          duration: const Duration(milliseconds: 120),
          child: Container(
            height: side,
            padding: EdgeInsets.symmetric(horizontal: t.space(3)),
            decoration: BoxDecoration(color: t.color('app-accent'), borderRadius: BorderRadius.circular(side / 2)),
            alignment: Alignment.center,
            child: ExcludeSemantics(
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                AppIcon(LucideMore.messageSquareWarning, size: 15, strokeWidth: 2.2, wash: false, color: ink),
                SizedBox(width: t.space(1) + 2),
                Text('Share Feedback', maxLines: 1, style: pageText(t, t.fontSize('sm'), weight: 'semibold', color: ink)),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

/// The feedback form in the drawer that slides up from the foot, as Members and Add people do (lib/ui/circles/
/// members_drawer.dart): on a phone, in place of the page (Matt, 2026-11-20: "make share feedback open in a drawer on
/// mobile"). Sending closes it.
Future<void> showFeedbackDrawer(BuildContext context, {FeedbackSend? send, String? username, Future<List<({String name, Uint8List bytes})>> Function()? pickPictures}) => showMembersDrawer(
      context,
      title: 'Share feedback',
      subtitle: 'It goes to the Uplink team',
      list: (_) => FeedbackScreen(key: const ValueKey('feedback-drawer'), drawer: true, send: send, username: username, pickPictures: pickPictures),
    );

/// The feedback page: what it is (a select of [FeedbackType]), a short title, what happened, up to three
/// screenshots, and whether to say the username, for a bug bounty. [drawer]: the form alone, for the drawer
/// ([showFeedbackDrawer]), as tall as what it holds.
class FeedbackScreen extends StatefulWidget {
  const FeedbackScreen({super.key, this.send, this.username, this.pickPictures, this.drawer = false});

  final bool drawer;

  /// How it is sent; the app's own ([sendFeedbackLive]) where null.
  final FeedbackSend? send;

  /// The username to offer; this install's ([Me.username]) where null.
  final String? username;

  /// Chooses pictures: their bytes and names. The device's own picker where null.
  final Future<List<({String name, Uint8List bytes})>> Function()? pickPictures;

  @override
  State<FeedbackScreen> createState() => _FeedbackScreenState();
}

class _FeedbackScreenState extends State<FeedbackScreen> {
  final _title = TextEditingController();
  final _text = TextEditingController();
  final _focus = FocusNode();
  var _type = FeedbackType.bug;
  final _shots = <FeedbackShot>[];
  late bool _withName = (_username ?? '').isNotEmpty;
  bool _sending = false;
  bool _picking = false;

  /// Each screenshot at most this large, so three of them in base64 stay under the relay's 10 MB.
  static const _shotTarget = 2400 * 1024;

  /// The username the feedback can go with, without its @; null where there is none.
  String? get _username {
    final u = (widget.username ?? Me.instance.username)?.trim().replaceFirst(RegExp(r'^@'), '');
    return u == null || u.isEmpty ? null : u;
  }

  @override
  void initState() {
    super.initState();
    _text.addListener(_changed);
  }

  void _changed() => setState(() {});

  @override
  void dispose() {
    _title.dispose();
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  bool get _ready => !_sending && _text.text.trim().isNotEmpty;

  static LucideIcon _iconOf(FeedbackType type) => switch (type) {
        FeedbackType.bug => LucideMore.bug,
        FeedbackType.feature => Lucide.lightbulb,
        FeedbackType.confusing => Lucide.circleQuestionMark,
        FeedbackType.praise => LucideMore.smile,
        FeedbackType.other => Lucide.ellipsis,
      };

  void _chooseType() => showChoices(context, title: 'What is it?', choices: [
        for (final type in FeedbackType.values) Choice(type.label, _iconOf(type), () => setState(() => _type = type)),
      ]);

  /// The pictures chosen in the device's own picker, each read whole with its file's name.
  Future<List<({String name, Uint8List bytes})>> _pickFromDevice() async {
    final out = <({String name, Uint8List bytes})>[];
    for (final picked in await Sms.instance.pickImages()) {
      final path = await Sms.instance.cacheCopy(picked);
      out.add((name: path.split(RegExp(r'[/\\]')).last, bytes: await File(path).readAsBytes()));
    }
    return out;
  }

  /// Adds the pictures picked as screenshots, up to the most a report takes; one that can't be used, and any left
  /// over, are said.
  Future<void> _addShot() async {
    if (_picking || _shots.length >= FeedbackReport.mostShots) return;
    setState(() => _picking = true);
    try {
      final picked = await (widget.pickPictures ?? _pickFromDevice)();
      var refused = false, left = false;
      for (final p in picked) {
        if (_shots.length >= FeedbackReport.mostShots) {
          left = true;
          break;
        }
        final shot = await _shotOf(p.name, p.bytes);
        if (shot == null) {
          refused = true;
        } else {
          _shots.add(shot);
        }
      }
      if (!mounted) return;
      if (refused) {
        toast(context, 'Couldn\'t use that picture.', tone: GlacierToastTone.danger);
      } else if (left) {
        toast(context, 'Up to ${FeedbackReport.mostShots} screenshots go with feedback.');
      }
    } catch (e) {
      if (mounted) toast(context, 'Couldn\'t add the screenshot: $e', tone: GlacierToastTone.danger);
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  /// [bytes] as a screenshot the relay takes: as it is where it is a kind it takes and small enough, else drawn
  /// smaller as a PNG until it fits. Null where it isn't a picture.
  static Future<FeedbackShot?> _shotOf(String name, Uint8List bytes) async {
    final mime = FileKind.mimeOf(name.toLowerCase());
    if (FeedbackShot.mimes.contains(mime) && bytes.length <= _shotTarget) return FeedbackShot(name: name, mime: mime, bytes: bytes);
    ui.Image? image;
    try {
      final codec = await ui.instantiateImageCodec(bytes);
      image = (await codec.getNextFrame()).image;
      final long = math.max(image.width, image.height);
      final base = name.contains('.') ? name.substring(0, name.lastIndexOf('.')) : name;
      for (final most in const [2400, 1800, 1400, 1080, 800]) {
        final k = math.min(1.0, most / long);
        final w = math.max(1, (image.width * k).round()), h = math.max(1, (image.height * k).round());
        final recorder = ui.PictureRecorder();
        ui.Canvas(recorder).drawImageRect(image, Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()), Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()), Paint()..filterQuality = FilterQuality.medium);
        final small = await recorder.endRecording().toImage(w, h);
        final png = await small.toByteData(format: ui.ImageByteFormat.png);
        small.dispose();
        if (png == null) continue;
        final out = png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes);
        if (out.length <= _shotTarget) return FeedbackShot(name: '$base.png', mime: 'image/png', bytes: out);
      }
      return null;
    } catch (_) {
      return null;
    } finally {
      image?.dispose();
    }
  }

  /// Sends the report with this platform and version, the username only where it was left ticked, thanks with the
  /// ticket's id where the relay gave one, and closes the form.
  Future<void> _send() async {
    if (!_ready) return;
    final report = FeedbackReport(
      type: _type,
      title: _title.text.trim(),
      text: _text.text.trim(),
      username: _withName ? _username : null,
      platform: FeedbackReport.thisPlatform,
      version: FeedbackReport.thisVersion(appVersion),
      shots: List.of(_shots),
    );
    setState(() => _sending = true);
    try {
      final id = await (widget.send ?? sendFeedbackLive)(report);
      if (!mounted) return;
      // Said before the page goes: the toast is the app's, over every page, so it stays.
      toast(context, id.isEmpty ? 'Thanks! Your feedback was sent.' : 'Thanks! Sent as $id');
      Navigator.of(context).maybePop();
    } catch (e) {
      if (!mounted) return;
      setState(() => _sending = false);
      toast(context, e is FeedbackError ? e.message : 'Couldn\'t send your feedback: $e', tone: GlacierToastTone.danger);
    }
  }

  /// A many-lined field's own semantics: in a browser [composerSemantics], elsewhere a label on a text field, as before.
  static Widget _textSemantics({required String label, required FocusNode focus, required Widget child}) =>
      PlatformInfo.isWeb ? composerSemantics(hint: label, onPress: focus.requestFocus, child: child) : Semantics(label: label, textField: true, child: child);

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    // Closer together in the drawer, where the form shares the screen with what it was opened over.
    final gap = SizedBox(height: widget.drawer ? t.space(3) : t.space(5));
    final ink = pageText(t, t.fontSize('md'), color: t.color('app-ink'), height: 1.4);
    final name = _username;
    ListView form({required EdgeInsets padding, bool shrinkWrap = false}) => ListView(
            padding: padding,
            shrinkWrap: shrinkWrap,
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            children: [
              PaneSection(children: [
                SettingRow(
                  key: const ValueKey('feedback-type'),
                  icon: AppIcon(_iconOf(_type), size: 18),
                  label: 'What is it?',
                  value: Text(_type.label),
                  onPress: _sending ? null : _chooseType,
                ),
              ]),
              gap,
              PaneSection(title: 'Title', children: [
                SettingRowBox(
                  child: GlacierInput(
                    key: const ValueKey('feedback-title'),
                    controller: _title,
                    placeholder: 'A few words (optional)'.t,
                    ariaLabel: 'Title',
                    autoCapitalize: TextCapitalization.sentences,
                    maxLength: FeedbackReport.titleMost,
                  ),
                ),
              ]),
              gap,
              PaneSection(
                title: 'What happened?',
                description: Text(switch (_type) {
                  FeedbackType.bug => 'What you did, what you expected, and what happened instead.',
                  FeedbackType.feature => 'What you\'d like Uplink to do, and what it would help with.',
                  FeedbackType.confusing => 'Where you were, and what wasn\'t clear.',
                  FeedbackType.praise => 'What you like.',
                  FeedbackType.other => 'Tell us anything.',
                }),
                children: [
                  SettingRowBox(
                    child: GestureDetector(
                      key: const ValueKey('feedback-text'),
                      onTap: _focus.requestFocus,
                      child: Container(
                        constraints: BoxConstraints(minHeight: t.lenOf('8rem')),
                        padding: EdgeInsets.all(t.space(3)),
                        decoration: BoxDecoration(color: t.color('app-paper-3'), borderRadius: BorderRadius.circular(t.radius('md'))),
                        child: Stack(children: [
                          if (_text.text.isEmpty) IgnorePointer(child: Tr('Describe it here', style: ink.copyWith(color: t.color('app-ink-3')))),
                          // In a browser, named and focused as a composer's words are there (composerSemantics): a bare
                          // EditableText under a label could be read and never written in with the page's tree for
                          // screen readers on. Elsewhere as it was.
                          _textSemantics(
                            label: 'What happened',
                            focus: _focus,
                            child: EditableText(
                              controller: _text,
                              focusNode: _focus,
                              style: ink,
                              cursorColor: t.color('app-ink'),
                              backgroundCursorColor: t.color('app-ink-3'),
                              selectionColor: t.textSelection,
                              minLines: 5,
                              maxLines: 14,
                              keyboardType: TextInputType.multiline,
                              textCapitalization: TextCapitalization.sentences,
                              inputFormatters: [LengthLimitingTextInputFormatter(FeedbackReport.textMost)],
                              readOnly: _sending,
                            ),
                          ),
                        ]),
                      ),
                    ),
                  ),
                ],
              ),
              gap,
              PaneSection(
                title: 'Screenshots',
                footer: Sms.browser ? null : Text('Up to ${FeedbackReport.mostShots}.'),
                children: [
                  if (_shots.isNotEmpty)
                    SettingRowBox(
                      child: Wrap(spacing: t.space(3), runSpacing: t.space(3), children: [
                        for (final (i, s) in _shots.indexed) _thumb(t, i, s),
                      ]),
                    ),
                  // Not in a browser, which can't choose a picture yet (Sms.browser): the words go alone there, and the
                  // row says so (a plain row, which a screen reader reads; a switched-off one it doesn't).
                  if (Sms.browser)
                    SettingRow(
                      key: const ValueKey('feedback-no-shots'),
                      icon: AppIcon(Lucide.image, size: 18),
                      label: 'Not from a browser yet',
                      hint: const Tr('Say what you saw in words, or send screenshots from the app on your phone or computer.'),
                    )
                  else if (_shots.length < FeedbackReport.mostShots)
                    SettingRow(
                      key: const ValueKey('feedback-add-shot'),
                      icon: AppIcon(Lucide.imagePlus, size: 18),
                      label: _picking ? 'Adding…' : 'Add a screenshot',
                      disabled: _sending || _picking,
                      onPress: _sending || _picking ? null : _addShot,
                    ),
                ],
              ),
              // Only where there is a username to say: on by default, so a bug's finder can be thanked.
              if (name != null) ...[
                gap,
                PaneSection(children: [
                  SettingRow(
                    label: 'Include my username (@$name)',
                    hint: const Tr('For bug bounties'),
                    control: GlacierSwitch(
                      key: const ValueKey('feedback-username'),
                      checked: _withName,
                      disabled: _sending,
                      onCheckedChange: (v) => setState(() => _withName = v),
                      ariaLabel: 'Include my username',
                    ),
                  ),
                ]),
              ],
              gap,
              PaneSection(children: [
                SettingRow(
                  key: const ValueKey('feedback-send'),
                  icon: AppIcon(Lucide.send, size: 18),
                  label: _sending ? 'Sending…' : 'Send',
                  hint: Text(_sending ? 'One moment.' : (_text.text.trim().isEmpty ? 'Say what happened first.' : feedbackGoesWords(Net.instance.hubUrl))),
                  disabled: !_ready,
                  onPress: _ready ? _send : null,
                ),
              ]),
            ],
          );
    // In the drawer: the form alone on the drawer's gutter, as tall as it is (the drawer is no taller than the screen
    // and scrolls it).
    if (widget.drawer) {
      final gutter = DrawerHead.gutter(t);
      return SettingsPaneScope(finder: SettingsFinder(), child: form(padding: EdgeInsets.fromLTRB(gutter, t.space(3), gutter, t.space(4)), shrinkWrap: true));
    }
    return GhostPage(
      title: 'Share feedback',
      body: SettingsPaneScope(
        finder: SettingsFinder(),
        child: LayoutBuilder(builder: (context, box) {
          final side = math.max(t.space(4), (box.maxWidth - 640) / 2);
          return form(padding: EdgeInsets.fromLTRB(side, t.space(2), side, t.space(8) + MediaQuery.paddingOf(context).bottom));
        }),
      ),
    );
  }

  /// One screenshot added, as a small square.
  Widget _thumb(Tokens t, int i, FeedbackShot s) {
    final side = t.lenOf('6rem');
    return SizedBox(
      key: ValueKey('feedback-shot-$i'),
      width: side,
      height: side,
      child: Stack(children: [
        Positioned.fill(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(t.radius('md')),
            child: DecoratedBox(
              decoration: BoxDecoration(color: t.color('app-paper-3')),
              child: Image.memory(s.bytes, fit: BoxFit.cover, cacheWidth: 240, gaplessPlayback: true, semanticLabel: 'Screenshot ${i + 1}'),
            ),
          ),
        ),
        PositionedDirectional(
          top: t.space(1),
          end: t.space(1),
          child: Container(
            decoration: BoxDecoration(color: t.color('app-paper'), shape: BoxShape.circle),
            child: IconTap(
              key: ValueKey('feedback-remove-shot-$i'),
              icon: Lucide.x,
              label: 'Remove screenshot ${i + 1}',
              size: 14,
              box: t.lenOf('1.75rem'),
              onPressed: _sending ? null : () => setState(() => _shots.removeAt(i)),
            ),
          ),
        ),
      ]),
    );
  }
}
