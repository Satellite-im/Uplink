import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../net/carrier.dart';
import '../net/crypto.dart';
import '../net/net.dart';
import '../net/packet.dart';
import '../net/switchboard.dart';
import '../sms.dart';
import '../sounds.dart';
import 'friends.dart';

/// One member of a group: who they are to the routes ([id], the name of their [key]), the number the group lists them
/// under, and who they are to this phone: the address they are shown under and the contact it is.
class GroupMember {
  const GroupMember({required this.id, required this.key, this.address = '', String? shown, this.name, this.photo, this.admin = false, this.me = false}) : shown = shown ?? address;
  final String id;
  final String key;

  /// The address the group's record lists them under: its admin's word, which goes back into the record as it is
  /// changed ([Group.state]). Never what they are shown as.
  final String address;

  /// The address they are shown under (android Groups.shownAddress): this phone's own record for their key, else the
  /// listed one where it is nobody's here, else one that is nobody's ("Someone"). Never a number this phone holds a
  /// record for, nor an @name, unless it is theirs (found in review, 2026-11-23: a stranger listed under Mom's number
  /// was shown as Mom). [name] and [photo] are the contact this one is.
  final String shown;
  final String? name;
  final String? photo;

  /// Whether they are an admin of the group, and whether this member is this phone.
  final bool admin;
  final bool me;

  /// What they are called in a line about the group.
  String get label => me ? 'You' : (name ?? (shown.isEmpty ? 'Someone' : shown));

  /// Shown under a stand-in that is nobody's (android Groups.memberAddress): no address of theirs is known here.
  bool get standIn => shown.endsWith('@member.ghost-sms.com');

  /// As the screens draw a person: under the address they are shown by, never the listed one.
  Person get person => Person(address: shown, name: name, photo: photo);

  /// A member as the phone gives one (android Groups.view).
  factory GroupMember.from(Map m) => GroupMember(
        id: m['id'] as String,
        key: (m['key'] as String?) ?? '',
        address: (m['address'] as String?) ?? '',
        shown: m['shown'] as String?,
        name: m['name'] as String?,
        photo: m['photo'] as String?,
        admin: m['admin'] == true,
        me: m['me'] == true,
      );
}

/// A group of friends as this phone holds it (android Groups.view).
class Group {
  const Group({required this.id, required this.name, required this.v, required this.thread, required this.members, this.gone = false});
  final String id;
  final String name;

  /// How many times it has been changed: a later state is one with a higher count.
  final int v;

  /// Its conversation on this phone.
  final int thread;
  final List<GroupMember> members;

  /// This phone left it or was taken out: its conversation is kept, and nothing more is written in it.
  final bool gone;

  /// The member with [id]; this phone's own; everyone else; and whether this phone may change the group.
  GroupMember? member(String id) => members.where((m) => m.id == id).firstOrNull;
  GroupMember? get mine => members.where((m) => m.me).firstOrNull;
  List<GroupMember> get others => members.where((m) => !m.me).toList();
  bool get amAdmin => !gone && (mine?.admin ?? false);

  /// What it goes by: its name, or its people where it has none.
  String get title => name.isNotEmpty ? name : Conversation.peopleTitle([for (final m in others) m.person]);

  factory Group.from(Map m) => Group(
        id: m['id'] as String,
        name: (m['name'] as String?) ?? '',
        v: (m['v'] as num?)?.toInt() ?? 1,
        thread: (m['thread'] as num?)?.toInt() ?? -1,
        gone: m['gone'] == true,
        members: [for (final x in (m['members'] as List? ?? const [])) GroupMember.from(x as Map)],
      );

  /// As it is kept and told: `{id, name, v, members: [{i, k, a}], admins: [i]}`.
  Map<String, dynamic> state({String? name, int? v, List<Map<String, dynamic>>? members, List<String>? admins, bool? gone}) => {
        'id': id,
        'name': name ?? this.name,
        'v': v ?? this.v,
        'members': members ?? [for (final m in this.members) {'i': m.id, 'k': m.key, 'a': m.address}],
        'admins': admins ?? [for (final m in this.members.where((m) => m.admin)) m.id],
        if (gone ?? this.gone) 'gone': true,
      };
}

