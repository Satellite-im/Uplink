/// Human check: a first message from someone new on a network the person chose waits out of Messages, without a
/// notification, until its sender answers a small question sent back automatically (GMFB-23, Matt, Mac 0.12.6: "I'd
/// like to be able to chose given platforms and have new messages from that platform stay hidden from notificatoins
/// and my messages until they solve a small challenge with a local AI messenger like if someone from telegram is a bot
/// and they message me "WHat are you doing tonight?" it would ask the bot to solve a small riddle or other problem to
/// help weed out bots and spam").
///
/// Called "Human check" because that is what it asks of a sender, in plain words; "Gatekeeper" is also macOS's own
/// name for something else on the Mac it runs on.
///
/// This is the switch, the networks it guards (each off until chosen), and the "held" row over Messages with the page
/// it opens; the work is lib/inbox/human_check.dart. Off until added.
library;

import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../app_state.dart';
import '../art/app_icon.dart';
import '../art/lucide.g.dart';
import '../inbox/human_check.dart';
import '../inbox/inbox.dart';
import '../kit/settings_type.dart';
import '../ui/common.dart';
import '../ui/inbox_ui.dart' show InboxChatRow, openInboxChat;
import 'plugin.dart';
import 'registry.dart';
import 'ui.dart' show PluginNote;

/// Starts the Human check's work for [app], once: on a phone, an iPhone and a computer alike. Each start-up path calls
/// this after the networks are added (`addInboxSettings`) and started, so a guarded network's new chats are held on
/// every device the person uses (GMFB-23: the computer's start-up never made it, so on a Mac, Windows or Linux no
/// first message was ever held or asked its question).
void startHumanCheck(AppState app) {
  HumanCheck.instance ??= HumanCheck(
    choices: () => HumanCheckPlugin.choicesIn(PluginRegistry.instance, AppStore(app)),
    read: (key) => app.choice(key, ''),
    write: app.keep,
  )..watch(Inbox.instance, choicesChanged: app);
}

class HumanCheckPlugin extends GhostPlugin {
  const HumanCheckPlugin();

  /// The networks it can guard, by id and name, in Settings › Connections' order: written out, as the registry asks
  /// for a plugin's settings as the app starts and the networks are not to be made for that.
  /// test/human_check_test.dart holds it to Inbox's own list.
  static const networks = [
    ('telegram', 'Telegram'),
    ('signal', 'Signal'),
    ('whatsapp', 'WhatsApp'),
    ('matrix', 'Matrix'),
    ('teams', 'Microsoft Teams'),
    ('googlechat', 'Google Chat'),
    ('messenger', 'Messenger'),
    ('instagram', 'Instagram'),
    ('discord', 'Discord'),
    ('twitter', 'X'),
    ('slack', 'Slack'),
  ];

  static const pluginId = 'humancheck';

  /// The choice that guards a network, by its id.
  static String netKey(String network) => 'net_$network';

  @override
  String get id => pluginId;

  @override
  String get name => 'Human check';

  @override
  String get description => 'A first message from someone new on the networks you choose waits out of sight, without a notification, until they answer a small question sent back automatically.';

  @override
  LucideIcon get icon => Lucide.shieldCheck;

  // It hides messages, so it is chosen (GhostPlugin.onByDefault).
  @override
  bool get onByDefault => false;

  @override
  PluginShelf get shelf => PluginShelf.safety;

  @override
  List<String> get labels => const ['safety', 'filters'];

  @override
  String get tagline => 'Strangers answer a small question before they reach you.';

  @override
  String get pitch => 'New people on the networks you choose answer a small riddle or sum before their message shows or makes a sound. Bots and spam don\'t.';

  @override
  List<String> get adds => const [
        'A "held" row at the top of Messages with the chats waiting on an answer',
        'One automatic question back to someone new, and one more try after a wrong answer',
        'Let in or Block on each held chat',
      ];

