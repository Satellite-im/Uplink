/// Making a circle, adding a space to one, and a circle's settings (Matt, 2026-11-17: "make a new design for [circles]
/// ... simpler and easier to digest ... use iconography and color where possible"): a name, one of the app's hues, an
/// icon or a picture, previewed on the circle's face as they are chosen, its first spaces and friends to bring; a
/// space's name, kind (three big cards, each in its colour) and heading; and, in settings, its people and their roles,
/// its invite link and QR code, arranging its spaces, and leaving or deleting it.
library;

import 'dart:async';
import '../../platform_info.dart';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart' show TextCapitalization;
import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../../art/app_icon.dart';
import '../../art/lucide.g.dart';
import '../../circles/circles.dart';
import '../../circles/sms_space.dart';
import '../../files/files_store.dart';
import '../../friends/buddies.dart';
import '../../kit/semantic_colors.dart';
import '../../kit/settings_kit.dart';
import '../../kit/settings_type.dart';
import '../../voice/channels.dart';
import '../../voice/voice.dart';
import '../common.dart';
import '../profile_card.dart';
import '../dialup/bevel.dart';
import '../shell.dart';
import '../../sms.dart' show Sms;
import 'circle_face.dart';
import 'circle_settings.dart';
import 'circle_picture.dart';
import '../../voice/roles.dart' show Role;
import '../../l10n/words.dart';

/// A section of a settings-like page, its rows' icons on [hue] (as Settings' own sections are).
Widget _hued(String hue, Widget section) => GlacierScope(attrs: {'hue': hue}, child: section);

/// A form's list: no wider than 640 and centred on a wide window (a Fold open, a computer), so its fields and its
/// button read as a form rather than bars across the whole window; the margins still scroll it.
Widget _form(List<Widget> children) => Builder(
      builder: (context) => LayoutBuilder(builder: (context, box) {
        final t = context.tokens;
        final side = math.max(t.space(4), (box.maxWidth - 640) / 2);
        return ListView(padding: EdgeInsetsDirectional.fromSTEB(side, t.space(2), side, t.space(8) + MediaQuery.paddingOf(context).bottom), children: children);
      }),
    );

/// The hues as round swatches, the chosen one ringed and ticked. Each swatch is its hue's own colour
/// ([AppColors.hueSwatch]), not the look's settling of it: in Dial-Up, Runestone and Mist the look's hues fold into one
/// or a few, and a picker of twelve identical swatches could not be read. Where the look does fold them, a line says
/// that this look draws circles in its own colours and others see the one picked.
class CircleHuePicker extends StatelessWidget {
  const CircleHuePicker({super.key, required this.value, required this.onChanged});
  final String value;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final bevel = isBevelChrome(t);
    final folded = {for (final h in circleHues) settingsHue(t.child(attrs: {'hue': h})).toARGB32()}.length < circleHues.length;
    final swatches = Wrap(spacing: t.space(2), runSpacing: t.space(2), children: [
      for (final h in circleHues)
        GlacierPressable(
          key: ValueKey('circle-hue-$h'),
          onPressed: () => onChanged(h),
          semanticLabel: '$h${h == value ? ', chosen' : ''}',
          builder: (context, _) {
            final chosen = h == value;
            final fill = t.hueSwatch(h);
            return Container(
              width: 38,
              height: 38,
              padding: const EdgeInsets.all(3),
              decoration: BoxDecoration(
                shape: bevel ? BoxShape.rectangle : BoxShape.circle,
                border: Border.all(color: chosen ? t.color('app-ink') : const Color(0x00000000), width: 2),
              ),
              child: Container(
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: bevel ? BoxShape.rectangle : BoxShape.circle,
                  color: fill,
                  border: bevel ? Border.all(color: DialupColors.of(t).dark) : null,
                ),
                child: chosen ? AppIcon(Lucide.check, size: 16, strokeWidth: 3, wash: false, color: fill.computeLuminance() > 0.45 ? const Color(0xFF000000) : const Color(0xFFFFFFFF)) : null,
              ),
            );
          },
        ),
    ]);
    if (!folded) return swatches;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      swatches,
      SizedBox(height: t.space(2)),
      Text('This look draws circles in its own colours. Everyone else sees the colour you pick.', style: pageText(t, t.fontSize('xs'), color: t.color('app-ink-3'))),
    ]);
  }
}

