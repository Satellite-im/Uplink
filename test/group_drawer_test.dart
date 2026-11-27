import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/inbox/inbox.dart';
import 'package:ghost_messaging/inbox/signal.dart';
import 'package:ghost_messaging/inbox/telegram.dart';
import 'package:ghost_messaging/ui/group_drawer.dart';
import 'package:ghost_messaging/ui/inbox_ui.dart';
import 'package:glacier/glacier.dart';

import 'support/list_harness.dart';

/// A group's drawer (lib/ui/group_drawer.dart; Matt, 2026-11-16: "Add them to a drawer when pressing and holding on
/// the group name add support for all supported featues"): what Signal's helper and Telegram say of a group, and the
/// drawer that changes it.
class _Net extends InboxNetwork {
  _Net(this.details);
  GroupDetails details;
  final changes = <GroupChange>[];

  @override
  String get id => 'signal';
  @override
  String get name => 'Signal';
  @override
  InboxState get state => InboxState.ready;
  @override
  String? get error => null;
  @override
  String? get account => null;
  @override
  List<InboxChat> get chats => [InboxChat(network: 'signal', id: 'g1', title: details.title, date: DateTime(2026, 11, 16, 12), snippet: 'tent is packed', group: true)];
  @override
  List<InboxContact> get contacts => const [InboxContact(network: 'signal', id: 'c9', name: 'Priya Shah', number: '+15550009999')];
  @override
  List<InboxMessage> messagesOf(String chatId) => const [];
  @override
  Future<void> load(String chatId, {bool older = false}) async {}
  @override
  Future<void> send(String chatId, String text) async {}
  @override
  Future<void> markRead(String chatId) async {}
  @override
  set watching(String? chatId) {}
  @override
  Future<void> start(AppState app) async {}
  @override
  Future<void> signOut() async {}

  @override
  Future<GroupDetails?> groupDetails(String chatId) async => details;

  @override
  Future<GroupDetails?> changeGroup(String chatId, GroupChange change) async {
    changes.add(change);
    if (change.leave) return null;
    details = GroupDetails(
      title: change.title ?? details.title,
      description: change.description ?? details.description,
      timer: change.timer ?? details.timer,
      people: [
        for (final p in details.people)
          if (!change.remove.contains(p.id)) GroupPerson(id: p.id, name: p.name, number: p.number, me: p.me, admin: change.admin.contains(p.id) || (p.admin && !change.unadmin.contains(p.id))),
        for (final a in change.add) GroupPerson(id: a, name: 'Priya Shah'),
      ],
      admin: details.admin,
      announcementsOnly: change.announcementsOnly ?? details.announcementsOnly,
      supports: details.supports,
      canEditInfo: details.canEditInfo,
      canAddPeople: details.canAddPeople,
      canRemovePeople: details.canRemovePeople,
      canSetAdmins: details.canSetAdmins,
      canChangeRules: details.canChangeRules,
      inviteLink: details.inviteLink,
    );
    notifyListeners();
    return details;
  }
}

GroupDetails _crew({bool admin = true}) => GroupDetails(
      title: 'Weekend crew',
      description: 'Camping, mostly',
      timer: 0,
      people: const [
        GroupPerson(id: 'me', name: 'Matt', me: true, admin: true),
        GroupPerson(id: 'a1', name: 'Jo Park', number: '+15550001111'),
      ],
      admin: admin,
      supports: GroupFeature.values.toSet(),
      canEditInfo: admin,
      canAddPeople: true,
      canRemovePeople: admin,
      canSetAdmins: admin,
      canChangeRules: admin,
      inviteLink: 'https://signal.group/#abc',
    );