/// What [Groups] stands on: the routes and the phone. The app's own is [_AppPort]; a test gives several of its own.
abstract class GroupsPort {
  /// This phone's name to the routes; null until they are set up.
  String? get me;

  /// The routes: who [id] is to them, whether one that costs nothing is up, sending, and what comes.
  Peer? peer(String id);
  bool get internet;
  Future<Delivery> send(Peer peer, Envelope envelope);
  Stream<Received> get received;

  /// Whether the install named [id] is a friend, by the record that names it (Friends.isFriendId): a group is joined
  /// only at a friend's asking. Never by an address, which may be what another group's admin wrote for anyone.
  bool isFriend(String id);

  /// The address this phone's own records give the install named [id] (Friends.addressOf): a number, or `@username`;
  /// null where none names it.
  String? addressOf(String id);
  void wake(Peer peer);

  /// The records (android Groups.kt): read, a new one of this phone's making, a person as a member, kept.
  Future<List<Group>> groups();
  Future<Map<String, dynamic>> draft(String id, String name, List<String> addresses);
  Future<Map<String, dynamic>> member(String address);
  Future<Group> save(Map<String, dynamic> state);

  /// Told whenever the routes change: one came up, or a link to someone's device was made.
  Listenable get changed;

  /// What members are still owed ([Groups], "What a member was not handed"), as it was last kept; and keeping it.
  Future<String?> owed();
  Future<void> keepOwed(String owed);

  /// What is written in a group, kept in its conversation.
  Future<int> storeOut(String id, String words);
  Future<void> rowState(int row, String state);
  Future<void> storeIn(String id, String from, String words, int at);
  Future<void> note(String id, String words);
}

/// Groups of friends (Matt, 2026-11-14: "expand on the ability to create, name and manage groups like telegram").
///
/// **What one is.** A name, members, and admins, held on each member's phone and changed only by an admin. It is
/// made out of friends by one person, who is its first admin. It is not a group text: what is written in it goes to
/// each member by the app's routes (lib/net), sealed with that pair's key, and never as an MMS; its conversation on
/// the phone is its own (android Groups.kt).
///
/// **How it is told.** Envelopes of kind `group`, each naming the group (`g`):
/// - `state`: the whole group as it now is (`s`), from an admin, with a count that goes up by one each change. It
///   is how a group is joined (sent by a friend who is its admin), renamed, and how members are added and taken out
///   and admins made. A phone takes a state for a group it has only from someone who is an admin in the state it
///   holds, and only one with a higher count.
/// - `text`: words (`t`), from a member, to each of the others.
/// - `leave`: from a member who is going.
///
/// Two members need not be friends: each has the other's key from the state, and the phone makes their pair's key
/// from it (android Groups.peers), so the routes reach them.
///
/// With no route that costs nothing up, nothing is sent ([sendText] says so): a group has no text to fall back to.
///
/// **What a member was not handed.** A route that is up need not reach everyone: with no relay and the local network
/// route linked to two of five members (lib/net/lan), what is written goes to those two and no route takes it for the
/// other three, and with nothing more done they never had it, though the conversation said "sent" (found in the
/// review of the local network route, 2026-11-26). So what a member was not handed is owed to them: kept with the
/// app's choices, and sent, in the order it was written and under the name it first had (so one that did arrive after
/// all is not kept twice), once a route reaches them, for [owedFor]. The same of a change to the group: what is owed
/// is the group as it then is. Nothing is owed where no member at all was handed it: the conversation says it failed,
/// and the person sends it again.
class Groups extends ChangeNotifier {
  Groups(this._port);

  static Groups? _instance;
  static Groups get instance => _instance ??= Groups(_AppPort());

