/// Settings › Appearance › Make your own look (GMFB-41, from the Uplink gap review: "Customization: custom CSS-style
/// themes"): four colours, light or dark, and a name, seen as they are changed, then kept and used. Shared as a short
/// code, and taken in from one pasted (lib/custom_theme.dart refuses anything that is not a look's colours and name).
/// A look can draw in one of the app's own faces, and is kept as a .ghostlook file, with the custom CSS in use, and
/// taken in from one (lib/look_file.dart).
library;

import 'dart:async';
import 'dart:convert' show utf8;
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../app_state.dart';
import '../art/app_icon.dart';
import '../art/lucide.g.dart';
import '../custom_css.dart';
import '../custom_theme.dart';
import '../export_chat.dart' show writeExport;
import '../files/file_platform.dart';
import '../look_file.dart';
import '../kit/settings_kit.dart';
import '../kit/settings_type.dart';
import 'common.dart';
import '../l10n/words.dart';

Widget _icon(LucideIcon icon) => AppIcon(icon, size: 18);

/// A look of one's own drawn small from its four colours: its page, a bubble from someone else on the surface's
/// colour, and one of yours in the accent. Drawn straight from the colours, so the editor's preview follows each
/// change at once.
class CustomThemePreview extends StatelessWidget {
  const CustomThemePreview({super.key, required this.theme, this.width, this.large = false});
  final CustomTheme theme;
  final double? width;

  /// The editor's: taller, with a line of words on the page too.
  final bool large;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final size = large ? t.fontSize('sm') : t.fontSize('xs');
    // In its own face, where it has one: the face is the page's only once the look is in use.
    final family = CustomTheme.fontFamilies[theme.font];
    final words = family == null ? t.textAt(size, color: theme.ink) : t.textAt(size, color: theme.ink).copyWith(fontFamily: family);
    final strut = StrutStyle(fontSize: size, height: 1.25, forceStrutHeight: true);
    Widget line(String text, {required bool out}) => Align(
          alignment: out ? AlignmentDirectional.centerEnd : AlignmentDirectional.centerStart,
          child: Container(
            padding: EdgeInsets.symmetric(horizontal: t.space(large ? 3 : 1) + 2, vertical: t.space(large ? 2 : 1)),
            decoration: BoxDecoration(color: out ? theme.accent : theme.surface, borderRadius: BorderRadius.circular(t.radius(large ? 'lg' : 'md'))),
            child: Text(text, maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis, strutStyle: strut, style: out ? words.copyWith(color: theme.onAccent) : words),
          ),
        );
    return Container(
      width: width,
      padding: EdgeInsets.all(large ? t.space(4) : t.space(1) + 2),
      color: theme.paper,
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (large) ...[
          Text(theme.name.trim().isEmpty ? 'Your own look' : theme.name.trim(), maxLines: 1, overflow: TextOverflow.ellipsis, style: t.textAt(t.fontSize('md'), weight: 'semibold', color: theme.ink).copyWith(fontFamily: family)),
          SizedBox(height: t.space(3)),
          line('Are we still on for Friday?', out: false),
          SizedBox(height: t.space(2)),
          line('Yes! See you at 7', out: true),
        ] else ...[
          line('Free?', out: false),
          SizedBox(height: t.space(1)),
          line('Yes!', out: true),
        ],
      ]),
    );
  }
}

/// Copies [theme]'s code, to paste to anyone.
void shareTheme(BuildContext context, CustomTheme theme) {
  Clipboard.setData(ClipboardData(text: theme.code));
  toast(context, 'Copied ${theme.name}\'s code. Whoever you send it to pastes it in Settings › Appearance.');
}

/// Takes in a look from a code copied: shown in the editor first, to keep or leave. Said plainly where what was copied
/// is not a look's code.
Future<void> pasteTheme(BuildContext context, AppState app) async {
  final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text ?? '';
  if (!context.mounted) return;
  final theme = CustomTheme.decode(text);
  if (theme == null) {
    toast(context, text.trim().isEmpty ? 'Copy a look\'s code first, then paste it here' : 'That isn\'t a look\'s code. A code starts GT1 or GT2.', tone: GlacierToastTone.danger);
    return;
  }
  await push<void>(context, (_) => CustomThemeEditor(app: app, start: theme, pasted: true));
}

// --- a look as a file (lib/look_file.dart) -----------------------------------------------------------------------

