/// What the Marketplace's developer and review screens share (Matt, 2026-11-20: "I would like users to be able to develop
/// and submit their own plugins to our plugin marketplace and I'd like to be able to verify them for the store through a
/// review process"): a submission's status in words, its date, the blocks that say why a screen can't be used here (no
/// identity of this device's own, another server), the line for a Marketplace that couldn't be reached, a box of
/// several lines, and a submission's tile.
library;

import 'dart:typed_data';

import 'package:flutter/services.dart' show LengthLimitingTextInputFormatter, TextCapitalization, TextEditingValue, TextInputFormatter, TextInputType, TextSelection;
import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../../art/app_icon.dart';
import '../../art/lucide.g.dart';
import '../../kit/semantic_colors.dart';
import '../../kit/settings_kit.dart';
import '../../kit/settings_type.dart';
import '../../market/market_api.dart' show marketIsOwn;
import '../../market/market_models.dart';
import '../../net/net.dart';
import '../../plugins/pack/pack.dart' show PackIssue, PluginPack, packHere, packIssuesMost;
import '../../plugins/plugin.dart';
import '../../sms.dart';
import '../admin_page.dart' show AdminSignIn;
import '../common.dart';
import '../settings.dart' show SettingsSectionScreen;
import '../shell.dart';

/// A submission's status as its developer and the reviewer read it (SPEC D.9's table).
String submissionStatusWords(SubmissionView s) => switch (s.status) {
      'submitted' => 'Waiting for review',
      'in_review' => 'In review',
      'changes_requested' => 'Changes asked for',
      'approved' when s.revokedAt != null => 'Withdrawn by review: ${s.revokedWhy ?? ''}'.trim(),
      'approved' => 'Approved${switch (s.listing) { 'listed' => ' · listed', 'unlisted' => ' · not listed', _ => '' }}',
      'rejected' => 'Not accepted',
      'withdrawn' => 'Withdrawn',
      'superseded' => 'Replaced by a newer version',
      final other => other,
    };

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/// A day as the Marketplace's lists say it: "20 Nov 2026"; '' for none.
String marketDate(int ms) {
  if (ms <= 0) return '';
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  return '${d.day} ${_months[d.month - 1]} ${d.year}';
}

/// The words a Marketplace that couldn't be reached is said in, on every screen that reads it.
const String marketUnreachableWords = 'Couldn\'t reach the Marketplace. Try again in a moment.';

/// Where the app's hub isn't Uplink's own: plugins are reviewed on ours alone (MarketApi.live), so the line
/// names the server this app uses and where to switch back: Settings › Routes, as that section has been called since
/// Matt renamed it (2026-11-19: "Rename 'Network' to 'Routes'"), which is on the phone alone.
String marketServerWords(String hub) => 'Plugins are reviewed on Uplink\'s own server, and this app uses ${Uri.tryParse(hub)?.host.ifEmpty(hub) ?? hub}. Switch back in Settings › Routes${Sms.remote ? ' on your phone' : ''} to submit.';

/// The first [most] of [issues] a line each, and one saying how many more where there are more: a stranger's package
/// held tens of thousands of problems, and a line drawn for each froze the screen of the one device that holds the
/// review key (review, 2026-11-20).
List<String> issueLines(List<PackIssue> issues, String Function(PackIssue issue) line, {int most = packIssuesMost}) => [
      for (final i in issues.take(most)) line(i),
      if (issues.length > most) 'And ${issues.length - most} more.',
    ];

/// Opens Settings › Me, [seek] lit, from a Marketplace page: in the frame where there is one, over this page where not.
void openSettingsMe(BuildContext context, [String? seek]) {
  final shell = AppShell.maybeOf(context);
  if (shell != null) return shell.settings('me', seek);
  push<void>(context, (_) => SettingsSectionScreen('me', seek: seek));
}

/// A line that stops a screen, with a row that goes where it can be put right: the computer that follows its phone
/// (no identity of its own), no username, a blocked account.
class MarketBlock extends StatelessWidget {
  const MarketBlock({super.key, required this.words, this.icon = Lucide.circleAlert, this.action, this.actionKey, this.onAction});
  final String words;
  final LucideIcon icon;
  final String? action;
  final Key? actionKey;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) => PaneSection(children: [
        SettingRow(icon: AppIcon(icon, size: 18), label: words),
        if (action != null) SettingRow(key: actionKey, icon: const AppIcon(Lucide.userCheck, size: 18), label: action!, onPress: onAction),
      ]);
}

/// The block for a device with no Uplink identity of its own (a computer that follows its phone): submitting, like
/// reviewing, is signed with this device's own key.
Widget marketWhoBlock(BuildContext context, {required Key key, required Key rowKey}) => MarketBlock(
      key: key,
      words: 'Submitting needs your Uplink identity on this ${packHere()}. Become the same you as your phone in Settings › Me, or submit from your phone.',
      icon: Lucide.keyRound,
      action: 'Open Settings › Me',
      actionKey: rowKey,
      onAction: () => openSettingsMe(context, 'Become the same you as your phone'),
    );

/// Whether the app's hub ([hub], else Net's) is someone else's server than Uplink's own, where the Marketplace
/// is.
bool marketHubIsOther(String? hub) => !marketIsOwn(hub ?? Net.instance.hubUrl);

