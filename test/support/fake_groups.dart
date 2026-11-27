import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:ghost_messaging/friends/groups.dart';
import 'package:ghost_messaging/net/carrier.dart';
import 'package:ghost_messaging/net/packet.dart';
import 'package:ghost_messaging/net/switchboard.dart';

// Stand-ins for what Groups stands on (lib/friends/groups.dart, GroupsPort): several phones in one [World], each
// with its own records and conversation, and what one sends handed to the one it is for.

/// The phones there are, by the names of their keys.
class World {
  final Map<String, FakeGroupsPort> phones = {};
}

class _Routes extends ChangeNotifier {
  void say() => notifyListeners();
}

class FakeGroupsPort implements GroupsPort {
  FakeGroupsPort(this.world, this.number) {
    world.phones[me] = this;
  }

  final World world;

  /// This phone's number. Its name to the routes is made from it, as a key's would be: 32 hex digits.
  final String number;

  @override
  late final String me = number.replaceAll(RegExp(r'[^0-9]'), '').padLeft(32, '0');
  String get key => 'key-of-$number';

  /// The numbers of this phone's friends (encryption on, and friends).
  final Set<String> friends = {};

  /// The address the routes hold another phone under here, by its name, where it is not that phone's own number: on
  /// Android, a member of a group is held under whatever the group's admin wrote for them.
  final Map<String, String> listedAs = {};

  String _addressOf(String id) => listedAs[id] ?? world.phones[id]!.number;

  bool up = true;
  bool here = true;

  /// The phones no route reaches from here just now, by name, though one is up: as with no relay and the local network
  /// linked to some members and not others. What is sent to one is taken by no route.
  final Set<String> unreached = {};

  /// What is owed to members as this phone last kept it, and the routes changing (a test says when).
  String? keptOwed;
  final _routes = _Routes();
  @override
  Listenable get changed => _routes;

  /// The routes changed, as when one comes up or a link to someone's device is made.
  void routesChanged() => _routes.say();
  @override
  Future<String?> owed() async => keptOwed;
  @override
  Future<void> keepOwed(String owed) async => keptOwed = owed;

  /// For a screen's picture: the conversation a group is on this phone, and who a number is in its contacts.
  final Map<String, int> threads = {};
  final Map<String, String> names = {};

  /// The groups as this phone keeps them, what is in each one's conversation, and who was sent the wake.
  final Map<String, Map<String, dynamic>> records = {};
  final Map<String, List<String>> lines = {};
  final rows = <int, ({String group, String words, String state})>{};
  final woken = <String>[];
  final sent = <({String to, Envelope envelope})>[];
  final List<({String from, Envelope envelope})> _held = [];
  final _in = StreamController<Received>.broadcast();

  FakeGroupsPort? _phoneAt(String number) => world.phones.values.where((p) => p.number == number).firstOrNull;

  /// Whether the routes reach the phone named [id] from here: a friend, or a member of a group this phone is in.
  bool _reaches(String id) {
    final other = world.phones[id];
    if (other == null) return false;
    if (friends.contains(other.number)) return true;
    return records.values.any((r) => r['gone'] != true && (r['members'] as List).any((m) => (m as Map)['i'] == id));
  }

  @override
  Peer? peer(String id) => _reaches(id) ? Peer(id: id, key: Uint8List(32), address: _addressOf(id)) : null;

  @override
  bool get internet => up;

  @override
  Future<Delivery> send(Peer peer, Envelope envelope) async {
    sent.add((to: peer.id, envelope: envelope));
    if (!up) return Delivery(envelope.id, tried: const ['hub: not up']);
    if (unreached.contains(peer.id)) return Delivery(envelope.id, tried: const ['lan: they are not on this network now']);
    final other = world.phones[peer.id]!;
    if (!other.here) {
      other._held.add((from: me, envelope: envelope));
      return Delivery(envelope.id, via: 'hub', handed: Handed.held);
    }
    other._arrive(me, envelope);
    return Delivery(envelope.id, via: 'hub', handed: Handed.passed, acked: true);
  }

  /// As the switchboard does: nothing is taken from a name the routes do not reach from here.
  void _arrive(String from, Envelope envelope) {
    if (!_reaches(from)) return;
    _in.add(Received(Peer(id: from, key: Uint8List(32), address: _addressOf(from)), envelope, 'hub'));
  }

  /// This phone's app opens: what was kept for it is handed over.
  void back() {
    here = true;
    for (final h in _held) {
      _arrive(h.from, h.envelope);
    }
    _held.clear();
  }

  @override
  Stream<Received> get received => _in.stream;
  /// A friend by the name of their key: the phone so named is one whose number is a friend's here (its record's key).
  @override
  bool isFriend(String id) => friends.contains(world.phones[id]?.number);

  /// A friend's own number, as their record has it; nobody else's is known here but by a group.
  @override
  String? addressOf(String id) {
    final number = world.phones[id]?.number;
    return friends.contains(number) ? number : null;
  }

  @override
  void wake(Peer peer) => woken.add(peer.id);

  Group _view(Map<String, dynamic> r) => Group.from({
        ...r,
        'thread': threads[r['id']] ?? 100 + records.keys.toList().indexOf(r['id'] as String),
        'members': [
          for (final m in (r['members'] as List).cast<Map>())
            {'id': m['i'], 'key': m['k'], 'address': m['a'], 'name': names[m['a']], 'admin': (r['admins'] as List).contains(m['i']), 'me': m['i'] == me},
        ],
      });

  @override
  Future<List<Group>> groups() async => records.values.map(_view).toList();

  @override
  Future<Map<String, dynamic>> draft(String id, String name, List<String> addresses) async => {
        'id': id,
        'name': name,
        'v': 1,
        'members': [
          {'i': me, 'k': key, 'a': ''},
          for (final a in addresses) await member(a),
        ],
        'admins': [me],
      };

  @override
  Future<Map<String, dynamic>> member(String address) async {
    final other = _phoneAt(address);
    if (other == null || !friends.contains(address)) throw StateError('No key is here for $address');
    return {'i': other.me, 'k': other.key, 'a': address};
  }

  @override
  Future<Group> save(Map<String, dynamic> state) async {
    final id = state['id'] as String;
    records[id] = {...state, 'members': [for (final m in (state['members'] as List)) Map<String, dynamic>.from(m as Map)], 'admins': List<String>.from(state['admins'] as List)};
    return _view(records[id]!);
  }

  @override
  Future<int> storeOut(String id, String words) async {
    final row = rows.length + 1;
    rows[row] = (group: id, words: words, state: 'sending');
    (lines[id] ??= []).add('me: $words');
    return row;
  }

  @override
  Future<void> rowState(int row, String state) async => rows[row] = (group: rows[row]!.group, words: rows[row]!.words, state: state);
  @override
  Future<void> storeIn(String id, String from, String words, int at) async => (lines[id] ??= []).add('${world.phones[from]!.number}: $words');
  @override
  Future<void> note(String id, String words) async => (lines[id] ??= []).add('* $words');
}