/// The circle icons as an even grid, each in the circle's hue, the chosen one filled.
class CircleIconPicker extends StatelessWidget {
  const CircleIconPicker({super.key, required this.hue, required this.value, required this.onChanged});
  final String hue;
  final String value;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final gap = t.space(2);
    return LayoutBuilder(builder: (context, box) {
      // Six across on a phone, more as there is room, every cell the same width.
      final across = ((box.maxWidth + gap) / (44 + gap)).floor().clamp(6, 12);
      final cell = (box.maxWidth - gap * (across - 1)) / across;
      return Wrap(spacing: gap, runSpacing: gap, children: [
        for (final name in circleIcons.keys)
          SizedBox(
            width: cell,
            child: Center(
              child: GlacierPressable(
                key: ValueKey('circle-icon-$name'),
                onPressed: () => onChanged(name),
                semanticLabel: '${name.replaceAll('-', ' ')}${name == value ? ', chosen' : ''}',
                builder: (context, _) => CircleFace(hue: hue, icon: name, size: cell.clamp(32.0, 44.0), selected: name == value),
              ),
            ),
          ),
      ]);
    });
  }
}

/// A space's kind as three big cards: its mark in its colour, its name and what it is for; the chosen one filled with
/// its colour's wash and ringed. Side by side where there is room, else one above another.
class SpaceKindCards extends StatelessWidget {
  const SpaceKindCards({super.key, required this.value, required this.onChanged, this.title = 'What it\'s for'});
  final SpaceKind value;
  final ValueChanged<SpaceKind> onChanged;

  /// Over the cards, drawn as a settings section's title is (in capitals; as written under Dial-Up); none if empty.
  final String title;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final size = t.lenOf('0.72rem');
    final cards = _cards(context);
    if (title.isEmpty) return cards;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      Padding(
        padding: EdgeInsetsDirectional.fromSTEB(t.space(2), 0, t.space(2), t.space(2)),
        child: Semantics(
          label: title,
          child: ExcludeSemantics(
            child: Text(isBevelChrome(t) ? title : title.toUpperCase(), style: pageText(t, size, weight: 'semibold', color: t.color('app-ink-3'), tracking: t.len('app-tracking-caps', em: size))),
          ),
        ),
      ),
      cards,
    ]);
  }

  Widget _cards(BuildContext context) {
    final t = context.tokens;
    return LayoutBuilder(builder: (context, box) {
      final across = box.maxWidth >= 540;
      final cards = [for (final k in spaceKindsOffered) _KindCard(kind: k, chosen: k == value, tall: across, onPress: () => onChanged(k))];
      if (across) {
        return IntrinsicHeight(
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            for (final (i, c) in cards.indexed) ...[if (i > 0) SizedBox(width: t.space(2)), Expanded(child: c)],
          ]),
        );
      }
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        for (final (i, c) in cards.indexed) ...[if (i > 0) SizedBox(height: t.space(2)), c],
      ]);
    });
  }
}

/// One kind's card: its mark, its name and what it is for.
class _KindCard extends StatelessWidget {
  const _KindCard({required this.kind, required this.chosen, required this.tall, required this.onPress});
  final SpaceKind kind;
  final bool chosen;

  /// One of three across: the mark above the words.
  final bool tall;
  final VoidCallback onPress;

  @override
  Widget build(BuildContext context) => GlacierPressable(
        key: ValueKey('space-kind-${kind.wire}'),
        onPressed: onPress,
        semanticLabel: '${spaceKindTitle(kind)}, ${spaceKindBlurb(kind)}${chosen ? ', chosen' : ''}',
        builder: (context, state) => GlacierScope(
          attrs: {'hue': SpaceKindBadge.hueOf(kind)},
          child: Builder(builder: (context) {
            final t = context.tokens;
            final bevel = isBevelChrome(t);
            final hue = settingsHue(t);
            final words = [
              Text(spaceKindTitle(kind), style: pageText(t, t.fontSize('md'), weight: 'bold', color: t.color('app-ink'))),
              SizedBox(height: t.space(1) / 2),
              Text(spaceKindBlurb(kind), style: pageText(t, t.fontSize('sm'), color: t.color('app-ink-2'), height: 1.35)),
            ];
            final tick = AppIcon(chosen ? Lucide.circleCheck : Lucide.circle, size: 20, wash: false, color: chosen ? hue : t.color('app-ink-4'));
            final inside = tall
                ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [SpaceKindBadge(kind: kind, size: 44, live: chosen), const Spacer(), tick]),
                    SizedBox(height: t.space(3)),
                    ...words,
                  ])
                : Row(children: [
                    SpaceKindBadge(kind: kind, size: 44, live: chosen),
                    SizedBox(width: t.space(3)),
                    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: words)),
                    SizedBox(width: t.space(2)),
                    tick,
                  ]);
            final pad = EdgeInsets.all(t.space(3) + 2);
            // Dial-Up: a raised card that is pressed in while chosen.
            if (bevel) return Bevel(style: chosen || state.pressed ? BevelStyle.sunken : BevelStyle.raised, color: chosen ? DialupColors.of(t).paper : null, padding: pad, child: inside);
            return AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              padding: pad,
              decoration: BoxDecoration(
                color: chosen ? settingsHueWash(t) : t.color(state.pressed ? 'app-paper-3' : 'app-paper-2'),
                borderRadius: BorderRadius.circular(t.radius('lg')),
                border: Border.all(color: chosen ? hue : t.color('app-rule'), width: chosen ? 2 : 1),
              ),
              child: inside,
            );
          }),
        ),
      );
}