  /// A stand-in for the app's own, for a test of a screen; null puts the app's own back.
  @visibleForTesting
  static set instance(Groups? g) => _instance = g;

  final GroupsPort _port;
  final Map<String, Group> _by = {};
  StreamSubscription<Received>? _sub;
  bool _started = false;

  /// The most members a group can have: what one change of state can tell in a packet with room to spare.
  static const most = 50;

  /// What members were not handed, oldest first ("What a member was not handed"): how long it is owed, and the most
  /// kept (the oldest give way).
  final List<_Owed> _owed = [];
  static const owedFor = Duration(days: 7);
  static const mostOwed = 300;
  Timer? _owedSoon;
  bool _settling = false;

  /// The time, for a test to say.
  @visibleForTesting
  DateTime Function() clock = DateTime.now;

  /// How many things are owed to members now.
  @visibleForTesting
  int get owedCount => _owed.length;

  /// Starts listening to the routes and reads the groups from the phone. Once.
  Future<void> start() async {
    if (_started) return;
    _started = true;
    _sub = _port.received.listen(_received);
    await refresh();
    try {
      final kept = await _port.owed();
      if (kept != null && kept.isNotEmpty) {
        _owed
          ..clear()
          ..addAll([for (final m in jsonDecode(kept) as List) ?_Owed.from(m)]);
      }
    } catch (_) {}
    _port.changed.addListener(_routesChanged);
    unawaited(settleOwed());
  }

  Future<void> shutdown() async {
    if (_started) _port.changed.removeListener(_routesChanged);
    _owedSoon?.cancel();
    _owedSoon = null;
    await _sub?.cancel();
    _sub = null;
    _started = false;
    _by.clear();
    _owed.clear();
  }

  /// The routes changed: what is owed is tried a moment later, so many changes at once are one try.
  void _routesChanged() {
    if (_owed.isEmpty) return;
    _owedSoon?.cancel();
    _owedSoon = Timer(const Duration(milliseconds: 300), () => unawaited(settleOwed()));
  }

  /// [missed] were not handed something: it is owed to them. One change of a group owed to a member takes the place
  /// of an earlier one (what is sent is the group as it then is).
  void _owe(Iterable<_Owed> missed) {
    for (final o in missed) {
      if (o.words == null) _owed.removeWhere((x) => x.words == null && x.group == o.group && x.to == o.to);
      _owed.add(o);
    }
    if (_owed.length > mostOwed) _owed.removeRange(0, _owed.length - mostOwed);
    unawaited(_keepOwed());
  }

  Future<void> _keepOwed() async {
    try {
      await _port.keepOwed(jsonEncode([for (final o in _owed) o.toJson()]));
    } catch (_) {}
  }

  /// Sends what is owed to whoever a route now takes it for, each member's in the order it was written (what comes
  /// after one that still can't go waits behind it). Lets go of what is older than [owedFor], what was for a group
  /// this phone has left or no longer holds, and words for someone no longer in the group.
  Future<void> settleOwed() async {
    if (_settling || !_started || _owed.isEmpty || !_port.internet) return;
    _settling = true;
    final before = _owed.length;
    try {
      final now = clock().millisecondsSinceEpoch;
      final waiting = <String>{};
      for (final o in _owed.toList()) {
        if (!_started) return;
        if (!_owed.contains(o)) continue;
        final g = _by[o.group];
        if (now - o.at > owedFor.inMilliseconds || g == null || g.gone || (o.words != null && g.member(o.to) == null) || (o.words == null && !g.amAdmin)) {
          _owed.remove(o);
          continue;
        }
        final peer = _port.peer(o.to);
        if (peer == null || waiting.contains(o.to)) {
          waiting.add(o.to);
          continue;
        }
        final words = o.words;
        final envelope = words != null ? Envelope(id: o.id, kind: 'group', body: {'g': g.id, 'do': 'text', 't': words}, at: o.at) : Envelope(kind: 'group', body: {'g': g.id, 'do': 'state', 's': g.state()..remove('id')});
        Delivery d;
        try {
          d = await _port.send(peer, envelope);
        } catch (_) {
          d = Delivery(envelope.id);
        }
        if (!d.sent) {
          waiting.add(o.to);
          continue;
        }
        _owed.remove(o);
        if (!d.acked && d.handed == Handed.held) _port.wake(peer);
      }
    } finally {
      _settling = false;
      if (_owed.length != before) await _keepOwed();
    }
  }