/// Whether looks can be saved to files and taken in from them here: a computer's app and the Android phone's, which
/// save and choose files (lib/files/file_platform.dart). Not a browser's tab, which keeps no file of its own to hand
/// to Save, nor an iPhone's, which has no Save yet.
bool get lookFilesHere => !kIsWeb && FilePlatform.canSave && FilePlatform.canPick;

/// Saves [theme] to a .ghostlook where the person says, with the custom CSS in use if there is any ([CustomCss.used]).
Future<void> exportLook(BuildContext context, AppState app, CustomTheme theme) async {
  if (!lookFilesHere) {
    toast(context, 'This device can\'t save files yet');
    return;
  }
  final css = CustomCss.used(app);
  final name = LookFile.fileName(theme);
  try {
    final path = await writeExport(LookFile.write(theme, css: css), name);
    final done = await FilePlatform.save(path, name, 'application/json');
    if (context.mounted && done != null) toast(context, '$done: ${theme.name}${css.trim().isEmpty ? '' : ', with your custom CSS'}');
  } catch (e) {
    if (context.mounted) toast(context, 'Couldn\'t save the look: $e', tone: GlacierToastTone.danger);
  }
}

/// The text of the file at [path], where it is no larger than a look's file can be; null where it is larger.
Future<String?> readLookText(String path) async {
  final bytes = <int>[];
  await for (final piece in File(path).openRead(0, LookFile.mostBytes + 1)) {
    bytes.addAll(piece);
  }
  if (bytes.length > LookFile.mostBytes) return null;
  return utf8.decode(bytes, allowMalformed: true);
}

/// Takes in a look from a .ghostlook chosen with the device's picker: shown in the editor first, to keep or leave, as
/// a pasted code's is. Where it came with CSS, asked first whether that is taken too (it takes the place of the
/// person's own). Said plainly where the file is not a look.
Future<void> importLook(BuildContext context, AppState app) async {
  if (!lookFilesHere) {
    toast(context, 'This device can\'t open files yet');
    return;
  }
  String? text;
  try {
    final picked = await FilePlatform.pick();
    if (picked.isEmpty) return;
    try {
      text = await readLookText(picked.first.path);
    } finally {
      // A phone's picked copy is the app's own, and goes once read.
      for (final p in picked) {
        if (p.owned) {
          try {
            await File(p.path).delete();
          } catch (_) {}
        }
      }
    }
  } catch (e) {
    if (context.mounted) toast(context, 'Couldn\'t open the file: $e', tone: GlacierToastTone.danger);
    return;
  }
  if (!context.mounted) return;
  if (text == null) {
    toast(context, 'That file is too large to be a look', tone: GlacierToastTone.danger);
    return;
  }
  await takeLookFile(context, app, text);
}

/// Takes in the look in a file's [text]: what [importLook] does once the file is read.
Future<void> takeLookFile(BuildContext context, AppState app, String text) async {
  final read = LookFile.read(text);
  final look = read.file;
  if (look == null) {
    toast(context, read.problem ?? 'That file isn\'t a look', tone: GlacierToastTone.danger);
    return;
  }
  for (final p in look.passedOver) {
    toast(context, p);
  }
  Future<void> open(String? css) => push<void>(context, (_) => CustomThemeEditor(app: app, start: look.theme, pasted: true, css: css));
  final css = look.css;
  if (css == null) return open(null);
  final mine = CustomCss.text(app).trim().isNotEmpty;
  await showChoices(context, title: '${look.theme.name} comes with custom CSS', choices: [
    Choice('Use its CSS too', Lucide.braces, () => unawaited(open(css)), hint: mine ? 'It takes the place of your own custom CSS.' : 'Its styles go over the look, as in Custom CSS.'),
    Choice('Only its colours and font', Lucide.palette, () => unawaited(open(null)), hint: mine ? 'Your own custom CSS stays as it is.' : null),
  ]);
}

/// What a look of one's own offers when pressed while it is in use: change it, share it, remove it.
void themeMenu(BuildContext context, AppState app, CustomTheme theme) => showChoices(context, title: theme.name, choices: [
      Choice('Edit', Lucide.pencil, () => push<void>(context, (_) => CustomThemeEditor(app: app, start: theme, replacing: theme))),
      Choice('Copy its code to share', Lucide.share2, () => shareTheme(context, theme)),
      if (lookFilesHere) Choice('Save it to a file', Lucide.hardDriveDownload, () => unawaited(exportLook(context, app, theme))),
      Choice('Remove', Lucide.trash2, () {
        CustomTheme.remove(app, theme);
        toast(context, '${theme.name} removed');
      }),
    ]);