/// A space as a small pill: its mark and name. The new circle's preview of its first spaces.
class _SpacePill extends StatelessWidget {
  const _SpacePill({required this.kind, required this.name});
  final SpaceKind kind;
  final String name;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Container(
      padding: EdgeInsetsDirectional.fromSTEB(t.space(1), t.space(1), t.space(3), t.space(1)),
      decoration: BoxDecoration(color: isBevelChrome(t) ? null : t.color('app-paper-2'), borderRadius: BorderRadius.circular(t.radius('full'))),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        SpaceKindBadge(kind: kind, size: 22),
        SizedBox(width: t.space(1) + 2),
        Text(name, style: pageText(t, t.fontSize('sm'), weight: 'medium', color: t.color('app-ink-2'))),
      ]),
    );
  }
}

/// A circle's picture, chosen or taken away: a row for each.
List<Widget> _pictureRows(BuildContext context, {required String? picture, required ValueChanged<String> onPicked, required VoidCallback onCleared}) => [
      SettingRow(
        key: const ValueKey('circle-picture'),
        icon: AppIcon(Lucide.imagePlus, size: 18),
        label: picture == null ? 'Choose a picture' : 'Change the picture',
        hint: const Tr('Shown in the icon\'s place'),
        onPress: () async {
          final p = await pickCirclePicture(context);
          if (p != null) onPicked(p);
        },
      ),
      if (picture != null) SettingRow(icon: AppIcon(Lucide.trash2, size: 18), label: 'Use the icon instead', onPress: onCleared),
    ];

/// One of a new circle's first spaces, before it is made.
class _Draft {
  _Draft(this.name, this.kind);
  String name;
  SpaceKind kind;
}

/// A new circle: its name, colour, icon or picture, previewed; its first spaces (a texting space and a voice space to
/// start, each to rename, retype or drop); and friends to bring, sent it the moment it is made.
class NewCircleScreen extends StatefulWidget {
  const NewCircleScreen({super.key, this.buddies, this.make, this.share});

  /// For a test: friends, and what makes and shares the circle (Circles' own otherwise).
  final Buddies? buddies;
  final Future<Circle?> Function({required String name, String? hue, String icon, String? picture, List<CircleSpace>? spaces})? make;
  final Future<List<Buddy>> Function(Circle circle, List<Buddy> friends)? share;

  @override
  State<NewCircleScreen> createState() => _NewCircleScreenState();
}

class _NewCircleScreenState extends State<NewCircleScreen> {
  final _name = TextEditingController();
  // The same colour each time the page opens (a random one made the page, and its pictures, differ run to run).
  String _hue = 'indigo';
  String _icon = 'users';
  String? _picture;
  // The two spaces a circle starts with (Circles.make's own): one to text in, one to talk in.
  final _spaces = [_Draft('General', SpaceKind.text), _Draft('Lounge', SpaceKind.voice)];
  // The ids of the friends ticked to bring.
  final Set<String> _with = {};
  bool _making = false;

  Buddies get _buddies => widget.buddies ?? Buddies.instance;