  /// Reads the groups from the phone again.
  Future<void> refresh() async {
    try {
      final all = await _port.groups();
      _by
        ..clear()
        ..addEntries(all.map((g) => MapEntry(g.id, g)));
    } catch (_) {}
    notifyListeners();
  }

  // --- what the screens ask -------------------------------------------------------------------------------------------

  /// Every group held, left or not; the one with [id]; and the one whose conversation is [thread].
  List<Group> get all => _by.values.toList();
  Group? of(String id) => _by[id];
  Group? ofThread(int thread) => _by.values.where((g) => g.thread == thread).firstOrNull;

  /// Whether what is written in a group can go now.
  bool get online => _port.internet;

  // --- making and changing --------------------------------------------------------------------------------------------

  /// Makes a group called [name] out of friends at [addresses]. This phone is its admin.
  Future<Group> create(String name, List<String> addresses) async {
    if (addresses.isEmpty) throw StateError('A group needs someone in it');
    if (addresses.length + 1 > most) throw StateError('A group can have $most people');
    final id = NetCrypto.hex(NetCrypto.randomBytes(16));
    final state = await _port.draft(id, name.trim(), addresses);
    final group = await _keep(state);
    await _port.note(id, name.trim().isEmpty ? 'You made the group' : 'You made the group "${name.trim()}"');
    await _tell(group, group.others.map((m) => m.id));
    return group;
  }

  /// Keeps [state] on the phone and here; the group as the phone then holds it.
  Future<Group> _keep(Map<String, dynamic> state) async {
    final group = await _port.save(state);
    _by[group.id] = group;
    notifyListeners();
    return group;
  }

  /// Tells [to] the group as it now is. Whoever no route takes it for is owed it.
  Future<void> _tell(Group group, Iterable<String> to) async {
    final wire = group.state()..remove('id');
    final missed = <_Owed>[];
    await Future.wait([
      for (final id in to.toSet())
        if (_port.peer(id) case final peer?)
          () async {
            final envelope = Envelope(kind: 'group', body: {'g': group.id, 'do': 'state', 's': wire});
            Delivery d;
            try {
              d = await _port.send(peer, envelope);
            } catch (_) {
              d = Delivery(envelope.id);
            }
            if (!d.sent) {
              missed.add(_Owed(group: group.id, to: id, id: envelope.id, at: envelope.at));
            } else if (!d.acked && d.handed == Handed.held) {
              _port.wake(peer);
            }
          }(),
    ]);
    if (missed.isNotEmpty) _owe(missed);
  }

  /// The group with [id], which this phone must still be in: throws where it isn't.
  Group _mine(String id) {
    final g = _by[id];
    if (g == null || g.gone) throw StateError('Not in that group');
    return g;
  }

  /// The same, where this phone is an admin of it: throws where it isn't.
  Group _asAdmin(String id) {
    final g = _mine(id);
    if (!g.amAdmin) throw StateError('Only an admin of the group can change it');
    return g;
  }

  /// Names the group for everyone in it.
  Future<void> rename(String id, String name) async {
    final g = _asAdmin(id);
    final clean = name.trim();
    if (clean == g.name) return;
    final next = await _keep(g.state(name: clean, v: g.v + 1));
    await _port.note(id, clean.isEmpty ? 'You removed the group\'s name' : 'You named the group "$clean"');
    await _tell(next, next.others.map((m) => m.id));
  }

