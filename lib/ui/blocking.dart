import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../art/lucide.g.dart';
import '../friends/buddies.dart';
import '../inbox/inbox.dart';
import '../inbox/people.dart' show Reach;
import '../kit/settings_kit.dart';
import '../sms.dart';
import 'common.dart';
import 'inbox_ui.dart' show inboxMark;
import 'person_reach.dart';
import '../l10n/words.dart';

/// Blocking, said and done the same way for texts, Telegram and Signal (Matt, 2026-11-17: "add the signal helper and
/// do your recommendation. Make sure the UIs are unified across SMS Telegram and Signal, Also add a block list to our
/// address book pages"): one word in every menu (Block, Unblock), one question before it, one toast after, and one list
/// of everyone blocked, in Settings and in Contacts.
///
/// Each is blocked where it lives: a number in the phone's own list (Android stops their texts and calls before any
/// app sees them), a Telegram or Signal person on that network itself (lib/inbox: Telegram's own block, Signal's
/// through the helper), so the block holds in the network's own app too.
@immutable
class BlockTarget {
  const BlockTarget.number(this.id, this.name, {this.thread}) : network = null;
  const BlockTarget.network(InboxNetwork this.network, this.id, this.name) : thread = null;

  /// The network they are on; null for a phone number.
  final InboxNetwork? network;

  /// A phone number, or the network's id for the chat with them.
  final String id;
  final String name;

  /// A number's conversation of texts, archived as it is blocked (as it always was).
  final int? thread;

  /// "Texts", or the network's name.
  String get where => network?.name ?? 'Texts';

  /// What blocking them does, in a sentence.
  String get does => switch (network?.id) {
        null => '${Sms.remote ? 'Your phone' : 'Android'} will stop their texts and calls before they reach you.',
        'telegram' => 'Telegram will stop their messages and calls, on all your devices.',
        'signal' => 'Signal will stop their messages and calls, on your phone too.',
        'matrix' => 'Uplink will hide them here; Matrix itself is not told.',
        _ => 'Their messages won\'t show here.',
      };

  /// Whether they are blocked now, where that is known without asking (a network's; a number's from its conversation).
  bool get blocked => network?.isBlocked(id) ?? false;
}

/// The menu line: Block, or Unblock where [blocked].
Choice blockChoice(BuildContext context, BlockTarget who, {required bool blocked, VoidCallback? done}) =>
    Choice(blocked ? 'Unblock' : 'Block', Lucide.ban, () => blocked ? confirmUnblock(context, who, done: done) : confirmBlock(context, who, done: done), danger: !blocked);

/// Asks, then blocks [who] and archives the chat with them.
void confirmBlock(BuildContext context, BlockTarget who, {VoidCallback? done}) {
  showChoices(context, title: 'Block ${who.name}? ${who.does}', choices: [
    Choice('Block', Lucide.ban, () => setBlock(context, who, true, done: done), danger: true),
  ]);
}

/// Asks, then unblocks [who].
void confirmUnblock(BuildContext context, BlockTarget who, {VoidCallback? done}) {
  showChoices(context, title: 'Unblock ${who.name}? Their messages and calls will reach you again.', choices: [
    Choice('Unblock', Lucide.check, () => setBlock(context, who, false, done: done)),
  ]);
}

/// Blocks or unblocks [who] where they live, and says so. A block archives the chat with them, for every kind.
Future<void> setBlock(BuildContext context, BlockTarget who, bool on, {VoidCallback? done}) async {
  try {
    final n = who.network;
    if (n == null) {
      await Sms.instance.setBlocked(who.id, on);
      if (on && who.thread != null) await Sms.instance.archive(who.thread!, true);
    } else {
      await n.block(who.id, name: who.name, on: on);
      if (on) await n.archive(who.id, true);
    }
    if (context.mounted) toast(context, on ? 'Blocked and archived' : 'Unblocked');
  } catch (e) {
    final why = e is StateError ? e.message : '$e';
    if (context.mounted) toast(context, 'Couldn\'t ${on ? 'block' : 'unblock'}: $why', tone: GlacierToastTone.danger);
  }
  done?.call();
}

/// Everyone blocked, numbers then each network, each tapped to unblock: Settings › Blocked and Contacts › Blocked.
class BlockedList extends StatefulWidget {
  const BlockedList({super.key});

  @override
  State<BlockedList> createState() => _BlockedListState();
}