  @override
  void initState() {
    super.initState();
    _name.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  /// Makes the circle with its drafted spaces (one with no name goes by its kind's), shares it with the friends
  /// ticked, says how that went, and opens it.
  Future<void> _make() async {
    if (_making) return;
    setState(() => _making = true);
    final shell = AppShell.maybeOf(context);
    final make = widget.make ?? Circles.instance.make;
    final c = await make(
      name: _name.text,
      hue: _hue,
      icon: _icon,
      picture: _picture,
      spaces: [for (final (i, d) in _spaces.indexed) CircleSpace.make(d.name.trim().isEmpty ? spaceKindTitle(d.kind) : d.name.trim(), kind: d.kind, order: i)],
    );
    if (!mounted) return;
    if (c == null) {
      setState(() => _making = false);
      toast(context, 'Couldn\'t make the circle: the relay server isn\'t connected yet.', tone: GlacierToastTone.danger);
      return;
    }
    final friends = [for (final f in _buddies.friends) if (_with.contains(f.id)) f];
    final missed = friends.isEmpty ? const <Buddy>[] : await (widget.share ?? Circles.instance.share)(c, friends);
    if (!mounted) return;
    setState(() => _making = false);
    toast(context, friends.isEmpty ? '${c.name} made' : '${c.name} made and shared with ${friends.length - missed.length}${missed.isEmpty ? '' : '; couldn\'t reach ${missed.map((f) => f.shown).join(', ')}'}');
    if (shell != null) {
      shell.close();
      shell.openCircle(c);
    } else {
      Navigator.of(context).maybePop();
    }
  }

  /// A drafted space's menu: rename it, make it another kind, or leave it out.
  void _spaceMenu(_Draft d) {
    showChoices(context, title: '${d.name} · ${spaceKindTitle(d.kind)}', choices: [
      Choice('Rename', Lucide.pencil, () => askCircleWords(context, title: 'Rename ${d.name}', initial: d.name, then: (n) => setState(() => d.name = n))),
      for (final k in spaceKindsOffered)
        if (k != d.kind) Choice('Make it ${spaceKindTitle(k).toLowerCase()}', spaceKindIcon(k), () => setState(() => d.kind = k), hint: spaceKindBlurb(k)),
      Choice('Leave it out', Lucide.x, () => setState(() => _spaces.remove(d)), danger: true),
    ]);
  }

  void _addSpace() {
    showChoices(context, title: 'Add a space', choices: [
      for (final k in spaceKindsOffered) Choice(spaceKindTitle(k), spaceKindIcon(k), () => setState(() => _spaces.add(_Draft(_firstName(k), k))), hint: spaceKindBlurb(k)),
    ]);
  }

  /// The name a space added here starts with, by its kind.
  static String _firstName(SpaceKind k) => switch (k) {
        SpaceKind.voice => 'Voice',
        SpaceKind.text => 'Chat',
        SpaceKind.files => 'Files',
        SpaceKind.open => 'Open',
      };

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final name = _name.text.trim().isEmpty ? 'New circle' : _name.text.trim();
    final gap = SizedBox(height: t.space(5));
    return GhostPage(
      title: 'New circle',
      body: SettingsPaneScope(
        finder: SettingsFinder(),
        child: ListenableBuilder(
          listenable: _buddies,
          builder: (context, _) {
            final friends = _buddies.roomFriends;
            return _form([
                // The circle as it will look: its face, name and first spaces.
                Center(child: CircleFace(key: const ValueKey('new-circle-face'), hue: _hue, icon: _icon, picture: _picture, size: 76, selected: _picture == null)),
                SizedBox(height: t.space(2)),
                Text(name, textAlign: TextAlign.center, maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('xl'), weight: 'bold')),
                SizedBox(height: t.space(2)),
                Wrap(alignment: WrapAlignment.center, spacing: t.space(1) + 2, runSpacing: t.space(1) + 2, children: [for (final d in _spaces) _SpacePill(kind: d.kind, name: d.name)]),
                SizedBox(height: t.space(5)),
                PaneSection(title: 'Name', children: [
                  SettingRowBox(child: GlacierInput(controller: _name, placeholder: 'Circle name'.t, ariaLabel: 'Circle name', autoFocus: true, autoCapitalize: TextCapitalization.words, size: GlacierFieldSize.md)),
                ]),
                gap,
                PaneSection(title: 'Colour', children: [SettingRowBox(child: CircleHuePicker(value: _hue, onChanged: (h) => setState(() => _hue = h)))]),
                gap,
                PaneSection(title: 'Icon', children: [SettingRowBox(child: CircleIconPicker(hue: _hue, value: _icon, onChanged: (i) => setState(() => _icon = i)))]),
                gap,
                // Not in a browser, which can't choose a picture yet (Sms.browser).
                if (!Sms.browser) ...[
                  _hued('purple', PaneSection(title: 'Picture', description: const Tr('Optional: a picture of your own on the circle\'s face.'), children: _pictureRows(context, picture: _picture, onPicked: (p) => setState(() => _picture = p), onCleared: () => setState(() => _picture = null)))),
                  gap,
                ],
                PaneSection(
                  title: 'First spaces',
                  // A browser without Files spaces makes none (spaceKindsOffered), so it doesn't offer them here either.
                  description: Text(!Sms.filesHere ? 'Press one to rename it or change what it\'s for. You can add more any time.' : 'Press one to rename it or change what it\'s for. You can add more, files spaces too, any time.'),
                  children: [
                    for (final (i, d) in _spaces.indexed)
                      SettingRow(
                        key: ValueKey('new-circle-space-$i'),
                        icon: SpaceKindBadge(kind: d.kind, size: 26),
                        label: d.name,
                        hint: Text(spaceKindTitle(d.kind)),
                        onPress: () => _spaceMenu(d),
                      ),
                    _hued('green', SettingRow(key: const ValueKey('new-circle-add-space'), icon: AppIcon(Lucide.plus, size: 18), label: 'Add a space', onPress: _addSpace)),
                  ],
                ),
                gap,
                _hued('mint', PaneSection(
                  title: 'Bring friends',
                  description: Text(friends.isEmpty ? 'Add friends by username (Settings › Me › Friends) to bring them in one press. Anyone can join by the circle\'s link too.' : 'They\'re sent the circle as soon as it\'s made.'),
                  children: [
                    for (final f in friends)
                      SettingRow(
                        key: ValueKey('new-circle-friend-${f.id}'),
                        icon: AppIcon(Lucide.userRound, size: 18),
                        label: f.shown,
                        control: GlacierSwitch(checked: _with.contains(f.id), onCheckedChange: (on) => setState(() => on ? _with.add(f.id) : _with.remove(f.id)), ariaLabel: f.shown),
                      ),
                  ],
                )),
                gap,
                _hued('green', PaneSection(children: [
                  SettingRow(key: const ValueKey('circle-make'), icon: AppIcon(Lucide.check, size: 18), label: _making ? 'Making…' : 'Make the circle', onPress: _making ? null : _make),
                ])),
            ]);
          },
        ),
      ),
    );
  }
}

