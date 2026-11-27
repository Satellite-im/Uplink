import 'package:flutter/foundation.dart';

import 'inbox.dart';

/// People, put together from the phone's contacts and the networks' (Matt, 2026-11-16: "Show telegram and signal
/// contacts when linked with icons to show which each is and filters, where contacts can be messages on multiple
/// platforms as which you like to use when stating a conversation").
///
/// One person is one row: their phone contact, their Telegram contact and their Signal contact are found to be the
/// same by their phone number (its last ten digits, so +1 555… and 555… agree), or, where one of them has no number,
/// by the same full name of two words or more, and only where that name is nobody else's. Each way they can be
/// reached is a [Reach]; starting a conversation with someone reachable more than one way asks which.

/// One way to write to someone.
@immutable
class Reach {
  const Reach.phone(String this.address) : contact = null;
  const Reach.on(InboxContact this.contact) : address = null;

  /// A text (or Uplink, for a friend) to this number.
  final String? address;

  /// A chat on this contact's network.
  final InboxContact? contact;

  /// 'phone', or the network's id ('telegram', 'signal').
  String get kind => contact?.network ?? 'phone';
}

/// Someone in the contacts, however many ways they can be reached.
@immutable
class Someone {
  const Someone({required this.name, required this.reaches, this.photo, this.number, this.label, this.friend = false, this.inPhone = false});

  final String name;
  final String? photo;

  /// The number shown under the name, where there is one.
  final String? number;

  /// The phone contact's label for the number (Mobile, Work).
  final String? label;

  /// On Uplink (lib/friends/friends.dart): a text to them goes over the internet.
  final bool friend;

  /// In the phone's own contacts.
  final bool inPhone;

  /// Every way to write to them: the phone first, then each network.
  final List<Reach> reaches;

  /// The networks they are on, by id.
  Set<String> get kinds => {for (final r in reaches) r.kind};
}

/// A phone contact, as the phone gives it (Sms.searchContacts), and whether they are a friend.
@immutable
class PhoneContact {
  const PhoneContact({required this.address, this.name, this.photo, this.label, this.friend = false});
  final String address;
  final String? name;
  final String? photo;
  final String? label;
  final bool friend;
}

/// A number's last ten digits: what two ways of writing the same number agree on.
String numberKey(String? number) {
  final d = (number ?? '').replaceAll(RegExp(r'\D'), '');
  if (d.length < 7) return '';
  return d.length > 10 ? d.substring(d.length - 10) : d;
}

/// A name as two spellings of it agree: trimmed, lowercase, runs of spaces made one.
String _nameKey(String? name) => (name ?? '').trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

/// [phone]'s people and the networks' [contacts], one row a person, in [phone]'s order and then the rest by name.
List<Someone> gather(List<PhoneContact> phone, List<InboxContact> contacts) {
  // Each person being built: their phone side, and their contacts on networks.
  final people = <_Building>[for (final p in phone) _Building(phone: p)];
  final byNumber = <String, _Building>{};
  for (final b in people) {
    final k = numberKey(b.phone!.address);
    if (k.isNotEmpty) byNumber.putIfAbsent(k, () => b);
  }

  // A name is matched only where it names one person on each side: two "Sam Rivera"s are not guessed between.
  int count(Iterable<String> names, String key) => names.where((n) => n == key).length;
  final phoneNames = [for (final p in phone) _nameKey(p.name)];

  for (final c in contacts) {
    final k = numberKey(c.number);
    _Building? into = k.isEmpty ? null : byNumber[k];
    if (into == null) {
      final n = _nameKey(c.name);
      // Unique on its own network: the same full name on Telegram and on Signal is one person seen twice, two of it on
      // one network are two people (Matt, 2026-11-18: someone on both was never put together, nor offered a new chat).
      if (n.split(' ').length >= 2 && contacts.where((x) => x.network == c.network && _nameKey(x.name) == n).length == 1) {
        // Someone with the same full name, on the phone or met already on another network.
        final candidates = [for (final b in people) if (_nameKey(b.name) == n) b];
        if (candidates.length == 1 && (count(phoneNames, n) <= 1)) {
          final b = candidates.first;
          final theirs = numberKey(b.number);
          // Two numbers that differ are two people, whatever their names.
          if (k.isEmpty || theirs.isEmpty || theirs == k) into = b;
        }
      }
    }
    // No one to join, or the person found already has a contact on this network: a row of their own.
    if (into == null || into.contacts.any((x) => x.network == c.network)) {
      into = _Building();
      people.add(into);
    }
    into.contacts.add(c);
    if (k.isNotEmpty) byNumber.putIfAbsent(k, () => into!);
  }

  final fromPhone = people.where((b) => b.phone != null).map((b) => b.build());
  final rest = people.where((b) => b.phone == null).map((b) => b.build()).toList()..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  return [...fromPhone, ...rest];
}