/// The admin sign-in on a page of its own over this one, [words] saying why above it; signed in, the page goes and
/// [signedIn] is called. A sheet rising from the foot of the screen sat under the phone's keyboard once a field was
/// pressed, its fields and Sign in hidden, and the relay wants a sign-in within the half hour for every approval
/// (review, 2026-11-20): a page's list puts the fields at its top, over the keyboard, as askCircleWords asks for words.
Future<void> pushAdminSignIn(BuildContext context, {required String words, required Key key, Future<Map<String, dynamic>> Function(Map<String, Object?> what)? ask, required VoidCallback signedIn}) => push<void>(
      context,
      (page) => GhostPage(
        title: 'Admin sign-in',
        body: ListView(
          padding: EdgeInsets.all(page.tokens.space(4)),
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          children: [
            PaneSection(children: [SettingRow(icon: const AppIcon(Lucide.keyRound, size: 18), label: words)]),
            SizedBox(height: page.tokens.space(4)),
            AdminSignIn(
              key: key,
              ask: ask,
              onDone: () async {
                Navigator.of(page).pop();
                signedIn();
              },
            ),
          ],
        ),
      ),
    );

/// Keeps a field to [most] UTF-16 code units, which is how the Marketplace counts, never cutting a character in two.
/// Flutter's own limit counts what shows as one character, so 990 letters and six emoji passed a field of 1,000 and
/// were refused (review, 2026-11-20). While a word is being composed it is left whole, as Flutter leaves it.
class MarketLengthLimit extends TextInputFormatter {
  const MarketLengthLimit(this.most);
  final int most;

  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    if (newValue.text.length <= most || newValue.composing.isValid) return newValue;
    // Full already, and more typed: as it was.
    if (oldValue.text.length == most && oldValue.selection.isCollapsed) return oldValue;
    final last = newValue.text.codeUnitAt(most - 1);
    final text = newValue.text.substring(0, last >= 0xD800 && last <= 0xDBFF ? most - 1 : most);
    final at = newValue.selection.extentOffset;
    return TextEditingValue(text: text, selection: TextSelection.collapsed(offset: at < 0 || at > text.length ? text.length : at));
  }
}

/// "Couldn't reach the Marketplace" with a way to try again, where a screen's first read failed.
class MarketUnreachable extends StatelessWidget {
  const MarketUnreachable({super.key, required this.onRetry, this.words = marketUnreachableWords});
  final VoidCallback onRetry;
  final String words;

  @override
  Widget build(BuildContext context) => PaneSection(children: [
        SettingRow(icon: const AppIcon(Lucide.globe, size: 18), label: words),
        SettingRow(icon: const AppIcon(Lucide.refreshCw, size: 18), label: 'Try again', onPress: onRetry),
      ]);
}

/// Words over several lines, as Share feedback's "What happened?": a box pressed to type in, its words kept to [most].
class MarketTextArea extends StatefulWidget {
  const MarketTextArea({super.key, required this.controller, required this.label, required this.placeholder, this.most = 1000, this.minLines = 4, this.maxLines = 12, this.readOnly = false, this.onChanged});
  final TextEditingController controller;
  final String label, placeholder;
  final int most, minLines, maxLines;
  final bool readOnly;
  final ValueChanged<String>? onChanged;

  @override
  State<MarketTextArea> createState() => _MarketTextAreaState();
}

class _MarketTextAreaState extends State<MarketTextArea> {
  final _focus = FocusNode();

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final ink = pageText(t, t.fontSize('md'), color: t.color('app-ink'), height: 1.4);
    return GestureDetector(
      onTap: _focus.requestFocus,
      child: Container(
        constraints: BoxConstraints(minHeight: t.lenOf('6rem')),
        padding: EdgeInsets.all(t.space(3)),
        decoration: BoxDecoration(color: t.color('app-paper-3'), borderRadius: BorderRadius.circular(t.radius('md'))),
        child: Stack(children: [
          ListenableBuilder(listenable: widget.controller, builder: (context, _) => widget.controller.text.isEmpty ? IgnorePointer(child: Text(widget.placeholder, style: ink.copyWith(color: t.color('app-ink-3')))) : const SizedBox.shrink()),
          Semantics(
            label: widget.label,
            textField: true,
            child: EditableText(
              controller: widget.controller,
              focusNode: _focus,
              style: ink,
              cursorColor: t.color('app-ink'),
              backgroundCursorColor: t.color('app-ink-3'),
              selectionColor: t.textSelection,
              minLines: widget.minLines,
              maxLines: widget.maxLines,
              keyboardType: TextInputType.multiline,
              textCapitalization: TextCapitalization.sentences,
              inputFormatters: [LengthLimitingTextInputFormatter(widget.most), MarketLengthLimit(widget.most)],
              readOnly: widget.readOnly,
              onChanged: widget.onChanged,
            ),
          ),
        ]),
      ),
    );
  }
}

/// What a submission's or a pack's tile is drawn from: its symbol on its hue, or its icon, with no plugin behind it.
class MarketFace extends GhostPlugin {
  MarketFace({required this.id, required this.name, String symbol = 'puzzle', this.hue = 'slate', this.iconPng}) : icon = Lucide.all[symbol] ?? Lucide.puzzle;

  /// A submission's tile: its symbol on its hue, as the developer's words gave them.
  factory MarketFace.of(SubmissionView s) => MarketFace(id: 'x${s.plugin}', name: s.name.ifEmpty(s.plugin), symbol: s.symbol, hue: s.hue);

  /// A checked pack's: its own icon where it has one.
  factory MarketFace.ofPack(PluginPack p) => MarketFace(id: 'x${p.id}', name: p.name, symbol: p.symbol, hue: p.hue, iconPng: p.icon);

  @override
  final String id;
  @override
  final String name;
  @override
  String get description => name;
  @override
  final LucideIcon icon;
  @override
  final String hue;
  @override
  final Uint8List? iconPng;
  @override
  bool get onByDefault => false;
}

extension MarketWords on String {
  String ifEmpty(String other) => isEmpty ? other : this;
}