/// The four colours, each with what it colours.
enum _Part {
  paper('Background', 'The page behind everything'),
  surface('Surface', 'Cards, fields and other people\'s bubbles'),
  ink('Text', 'The words'),
  accent('Accent', 'Your bubbles, Send and what is chosen');

  const _Part(this.label, this.hint);
  final String label, hint;
}

/// Making a look, or changing one ([replacing]); [start] is where it begins: the colours on the screen now for a new
/// one, a code's or a file's for one [pasted]. [css]: the custom CSS a file brought, taken with the look when it is
/// kept.
class CustomThemeEditor extends StatefulWidget {
  const CustomThemeEditor({super.key, required this.app, this.start, this.replacing, this.pasted = false, this.css});
  final AppState app;
  final CustomTheme? start;
  final CustomTheme? replacing;
  final bool pasted;
  final String? css;

  @override
  State<CustomThemeEditor> createState() => _CustomThemeEditorState();
}

class _CustomThemeEditorState extends State<CustomThemeEditor> {
  CustomTheme? _theme;
  late final TextEditingController _name = TextEditingController(text: widget.start?.name ?? '')..addListener(_named);

  /// The colour whose mixer is open, if any.
  _Part? _open;

  /// The name typed goes into the look, so the preview's heading and the problem line follow it.
  void _named() => setState(() => _theme = _theme?.copyWith(name: _name.text));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // A new look starts from the colours on the screen now.
    if (_theme == null) {
      final t = context.tokens;
      _theme = widget.start ??
          CustomTheme(name: '', dark: t.isDark, paper: t.color('app-paper'), surface: t.color('app-paper-2'), ink: t.color('app-ink'), accent: t.color('app-accent'));
    }
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Color _of(CustomTheme theme, _Part p) => switch (p) { _Part.paper => theme.paper, _Part.surface => theme.surface, _Part.ink => theme.ink, _Part.accent => theme.accent };

  /// Sets one colour from the mixer's "#RRGGBB"; anything else is left alone. Always opaque.
  void _set(_Part p, String text) {
    final h = text.replaceFirst('#', '');
    final v = int.tryParse(h, radix: 16);
    if (h.length != 6 || v == null) return;
    final c = Color(0xFF000000 | v);
    setState(() => _theme = switch (p) {
          _Part.paper => _theme!.copyWith(paper: c),
          _Part.surface => _theme!.copyWith(surface: c),
          _Part.ink => _theme!.copyWith(ink: c),
          _Part.accent => _theme!.copyWith(accent: c),
        });
  }

  /// Keeps the look (in [CustomThemeEditor.replacing]'s place when editing) and goes back. Nothing while the look has
  /// a problem.
  void _save() {
    final theme = _theme!.copyWith(name: _name.text.trim());
    if (theme.problem != null) return;
    CustomTheme.save(widget.app, theme, replacing: widget.replacing);
    final css = widget.css;
    if (css != null) CustomCss.save(widget.app, css, on: true);
    toast(context, css != null ? '${theme.name} and its CSS are your look now' : '${theme.name} is your look now');
    Navigator.of(context).maybePop();
  }

