import 'package:flutter/widgets.dart';

import '../art/lucide.g.dart';
import '../friends/friends.dart';
import '../inbox/inbox.dart';
import '../inbox/people.dart';
import '../sms.dart';
import 'blocking.dart';
import 'common.dart';
import 'inbox_ui.dart' show inboxMark, openInboxChat;
import 'shell.dart';
import 'thread.dart';

/// A new chat with the person a conversation is with, the other ways they can be reached (Matt, 2026-11-18: "add a way
/// to start a new chat with a contact from the contact menu right now it just says "block contact""): from a texts
/// conversation their Telegram or Signal, from a Telegram chat their number or their Signal, and so on. They are found
/// as Contacts finds them (lib/inbox/people.dart): the same number, or the same full name nobody else has.

/// Every way to reach [who] but the one their conversation is on.
Future<List<Reach>> otherReaches(BlockTarget who) async {
  final contacts = [for (final n in Inbox.instance.ready) ...n.contacts];
  final network = who.network;
  String? number;
  InboxContact? here;
  if (network == null) {
    number = who.id;
  } else {
    here = network.contacts.where((c) => c.id == who.id).firstOrNull;
    number = here?.number;
  }
  // A network's contact with no number: the phone's contact of the same name gives one, where there is just one.
  final phone = <PhoneContact>[];
  if (number != null && number.isNotEmpty) {
    phone.add(PhoneContact(address: number, name: who.name));
  } else if (!Sms.remote || Sms.can('searchContacts')) {
    try {
      final found = [for (final c in await Sms.instance.searchContacts(who.name)) if ((c['name'] ?? '').trim().toLowerCase() == who.name.trim().toLowerCase()) c];
      if (found.length == 1 && (found.single['address'] ?? '').isNotEmpty) phone.add(PhoneContact(address: found.single['address']!, name: who.name));
    } catch (_) {}
  }
  final people = gather(phone, contacts);
  bool isHere(Reach r) => network == null ? r.contact == null && numberKey(r.address) == numberKey(who.id) : r.contact?.network == network.id && r.contact?.id == who.id;
  // The row this conversation's person is: by this way of reaching them, or by their name for a chat whose contact the
  // network has not listed.
  final them = people.where((s) => s.reaches.any(isHere)).firstOrNull ??
      (here == null ? people.where((s) => s.name.trim().toLowerCase() == who.name.trim().toLowerCase()).firstOrNull : null);
  if (them == null) return const [];
  return [for (final r in them.reaches) if (!isHere(r) && !(network != null && r.contact?.network == network.id)) r];
}

/// The menu's lines for [reaches]: one a way, each opening a chat with them there.
List<Choice> reachChoices(BuildContext context, String name, List<Reach> reaches) {
  final friends = {for (final f in Friends.instance.friends) Friends.digits(f.address)};
  return [
    for (final r in reaches)
      if (r.contact == null)
        friends.contains(Friends.digits(r.address!))
            ? Choice('New chat on Uplink', Lucide.userCheck, () => openReach(context, name, r), hint: '${r.address} · over the internet')
            : Choice('New text message', Lucide.messageSquare, () => openReach(context, name, r), hint: r.address)
      else
        Choice(
          'New chat on ${Inbox.instance.named(r.contact!.network)?.name ?? r.contact!.network}',
          Lucide.messageSquare,
          () => openReach(context, name, r),
          mark: Inbox.instance.named(r.contact!.network) == null ? null : inboxMark(Inbox.instance.named(r.contact!.network)!, size: 20),
          hint: r.contact!.handle ?? r.contact!.number ?? r.contact!.name,
        ),
  ];
}

/// Opens the chat with [name] by [r]: a conversation of texts, or a chat on the network, made there where there is
/// none yet. In the app's frame it takes the pane; on its own it opens over the page.
Future<void> openReach(BuildContext context, String name, Reach r) async {
  try {
    final c = r.contact;
    if (c == null) {
      final person = Person(address: r.address!, name: name);
      final thread = await Sms.instance.threadFor([person.address]);
      if (!context.mounted) return;
      final shell = AppShell.maybeOf(context);
      if (shell != null) return shell.openThread(thread, [person]);
      push<void>(context, (_) => ThreadScreen(thread: thread, people: [person]));
      return;
    }
    final network = Inbox.instance.named(c.network);
    if (network == null) return;
    final chat = await network.chatWith(c);
    if (!context.mounted) return;
    if (chat == null) {
      toast(context, 'Couldn\'t start a chat with $name on ${network.name}');
      return;
    }
    openInboxChat(context, network, network.chats.where((x) => x.id == chat).firstOrNull ?? InboxChat(network: network.id, id: chat, title: c.name, date: DateTime.now(), avatar: c.avatar));
  } catch (e) {
    if (context.mounted) toast(context, 'Couldn\'t start that chat: $e');
  }
}
