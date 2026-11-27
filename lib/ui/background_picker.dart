import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../app_state.dart';
import '../art/app_icon.dart';
import '../art/lucide.g.dart';
import '../backgrounds.dart';
import '../kit/settings_kit.dart';
import '../kit/settings_type.dart';
import '../sms.dart';
import 'common.dart';
import 'dialup/bevel.dart' show DialupColors, Sunken, isDialup;
import 'message_line.dart';
import '../l10n/words.dart';

/// Choosing what is behind the messages (lib/backgrounds.dart): for every chat (Settings › Chat background), or for
/// one conversation (its header › Chat background), which may also wear every chat's. A small conversation at the
/// top shows the choice as it will look.
///
/// A conversation's background can sync with its [people]: as the page is left, what the conversation now wears is
/// sent to them as a text their copy of Uplink wears too. It is on by itself where everyone is known to have
/// the app, and can be switched on for someone who is not known to yet.
class BackgroundPicker extends StatefulWidget {
  const BackgroundPicker({super.key, this.thread, this.who, this.people = const []});

  /// The conversation whose background this is; null for every chat's.
  final int? thread;

  /// Who the conversation is with, for the page's title.
  final String? who;

  /// The conversation's people, to sync its background with.
  final List<Person> people;

  @override
  State<BackgroundPicker> createState() => _BackgroundPickerState();
}

class _BackgroundPickerState extends State<BackgroundPicker> {
  bool _mixing = false;
  bool _busy = false;

  /// Whether everyone here is known to have Uplink; null until Android has said.
  bool? _known;

  /// Something was chosen, or syncing switched on, while the page was open: there may be something to send.
  bool _dirty = false;

  /// Kept for the moment the page is left, when there is no context to ask.
  AppState? _app;
  GlacierToastController? _toasts;

  /// Sharing what a conversation wears is the phone's to do: a computer's choice is its own.
  bool get _canSync => widget.thread != null && widget.people.isNotEmpty && !Sms.remote;
  // The choices kept for this conversation: whether it syncs, and the background its people were last sent.
  String get _syncKey => 'chat_bg_sync_${widget.thread}';
  String get _syncedKey => 'chat_bg_synced_${widget.thread}';

  /// Syncing: as the person set it for this conversation, else on where everyone is known to have the app.
  bool _syncOn(AppState app) => _canSync && app.flag(_syncKey, fallback: _known ?? false);

  /// Who the background is shared with, as the toast names them.
  String get _them => widget.people.length > 1 ? 'everyone here' : widget.people.first.label;

  @override
  void initState() {
    super.initState();
    if (_canSync) {
      Sms.instance.ghostPeers([for (final p in widget.people) p.address]).then((known) {
        if (mounted) setState(() => _known = known);
      }).catchError((_) {});
    }
  }