/// A new space in [circle]: its kind as three cards, its name, and a heading (those the circle has offered to tap).
class NewCircleSpaceScreen extends StatefulWidget {
  const NewCircleSpaceScreen({super.key, required this.circle, this.section});
  final Circle circle;
  final String? section;

  @override
  State<NewCircleSpaceScreen> createState() => _NewCircleSpaceScreenState();
}

class _NewCircleSpaceScreenState extends State<NewCircleSpaceScreen> {
  final _name = TextEditingController();
  late final _section = TextEditingController(text: widget.section ?? '');
  SpaceKind _kind = SpaceKind.text;
  bool _adding = false;

  /// An SMS space: people without the app are in it by text from this phone (lib/circles/sms_space.dart).
  bool _sms = false;

  /// Whether this device can text for a space: an Android phone, the phone's texting app being this one.
  static bool get _canText => !kIsWeb && PlatformInfo.isAndroid;

  @override
  void initState() {
    super.initState();
    _section.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _name.dispose();
    _section.dispose();
    super.dispose();
  }

  /// Adds the space to the circle as it stands now: by its kind's name where none is typed, and marked as an SMS
  /// space, texted for by this phone, where that was chosen and this phone can.
  Future<void> _add() async {
    if (_adding) return;
    setState(() => _adding = true);
    final circle = Circles.instance.bySeed(widget.circle.seed) ?? widget.circle;
    final me = SmsSpaces.instance.me;
    final sms = _sms && _kind == SpaceKind.text && _canText && me != null;
    final s = await Circles.instance.addSpace(circle, _name.text.trim().isEmpty ? (sms ? 'Texts' : spaceKindTitle(_kind)) : _name.text, kind: _kind, section: _section.text, extra: sms ? {'sms': {'by': me}} : const {});
    if (!mounted) return;
    setState(() => _adding = false);
    if (s == null) {
      toast(context, 'Couldn\'t add the space: only the circle\'s owner and admins can.', tone: GlacierToastTone.danger);
      return;
    }
    toast(context, '${s.name} added');
    Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final headings = <String>{for (final s in widget.circle.spaces) ?s.section};
    final gap = SizedBox(height: t.space(5));
    final typed = _section.text.trim();
    return GhostPage(
      title: 'New space',
      subtitle: widget.circle.name,
      titleLeading: TitleBarMark(icon: circleIconOf(widget.circle.icon), child: CircleFace.of(widget.circle, size: 18)),
      body: SettingsPaneScope(
        finder: SettingsFinder(),
        child: _form([
            SizedBox(height: t.space(2)),
            SpaceKindCards(value: _kind, onChanged: (k) => setState(() => _kind = k)),
            // A texting space may be an SMS space, texted for by this phone (Matt, 2026-11-19: "a special space in the
            // circle called a "SMS Space" to text members").
            if (_kind == SpaceKind.text && _canText) ...[
              gap,
              PaneSection(children: [
                SettingRow(
                  key: const ValueKey('new-space-sms'),
                  icon: AppIcon(Lucide.smartphone, size: 18),
                  label: 'SMS space',
                  hint: const Tr('People without the app are in it by text, sent from your phone and your number.'),
                  control: GlacierSwitch(checked: _sms, ariaLabel: 'SMS space', onCheckedChange: (v) => setState(() => _sms = v)),
                ),
              ]),
            ],
            gap,
            PaneSection(title: 'Name', children: [
              SettingRowBox(
                child: Row(children: [
                  SpaceKindBadge(kind: _kind, size: 28),
                  SizedBox(width: t.space(2)),
                  Expanded(child: GlacierInput(controller: _name, placeholder: 'Space name'.t, ariaLabel: 'Space name', autoCapitalize: TextCapitalization.words, size: GlacierFieldSize.md)),
                ]),
              ),
            ]),
            gap,
            PaneSection(
              title: 'Heading',
              description: const Tr('Spaces with the same heading are listed together. Leave it empty for none.'),
              children: [
                SettingRowBox(child: GlacierInput(controller: _section, placeholder: 'No heading'.t, ariaLabel: 'Heading', autoCapitalize: TextCapitalization.words, size: GlacierFieldSize.md)),
                if (headings.isNotEmpty)
                  SettingRowBox(
                    child: Wrap(spacing: t.space(2), runSpacing: t.space(2), children: [
                      for (final h in headings)
                        GlacierPressable(
                          key: ValueKey('space-heading-$h'),
                          onPressed: () => _section.text = h,
                          semanticLabel: 'Under $h${typed == h ? ', chosen' : ''}',
                          builder: (context, state) => Container(
                            padding: EdgeInsets.symmetric(horizontal: t.space(3), vertical: t.space(1)),
                            decoration: BoxDecoration(
                              color: typed == h ? t.color('app-ink') : t.color(state.pressed ? 'app-paper-3' : 'app-paper'),
                              borderRadius: BorderRadius.circular(isBevelChrome(t) ? 0 : t.radius('full')),
                              border: Border.all(color: t.color('app-rule')),
                            ),
                            child: Text(h, style: pageText(t, t.fontSize('sm'), weight: 'medium', color: typed == h ? t.color('app-paper') : t.color('app-ink-2'))),
                          ),
                        ),
                    ]),
                  ),
              ],
            ),
            gap,
            _hued('green', PaneSection(children: [
              SettingRow(key: const ValueKey('circle-space-add'), icon: AppIcon(Lucide.plus, size: 18), label: _adding ? 'Adding…' : 'Add the space', onPress: _adding ? null : _add),
            ])),
        ]),
      ),
    );
  }
}

