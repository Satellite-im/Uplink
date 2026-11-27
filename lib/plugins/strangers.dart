/// Unknown numbers: over the composer of a conversation with someone not in your contacts, a line guessing what they
/// are (a person, a business, likely spam) and three buttons: Save, Block, and Not now (Matt, 2026-11-14, of the
/// ideas to streamline someone's day: "Unknown-number triage: a first text from a new number gets a one-line guess at
/// what it is (a person, a business, a scam) and a quick Block / Save / Ignore").
///
/// The guess is made on the phone from the number and the words: a short code or a text that speaks like a company
/// is a business; one the Spam filter would call spam is likely spam; anything else could be a person. Not now puts
/// the line away for that conversation.
library;

import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../art/app_icon.dart';
import '../art/lucide.g.dart';
import '../art/lucide_more.dart';
import '../kit/settings_type.dart';
import '../sms.dart';
import '../ui/common.dart';
import 'plugin.dart';
import 'spam.dart';
import '../kit/semantic_colors.dart';

/// What a stranger likely is: `spam`, `business` or `person`.
String strangerGuess(String address, String words) {
  if (judgeSpam(MessageFacts(thread: 0, senders: [address], text: words, contact: false)).spam) return 'spam';
  final digits = address.replaceAll(RegExp(r'\D'), '');
  if (address.contains('@') || (digits.isNotEmpty && digits.length <= 6)) return 'business';
  if (RegExp(r'(?<![a-z])(?:reply stop|txt stop|text stop|opt[ -]out|unsubscribe|msg&data|msg & data|your order|your account|appointment|customer|we\x27re|our team|llc|inc\.?)(?![a-z])', caseSensitive: false).hasMatch(words)) return 'business';
  return 'person';
}

class StrangersPlugin extends GhostPlugin {
  const StrangersPlugin();

  @override
  String get id => 'strangers';

  @override
  String get name => 'Unknown numbers';

  @override
  String get description => 'A conversation with someone not in your contacts says what they likely are, with Save and Block.';

  @override
  LucideIcon get icon => LucideMore.userRoundSearch;

  // Its card and page on the Plugins page (Matt, 2026-11-17: "redo how the plugins look with their own dedicated plugins page
  // with a marketplace like look how ghostmd has").
  @override
  PluginShelf get shelf => PluginShelf.safety;

  // Its tags in the Marketplace, so a search by tag finds it beside the plugins from other developers (Matt, 2026-11-20:
  // "plugin tags").
  @override
  List<String> get labels => const ['safety'];

  @override
  String get tagline => 'Someone not in your contacts, at a glance, with Save and Block.';

  @override
  List<String> get adds => const ['A line at the top of a conversation with a stranger: what they likely are', 'Save, Block and Not now'];

  @override
  List<PluginReach> get reaches => const [PluginReach(Lucide.contactRound, 'The number and its words, on this phone', 'Guessed here. Block uses the phone\'s own blocked numbers.')];

  @override
  List<SlotFill> get slots => [
        Slots.aboveComposer.fill((context, place, prefs) {
          if (place.contact || place.group || Sms.remote || place.senders.isEmpty) return const [];
          if (prefs.flag('away_${place.thread}', fallback: false)) return const [];
          final words = place.lastIn ?? place.lastOut ?? '';
          return [StrangerLine(address: place.senders.first, guess: strangerGuess(place.senders.first, words), away: () => prefs.setFlag('away_${place.thread}', true))];
        }),
      ];

  @override
  PluginSettingsPage? get settingsPage => PluginSettingsPage(hue: 'orange', intro: 'Someone not in your contacts, at a glance.', summary: (prefs) => 'A guess, with Save and Block');

  @override
  List<PluginSetting> get settings => const [
        PluginSetting.note(label: 'The guess', hint: 'Likely spam where the Spam filter would say so; a business for a short code, an email address, or words like "Reply STOP" or "your order"; else someone you may know.', icon: LucideMore.userRoundSearch),
        PluginSetting.note(label: 'Save, Block, Not now', hint: 'Save opens a new contact with the number filled in; Block adds it to Android\'s blocked numbers; Not now puts the line away for that conversation.', icon: Lucide.ban),
        PluginSetting.note(label: 'On this phone only', hint: 'Guessed from the number and the words, on the phone.', icon: Lucide.lock),
      ];
}

/// The line over the composer.
class StrangerLine extends StatelessWidget {
  const StrangerLine({super.key, required this.address, required this.guess, required this.away});
  final String address;
  final String guess;
  final VoidCallback away;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final (icon, words) = switch (guess) {
      'spam' => (Lucide.triangleAlert, 'Not in your contacts · likely spam'),
      'business' => (LucideMore.receipt, 'Not in your contacts · looks like a business'),
      _ => (Lucide.userRound, 'Not in your contacts · could be someone you know'),
    };
    Widget button(String label, VoidCallback onPress, {bool danger = false}) => GlacierPressable(
          onPressed: onPress,
          builder: (context, state) => Padding(
            padding: EdgeInsets.symmetric(horizontal: t.space(2), vertical: t.space(1)),
            child: Text(label, style: pageText(t, t.fontSize('sm'), weight: 'semibold', color: danger ? t.danger : t.color(state.pressed ? 'app-ink-3' : 'app-ink'))),
          ),
        );
    return Padding(
      padding: EdgeInsetsDirectional.fromSTEB(t.space(3), t.space(2), t.space(3), 0),
      child: Container(
        padding: EdgeInsetsDirectional.fromSTEB(t.space(3), t.space(2), t.space(1), t.space(2)),
        decoration: BoxDecoration(color: t.color('app-paper-2'), borderRadius: BorderRadius.circular(t.radius('lg')), border: Border.all(color: t.color('app-rule'))),
        child: Row(children: [
          AppIcon(icon, size: 16, strokeWidth: 2.2, wash: false, color: guess == 'spam' ? t.danger : t.color('app-ink-2')),
          SizedBox(width: t.space(2)),
          Expanded(child: Text(words, maxLines: 2, style: pageText(t, t.fontSize('xs'), weight: 'medium', color: t.color('app-ink-2')))),
          button('Save', () async {
            if (!await Sms.instance.addContact(address) && context.mounted) toast(context, 'No contacts app to save it in');
          }),
          button('Block', () async {
            try {
              await Sms.instance.setBlocked(address, true);
              if (context.mounted) toast(context, 'Blocked');
            } catch (e) {
              if (context.mounted) toast(context, 'Couldn\'t block: $e', tone: GlacierToastTone.danger);
            }
          }, danger: true),
          button('Not now', away),
        ]),
      ),
    );
  }
}