class _BlockedListState extends State<BlockedList> {
  List<Person>? _numbers;
  bool _numbersFailed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// Reads who is blocked: each network asked for its own list, and the phone for its blocked numbers.
  Future<void> _load() async {
    // The networks' own lists first come in (someone blocked in Telegram's app shows here too).
    for (final n in Inbox.instance.ready) {
      if (n.canBlock) n.refreshBlocked();
    }
    if (!Sms.can('setBlocked')) return;
    try {
      final got = await Sms.instance.blockedNumbers();
      if (mounted) setState(() => _numbers = got);
    } catch (_) {
      if (mounted) setState(() => _numbersFailed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([Inbox.instance.changes, Buddies.instance]),
      builder: (context, _) {
        final ghosts = Buddies.instance.blocked;
        final networks = [for (final n in Inbox.instance.networks) if (!n.soon && (n.state == InboxState.ready || n.blockedPeople.isNotEmpty)) n];
        final groups = <(String, List<Widget>, String?)>[
          // Uplink people blocked with a report (GMFB-40): kept here, unblocked here.
          if (ghosts.isNotEmpty)
            (
              'Uplink',
              [
                for (final b in ghosts)
                  SettingRow(
                    key: ValueKey('blocked-ghost-${b.id}'),
                    icon: Avatar(people: [Person(address: '@${b.username}', name: b.shown)], size: 30),
                    label: b.username.isEmpty ? b.shown : '@${b.username}',
                    onPress: () => showChoices(context, title: 'Unblock ${b.username.isEmpty ? b.shown : '@${b.username}'}? They can ask to be friends again.', choices: [
                      Choice('Unblock', Lucide.check, () async {
                        try {
                          await Buddies.instance.unblock(b);
                          if (context.mounted) toast(context, 'Unblocked');
                        } catch (e) {
                          if (context.mounted) toast(context, 'Couldn\'t unblock: $e', tone: GlacierToastTone.danger);
                        }
                      }),
                    ]),
                  ),
              ],
              null,
            ),
          if (Sms.can('setBlocked') && (_numbersFailed || (_numbers?.isNotEmpty ?? false)))
            (
              'Texts',
              [
                for (final p in _numbers ?? const <Person>[])
                  _row(context, BlockTarget.number(p.address, p.label), people: [p], detail: p.name != null && p.name!.isNotEmpty ? p.address : null),
              ],
              _numbersFailed ? 'The phone\'s list couldn\'t be read.' : null,
            ),
          for (final n in networks)
            if (n.blockedPeople.isNotEmpty)
              (
                n.name,
                [
                  for (final b in n.blockedPeople)
                    _row(context, BlockTarget.network(n, b.id, b.name), people: [Person(address: '${n.id}:${b.id}', name: b.name)], badge: inboxMark(n, size: 14, badge: true)),
                ],
                null,
              ),
        ];
        const intro = Tr('Blocked where they are: a number on your phone, a Telegram or Signal person on that network itself, so it holds in their apps too. Block someone with a long press on their name in a chat; an Uplink person when you report them.');
        if (groups.isEmpty) {
          return PaneSection(
            title: 'Blocked',
            description: intro,
            children: [if (_numbers == null && !_numbersFailed && Sms.can('setBlocked')) const SettingRow(label: 'Reading the list…') else const SettingRow(label: 'No one is blocked')],
          );
        }
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          for (var i = 0; i < groups.length; i++)
            PaneSection(
              title: groups[i].$1,
              description: i == 0 ? intro : null,
              footer: groups[i].$3 != null ? Text(groups[i].$3!) : (i == groups.length - 1 ? const Tr('Tap someone to unblock them.') : null),
              children: groups[i].$2,
            ),
        ]);
      },
    );
  }

  /// One blocked person's row: their face, with the network's mark at its corner where [badge] is given.
  Widget _row(BuildContext context, BlockTarget who, {required List<Person> people, Widget? badge, String? detail}) => SettingRow(
        icon: SizedBox.square(
          dimension: 30,
          child: Stack(clipBehavior: Clip.none, children: [
            Avatar(people: people, size: 30),
            if (badge != null)
              PositionedDirectional(
                end: -3,
                bottom: -3,
                child: Container(
                  padding: const EdgeInsets.all(1.5),
                  decoration: BoxDecoration(shape: BoxShape.circle, color: context.tokens.color('glacier-bg')),
                  child: badge,
                ),
              ),
          ]),
        ),
        label: who.name,
        hint: detail == null ? null : Text(detail),
        onPress: () => confirmUnblock(context, who, done: _load),
      );
}

/// Contacts › Blocked, and wherever else the list is a page of its own.
class BlockedScreen extends StatelessWidget {
  const BlockedScreen({super.key, this.onBack});

  /// Where its back arrow goes, where it took Contacts' place in the pane (Matt, 2026-11-17: "include a back arrow when
  /// clicking blocked to go back to the main contacts page").
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return GhostPage(
      title: 'Blocked',
      onBack: onBack,
      body: ListView(padding: EdgeInsetsDirectional.fromSTEB(t.space(4), t.space(2), t.space(4), t.space(8) + MediaQuery.paddingOf(context).bottom), children: const [BlockedList()]),
    );
  }
}

/// The person menu a long press on a one-to-one conversation's name opens, the same for texts, Telegram and Signal:
/// who they are, a new chat with them the other ways they can be reached (lib/ui/person_reach.dart), and Block or
/// Unblock.
Future<void> showPersonBlock(BuildContext context, BlockTarget who) async {
  var blocked = who.blocked;
  if (who.network == null) {
    // A number's block is the phone's: asked for as the menu opens.
    String digits(String a) {
      final d = a.replaceAll(RegExp(r'\D'), '');
      return d.length > 10 ? d.substring(d.length - 10) : d;
    }

    try {
      blocked = (await Sms.instance.blockedNumbers()).any((p) => digits(p.address) == digits(who.id));
    } catch (_) {}
  }
  // A new chat with them the other ways they can be reached, above Block (Matt, 2026-11-18: "add a way to start a new
  // chat with a contact from the contact menu right now it just says "block contact"").
  var reaches = const <Reach>[];
  try {
    reaches = await otherReaches(who);
  } catch (_) {}
  if (!context.mounted) return;
  showChoices(context, title: '${who.name} · ${who.where}', choices: [...reachChoices(context, who.name, reaches), blockChoice(context, who, blocked: blocked)]);
}