  @override
  List<PluginReach> get reaches => const [
        PluginReach(Lucide.messageSquare, 'New chats on the networks you choose, on this device', 'Looked at here. The question is made and the answer judged on this device; nothing is sent anywhere else.'),
        PluginReach(Lucide.bot, 'Sends one message for you in a new chat', 'An automatic check, which says it is one, and a second try after a wrong answer. Never to your contacts, groups, or a chat you wrote in.'),
      ];

  /// The person's choices while it is on, for lib/inbox/human_check.dart; null while it is off.
  static HumanCheckChoices? choicesIn(PluginRegistry registry, PluginStore store) {
    final plugin = registry.plugins.whereType<HumanCheckPlugin>().firstOrNull;
    if (plugin == null || !registry.isOn(plugin, store)) return null;
    final prefs = registry.prefsOf(plugin, store);
    return HumanCheckChoices(
      networks: {for (final (id, _) in networks) if (prefs.flag(netKey(id), fallback: false)) id},
      groups: prefs.flag('groups', fallback: false),
    );
  }

  @override
  PluginSettingsPage? get settingsPage => PluginSettingsPage(
        hue: 'green',
        intro: 'Someone new on the networks you choose answers a small question before their message reaches you.',
        summary: (prefs) {
          final on = [for (final (id, name) in networks) if (prefs.flag(netKey(id), fallback: false)) name];
          return on.isEmpty ? 'No networks chosen' : on.join(', ');
        },
      );

  @override
  List<PluginSetting> get settings => [
        const PluginSetting.heading(label: 'Networks', hint: 'A first message from someone new here waits for their answer. Chats there already, and your contacts, are never held.'),
        for (final (id, name) in networks) PluginSetting.toggle(key: netKey(id), label: name, icon: Lucide.messageSquare, fallback: false),
        const PluginSetting.heading(label: 'Who is asked'),
        const PluginSetting.toggle(key: 'groups', label: 'Groups too', hint: 'A group you were added to by someone new is held and asked as well.', icon: Lucide.users, fallback: false),
        const PluginSetting.note(
          label: 'Never asked',
          hint: 'Your contacts on the network, a chat you have written in, the network\'s own account and bots (sign-in codes come from those).',
          icon: Lucide.userCheck,
        ),
        const PluginSetting.note(
          label: 'The question',
          hint: 'A small sum, a word picked from a sentence, or a riddle, sent once and saying it is an automatic check from your app. A right answer brings the chat into Messages; a wrong one gets one more try, then it stays held.',
          icon: Lucide.shieldCheck,
        ),
        const PluginSetting.note(label: 'On this device only', hint: 'Made and judged here; nothing about the chat goes anywhere but the question, sent in that chat.', icon: Lucide.lock),
      ];

  @override
  List<SlotFill> get slots => [
        Slots.aboveList.fill((context, place, prefs) => [if (place.section == null && HumanCheck.instance != null) HeldRow(check: HumanCheck.instance!, inbox: Inbox.instance)]),
      ];
}

/// What [r] says of where a held chat stands, for its line.
String heldWords(HoldRecord r) => switch (r.state) {
      HoldState.checking => 'New · about to be asked',
      HoldState.asked => r.tries > 0 ? 'Wrong once · asked again' : 'Asked · waiting for an answer',
      HoldState.unsent => 'The question couldn\'t be sent',
      HoldState.failed => 'Answered wrong twice',
      _ => '',
    };