  /// Colours to start from, the same for every part: the page's whites and blacks and a few clear hues.
  static const _presets = ['#FFFFFF', '#F4F1EA', '#E8EEF7', '#1E1F24', '#0B0B0C', '#101A2B', '#0C7F7A', '#4F5BD5', '#C2410C', '#BE185D', '#15803D', '#E5A152'];

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final theme = _theme!;
    final problem = theme.problem;
    final editing = widget.replacing != null;
    return GhostPage(
      title: editing ? 'Edit ${widget.replacing!.name}' : (widget.pasted ? 'A look someone shared' : 'Make your own look'),
      body: SettingsPaneScope(
        finder: SettingsFinder(),
        child: ListView(
          padding: EdgeInsetsDirectional.fromSTEB(t.space(4), t.space(2), t.space(4), t.space(8)),
          children: [
            PaneSection(
              description: Text(widget.pasted
                  ? 'This is how it looks. Keep it to use it; you can change it first.${widget.css != null ? ' Its custom CSS is used with it once kept.' : ''}'
                  : 'Choose four colours and a font, and see them here as you go.'),
              children: [
                SettingRowBox(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(t.radius('lg')),
                    child: CustomThemePreview(key: const ValueKey('custom-theme-preview'), theme: theme, large: true),
                  ),
                ),
              ],
            ),
            SizedBox(height: t.space(5)),
            PaneSection(title: 'Name', children: [
              SettingRowBox(
                child: GlacierInput(
                  key: const ValueKey('custom-theme-name'),
                  controller: _name,
                  placeholder: 'What to call it'.t,
                  ariaLabel: 'Name',
                  autoCapitalize: TextCapitalization.words,
                  maxLength: CustomTheme.nameMost,
                ),
              ),
            ]),
            SizedBox(height: t.space(5)),
            PaneSection(
              title: 'Colours',
              footer: problem == null || problem == 'Give it a name' ? null : Text(problem, key: const ValueKey('custom-theme-problem'), style: TextStyle(color: t.colorOf('#c27c0e'))),
              children: [
                SettingRow(
                  icon: _icon(Lucide.sunMoon),
                  label: 'Brightness',
                  layout: SettingRowLayout.stacked,
                  control: GlacierSegmentedControl(
                    fullWidth: true,
                    value: theme.dark ? 'dark' : 'light',
                    onValueChange: (v) => setState(() => _theme = theme.copyWith(dark: v == 'dark')),
                    options: const [
                      GlacierSegmentedOption(value: 'light', label: Tr('Light')),
                      GlacierSegmentedOption(value: 'dark', label: Tr('Dark')),
                    ],
                  ),
                ),
                // A face of the app's own (GMFB-41, "colours and fonts"): every one is bundled, so nothing is downloaded.
                SettingRow(
                  key: const ValueKey('custom-theme-font'),
                  icon: _icon(Lucide.type),
                  label: 'Font',
                  layout: SettingRowLayout.stacked,
                  control: GlacierSegmentedControl(
                    fullWidth: true,
                    value: theme.font ?? 'app',
                    onValueChange: (v) => setState(() => _theme = theme.copyWith(font: v == 'app' ? null : v)),
                    options: [
                      const GlacierSegmentedOption(value: 'app', label: Tr('Standard')),
                      for (final f in CustomTheme.fonts.entries) GlacierSegmentedOption(value: f.key, label: Text(f.value)),
                    ],
                  ),
                ),
                for (final p in _Part.values) ...[
                  SettingRow(
                    key: ValueKey('custom-theme-${p.name}'),
                    label: p.label,
                    hint: Text(p.hint),
                    value: Row(mainAxisSize: MainAxisSize.min, children: [
                      Text(hex(_of(theme, p)), style: pageText(t, t.fontSize('sm'), color: t.color('app-ink-2'), mono: true)),
                      SizedBox(width: t.space(2)),
                      Container(
                        width: 22,
                        height: 22,
                        decoration: BoxDecoration(color: _of(theme, p), shape: BoxShape.circle, border: Border.all(color: t.color('app-rule'))),
                      ),
                    ]),
                    onPress: () => setState(() => _open = _open == p ? null : p),
                  ),
                  if (_open == p)
                    SettingRowBox(
                      child: GlacierColorPicker(
                        key: ValueKey('custom-theme-picker-${p.name}'),
                        value: hex(_of(theme, p)),
                        presets: _presets,
                        onValueChange: (h) => _set(p, h),
                      ),
                    ),
                ],
              ],
            ),
            SizedBox(height: t.space(5)),
            PaneSection(children: [
              SettingRow(
                key: const ValueKey('custom-theme-save'),
                icon: _icon(Lucide.check),
                label: editing ? 'Save and use it' : 'Keep it and use it',
                disabled: problem != null,
                disabledReason: problem,
                onPress: _save,
              ),
              if (problem == null) SettingRow(icon: _icon(Lucide.share2), label: 'Copy its code to share', onPress: () => shareTheme(context, theme.copyWith(name: _name.text.trim()))),
              if (problem == null && lookFilesHere)
                SettingRow(
                  key: const ValueKey('custom-theme-export'),
                  icon: _icon(Lucide.hardDriveDownload),
                  label: 'Save it to a file',
                  hint: Text(CustomCss.used(widget.app).trim().isEmpty ? 'A .ghostlook anyone can open in Appearance' : 'A .ghostlook, with your custom CSS'),
                  onPress: () => unawaited(exportLook(context, widget.app, theme.copyWith(name: _name.text.trim()))),
                ),
              if (editing)
                SettingRow(
                  icon: _icon(Lucide.trash2),
                  label: 'Remove it',
                  onPress: () {
                    CustomTheme.remove(widget.app, widget.replacing!);
                    toast(context, '${widget.replacing!.name} removed');
                    Navigator.of(context).maybePop();
                  },
                ),
            ]),
          ],
        ),
      ),
    );
  }
}