  // Kept for dispose, which sends the background and toasts after the context can no longer be asked.
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _app = AppState.of(context);
    _toasts = GlacierToast.of(context);
  }

  /// As the page is left: what the conversation wears now goes to its people, once, if it is not what they have.
  @override
  void dispose() {
    final app = _app;
    final thread = widget.thread;
    if (app != null && thread != null && _dirty && _syncOn(app)) {
      final send = ChatBackground.of(app, thread).shareable;
      if (send != null && send.raw != app.choice(_syncedKey, '')) {
        final toasts = _toasts;
        final them = _them;
        Sms.instance.shareBackground([for (final p in widget.people) p.address], thread, send.raw).then((_) {
          toasts?.toast(message: Text('Background sent to $them'));
        }).catchError((Object e) {
          toasts?.toast(message: Text('Couldn\'t send the background: $e'), tone: GlacierToastTone.danger);
        });
      }
    }
    super.dispose();
  }

  /// The choice this page writes: every chat's background, or this conversation's own.
  String get _key => widget.thread == null ? 'chat_bg' : ChatBackground.threadKey(widget.thread!);

  /// The name the app keeps this one's picture under.
  String get _file => widget.thread == null ? 'all' : 't${widget.thread}';

  /// [next] null is "the same as every chat" (a conversation's only).
  void _set(ChatBackground? next) {
    final app = AppState.of(context);
    final before = ChatBackground.parse(app.choice(_key, ''));
    app.set(_key, next?.raw ?? '');
    _dirty = true;
    // A picture no longer worn is not kept.
    if (before.kind == 'image' && next?.kind != 'image' && !Sms.remote) Sms.instance.deleteBackground(_file);
  }

  /// A picture from the phone as the background: the first one picked is copied into the app's own files and worn.
  Future<void> _pickPicture() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final uris = await Sms.instance.pickImages();
      if (uris.isEmpty) return;
      final path = await Sms.instance.importBackground(uris.first, _file);
      if (!mounted) return;
      if (path == null) {
        toast(context, 'That picture couldn\'t be read.', tone: GlacierToastTone.danger);
      } else {
        _set(ChatBackground('image', path));
      }
    } catch (e) {
      if (mounted) toast(context, 'Couldn\'t use that picture: $e', tone: GlacierToastTone.danger);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = AppState.of(context);
    final thread = widget.thread;
    final every = ChatBackground.everyChat(app);
    final own = thread == null ? every : ChatBackground.own(app, thread);
    final worn = own ?? every;
    final hasPalette = PhonePalette.current != null;
    bool chosen(ChatBackground b) => own != null && own.kind == b.kind && own.value == b.value;

    return GlacierScope(
      attrs: const {'hue': 'purple'},
      child: Builder(builder: (context) {
        final t = context.tokens;
        return SettingsPaneScope(
          finder: SettingsFinder(),
          child: GhostPage(
            title: thread == null ? 'Chat background' : (widget.who == null ? 'Background' : 'Background with ${widget.who}'),
            body: ListView(
              padding: EdgeInsetsDirectional.fromSTEB(t.space(4), t.space(2), t.space(4), t.space(8) + MediaQuery.paddingOf(context).bottom),
              children: [
                BackgroundPreview(background: worn, thread: thread),
                SizedBox(height: t.space(5)),
                if (_canSync) ...[
                  PaneSection(
                    footer: Text(_known == true
                        ? 'When you leave this page, what this conversation wears is sent to $_them as a text, and their Uplink wears it too. What they choose comes back the same way.'
                        : '${widget.people.length > 1 ? 'Not everyone here is' : '${widget.people.first.label} isn\'t'} known to have Uplink yet. It is known once a key or a background has come from them. To anyone without the app, the background arrives as a text of letters.'),
                    children: [
                      SettingRow(
                        icon: const AppIcon(Lucide.refreshCw, size: 18),
                        label: 'Sync with $_them',
                        hint: worn.kind == 'image' ? const Tr('A picture goes as a picture message, at the size your carrier allows.') : null,
                        control: GlacierSwitch(
                          checked: _syncOn(app),
                          ariaLabel: 'Sync with $_them',
                          onCheckedChange: (on) {
                            app.setFlag(_syncKey, on);
                            if (on) _dirty = true;
                          },
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: t.space(5)),
                ],
                PaneSection(
                  footer: thread == null
                      ? const Tr('What a conversation wears until it has a background of its own. Each conversation\'s own is in its settings: the cog at its top.')
                      : const Tr('For this conversation alone. Every other conversation keeps what it wears.'),
                  children: [
                    if (thread != null)
                      SettingRow(
                        label: 'Same as every chat',
                        hint: Text(every.label),
                        control: Pick(checked: own == null, label: 'Use every chat\'s background', onPress: () => _set(null)),
                      ),
                    SettingRow(
                      label: 'None',
                      hint: const Tr('The plain page.'),
                      control: Pick(checked: chosen(ChatBackground.none), label: 'No background', onPress: () => _set(ChatBackground.none)),
                    ),
                    // The phone's wallpaper is the phone's: a computer has none of Android's to match.
                    if (!Sms.remote)
                    SettingRow(
                      label: 'Match my wallpaper',
                      hint: const Tr('The colours Android takes from this phone\'s wallpaper, which the phone\'s own apps wear too. It changes when the wallpaper does.'),
                      disabledReason: hasPalette ? null : 'Needs Android 12 or later.',
                      control: Pick(checked: chosen(ChatBackground.wallpaper), label: 'Match my wallpaper', onPress: () => _set(ChatBackground.wallpaper)),
                    ),
                  ],
                ),
                SizedBox(height: t.space(5)),
                PaneSection(title: 'Washes', children: [
                  SettingRowBox(
                    child: Wrap(spacing: t.space(3), runSpacing: t.space(3), children: [
                      for (final p in chatPresets)
                        _Swatch(
                          label: p.name,
                          top: t.isDark ? p.darkTop : p.lightTop,
                          bottom: t.isDark ? p.darkBottom : p.lightBottom,
                          chosen: chosen(ChatBackground('preset', p.id)),
                          onPress: () => _set(ChatBackground('preset', p.id)),
                        ),
                    ]),
                  ),
                ]),
                SizedBox(height: t.space(5)),
                PaneSection(title: 'A colour', children: [
                  SettingRowBox(
                    child: Wrap(spacing: t.space(3), runSpacing: t.space(3), children: [
                      for (final hex in chatColors)
                        _Swatch(
                          top: ChatBackground('color', hex).colors(false)!.$1,
                          bottom: ChatBackground('color', hex).colors(false)!.$1,
                          chosen: chosen(ChatBackground('color', hex)),
                          onPress: () => _set(ChatBackground('color', hex)),
                          semanticLabel: 'Colour $hex',
                        ),
                    ]),
                  ),
                  SettingRow(
                    icon: const AppIcon(Lucide.palette, size: 18),
                    label: 'Mix a colour',
                    control: GlacierSwitch(checked: _mixing, onCheckedChange: (on) => setState(() => _mixing = on), ariaLabel: 'Mix a colour'),
                  ),
                  if (_mixing)
                    SettingRowBox(
                      child: GlacierColorPicker(
                        defaultValue: own?.kind == 'color' ? own!.value : '#DCE8FB',
                        // Kept as the drag ends, not on every frame of it.
                        onChangeEnd: (hex) => _set(ChatBackground('color', hex)),
                      ),
                    ),
                ]),
                // A picture is chosen from the phone's photos and kept by the app there: not from a computer.
                if (!Sms.remote) ...[
                SizedBox(height: t.space(5)),
                // Not in a browser, which can't choose a picture yet (Sms.browser).
                if (!Sms.browser) PaneSection(
                  title: 'A picture',
                  footer: const Tr('A copy is kept by the app on this phone. It is drawn under a light veil so messages stay readable.'),
                  children: [
                    SettingRow(
                      icon: const AppIcon(Lucide.imagePlus, size: 18),
                      label: own?.kind == 'image' ? 'Choose another picture' : 'Choose a picture',
                      hint: const Tr('From your photos.'),
                      onPress: _pickPicture,
                    ),
                  ],
                ),
                ],
                if (thread == null) ...[
                  SizedBox(height: t.space(5)),
                  PaneSection(
                    title: 'Shared backgrounds',
                    footer: const Tr('Someone with Uplink can sync a conversation\'s background with you, and you with them, from the conversation\'s header. It travels as a text in the conversation. Off, theirs is not worn here.'),
                    children: [
                      SettingRow(
                        icon: const AppIcon(Lucide.refreshCw, size: 18),
                        label: 'Wear backgrounds shared with you',
                        control: GlacierSwitch(checked: app.flag('bg_accept'), onCheckedChange: (on) => app.setFlag('bg_accept', on), ariaLabel: 'Wear backgrounds shared with you'),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        );
      }),
    );
  }
}

/// A few bubbles over [background], as a conversation will wear it.
class BackgroundPreview extends StatelessWidget {
  const BackgroundPreview({super.key, required this.background, this.thread});
  final ChatBackground background;

  /// The conversation whose bubbles these are, for its own bubble colour.
  final int? thread;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final app = AppState.of(context);
    final (mine, onMine) = myBubble(t, app, thread);
    final theirs = theirBubble(t, onBackground: !background.isNone);
    Widget bubble(String text, {required bool out}) => Align(
          alignment: out ? AlignmentDirectional.centerEnd : AlignmentDirectional.centerStart,
          child: Container(
            margin: EdgeInsets.only(top: t.space(1)),
            padding: EdgeInsets.symmetric(horizontal: t.space(3) + 2, vertical: t.space(2)),
            decoration: BoxDecoration(
              color: out ? mine : theirs,
              borderRadius: BorderRadius.circular(t.lenOf('1.15rem')),
              border: background.isNone && bubbleNeedsRim(out ? mine : theirs, t.color('glacier-bg')) ? Border.all(color: t.color('app-rule')) : null,
            ),
            child: Text(text, style: pageText(t, t.fontSize('md') * app.textScale, color: out ? onMine : t.color('app-ink'), height: 1.35)),
          ),
        );
    return Semantics(
      label: 'How it looks: ${background.label}',
      child: ExcludeSemantics(
        child: Container(
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(color: t.color('glacier-bg'), borderRadius: BorderRadius.circular(t.radius('lg'))),
          // The rule is drawn over the background, so it rings a picture as it rings the plain page.
          foregroundDecoration: BoxDecoration(borderRadius: BorderRadius.circular(t.radius('lg')), border: Border.all(color: t.color('app-rule'))),
          child: RepaintBoundary(
            child: Stack(children: [
              Positioned.fill(child: ChatBackgroundLayer(background: background)),
              Padding(
                padding: EdgeInsets.all(t.space(3)),
                // Dial-Up writes a conversation as transcript lines in a white well (lib/ui/message_line.dart): the
                // background shows round the well, as it will in the conversation.
                child: isDialup(context)
                    ? Sunken(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                          HostLine.day(DateTime.now()),
                          MessageLine(name: 'Maya', nameColor: DialupColors.of(t).nameTheirs, body: 'Are we still on for tonight?'),
                          MessageLine(name: 'You', nameColor: DialupColors.of(t).nameMine, mine: true, body: 'Yes! See you at 7'),
                          MessageLine(name: 'Maya', nameColor: DialupColors.of(t).nameTheirs, body: 'Perfect 🎉'),
                        ]),
                      )
                    : Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Center(child: OnBackground(busy: background.busy, child: Text('Today', style: pageText(t, t.fontSize('xs'), weight: 'semibold', color: t.color('app-ink-3'))))),
                  SizedBox(height: t.space(1)),
                  bubble('Are we still on for tonight?', out: false),
                  bubble('Yes! See you at 7', out: true),
                  bubble('Perfect 🎉', out: false),
                ]),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// One background to choose: a rounded square in its two colours, top to bottom, ringed and ticked when chosen, with
/// its name under it where it has one.
class _Swatch extends StatelessWidget {
  const _Swatch({required this.top, required this.bottom, required this.chosen, required this.onPress, this.label, this.semanticLabel});
  final Color top;
  final Color bottom;
  final bool chosen;
  final VoidCallback onPress;
  final String? label;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final side = t.lenOf('3.25rem');
    return GlacierPressable(
      onPressed: onPress,
      semanticLabel: '${semanticLabel ?? label}${chosen ? ', chosen' : ''}',
      builder: (context, state) => AnimatedScale(
        scale: state.pressed ? 0.94 : 1,
        duration: const Duration(milliseconds: 120),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: side,
            height: side,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(t.lenOf('0.9rem')),
              gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [top, bottom]),
              border: Border.all(color: chosen ? settingsHue(t) : t.color('app-rule'), width: chosen ? 2.5 : 1),
            ),
            alignment: Alignment.center,
            child: chosen ? AppIcon(Lucide.check, size: 18, strokeWidth: 2.6, wash: false, color: settingsHue(t)) : null,
          ),
          if (label != null) ...[
            SizedBox(height: t.space(1)),
            Text(label!, style: pageText(t, t.fontSize('xs'), weight: chosen ? 'semibold' : 'regular', color: t.color(chosen ? 'app-ink' : 'app-ink-2'))),
          ],
        ]),
      ),
    );
  }
}
