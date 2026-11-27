/// Settings › Appearance › Custom CSS (GMFB-41; Matt, 2026-11-25: "where can I find the css custom styles if I
/// search css or styles i don't see anything in settings"): a box to write CSS of one's own in, laid over the look in
/// use. What it can change and what keeps it from breaking the app are in lib/custom_css.dart.
library;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../app_state.dart';
import '../art/app_icon.dart';
import '../art/lucide.g.dart';
import '../custom_css.dart';
import '../kit/semantic_colors.dart';
import '../kit/settings_kit.dart';
import '../kit/settings_type.dart';
import 'common.dart';
import '../l10n/words.dart';

Widget _icon(LucideIcon icon) => AppIcon(icon, size: 18);

/// Something to start from: the accent, the corners and the dark page, with the way to write for one theme.
const customCssExample = '''/* Variables are what the app reads. Set them on :root. */
:root {
  --app-accent: #ff5c8a;
  --app-on-accent: #ffffff;
  --glacier-radius-md: 4px;
}

/* Only on the dark page. */
:root[data-theme='dark'] {
  --app-paper: #101418;
}
''';

class CustomCssEditor extends StatefulWidget {
  const CustomCssEditor({super.key, required this.app});
  final AppState app;

  @override
  State<CustomCssEditor> createState() => _CustomCssEditorState();
}

class _CustomCssEditorState extends State<CustomCssEditor> {
  late final TextEditingController _text = TextEditingController(text: CustomCss.text(widget.app))..addListener(() => setState(() {}));
  final FocusNode _focus = FocusNode();

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// Whether what is in the box is what is kept.
  bool get _changed => _text.text != CustomCss.text(widget.app);

  /// Keeps what is written and uses it. The app's sheet is made with it as the page is built again, and what could
  /// not be used is listed under the box then.
  void _apply() {
    CustomCss.save(widget.app, _text.text, on: true);
    _focus.unfocus();
    setState(() {});
  }

  /// Every property the stylesheets name with its value on this page, as a rule to paste and cut down.
  void _copyVariables() {
    final t = context.tokens;
    final b = StringBuffer(':root {\n');
    for (final name in CustomCss.known) {
      final value = t.raw(name);
      if (value != null && value.isNotEmpty) b.writeln('  $name: $value;');
    }
    b.writeln('}');
    Clipboard.setData(ClipboardData(text: b.toString()));
    toast(context, 'Copied ${CustomCss.known.length} variables with their values on this page');
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final app = widget.app;
    final on = CustomCss.on(app);
    // Made as the app above this page was built with what is kept: null while none is in use.
    final result = on && !_changed ? CustomCss.last : null;
    final mono = pageText(t, t.fontSize('sm'), color: t.color('app-ink'), mono: true, height: 1.45);
    return GhostPage(
      title: 'Custom CSS',
      body: SettingsPaneScope(
        finder: SettingsFinder(),
        child: ListView(
          padding: EdgeInsetsDirectional.fromSTEB(t.space(4), t.space(2), t.space(4), t.space(8)),
          children: [
            PaneSection(
              description: const Tr(
                'Write your own styles over the look you use. The app reads CSS variables, such as --app-accent, set on :root. Anything that would stop the app being drawn or read is left out and listed below.',
              ),
              children: [
                SettingRow(
                  key: const ValueKey('custom-css-on'),
                  icon: _icon(Lucide.braces),
                  label: 'Use my CSS',
                  hint: const Tr('Kept on this device'),
                  control: GlacierSwitch(checked: on, onCheckedChange: (v) => CustomCss.save(app, CustomCss.text(app), on: v), ariaLabel: 'Use my CSS'),
                ),
              ],
            ),
            SizedBox(height: t.space(5)),
            PaneSection(
              title: 'Your CSS',
              footer: result == null
                  ? null
                  : Text(
                      result.kept == 0 ? 'Nothing here is in use.' : '${result.kept} ${result.kept == 1 ? 'value is' : 'values are'} in use.',
                      key: const ValueKey('custom-css-kept'),
                    ),
              children: [
                SettingRowBox(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: _focus.requestFocus,
                    child: Stack(children: [
                      if (_text.text.isEmpty) IgnorePointer(child: Tr(':root { --app-accent: #ff5c8a; }', style: mono.copyWith(color: t.color('app-ink-3')))),
                      EditableText(
                        key: const ValueKey('custom-css-text'),
                        controller: _text,
                        focusNode: _focus,
                        style: mono,
                        cursorColor: t.color('app-ink'),
                        backgroundCursorColor: t.color('app-ink-3'),
                        selectionColor: t.textSelection,
                        minLines: 8,
                        maxLines: 24,
                        keyboardType: TextInputType.multiline,
                        autocorrect: false,
                        enableSuggestions: false,
                        smartDashesType: SmartDashesType.disabled,
                        smartQuotesType: SmartQuotesType.disabled,
                        textCapitalization: TextCapitalization.none,
                        inputFormatters: [LengthLimitingTextInputFormatter(CustomCss.mostText)],
                      ),
                    ]),
                  ),
                ),
                SettingRow(
                  key: const ValueKey('custom-css-apply'),
                  icon: _icon(Lucide.check),
                  label: on && !_changed ? 'In use' : 'Use it',
                  disabled: on && !_changed,
                  onPress: _apply,
                ),
              ],
            ),
            if (result != null && result.problems.isNotEmpty) ...[
              SizedBox(height: t.space(5)),
              PaneSection(
                title: 'Not used',
                children: [
                  for (final (i, problem) in result.problems.indexed)
                    SettingRowBox(
                      child: Text(problem, key: ValueKey('custom-css-problem-$i'), style: pageText(t, t.fontSize('sm'), color: t.color('app-warn'))),
                    ),
                ],
              ),
            ],
            SizedBox(height: t.space(5)),
            PaneSection(
              title: 'Help',
              footer: const Tr('Rules about elements (button, div) and plain properties (color: red) do nothing: the app is drawn from variables. Fonts can only be ones the app has.'),
              children: [
                if (_text.text.trim().isEmpty)
                  SettingRow(
                    key: const ValueKey('custom-css-example'),
                    icon: _icon(Lucide.fileCode),
                    label: 'Start from an example',
                    onPress: () => _text.text = customCssExample,
                  ),
                SettingRow(
                  key: const ValueKey('custom-css-variables'),
                  icon: _icon(Lucide.copy),
                  label: 'Copy every variable',
                  hint: const Tr('All the names the app reads, with their values now, to paste and change'),
                  onPress: _copyVariables,
                ),
                if (_text.text.isNotEmpty)
                  SettingRow(
                    key: const ValueKey('custom-css-clear'),
                    icon: _icon(Lucide.eraser),
                    label: 'Clear it',
                    onPress: () {
                      _text.clear();
                      CustomCss.save(app, '', on: false);
                    },
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