/// Someone in a circle, as its settings list them.
@immutable
class CirclePerson {
  const CirclePerson({required this.id, required this.name, this.owner = false, this.admin = false, this.here = false, this.me = false, this.hue});
  final String id;
  final String name;
  final bool owner, admin;

  /// Their name's colour: their highest role's that has one (CircleManifest.nameHueOf); null for none.
  final String? hue;

  /// In the circle's room, or one of its spaces, now.
  final bool here;

  /// This install.
  final bool me;

  String get role => owner ? 'Owner' : (admin ? 'Admin' : 'Member');
}

/// Everyone [c] knows of: its owner and admins, whoever is in its room or one of its spaces now, and whoever has
/// written in its spaces; each by the name they last gave, owner first, then admins, then the rest by name. A circle
/// keeps no list of members (holding its link is being in it), so this is who has been seen.
List<CirclePerson> circlePeople(Circle c) {
  final voice = Voice.instance;
  final me = Circles.instance.signer?.id ?? voice.me;
  final m = c.manifest;
  final ids = <String>{if (m.ownerId.isNotEmpty) m.ownerId, for (final id in m.adminGrants.keys) if (m.granted(id)) id};
  final here = <String>{...Circles.instance.presentIn(c)};
  final names = <String, String>{};
  for (final ch in c.channels) {
    final room = voice.hangoutFor(ch);
    if (room == null) continue;
    for (final p in room.present.values) {
      here.add(p.id);
      if (p.name.isNotEmpty) names[p.id] = p.name;
    }
    for (final msg in room.messages) {
      ids.add(msg.from);
      if (msg.name.isNotEmpty) names.putIfAbsent(msg.from, () => msg.name);
    }
  }
  // Whoever added a file to one of its Files spaces, as far as this device has the list (Matt, 2026-11-18: members
  // posting files were not listed).
  final files = FilesStore.instance;
  for (final ch in c.channels) {
    if (ch.kind != SpaceKind.files) continue;
    final s = files.of(ch);
    if (!s.ready) continue;
    for (final f in s.files.values) {
      ids.add(f.by);
      if (f.byName.isNotEmpty) names.putIfAbsent(f.by, () => f.byName);
    }
  }
  ids.addAll(here);
  // A device's id from before it spoke as its identity is that identity (Circles.sameAs; Matt, 2026-11-19: every
  // computer had been "a new matt"): one person, not two.
  final circles = Circles.instance;
  // The owner's own id stays its own: the row says Owner only where that one is, as the powers go by it.
  String same(String id) => id == m.ownerId ? id : circles.sameAs(id);
  for (final e in [...names.entries]) {
    if (same(e.key) != e.key) names.putIfAbsent(same(e.key), () => e.value);
  }
  final folded = {for (final id in ids) same(id)};
  final hereNow = {for (final id in here) same(id)};
  // And everyone seen in it before, kept on this device: still members once they have gone.
  circles.noteSeen(c, {for (final id in folded) if (id != me) id: names[id] ?? ''});
  for (final e in circles.seenIn(c).entries) {
    folded.add(same(e.key));
    if (e.value.isNotEmpty) names.putIfAbsent(same(e.key), () => e.value);
  }
  if (me != null && me.isNotEmpty) folded.add(me);
  // Put out by its owner or an admin: no longer among its members (Circles.removeMember).
  folded.removeAll(m.removed);
  final ownerNow = m.ownerId;
  String nameOf(String id) {
    if (id == me) return 'You';
    final said = names[id];
    if (said != null) return said;
    final known = voice.nameOf(id);
    return known == 'Someone' ? 'Someone (${id.length > 6 ? id.substring(0, 6) : id})' : known;
  }

  final people = [
    for (final id in folded)
      if (id.isNotEmpty) CirclePerson(id: id, name: nameOf(id), owner: id == ownerNow, admin: id != ownerNow && m.granted(id), here: id == me || hereNow.contains(id), me: id == me, hue: m.nameHueOf(id)),
  ];
  // As the roles stand (Matt, 2026-11-18: "permission hierarchy"): the owner, admins made by hand, then by each one's
  // highest role, then everyone else; by name within each.
  final rank = {for (final p in people) p.id: m.rankOf(p.id)};
  people.sort((a, b) => rank[a.id] != rank[b.id] ? rank[a.id]! - rank[b.id]! : a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  return people;
}

/// What the owner can do with someone in their circle, from its settings or its members drawer: make them an admin,
/// or take it back.
List<Choice> circlePersonChoices(BuildContext context, Circle c, CirclePerson p) {
  // Their profile card, with what can be done with them in this circle under it (Matt, 2026-11-19: "clicking on a member
  // in the member list should also show the users profile popup with linked numbers, and other details in addition to
  // things like changing the role").
  final circles = Circles.instance;
  final m = (circles.bySeed(c.seed) ?? c).manifest;
  final me = circles.signer?.id ?? '';
  void said(bool ok, String done) {
    if (context.mounted) toast(context, ok ? done : 'Couldn\'t change that for ${p.name}', tone: ok ? GlacierToastTone.neutral : GlacierToastTone.danger);
  }

  final roles = [for (final r in m.roles) if (circles.mayManageRole(c, r.id)) r];
  final theirs = {for (final r in m.rolesOf(p.id)) r.id};
  final more = <Choice>[
    if (!p.me && !p.owner)
      for (final r in roles)
        theirs.contains(r.id)
            ? Choice('Take away ${r.name}', Lucide.userMinus, () async => said(await circles.setRolesOf(c, p.id, [...theirs.where((x) => x != r.id)]), '${p.name} no longer has ${r.name}'))
            : Choice('Give ${r.name}', Lucide.userPlus, () async => said(await circles.setRolesOf(c, p.id, [...theirs, r.id]), '${p.name} has ${r.name}')),
    if (!p.me && !p.owner && me == m.ownerId)
      p.admin
          ? Choice('Remove as admin', Lucide.userMinus, () async => said(await circles.grantAdmin(c, p.id, on: false), '${p.name} is no longer an admin'))
          : Choice('Make admin', Lucide.shieldCheck, () async => said(await circles.grantAdmin(c, p.id), '${p.name} is an admin'), hint: 'Can change the circle and its spaces'),
    // Kick or ban (Matt, 2026-11-20: "I can't seem to kick users or ban them from circles"): a kick puts them out now
    // and they may come back by an invite; a ban keeps them out and nobody here hears them.
    if (m.mayRemove(me, p.id)) ...circleKickBanChoices(context, c, p, said),
  ];
  return more;
}

/// Kick and Ban for [p] in [c], each asked first; [said] tells how it went.
List<Choice> circleKickBanChoices(BuildContext context, Circle c, CirclePerson p, void Function(bool ok, String done) said) {
  final circles = Circles.instance;
  final name = (circles.bySeed(c.seed) ?? c).manifest.name;
  return [
    Choice('Kick from $name', Lucide.logOut, danger: true, hint: 'They leave now, and can come back if invited again', () {
      showChoices(context, title: 'Kick ${p.name} from $name? They leave now, and can come back if someone invites them again.', choices: [
        Choice('Kick ${p.name}', Lucide.logOut, danger: true, () async => said(await circles.kickMember(c, p.id), '${p.name} was kicked')),
      ]);
    }),
    Choice('Ban from $name', Lucide.ban, danger: true, hint: 'They leave and can\'t come back; nobody here hears them', () {
      showChoices(context, title: 'Ban ${p.name} from $name? They leave and can\'t come back, and nobody here hears them, until they\'re unbanned in Circle settings › Members.', choices: [
        Choice('Ban ${p.name}', Lucide.ban, danger: true, () async => said(await circles.removeMember(c, p.id), '${p.name} was banned')),
      ]);
    }),
  ];
}

/// [p]'s profile card from a circle's members, with what this device may change about them there ([circlePersonChoices]).
void circlePersonMenu(BuildContext context, Circle c, CirclePerson p) {
  final m = (Circles.instance.bySeed(c.seed) ?? c).manifest;
  final roles = [for (final r in m.rolesOf(p.id)) r.name];
  final detail = [p.me ? 'You' : p.role, if (roles.isNotEmpty) roles.join(', '), p.here ? 'On now' : 'Away'].join(' · ');
  showProfile(context, ProfileSubject.ghost(id: p.id, name: p.name, detail: detail), more: circlePersonChoices(context, c, p));
}

/// A person's role in a circle in words, where a row asks which: a green dot before it while they are on, and the
/// owner's or an admin's word in the admins' colour; a member says nothing (Matt, 2026-11-17: "Don't show the badges for
/// owner moderator etc, instead assign role colors like discord does"; 2026-11-18: "Remove the crown icon just use role
/// colors for members and such").
class CircleRoleTag extends StatelessWidget {
  const CircleRoleTag({super.key, required this.person});
  final CirclePerson person;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      if (person.here) ...[
        Container(width: 7, height: 7, decoration: BoxDecoration(shape: BoxShape.circle, color: t.online)),
        SizedBox(width: t.space(2)),
      ],
      if (person.owner || person.admin) Text(person.owner ? 'Owner' : person.role, style: pageText(t, t.fontSize('sm'), weight: 'semibold', color: circleRoleInk(t, person))),
    ]);
  }
}