  /// Adds a friend at [address] to the group.
  Future<void> add(String id, String address) async {
    final g = _asAdmin(id);
    if (g.members.length >= most) throw StateError('A group can have $most people');
    final m = await _port.member(address);
    if (g.member(m['i'] as String) != null) return;
    final members = [...(g.state()['members'] as List).cast<Map<String, dynamic>>(), m];
    final next = await _keep(g.state(members: members, v: g.v + 1));
    await _port.note(id, 'You added ${next.member(m['i'] as String)?.label ?? address}');
    await _tell(next, next.others.map((x) => x.id));
  }

  /// Takes a member out of the group.
  Future<void> remove(String id, String member) async {
    final g = _asAdmin(id);
    final gone = g.member(member);
    if (gone == null || gone.me) return;
    final members = (g.state()['members'] as List).cast<Map<String, dynamic>>().where((m) => m['i'] != member).toList();
    final admins = (g.state()['admins'] as List).cast<String>().where((a) => a != member).toList();
    final next = await _keep(g.state(members: members, admins: admins, v: g.v + 1));
    await _port.note(id, 'You removed ${gone.label}');
    // The one taken out is told too: it is how their phone learns of it.
    await _tell(next, [...next.others.map((x) => x.id), member]);
  }

  /// Makes a member an admin, or no longer one.
  Future<void> setAdmin(String id, String member, bool admin) async {
    final g = _asAdmin(id);
    final who = g.member(member);
    if (who == null || who.me || who.admin == admin) return;
    final before = (g.state()['admins'] as List).cast<String>();
    final next = await _keep(g.state(admins: admin ? [...before, member] : before.where((a) => a != member).toList(), v: g.v + 1));
    await _port.note(id, admin ? 'You made ${who.label} an admin' : '${who.label} is no longer an admin');
    await _tell(next, next.others.map((x) => x.id));
  }

  /// Leaves the group. Its conversation is kept.
  Future<void> leave(String id) async {
    final g = _mine(id);
    await Future.wait([
      for (final m in g.others)
        if (_port.peer(m.id) case final peer?) _port.send(peer, Envelope(kind: 'group', body: {'g': id, 'do': 'leave'})).catchError((_) => const Delivery('')),
    ]);
    await _keep(g.state(gone: true));
    await _port.note(id, 'You left the group');
  }

  // --- what goes ------------------------------------------------------------------------------------------------------

  /// Sends [words] to a group. False, with nothing kept, where this phone is not in it or no route that costs
  /// nothing is up: the caller says so. True once they are kept in its conversation: sent where a route took them
  /// for at least one member (or there is nobody else in it), failed where none did.
  Future<bool> sendText(String id, String words) async {
    final g = _by[id];
    if (!_started || g == null || g.gone || !_port.internet) return false;
    final row = await _port.storeOut(id, words);
    var took = g.others.isEmpty;
    final missed = <_Owed>[];
    await Future.wait([
      for (final m in g.others)
        if (_port.peer(m.id) case final peer?)
          () async {
            final envelope = Envelope(kind: 'group', body: {'g': id, 'do': 'text', 't': words});
            Delivery d;
            try {
              d = await _port.send(peer, envelope);
            } catch (_) {
              d = Delivery(envelope.id);
            }
            if (!d.sent) {
              missed.add(_Owed(group: id, to: m.id, id: envelope.id, at: envelope.at, words: words));
              return;
            }
            took = true;
            if (!d.acked && d.handed == Handed.held) _port.wake(peer);
          }(),
    ]);
    await _port.rowState(row, took ? 'sent' : 'failed');
    // Handed to some and not to others: the others are owed it, and have it once a route reaches them. Handed to
    // nobody, it failed, and is the person's to send again.
    if (took && missed.isNotEmpty) _owe(missed);
    return true;
  }

  // --- what comes -----------------------------------------------------------------------------------------------------

