import 'package:flutter/widgets.dart';
import 'package:ghost_messaging/art/lucide.g.dart';
import 'package:ghost_messaging/plugins/plugin.dart';
import 'package:ghost_messaging/plugins/ui.dart';

/// A plugin made up for the tests, using every extension point of the contract: texts that name a ticket ("ticket
/// 4411") are tagged, and those not from a contact get a Tickets section whose rows show the number large.
class TicketsPlugin extends GhostPlugin {
  TicketsPlugin({this.onByDefault = true});

  /// How many times its classifier has been asked.
  int asked = 0;

  @override
  String get id => 'tickets';
  @override
  String get name => 'Tickets';
  @override
  String get description => 'Texts with a ticket number get a section of their own.';
  @override
  final bool onByDefault;

  static final _ticket = RegExp(r'ticket (\d+)');

  PluginAction _copy(String number) => PluginAction(label: 'Copy $number', icon: Lucide.copy, run: (host) => host.copy(number, say: 'Copied $number'));
  PluginAction _keep(int thread) => PluginAction(label: 'Keep in Messages', icon: Lucide.messageSquare, run: (host) => host.move(thread, null));
  PluginAction _file(int thread) => PluginAction(label: 'Move to Tickets', icon: Lucide.ticket, run: (host) => host.move(thread, 'tickets'));

  @override
  List<Classifier> get classifiers => [
        (facts) {
          asked++;
          final found = _ticket.firstMatch(facts.text);
          return found == null ? const [] : [Tag('ticket', found.group(1))];
        },
      ];

  @override
  List<ListSection> get sections => [
        ListSection(
          id: 'tickets',
          label: 'Tickets',
          icon: Lucide.ticket,
          takes: (facts, tags, prefs) => tags.has('ticket') && !facts.contact,
          row: (facts, tags, prefs) {
            final number = tags.detail('ticket');
            return number == null ? const RowLook(caption: 'Filed here by you') : RowLook(value: number, caption: 'A ticket', end: _copy(number), word: _keep(facts.thread), tap: _copy(number));
          },
        ),
      ];

  @override
  List<SlotFill> get slots => [
        Slots.listHeader.fill((place, prefs) => [PluginAction(label: 'Ticket desk', icon: Lucide.ticket, run: (host) => host.say('${place.shown} shown'))]),
        Slots.aboveList.fill((context, place, prefs) => [if (place.section == 'tickets') const PluginNote('Tickets wait here.')]),
        Slots.conversationMenu.fill((place, prefs) => [
              if (place.section == 'tickets') _keep(place.facts.thread) else if (place.tags.has('ticket')) _file(place.facts.thread),
            ]),
        Slots.conversationHeader.fill((place, prefs) => [if (place.tags.has('ticket')) _copy(place.tags.detail('ticket')!)]),
        Slots.composer.fill((place, prefs) => [PluginAction(label: 'Ask for a ticket', icon: Lucide.ticket, run: (host) => host.write('Ticket please'))]),
        Slots.messageMenu.fill((place, prefs) => [if (place.tags.has('ticket')) _copy(place.tags.detail('ticket')!)]),
        Slots.settings.fill((context, place, prefs) => [const Text('A row of its own')]),
      ];

  @override
  List<IncomingRule> get incoming => [
        (facts, tags, section, prefs) => [
              if (section == 'tickets' && prefs.flag('read', fallback: false)) const MarkRead(),
              if (section == 'tickets' && prefs.flag('quiet', fallback: false)) const MuteNotification(),
              if (facts.text.contains('urgent ticket')) const MoveToSection('tickets'),
            ],
      ];

  @override
  List<PluginSetting> get settings => const [
        PluginSetting.toggle(key: 'read', label: 'Mark tickets as read', hint: 'As they arrive.', fallback: false),
        PluginSetting.note(label: 'What a ticket is', hint: 'A text that says "ticket" and a number.'),
      ];
}

/// A plugin whose every part throws.
class BrokenPlugin extends GhostPlugin {
  const BrokenPlugin();
  @override
  String get id => 'broken';
  @override
  String get name => 'Broken';
  @override
  String get description => 'Throws whenever it is asked anything.';
  @override
  List<Classifier> get classifiers => [(facts) => throw StateError('classifier')];
  @override
  List<ListSection> get sections => [ListSection(id: 'broken', label: 'Broken', icon: Lucide.circleAlert, takes: (f, t, p) => throw StateError('takes'), row: (f, t, p) => throw StateError('row'))];
  @override
  List<SlotFill> get slots => [Slots.listHeader.fill((place, prefs) => throw StateError('slot'))];
  @override
  List<IncomingRule> get incoming => [(f, t, s, p) => throw StateError('incoming')];
}