void main() {
  group('what each network says of a group', () {
    test('Signal: names, roles, rules and what you may do as a member or an admin', () {
      final m = {
        'id': 'g1',
        'title': 'Weekend crew',
        'description': 'Camping',
        'timer': 3600,
        'people': [
          {'aci': 'me', 'name': 'Matt', 'number': '+15550000000', 'admin': false, 'me': true},
          {'aci': 'a1', 'name': '', 'number': '+15550001111', 'admin': true, 'me': false},
          {'aci': 'a2', 'name': '', 'number': '', 'admin': false, 'me': false},
        ],
        'pending': [],
        'requesting': [],
        'admin': false,
        'edit_info': 'admins',
        'add_members': 'members',
        'announcements_only': false,
        'invite_link': 'https://signal.group/#x',
      };
      final g = signalGroupDetails(m, names: {'a2': 'Sam Rivera'});
      expect(g.title, 'Weekend crew');
      expect(g.timer, 3600);
      expect(g.people.map((p) => p.name), ['Matt', '+15550001111', 'Sam Rivera'], reason: 'a profile name, else the app\'s name for them, else their number');
      expect(g.people[1].admin, isTrue);
      expect((g.editInfoAdminsOnly, g.addPeopleAdminsOnly), (true, false));
      expect((g.canEditInfo, g.canAddPeople, g.canRemovePeople, g.canSetAdmins), (false, true, false, false), reason: 'a member, where only admins edit');
      final asAdmin = signalGroupDetails({...m, 'admin': true});
      expect((asAdmin.canEditInfo, asAdmin.canRemovePeople, asAdmin.canSetAdmins, asAdmin.canChangeRules), (true, true, true, true));
    });

    test('Telegram: the owner may do everything, an admin what their rights say, a member what the group allows', () {
      final chat = {
        'title': 'Book club',
        'message_auto_delete_time': 86400,
        'permissions': {'can_send_basic_messages': true, 'can_change_info': false, 'can_invite_users': true},
      };
      final people = [
        {'id': '1', 'name': 'Matt', 'number': '15550000000', 'status': 'chatMemberStatusCreator', 'me': true},
        {'id': '2', 'name': 'Ana', 'number': '', 'status': 'chatMemberStatusAdministrator', 'me': false},
        {'id': '3', 'name': 'Ben', 'number': '', 'status': 'chatMemberStatusMember', 'me': false},
      ];
      final owner = telegramGroupDetails(chat: chat, mine: {'@type': 'chatMemberStatusCreator'}, people: people);
      expect((owner.timer, owner.canEditInfo, owner.canSetAdmins, owner.canRemovePeople), (86400, true, true, true));
      expect(owner.people.first.owner, isTrue);
      expect(owner.people.first.number, '+15550000000');
      expect(owner.editInfoAdminsOnly, isTrue);
      final admin = telegramGroupDetails(chat: chat, mine: {'@type': 'chatMemberStatusAdministrator', 'rights': {'can_change_info': true, 'can_restrict_members': true}}, people: people);
      expect((admin.canEditInfo, admin.canRemovePeople, admin.canSetAdmins), (true, true, false));
      final member = telegramGroupDetails(chat: chat, mine: {'@type': 'chatMemberStatusMember'}, people: people);
      expect((member.canEditInfo, member.canAddPeople, member.canRemovePeople), (false, true, false));
    });

    test('Telegram\'s rules: only admins write turns every way of sending off; the others one permission each', () {
      final p = telegramPermissions({'can_send_basic_messages': true, 'can_send_photos': true, 'can_change_info': true, 'can_invite_users': true}, announcementsOnly: true, editInfoAdminsOnly: true);
      expect(p['@type'], 'chatPermissions');
      expect((p['can_send_basic_messages'], p['can_send_photos'], p['can_change_info'], p['can_invite_users']), (false, false, false, true));
    });
  });

  testWidgets('a long press on the group\'s name opens its drawer; a change made there is made on the network', (tester) async {
    final sheet = await loadSheet(tester);
    final net = _Net(_crew());
    await pumpScreen(tester, sheet, InboxChatScreen(network: net, chatId: 'g1'), AppState());
    await settle(tester);
    await tester.longPress(find.text('Weekend crew').first);
    await settle(tester);
    expect(find.byType(GroupDrawer), findsOneWidget);
    expect(find.textContaining(RegExp('2 people', caseSensitive: false)), findsOneWidget);
    expect(find.text('Camping, mostly'), findsOneWidget);

    // Renamed: on the network, and the drawer shows it.
    await tester.enterText(find.descendant(of: find.byType(GroupDrawer), matching: find.byType(EditableText)).first, 'Camping crew');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester);
    expect(net.changes.last.title, 'Camping crew');

    // Jo made admin, from their row.
    await tester.ensureVisible(find.text('Jo Park'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Jo Park'));
    await settle(tester);
    await tester.tap(find.text('Make admin'));
    await settle(tester);
    expect(net.changes.last.admin, ['a1']);

    // The timer.
    await tester.ensureVisible(find.text('Disappearing messages'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Disappearing messages'));
    await settle(tester);
    await tester.tap(find.text('1 day'));
    await settle(tester);
    expect(net.changes.last.timer, 86400);

    // Someone added from the network's contacts.
    await tester.ensureVisible(find.text('Add people'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add people'));
    await settle(tester);
    await tester.pump(const Duration(seconds: 6)); // the last change's toast gone from over the sheet
    await tester.tap(find.text('Priya Shah'));
    await settle(tester);
    expect(net.changes.last.add, ['c9']);

    // A rule, from its switch.
    final rule = find.ancestor(of: find.text('Only admins can send messages'), matching: find.byType(Row)).first;
    tester.widget<GlacierSwitch>(find.descendant(of: find.ancestor(of: rule, matching: find.byType(Padding)).first, matching: find.byType(GlacierSwitch)).first).onCheckedChange!(true);
    await settle(tester);
    expect(net.changes.last.announcementsOnly, isTrue);

    // Leaving, asked first: the drawer closes.
    await tester.pump(const Duration(seconds: 6));
    await tester.ensureVisible(find.text('Leave the group'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Leave the group'));
    await settle(tester);
    await tester.pump(const Duration(seconds: 6));
    await tester.tap(find.text('Leave the group').last);
    await settle(tester);
    expect(net.changes.last.leave, isTrue);
    expect(find.byType(GroupDrawer), findsNothing);
  });

  testWidgets('a member where only admins edit sees the group but is offered no change to it', (tester) async {
    final sheet = await loadSheet(tester);
    final net = _Net(_crew(admin: false));
    await pumpScreen(tester, sheet, InboxChatScreen(network: net, chatId: 'g1'), AppState());
    await settle(tester);
    await tester.longPress(find.text('Weekend crew').first);
    await settle(tester);
    expect(find.text('Only admins can change this group\'s details.'), findsOneWidget);
    expect(find.text('Change picture'), findsNothing);
    expect(find.descendant(of: find.byType(GroupDrawer), matching: find.byType(EditableText)), findsNothing, reason: 'name and description shown, not editable');
    await tester.ensureVisible(find.text('Jo Park'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Jo Park'));
    await settle(tester);
    expect(find.text('Make admin'), findsNothing);
    expect(find.text('Remove from the group'), findsNothing);
    expect(find.text('Copy +15550001111'), findsOneWidget);
  });

  testWidgets('a chat with one person has no drawer', (tester) async {
    final sheet = await loadSheet(tester);
    final net = _OneToOne(_crew());
    await pumpScreen(tester, sheet, InboxChatScreen(network: net, chatId: 'g1'), AppState());
    await settle(tester);
    await tester.longPress(find.text('Weekend crew').first);
    await settle(tester);
    expect(find.byType(GroupDrawer), findsNothing);
  });
}

class _OneToOne extends _Net {
  _OneToOne(super.details);
  @override
  List<InboxChat> get chats => [InboxChat(network: 'signal', id: 'g1', title: details.title, date: DateTime(2026, 11, 16, 12), snippet: 'hi')];
}