/// The colour a circle member's name is drawn in: their highest coloured role's, as Discord does (Matt, 2026-11-18:
/// "closer to discord server settings"); with none, the owner's and admins' red, as a space's admins
/// (Role.defaultColor); null for a member with neither, the text's own.
Color? circleRoleInk(Tokens t, CirclePerson p) => p.hue != null ? circleHueInk(t, p.hue!) : (p.owner || p.admin ? t.colorOf(Role.defaultColor(Role.admin)!) : null);

/// A circle hue as words are drawn in it on this page: the look's own reading of it, as a settings row's icon.
Color circleHueInk(Tokens t, String hue) => settingsHue(t.child(attrs: {'hue': hue}));

/// A circle's settings: the full-screen page with its own sidebar (lib/ui/circles/circle_settings.dart; Matt,
/// 2026-11-17: "manage roles users etc and other basic circle settings with a full screen sidebar and main page
/// settings"). Kept by this name for whoever opens it.
class CircleSettingsScreen extends StatelessWidget {
  const CircleSettingsScreen({super.key, required this.seed, this.qr = false});
  final String seed;

  /// Opened on the invite link with the QR code showing (a picture of it).
  final bool qr;

  @override
  Widget build(BuildContext context) => CircleSettingsPage(seed: seed, qr: qr, section: qr ? CircleSettingsSection.invite : CircleSettingsSection.overview);
}

/// Asks for a line of words (a name, a heading), then gives it to [then].
void askCircleWords(BuildContext context, {required String title, String initial = '', String? hint, required void Function(String words) then}) {
  unawaited(push<void>(context, (_) => _WordsPage(title: title, initial: initial, hint: hint, then: then)));
}

/// The page [askCircleWords] opens: one field and Done. With a [hint], leaving it empty is an answer too.
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
  void dispose() {
    _words.dispose();
    super.dispose();
  }

  void _done() {
    // Empty is an answer only where it means something ("no heading").
    if (_words.text.trim().isEmpty && widget.hint == null) return;
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
              SettingRowBox(child: GlacierInput(controller: _words, ariaLabel: widget.title, autoFocus: true, autoCapitalize: TextCapitalization.words, size: GlacierFieldSize.md, onSubmitted: (_) => _done())),
            ],
          ),
          SizedBox(height: t.space(4)),
          PaneSection(children: [SettingRow(key: const ValueKey('words-save'), icon: AppIcon(Lucide.check, size: 18), label: 'Save', onPress: _done)]),
        ],
      ),
    );
  }
}