/// The row over Messages while anything is held: how many, and a press to see them.
class HeldRow extends StatelessWidget {
  const HeldRow({super.key, required this.check, required this.inbox});
  final HumanCheck check;
  final Inbox inbox;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: Listenable.merge([check, inbox.changes]),
        builder: (context, _) {
          final held = check.heldChats(inbox);
          if (held.isEmpty) return const SizedBox.shrink();
          final t = context.tokens;
          return Padding(
            padding: EdgeInsetsDirectional.fromSTEB(t.space(3), t.space(1), t.space(3), t.space(1)),
            child: GlacierPressable(
              key: const ValueKey('humancheck-held-row'),
              onPressed: () => push<void>(context, (_) => HeldPage(check: check, inbox: inbox)),
              builder: (context, state) => Container(
                padding: EdgeInsets.symmetric(horizontal: t.space(3), vertical: t.space(2)),
                decoration: BoxDecoration(color: t.color(state.pressed ? 'app-paper-3' : 'app-paper-2'), borderRadius: BorderRadius.circular(t.radius('lg')), border: Border.all(color: t.color('app-rule'))),
                child: Row(children: [
                  AppIcon(Lucide.shieldCheck, size: 16, strokeWidth: 2.2, wash: false, color: t.color('app-ink-2')),
                  SizedBox(width: t.space(2)),
                  Expanded(child: Text('${held.length} held for a human check', style: pageText(t, t.fontSize('sm'), weight: 'medium', color: t.color('app-ink-2')))),
                  AppIcon(Lucide.chevronRight, size: 16, strokeWidth: 2.2, wash: false, color: t.color('app-ink-3')),
                ]),
              ),
            ),
          );
        },
      );
}

/// The held chats, each with where it stands; a press offers Open, Let in and Block.
class HeldPage extends StatelessWidget {
  const HeldPage({super.key, required this.check, required this.inbox});
  final HumanCheck check;
  final Inbox inbox;

  @override
  Widget build(BuildContext context) => GhostPage(title: 'Held', body: HeldList(check: check, inbox: inbox));
}

/// The page's list: a row for each held chat with where it stands under it, drawn again as the held chats change.
class HeldList extends StatelessWidget {
  const HeldList({super.key, required this.check, required this.inbox});
  final HumanCheck check;
  final Inbox inbox;

  void _choose(BuildContext context, HeldChat h, InboxChat chat) {
    final r = h.record;
    showChoices(context, title: '${chat.title} on ${h.network.name}${r.challenge == null ? '' : ' · asked: ${r.challenge!.question}'}', choices: [
      Choice('Let in', Lucide.check, () {
        check.release(h.network, h.id);
        toast(context, 'In Messages now');
      }, hint: 'Into Messages, without asking them anything more.'),
      Choice('Open', Lucide.messageSquare, () => openInboxChat(context, h.network, chat)),
      Choice('Block', Lucide.ban, () async {
        try {
          await check.block(h.network, h.id);
          if (context.mounted) toast(context, 'Blocked');
        } catch (e) {
          if (context.mounted) toast(context, 'Couldn\'t block: $e', tone: GlacierToastTone.danger);
        }
      }, danger: true),
    ]);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: Listenable.merge([check, inbox.changes]),
        builder: (context, _) {
          final t = context.tokens;
          final held = check.heldChats(inbox);
          return ListView(
            padding: EdgeInsets.only(bottom: t.space(6)),
            children: [
              const PluginNote('First messages from someone new, waiting on their answer to an automatic question. Nothing here notifies. Let in brings one into Messages.'),
              if (held.isEmpty) const PluginNote('Nothing is held.'),
              for (final h in held)
                Builder(builder: (context) {
                  // The network no longer lists the chat (it is away): a row from what was kept as it was held.
                  final chat = h.chat ?? InboxChat(network: h.network.id, id: h.id, title: h.record.title.isEmpty ? 'Someone new' : h.record.title, date: DateTime.fromMillisecondsSinceEpoch(h.record.at));
                  return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                    InboxChatRow(key: ValueKey('humancheck-held-${h.network.id}:${h.id}'), chat: chat, onPress: () => _choose(context, h, chat)),
                    Padding(
                      padding: EdgeInsetsDirectional.fromSTEB(t.space(4) + t.lenOf('3rem') + t.space(3), 0, t.space(4), t.space(2)),
                      child: Text(heldWords(h.record), style: pageText(t, t.fontSize('xs'), color: t.color('app-ink-3'))),
                    ),
                  ]);
                }),
            ],
          );
        },
      );
}