  /// A sealed `group` envelope: a state, words, or someone leaving. One that fails is passed over.
  Future<void> _received(Received r) async {
    if (r.envelope.kind != 'group' || !r.sealed) return;
    final id = r.envelope.body['g'];
    if (id is! String) return;
    try {
      switch (r.envelope.body['do']) {
        case 'state':
          await _state(id, r);
        case 'text':
          await _text(id, r);
        case 'leave':
          await _left(id, r.peer.id);
      }
    } catch (_) {}
  }

  /// Words from a member of a group this phone is in: kept in its conversation.
  Future<void> _text(String id, Received r) async {
    final g = _by[id];
    final words = r.envelope.body['t'];
    if (g == null || g.gone || words is! String || words.isEmpty || g.member(r.peer.id) == null) return;
    await _port.storeIn(id, r.peer.id, words, r.envelope.at);
  }

  /// The member [who] said they are going: taken out here, on their own word, with no change to the count.
  Future<void> _left(String id, String who) async {
    final g = _by[id];
    final gone = g?.member(who);
    if (g == null || g.gone || gone == null) return;
    final members = (g.state()['members'] as List).cast<Map<String, dynamic>>().where((m) => m['i'] != who).toList();
    var admins = (g.state()['admins'] as List).cast<String>().where((a) => a != who).toList();
    // The last admin went: the member whose name sorts first is one now, which every phone works out alike.
    if (admins.isEmpty && members.isNotEmpty) admins = [(members.map((m) => m['i'] as String).toList()..sort()).first];
    await _keep(g.state(members: members, admins: admins));
    await _port.note(id, '${gone.label} left');
  }

  /// A state from an admin: joins the group at a friend's asking, or changes the one held where it is newer, and
  /// writes a line in the conversation for each thing that changed.
  Future<void> _state(String id, Received r) async {
    final s = r.envelope.body['s'];
    final me = _port.me;
    if (s is! Map || me == null || !RegExp(r'^[0-9a-f]{32}$').hasMatch(id)) return;
    final from = r.peer.id;
    final members = [
      for (final m in (s['members'] as List? ?? const []))
        if (m is Map && m['i'] is String && m['k'] is String) {'i': m['i'] as String, 'k': m['k'] as String, 'a': (m['a'] as String?) ?? ''},
    ];
    final admins = [for (final a in (s['admins'] as List? ?? const [])) if (a is String) a];
    final v = (s['v'] as num?)?.toInt() ?? 1;
    if (members.isEmpty || members.length > most || !admins.contains(from) || !members.any((m) => m['i'] == from)) return;
    final mine = _by[id];
    final inIt = members.any((m) => m['i'] == me);
    if (mine == null || mine.gone) {
      // Joined, or joined again, only at the asking of a friend who is an admin of it: a friend by the key that sealed
      // it, as the records say, never by the address the routes have for them (found in review, 2026-11-23: a member
      // of another group, listed by its admin under a friend's number, was taken for that friend).
      if (!inIt || !_port.isFriend(from)) return;
    } else {
      // Changed only by someone who is an admin in the group as this phone holds it, and only forward.
      if (!(mine.member(from)?.admin ?? false) || v <= mine.v) return;
    }
    // Who sent it knows their own number least: this phone knows them by its own record of them, or as the group had
    // them before.
    final known = _port.addressOf(from) ?? mine?.member(from)?.address ?? '';
    for (final m in members) {
      if (m['i'] == from && (m['a'] as String).isEmpty) m['a'] = known;
    }
    final name = ((s['name'] as String?) ?? '').trim();
    final had = mine != null && !mine.gone;
    if (had && !inIt) {
      // Taken out: the group is kept as it was, marked as left.
      await _keep(mine.state(gone: true, v: v));
      await _port.note(id, '${mine.member(from)?.label ?? 'An admin'} removed you');
      return;
    }
    final next = await _keep({'id': id, 'name': name, 'v': v, 'members': members, 'admins': admins});
    final who = next.member(from)?.label ?? 'Someone';
    if (!had) {
      Sounds.instance.play(UiSound.groupAdded);
      await _port.note(id, name.isEmpty ? '$who added you to a group' : '$who added you to "$name"');
      return;
    }
    if (name != mine.name) await _port.note(id, name.isEmpty ? '$who removed the group\'s name' : '$who named the group "$name"');
    for (final m in next.members.where((m) => mine.member(m.id) == null)) {
      await _port.note(id, '$who added ${m.label}');
    }
    for (final m in mine.members.where((m) => next.member(m.id) == null)) {
      await _port.note(id, '$who removed ${m.label}');
    }
    for (final m in next.members) {
      final before = mine.member(m.id);
      if (before != null && before.admin != m.admin) await _port.note(id, m.admin ? '$who made ${m.label} an admin' : '${m.label} is no longer an admin');
    }
  }
}

