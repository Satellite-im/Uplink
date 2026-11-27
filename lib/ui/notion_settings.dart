/// Notion for a circle, in Circle settings › Plugins (lib/plugins/notion.dart): the row that says whether the circle
/// holds a token, and the page a token is given on. Whoever may change the circle gives it; everyone else sees that
/// it is set up.
library;

import 'package:flutter/services.dart' show TextCapitalization;
import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../art/app_icon.dart';
import '../art/lucide.g.dart';
import '../circles/circle.dart';
import '../circles/circles.dart';
import '../kit/semantic_colors.dart';
import '../kit/settings_kit.dart';
import '../kit/settings_type.dart';
import '../notion/notion.dart';
import '../plugins/notion.dart';
import 'common.dart';
import '../l10n/words.dart';

/// The Notion section of a circle's plugins: its token, and taking it away.
class NotionCircleSection extends StatelessWidget {
  const NotionCircleSection({super.key, required this.circle, required this.edit});
  final Circle circle;

  /// This device may change the circle.
  final bool edit;

  @override
  Widget build(BuildContext context) {
    final c = circle;
    final token = NotionCircle.tokenOf(c);
    final on = c.manifest.pluginOn(NotionPlugin.pluginId) ?? false;
    return PaneSection(
      title: 'Notion',
      description: Text(token == null
          ? (edit
              ? 'Give ${c.name} a Notion integration token and Notion links written in its spaces open out under the message, for everyone here.'
              : 'Not set up. Whoever has Change the circle gives ${c.name} a Notion token.')
          : (on ? 'Notion links written in ${c.name}\'s spaces open out under the message, for everyone here.' : 'A token is kept, and Notion is switched off above.')),
      children: [
        SettingRow(
          key: const ValueKey('circle-notion-token'),
          icon: AppIcon(Lucide.keyRound, size: 18),
          label: 'Notion token',
          hint: Text(token == null ? 'An internal integration\'s, from notion.so/profile/integrations' : 'Held by everyone in the circle, to read what it was shared in Notion.'),
          value: Text(token == null ? (edit ? 'Add' : 'None') : 'Ends in ${NotionCircle.endOf(token)}'),
          onPress: edit ? () => push<void>(context, (_) => NotionTokenScreen(seed: c.seed)) : null,
        ),
        if (token != null && edit)
          SettingRow(
            key: const ValueKey('circle-notion-remove'),
            icon: AppIcon(Lucide.trash2, size: 18),
            label: 'Take the token away',
            hint: const Tr('Notion links stop opening out. To cut off anyone who already has it, delete the integration in Notion too.'),
            onPress: () => showChoices(context, title: 'Take ${c.name}\'s Notion token away?', choices: [
              Choice('Take it away', Lucide.trash2, () async {
                final ok = await NotionCircle.remove(c);
                if (context.mounted) toast(context, ok ? 'Notion token taken away' : 'Couldn\'t change the circle');
              }, danger: true),
            ]),
          ),
      ],
    );
  }
}

/// The page a circle's Notion token is given on: what it means first, then the field. Notion is asked who the token
/// is before it is kept, so a wrong one is said here and never reaches the circle.
class NotionTokenScreen extends StatefulWidget {
  const NotionTokenScreen({super.key, required this.seed});
  final String seed;

  @override
  State<NotionTokenScreen> createState() => _NotionTokenScreenState();
}

class _NotionTokenScreenState extends State<NotionTokenScreen> {
  final _token = TextEditingController();
  bool _busy = false;
  String? _problem;

  @override
  void dispose() {
    _token.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final c = Circles.instance.bySeed(widget.seed);
    final token = _token.text.trim();
    if (_busy || token.isEmpty || c == null) return;
    if (!Notion.looksLikeToken(token)) {
      setState(() => _problem = 'That doesn\'t look like a Notion token. One starts with ntn_ or secret_; copy it from the integration\'s page in Notion.');
      return;
    }
    setState(() {
      _busy = true;
      _problem = null;
    });
    String? why;
    String? name;
    try {
      name = await NotionCircle.keep(c, token);
    } on NotionError catch (e) {
      why = e.problem == NotionProblem.token ? 'Notion refused that token. Copy it again from the integration\'s page in Notion.' : e.words;
    } on StateError catch (e) {
      why = e.message;
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _problem = why;
    });
    if (why != null) return;
    _token.clear();
    toast(context, 'Notion is set up for ${c.name}, as $name.');
    Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final c = Circles.instance.bySeed(widget.seed);
    final had = c != null && NotionCircle.tokenOf(c) != null;
    final pad = EdgeInsetsDirectional.fromSTEB(t.space(4), t.space(2), t.space(4), t.space(8) + MediaQuery.paddingOf(context).bottom);
    return GhostPage(
      title: 'Notion token',
      body: SettingsPaneScope(
        finder: SettingsFinder(),
        child: ListView(padding: pad, keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag, children: [
          SettingsCallout(
            icon: AppIcon(Lucide.info, size: 18),
            child: Text('The token is kept in ${c?.name ?? 'the circle'}\'s own page, so every member\'s device can read Notion with it. Everyone in the circle, and anyone given its invite, can read whatever this integration was shared in Notion. Share with it only what the whole circle may see, and give it read access only.'),
          ),
          SizedBox(height: t.space(4)),
          PaneSection(
            title: had ? 'A new token' : 'The circle\'s token',
            description: const Tr('In Notion, open Settings › Connections › Develop or manage integrations, make an internal integration that can only read content, and copy its secret. Then, on each page or database the circle should see, open ••• › Connections and add the integration.'),
            children: [
              SettingRowBox(
                child: GlacierInput(
                  key: const ValueKey('notion-token-field'),
                  controller: _token,
                  type: GlacierInputType.password,
                  placeholder: 'ntn_…'.t,
                  ariaLabel: 'Notion integration token',
                  autoCorrect: false,
                  autoCapitalize: TextCapitalization.none,
                  size: GlacierFieldSize.md,
                  onChange: (_) => setState(() {}),
                  onSubmitted: (_) => _save(),
                ),
              ),
              SettingRow(
                key: const ValueKey('notion-token-save'),
                icon: AppIcon(Lucide.check, size: 18),
                label: _busy ? 'Asking Notion…' : (had ? 'Use this token instead' : 'Keep this token'),
                disabled: _busy || _token.text.trim().isEmpty,
                onPress: _save,
              ),
            ],
          ),
          if (_problem != null)
            Padding(
              padding: EdgeInsets.only(top: t.space(3)),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Padding(padding: EdgeInsetsDirectional.only(end: t.space(2), top: 2), child: AppIcon(Lucide.triangleAlert, size: 16, color: t.danger)),
                Expanded(child: Text(_problem!, key: const ValueKey('notion-token-problem'), style: pageText(t, t.fontSize('sm'), color: t.danger, height: 1.4))),
              ]),
            ),
        ]),
      ),
    );
  }
}