/// One person while [gather] puts them together: their phone contact, where they have one, and their contacts on
/// networks, one a network at most.
class _Building {
  _Building({this.phone});
  final PhoneContact? phone;
  final List<InboxContact> contacts = [];

  /// The phone's name for them first, then the first network's that has one, then their number.
  String get name {
    final n = phone?.name?.trim();
    if (n != null && n.isNotEmpty) return n;
    for (final c in contacts) {
      if (c.name.trim().isNotEmpty) return c.name;
    }
    return number ?? 'Someone';
  }

  /// The phone's number for them, else the first a network shares.
  String? get number {
    if (phone != null && phone!.address.isNotEmpty) return phone!.address;
    for (final c in contacts) {
      if (c.number != null) return c.number;
    }
    return null;
  }

  /// The finished row, with every way to reach them.
  Someone build() {
    final number = this.number;
    // Networks in a steady order: Telegram, then Signal, then any other.
    final ordered = [...contacts]..sort((a, b) => _rank(a.network).compareTo(_rank(b.network)));
    return Someone(
      name: name,
      photo: phone?.photo ?? contacts.map((c) => c.avatar).whereType<String>().firstOrNull,
      number: number,
      label: phone?.label,
      friend: phone?.friend ?? false,
      inPhone: phone != null,
      reaches: [
        // A number known from anywhere can be texted, a network contact's too; a friend by username is written to on
        // Uplink by their @username, which has no digits to make a number of (Matt, 2026-11-19: "the message with isn't
        // working we should be able to see message phill with his internal account": a friend by username had no
        // way listed, so the choice opened empty).
        if (number != null && (numberKey(number).isNotEmpty || (phone?.friend == true && number.startsWith('@')))) Reach.phone(number),
        for (final c in ordered) Reach.on(c),
      ],
    );
  }

  static int _rank(String network) => switch (network) { 'telegram' => 0, 'signal' => 1, _ => 2 };
}

/// What the list is narrowed to: everyone, the phone's contacts, friends on Uplink, or one network's.
/// Friends are a filter of their own (Matt, 2026-11-17: "add the ability to sort contacts by friends in ghost").
List<Someone> narrowed(List<Someone> people, String filter) => switch (filter) {
      'all' => people,
      'phone' => [for (final s in people) if (s.inPhone || s.friend) s],
      'friends' => [for (final s in people) if (s.friend) s],
      _ => [for (final s in people) if (s.kinds.contains(filter)) s],
    };

/// Friends on Uplink first, by name, then everyone else in the order they came (the phone's, then the
/// networks' by name, as [gather] gives them): the friends are who Matt looks for first (2026-11-17: "add the ability
/// to sort contacts by friends in ghost").
List<Someone> friendsFirst(List<Someone> people) => [
      ...[for (final s in people) if (s.friend) s]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase())),
      for (final s in people) if (!s.friend) s,
    ];

/// Whether [s] answers [query]: by name, number or handle.
bool answers(Someone s, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return true;
  if (s.name.toLowerCase().contains(q)) return true;
  final digits = q.replaceAll(RegExp(r'\D'), '');
  if (digits.length >= 3) {
    for (final r in s.reaches) {
      final n = r.address ?? r.contact?.number;
      if (n != null && n.replaceAll(RegExp(r'\D'), '').contains(digits)) return true;
    }
  }
  for (final r in s.reaches) {
    final h = r.contact?.handle?.toLowerCase();
    if (h != null && (h.contains(q) || h.substring(1).contains(q))) return true;
  }
  return false;
}