/// The app's own: the routes as the app holds them and the phone.
/// Something a member of a group was not handed: words ([words]), or a change to the group (null: what is sent is the
/// group as it is when a route takes it), under the name ([id]) and the time ([at]) it first had.
class _Owed {
  const _Owed({required this.group, required this.to, required this.id, required this.at, this.words});
  final String group, to, id;
  final int at;
  final String? words;

  Map<String, dynamic> toJson() => {'g': group, 'to': to, 'i': id, 'at': at, if (words != null) 't': words};

  static _Owed? from(Object? m) {
    if (m is! Map) return null;
    final g = m['g'], to = m['to'], id = m['i'], at = m['at'], t = m['t'];
    if (g is! String || to is! String || id is! String || at is! num || (t != null && t is! String)) return null;
    return _Owed(group: g, to: to, id: id, at: at.toInt(), words: t as String?);
  }
}

class _AppPort implements GroupsPort {
  _AppPort() {
    Net.instance.listen(_in.add);
  }

  final _in = StreamController<Received>.broadcast();

  @override
  String? get me => Net.instance.id;
  @override
  Peer? peer(String id) => Net.instance.byId(id);
  @override
  bool get internet => Friends.instance.online;

  @override
  Future<Delivery> send(Peer peer, Envelope envelope) {
    final board = Net.instance.board;
    if (board == null) return Future.value(Delivery(envelope.id, tried: const ['the routes are not set up']));
    return board.send(peer, envelope);
  }

  @override
  Stream<Received> get received => _in.stream;
  @override
  bool isFriend(String id) => Friends.instance.isFriendId(id);
  @override
  String? addressOf(String id) => Friends.instance.addressOf(id);
  @override
  void wake(Peer peer) => Friends.instance.wake(peer);

  @override
  Future<List<Group>> groups() async => [for (final m in await Sms.instance.groups()) Group.from(m)];
  @override
  Future<Map<String, dynamic>> draft(String id, String name, List<String> addresses) async => (jsonDecode(await Sms.instance.groupDraft(id, name, addresses)) as Map).cast<String, dynamic>();
  @override
  Future<Map<String, dynamic>> member(String address) async => (jsonDecode(await Sms.instance.groupMember(address)) as Map).cast<String, dynamic>();

  @override
  Future<Group> save(Map<String, dynamic> state) async {
    final group = Group.from(await Sms.instance.groupSave(jsonEncode(state)));
    // Its members are people the routes reach from now on: read before anything is sent to one.
    await Net.instance.refresh();
    return group;
  }

  @override
  Listenable get changed => Net.instance;
  @override
  Future<String?> owed() async => (await Sms.instance.prefs())['groups_owed'];
  @override
  Future<void> keepOwed(String owed) => Sms.instance.setPref('groups_owed', owed);

  @override
  Future<int> storeOut(String id, String words) => Sms.instance.groupTextOut(id, words);
  @override
  Future<void> rowState(int row, String state) => Sms.instance.groupTextState(row, state);
  @override
  Future<void> storeIn(String id, String from, String words, int at) => Sms.instance.groupTextIn(id, from, words, at);
  @override
  Future<void> note(String id, String words) => Sms.instance.groupNote(id, words);
}
