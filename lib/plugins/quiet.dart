/// Quiet hours: texts that arrive between ten at night and seven in the morning from someone who is not a contact come
/// without a sound, and from everyone where chosen, a contact's urgent words still sounding; and the conversations
/// the filter hides (spam, political texts, debt collectors, sales) muted as they come (Matt, 2026-11-14, of the ideas
/// to streamline someone's day: "Quiet hours with a pass-through: sales, political and debt texts never notify,
/// people always do, and anything urgent from someone you know gets through", with "Commute and focus modes" grouped
/// with it).
///
/// The hours are worked out by the phone's own side as a text arrives (android Notifier.quietNow), whether the app is
/// open or not: a quiet text is shown on a Quiet hours channel, without sound or vibration. The kinds are muted by the
/// app as it sees them (an incoming rule), so their later texts arrive quietly too.
library;

import '../art/app_icon.dart';
import '../art/lucide.g.dart';
import 'plugin.dart';

class QuietPlugin extends GhostPlugin {
  const QuietPlugin();

  /// The sections whose conversations are muted as they come: the kinds hidden as the app ships.
  static const hushed = {'spam', 'political', 'debt', 'sales'};

  @override
  String get id => 'quiet';

  @override
  String get name => 'Quiet hours';

  @override
  String get description => 'Texts from strangers are silent at night, and spam, political texts, debt collectors and sales never make a sound.';

  @override
  LucideIcon get icon => Lucide.bell;

  // Its card and page on the Plugins page (Matt, 2026-11-17: "redo how the plugins look with their own dedicated plugins page
  // with a marketplace like look how ghostmd has").
  @override
  PluginShelf get shelf => PluginShelf.safety;

  // Its tags in the Marketplace, so a search by tag finds it beside the plugins from other developers (Matt, 2026-11-20:
  // "plugin tags").
  @override
  List<String> get labels => const ['quiet'];

  @override
  String get tagline => 'Strangers silent at night; spam and sales never make a sound.';

  @override
  List<String> get adds => const ['Quiet hours from 10 PM to 7 AM', 'Spam, political texts, debt collectors and sales muted as they come'];

  @override
  List<PluginReach> get reaches => const [PluginReach(Lucide.bell, 'Each text as it arrives, on this phone', 'A quiet text is still shown, on a notification channel of its own.')];

  @override
  List<IncomingRule> get incoming => [
        (facts, tags, at, prefs) => [if (at != null && hushed.contains(at) && prefs.flag('kinds')) const MuteNotification()],
      ];

  @override
  PluginSettingsPage? get settingsPage => PluginSettingsPage(
        hue: 'indigo',
        intro: 'When texts may make a sound.',
        summary: (prefs) => [if (prefs.flag('hours', fallback: false)) (prefs.flag('everyone', fallback: false) ? 'Quiet 10 PM–7 AM' : 'Strangers quiet at night'), if (prefs.flag('kinds')) 'Spam and sales silent'].join(' · ').ifEmpty('Off'),
      );

  @override
  List<PluginSetting> get settings => const [
        PluginSetting.toggle(key: 'kinds', label: 'Silence spam, political texts, debt collectors and sales', hint: 'Their conversations are muted as they come. "Not spam" and the like turn them back on.', icon: Lucide.bell),
        PluginSetting.toggle(key: 'hours', label: 'Quiet from 10 PM to 7 AM', hint: 'A text from someone who is not in your contacts arrives without a sound.', icon: Lucide.clock, fallback: false),
        PluginSetting.toggle(key: 'everyone', label: 'Everyone, in those hours', hint: 'Contacts too, unless they write "urgent", "emergency", "call me" or the like.', icon: Lucide.users, fallback: false),
        PluginSetting.note(label: 'On this phone only', hint: 'Decided on the phone as each text arrives. A quiet text is still shown, on the Quiet hours notification channel.', icon: Lucide.lock),
      ];
}

extension on String {
  String ifEmpty(String other) => isEmpty ? other : this;
}
