import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../account/account.dart' show Account;
import '../app_state.dart';
import '../net/carrier.dart';
import '../net/hub_link.dart';
import '../net/net.dart';
import '../net/packet.dart';
import '../net/switchboard.dart';
import '../sms.dart';
import '../sounds.dart';
import 'buddies.dart' show Buddies;

/// What [Friends] stands on: the app's routes (lib/net) and the phone. The app's own is [_AppPort]; a test gives two
/// of its own and lets what one sends reach the other.
abstract class FriendsPort {
  /// The routes' peer for the install named [id], or null where they don't reach it. Friends asks by the id the record
  /// for an address names ([Friends.idOf]), never by an address: the routes' list can hold someone under an address
  /// that isn't theirs (on Android, a member of a group under whatever its admin wrote).
  Peer? peer(String id);

  /// Whether a route that costs nothing is up now: the relay server's, later the local network's; the direct route's
  /// only while a link to someone's device is open.
  bool get internet;

  /// Sends [envelope] to [peer] by the routes. [metered] lets it go by a route that costs (a text); [only] names
  /// the routes it may go by.
  Future<Delivery> send(Peer peer, Envelope envelope, {bool metered = false, bool sealed = true, Set<String>? only});

  /// What the routes bring, and the name of each thing sent as the other install says it has it, however late.
  Stream<Received> get received;
  Stream<String> get acked;

  /// Where encryption and friendship stand with everyone something has been exchanged with.
  Future<List<E2eState>> states();

  /// Whether this device keeps the records for numbers and acts on them: the Android phone. Every other device of an
  /// account (a computer paired with the phone, an iPhone or a computer of its own, a browser) carries friends by
  /// username alone, though what is sent to the account reaches it too: the phone's records for numbers, which a paired
  /// computer shows, are the phone's to act on, say nothing there of who an install is ([Friends.whoIs]), and are never
  /// asked again or answered for from there.
  bool get numbers;

  /// Whether the install [id] is in this device's list of friends by username, whatever it stands at (asked, asking,
  /// friends, blocked): Buddies'. Such an install is never told "end" by Friends ([Friends]' answer to words from one no
  /// record names).
  bool knows(String id);
  Future<void> setFriend(String address, String state);

  /// Sends this phone's key to [address] by text: what turns encryption on, or asks for it.
  Future<void> offerKeys(String address);

  /// A friend's words kept with the phone's messages (android Friends.kt): going, what became of them, taken back,
  /// and come.
  Future<int> storeOut(String address, String words, {int? at});

  /// Sends [envelope] to this account's other devices (the same identity, here under other connections): sealed with
  /// the account's own key, so only they open it. A delivery with nothing sent where there is no account here
  /// (GMFB-21).
  Future<Delivery> sendMine(Envelope envelope, {bool hubOnly = false});

  /// Whether [peer] is this account's own other devices: what [sendMine] reaches, and what it comes from.
  bool isMine(Peer peer);

  /// The conversations with friends by username kept here, for a new device of the account (GMFB-53): each its
  /// address and its newest messages, oldest first.
  Future<List<({String address, List<PastRow> rows})>> history();

  /// Messages of [address]'s conversation that another device of the account held, kept here once each: how many new.
  Future<int> keepHistory(String address, List<PastRow> rows);

  /// This device's number on the account's list and its name; null where it is in no account.
  ({String device, String name})? get thisDevice;

  /// The name on the account's list of the device numbered [device], where it is listed now and is [hub] on the hub (the
  /// name the hub vouched for on what it sent); null where not (Account.vouches).
  Future<String?> vouch(String device, String hub);

  /// The numbers of the devices on the account's list, where this device can read it (it holds the account's key: not
  /// a browser); null where it can't.
  Future<List<String>?> listedDevices();
  Future<void> rowState(int id, String state);
  Future<void> dropRow(int id);
  Future<void> storeIn(String address, String words, int at);

  /// Tells when the people or the routes change.
  Listenable get changed;

  /// Whether a relay server answers where the app would look for one. Asked before anyone is a friend, when the
  /// routes have had nobody to dial for.
  Future<bool> probe();

  /// Whether what was last sent to the install [id] waits on this app's relay for theirs to be reached (it said so:
  /// `waiting` in its answer): what is unanswered for them is sent again only now and then meanwhile, since every copy
  /// would wait beside the first (found in the review, 2026-11-23).
  bool waitingAtRelay(String id);
}

/// A message as one device of an account hands it to another that has just been signed in on (GMFB-53;
/// [Friends.historyKind]): its words, when it was written, and whether it was this account's own.
typedef PastRow = ({String t, int at, bool o});

/// Friends (Matt, 2026-11-14: "Add a friend system that allows users to talk without using SMS or MMS but still
/// validate accounts by telephone numbers for now. If both users chatting are on ghost messenger show an 'add
/// friend' button").
///
/// **Who can be one.** Someone encryption is on with: the two phones exchanged keys by text, which is what proved
/// each number to the other. Add friend on someone who has the app and has not exchanged keys yet sends this
/// phone's key first ('want'), and asks as soon as theirs is here.
///
/// **Becoming friends** is said over the routes (lib/net), sealed, as an envelope of kind `friend`: `ask`, then
/// `yes` from the other, or `no`; `end` when one of them stops. Two who ask each other are friends at once. Where
/// the two stand is kept on the phone's encryption record for them (android E2e.friend): '', 'want', 'asked',
/// 'invited', 'yes'.
///
/// **What friends write** goes as an envelope of kind `text` by a route that costs nothing, and is kept with the
/// phone's own messages on both phones, so the conversation, the list, search and a paired computer show it as
/// they show a text, marked as having come by the internet. Where no such route is up it is not sent this way at
/// all ([sendText] says so) and goes as the encrypted text it would have been. Where the relay server is keeping it
/// for a friend who is away, one data text with nothing in it follows (`wake`, at most every ten minutes a
/// person), so a closed app's phone can say a message is waiting.
///
/// Nothing is offered until a relay server is known to answer ([available]): a build with none to reach offers
/// what it did before.
///
/// **Who someone is** comes from the records that say so, by the name of their key (found in review, 2026-11-23):
/// a number friend is the encryption record for that number, whose key gives an id (android E2e.state); a friend by
/// username is the record their username stands for (UsernameChats.states), by the ids of their installs. What comes
/// is from whoever the record naming the id that sealed it is for ([addressOf]); what goes, goes to the id the record
/// for an address names ([idOf]). The address the routes have for someone is never asked: on Android they reach the
/// members of this phone's groups too, each under whatever address the group's admin wrote, which may be a friend's
/// number or "@friend".
class Friends extends ChangeNotifier {
  Friends(this._port);

  static Friends? _instance;
  static Friends get instance => _instance ??= Friends(_AppPort());

  /// A stand-in for the app's own, for a test of a screen; null puts the app's own back.
  @visibleForTesting
  static set instance(Friends? f) => _instance = f;

  final FriendsPort _port;
  AppState? _app;

  /// Where each person stands, by their number's [digits].
  final Map<String, E2eState> _by = {};

  /// Who each install is: the record that names its id, by that record's address ([digits]), as [whoIs] decides.
  Map<String, String> _byId = {};
  final Map<String, int> _rows = {};

  /// When each friend was last sent a wake, by their id.
  final Map<String, DateTime> _woke = {};

  /// What went out and has had no answer yet, by its envelope's id: sent again until the friend's app says it has
  /// it ([_resend]). Kept with the app's choices (`friends_out`), so an app closed meanwhile goes on after.
  final Map<String, _Out> _out = {};

  /// The ids of what friends wrote that is kept already (`friends_in`, the newest [keepSeen]): what is sent again
  /// because an answer was lost is not kept twice.
  final List<String> _seen = [];
  Timer? _again;

  /// How long something unanswered is sent again for before it is said to have failed.
  static const giveUpAfter = Duration(days: 3);
  static const keepSeen = 500;

  /// When something unanswered is next sent: twenty seconds after, then twice as long each time, five minutes at most.
  static Duration resendAfter(int tries) => Duration(seconds: (20 * (1 << (tries - 1).clamp(0, 10))).clamp(20, 300));

  /// How long between copies while this app's relay says what was sent waits there for the friend's relay.
  static const waitingResendAfter = Duration(hours: 1);

  /// Why the last words to a friend weren't taken by any route, as the routes said it (their relay refused them, or
  /// can't be reached from this app's): shown in the conversation in place of a reason of its own. Null where nothing
  /// was refused.
  String? lastRefusal;
  final List<StreamSubscription<dynamic>> _subs = [];
  Timer? _soon;
  bool _started = false;

  // Whether a relay server has answered since the app started ([available]), and when one was last looked for
  // ([look]).
  bool? _answers;
  DateTime? _asked;

  /// How long before a friend who is away is sent another wake.
  static const wakeEvery = Duration(minutes: 10);

  /// A number as two phones agree on it whatever each wrote before it: its last ten digits. A username (`@name`) is
  /// never read as a number, whatever digits it holds: usernames may (Me.goodUsername), and "@ben.5550002222" was read
  /// as Ben's number and stood in for him (found in review, 2026-11-23).
  static String digits(String address) {
    final t = address.trim();
    if (t.startsWith('@')) return t.toLowerCase();
    final d = address.replaceAll(RegExp(r'[^0-9]'), '');
    return d.length >= 7 ? (d.length > 10 ? d.substring(d.length - 10) : d) : t.toLowerCase();
  }

  /// Starts listening to the routes. Asked for once, as the app opens, after the routes are set up.
  Future<void> start([AppState? app]) async {
    if (_started) return;
    _started = true;
    _app = app;
    _subs.add(_port.received.listen(_received));
    _subs.add(_port.acked.listen(_acked));
    _port.changed.addListener(_changed);
    _loadOut();
    _watchOut();
    await refresh();
    unawaited(_askHistory());
    unawaited(_askSince());
    // A request that never got an answer is said again, by a route that costs nothing: either was lost.
    for (final s in _by.values.where((s) => s.on && s.friend == 'asked' && _actsOn(s))) {
      _say(s.address, 'ask');
    }
  }

  /// Whether this device acts on [s]: every record on the phone; elsewhere friends by username alone ([FriendsPort.numbers]).
  bool _actsOn(E2eState s) => _port.numbers || s.address.startsWith('@');

  Future<void> shutdown() async {
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    _soon?.cancel();
    _again?.cancel();
    if (_started) _port.changed.removeListener(_changed);
    _started = false;
    _by.clear();
    _byId = {};
    _rows.clear();
    _woke.clear();
    _ended.clear();
    _lookedAt = null;
    _looking = null;
    _out.clear();
    _seen.clear();
    _historyAsked = false;
    _answering.clear();
    _takenRows.clear();
    _takenParts = 0;
    _nonce = null;
  }

  /// The people or the routes changed: read again a moment later, so many changes at once are one reading.
  void _changed() {
    _soon?.cancel();
    _soon = Timer(const Duration(milliseconds: 120), () async {
      await refresh();
      // A route that has just come up: what is waiting for an answer goes now, not at its next turn.
      if (_port.internet) _resend(all: true);
      unawaited(_askHistory());
      unawaited(_askSince());
    });
  }

  /// Reads where everyone stands again, and asks those it was waiting to ask now that their key is here.
  Future<void> refresh() async {
    List<E2eState> all;
    try {
      all = await _port.states();
    } catch (_) {
      return;
    }
    _by
      ..clear()
      ..addEntries(all.map((s) => MapEntry(digits(s.address), s)));
    // Off the phone, only friends by username say who an install is: what a paired computer's own routes bring is kept
    // with them, as before, never handed to the phone's conversation with the same person's number.
    _byId = whoIs(all.where(_actsOn));
    _failForOthers();
    for (final s in all.where((s) => s.on && s.friend == 'want' && _actsOn(s))) {
      await _ask(s.address);
    }
    if (_port.internet && _answers != true) {
      _answers = true;
      _app?.setFlag('friends_seen', true);
    }
    notifyListeners();
  }

  // --- what the screens ask -------------------------------------------------------------------------------------------

  /// Whether friends can be offered at all: a relay server has answered this phone, now or before.
  bool get available => _port.internet || _answers == true || (_app?.flag('friends_seen', fallback: false) ?? false);

  /// Looks whether a relay server answers, where that is not known: a conversation with someone who has the app
  /// asks as it opens. At most every ten minutes; listeners are told when the answer is yes.
  Future<void> look() async {
    if (available || !(_app?.flag('net_on') ?? true)) return;
    final last = _asked;
    if (last != null && DateTime.now().difference(last) < const Duration(minutes: 10)) return;
    _asked = DateTime.now();
    bool yes;
    try {
      yes = await _port.probe();
    } catch (_) {
      yes = false;
    }
    if (!yes) return;
    _answers = true;
    _app?.setFlag('friends_seen', true);
    notifyListeners();
  }

  /// Where [address] stands, where anything has been exchanged with them; their friend state ('' for none); and
  /// whether they are a friend.
  E2eState? of(String address) => _by[digits(address)];
  String stateOf(String address) => of(address)?.friend ?? '';
  bool isFriend(String address) => of(address)?.isFriend ?? false;

  /// The install the record for [address] names, while encryption is on with it: who that address is to the routes
  /// (a number's key, or the install a username stands for). Null where there is no such record, or it names no key.
  String? idOf(String address) {
    final s = of(address);
    return s != null && s.on ? s.id : null;
  }

  /// The address of the record that names the install [id] ([idOf] the other way): a number, or `@username`. Null
  /// where no record encryption is on with names it: a member of a group, say, is nobody's by an address an admin wrote.
  String? addressOf(String id) => _whose(id)?.address;

  /// Whether the install [id] is a friend, by the record that names it.
  bool isFriendId(String id) => _whose(id)?.isFriend ?? false;

  /// The record that names the install [id], while encryption is on with it; null for anyone else.
  E2eState? _whose(String id) {
    final key = _byId[id];
    final s = key == null ? null : _by[key];
    // The record kept for that address still names it (the two are read together; this holds them to each other).
    return s != null && s.on && (s.id == id || s.otherIds.contains(id)) ? s : null;
  }

  /// Who each install is, from [all] the records: the address ([digits]) of the record that names its id
  /// ([E2eState.id], and a friend by username's other installs). Where two name the same one (a person's number and
  /// username, both with the key of the one install; one person's two numbers on one phone; or a key someone sent from
  /// a number that isn't theirs), the record encryption is on with stands, then the one being friends has gone furthest
  /// with ([progress]), then a number's; two still alike go to the same one of them every time, the lower address. Never
  /// to nobody: a record's id seals for that key's own holder whatever address it is under, so the worst that can come
  /// of two alike is their words under the other of their numbers. Dropping them (as this did first) lost every word of
  /// someone with two SIMs while their phone was told each had arrived (found in review, 2026-11-23).
  @visibleForTesting
  static Map<String, String> whoIs(Iterable<E2eState> all) {
    int rank(E2eState s) => (s.on ? 16 : 0) + progress(s) * 2 + (s.address.startsWith('@') ? 0 : 1);
    final best = <String, E2eState>{};
    for (final s in all) {
      for (final id in {?s.id, ...s.otherIds}) {
        final had = best[id];
        if (had == null || rank(s) > rank(had) || (rank(s) == rank(had) && digits(s.address).compareTo(digits(had.address)) < 0)) best[id] = s;
      }
    }
    return {for (final e in best.entries) e.key: digits(e.value.address)};
  }

  /// How far being friends has gone with [s], encryption on with them: 3 friends, 2 asked or invited, 1 meant to ask
  /// (`want`), 0 nothing yet, or encryption off.
  @visibleForTesting
  static int progress(E2eState s) => !s.on ? 0 : switch (s.friend) { 'yes' => 3, 'asked' || 'invited' => 2, 'want' => 1, _ => 0 };

  /// Whether the record for [address] names the install [id], encryption on with it: their newest install or another.
  bool _names(String address, String id) {
    final s = of(address);
    return s != null && s.on && (s.id == id || s.otherIds.contains(id));
  }

  /// The routes' peer for whoever the record for [address] names ([idOf]), found by that id alone.
  Peer? _peerFor(String address) {
    final id = idOf(address);
    if (id == null) return null;
    final p = _port.peer(id);
    return p != null && p.id == id ? p : null;
  }

  /// Everyone who is a friend.
  List<E2eState> get friends => _by.values.where((s) => s.isFriend).toList();

  /// Whether the conversation with someone who stands at [e] should offer Add friend: both have the app, nothing
  /// has been said about being friends, and friends can be offered.
  bool offers(E2eState e) => available && e.friend.isEmpty && (e.on || e.offerable);

  // --- becoming friends -----------------------------------------------------------------------------------------------

  /// Add friend. With no keys exchanged yet this phone's goes first, by text, and the asking waits for theirs.
  Future<void> add(String address) async {
    final s = of(address);
    if (s == null || !s.on) {
      await _port.offerKeys(address);
      await _port.setFriend(address, 'want');
      await refresh();
      return;
    }
    if (s.friend == 'invited') return accept(address);
    await _ask(address, metered: true);
  }

  /// Notes [address] as asked, and asks them.
  Future<void> _ask(String address, {bool metered = false}) async {
    await _set(address, 'asked');
    await _say(address, 'ask', metered: metered);
  }

  /// Yes to someone who asked.
  Future<void> accept(String address) async {
    await _set(address, 'yes');
    await _say(address, 'yes', metered: true);
  }

  /// No to someone who asked.
  Future<void> decline(String address) async {
    await _set(address, '');
    await _say(address, 'no');
  }

  /// Stops being friends, or takes a request back. What is written to them goes as a text again.
  Future<void> remove(String address) async {
    await _set(address, '');
    await _say(address, 'end');
  }

  /// Keeps [state] as where friendship stands with [address], on the phone and here.
  Future<void> _set(String address, String state) async {
    await _port.setFriend(address, state);
    final s = of(address);
    if (s != null) _by[digits(address)] = s.withFriend(state);
    notifyListeners();
  }

  /// Says [what] about being friends to [address]: to the install its record names. Asking and answering by hand may
  /// cost a text where no other route is up ([metered]); what is said again unasked may not.
  Future<void> _say(String address, String what, {bool metered = false}) async {
    final peer = _peerFor(address);
    if (peer == null) return;
    try {
      await _port.send(peer, Envelope(kind: 'friend', body: {'do': what}), metered: metered);
    } catch (_) {}
  }

  // --- what comes -----------------------------------------------------------------------------------------------------

  /// What the routes bring: a `friend` or `text` envelope, sealed, from someone encryption is on with. Anything
  /// else is not for here.
  Future<void> _received(Received r) async {
    // A copy from another device of this account (GMFB-21).
    if (r.envelope.kind == copyKind && r.sealed && _port.isMine(r.peer)) return _mine(r.envelope);
    // A new device of this account asking for what is held here, and the answer to this device's own asking (GMFB-53).
    if (r.envelope.kind == historyAsk && r.sealed && _port.isMine(r.peer)) return _answerHistory(r.envelope, r.device);
    if (r.envelope.kind == historyKind && r.sealed && _port.isMine(r.peer)) return _takeHistory(r.envelope);
    if (r.envelope.kind == historyGot && r.sealed && _port.isMine(r.peer)) return _historyHad(r.envelope, r.device);
    // A device of this account catching up on what it missed while it was away ([sinceAsk]).
    if (r.envelope.kind == sinceAsk && r.sealed && _port.isMine(r.peer)) return _answerSince(r.envelope, r.device);
    if (!r.sealed) return;
    final kind = r.envelope.kind;
    if (kind != 'friend' && kind != 'text') return;
    // Who sent it is the install whose key sealed it ([Received.peer]'s id), and who that is to this phone is the
    // record that names that id, encryption on with it: a number's, whose key it is, or a friend by username's. Never
    // the address the routes have for them: they also reach the members of a group this phone is in (groups.dart),
    // each under whatever address the group's admin wrote, which may be a real friend's number or "@friend" (found in
    // review, 2026-11-23). Anyone no such record names is dropped, and told so ([_notAFriend]).
    var who = _whose(r.peer.id);
    if (who == null) {
      await _lookAgain();
      who = _whose(r.peer.id);
      if (who == null) {
        _notAFriend(r);
        return;
      }
    }
    switch (kind) {
      case 'friend':
        await _friend(who.address, r.envelope.body['do']);
      case 'text':
        await _text(who.address, r.envelope);
    }
  }

  /// When the records were last read again for something from an install none of them named, and that reading while it
  /// runs: once in [lookAgainAfter] at most, however many come. Any member of a group can send them, and each read is
  /// the phone's whole list of encryption records (found in review, 2026-11-23).
  DateTime? _lookedAt;
  Future<void>? _looking;
  static const lookAgainAfter = Duration(seconds: 15);

  /// Reads the records again for an install none of them names (a friend whose keys were just exchanged, before the
  /// change has been read), unless that was done a moment ago or is being done now.
  Future<void> _lookAgain() {
    final running = _looking;
    if (running != null) return running;
    final now = DateTime.now(), last = _lookedAt;
    if (last != null && now.difference(last) < lookAgainAfter) return Future.value();
    _lookedAt = now;
    return _looking = refresh().whenComplete(() => _looking = null);
  }

  /// When each install no record names was last answered `end` ([_notAFriend]).
  final Map<String, DateTime> _ended = {};

  /// Words came sealed from an install none of this phone's records names: a member of a group, or someone whose record
  /// is gone here while theirs still holds this phone a friend. The routes have already answered that they arrived, so
  /// they are answered `end` too, straight to the install that sealed them (by its id, [Received.peer]): their app stops
  /// writing to this phone as a friend's, and their words go as texts again rather than showing delivered (found in
  /// review, 2026-11-23). Only from the phone ([FriendsPort.numbers]): another device of the account doesn't hold the
  /// records for numbers, and would end a friendship that is the phone's. Only for words, never an ask or a yes (an ask
  /// from a member of a group whose key text hasn't come yet was taken back by it), and so never for an end or a no
  /// either (two phones would answer each other for ever); never to an install some record names whatever it stands at,
  /// nor anyone in the phone's list of friends by username in any state ([FriendsPort.knows]: one said yes to on a paired
  /// computer, or whose yes was lost, is only asked or asking here, and an "end" made their app hold this phone no
  /// friend); and at most every [wakeEvery] an install.
  void _notAFriend(Received r) {
    if (!_port.numbers || r.envelope.kind != 'text') return;
    final id = r.peer.id;
    if (_by.values.any((s) => s.id == id || s.otherIds.contains(id)) || _port.knows(id)) return;
    final last = _ended[id];
    if (last != null && DateTime.now().difference(last) < wakeEvery) return;
    _ended[id] = DateTime.now();
    unawaited(_port.send(r.peer, Envelope(kind: 'friend', body: {'do': 'end'})).catchError((_) => Delivery(r.envelope.id)));
  }

  /// What waits for an answer from an install the record for its address no longer names (their key changed, and the
  /// record names the new one, or waits for the person's yes to it): what was sealed for the one it went to can't be read
  /// by another, and is said to have failed now, not three days on (found in review, 2026-11-23).
  void _failForOthers() {
    var changed = false;
    for (final o in _out.values.toList()) {
      final to = o.to, s = of(o.address);
      if (to == null || s == null || s.id == null || s.id == to || s.otherIds.contains(to)) continue;
      _out.remove(o.id);
      changed = true;
      unawaited(_port.rowState(o.row, 'failed').catchError((_) {}));
    }
    if (changed) _saveOut();
  }

  Future<void> _friend(String address, Object? what) async {
    // A friend by username's "end" and "no" are Buddies' to take (its `buddy` messages say where the two stand): taken
    // here they marked a friend not one, in memory, until the records were read again, and nothing written to them went
    // meanwhile (found in review, 2026-11-23).
    if (address.startsWith('@') && (what == 'end' || what == 'no')) return;
    final mine = stateOf(address);
    switch (what) {
      case 'ask':
        if (mine == 'want' || mine == 'asked') {
          // Each asked the other: friends.
          await _set(address, 'yes');
          await _say(address, 'yes');
        } else if (mine == 'yes') {
          await _say(address, 'yes');
        } else {
          if (mine != 'invited') Sounds.instance.play(UiSound.friendRequest);
          await _set(address, 'invited');
        }
      case 'yes':
        if (mine == 'want' || mine == 'asked' || mine == 'invited') {
          if (mine != 'invited') Sounds.instance.play(UiSound.friendAccepted);
          await _set(address, 'yes');
        } else if (mine.isEmpty) {
          // They hold this phone to have asked, and it has not (it took the request back, or was reset): theirs
          // stands as a request.
          await _set(address, 'invited');
        }
      case 'no':
        if (mine == 'want' || mine == 'asked') await _set(address, '');
      case 'end':
        if (mine.isNotEmpty) await _set(address, '');
    }
  }

  /// Words [address] wrote as a friend: kept in their conversation, once.
  Future<void> _text(String address, Envelope e) async {
    final words = e.body['t'];
    if (words is! String || words.isEmpty) return;
    // Sent again because the answer to it was lost: it is here already.
    if (_seen.contains(e.id)) return;
    _seen.add(e.id);
    if (_seen.length > keepSeen) _seen.removeRange(0, _seen.length - keepSeen);
    _app?.set('friends_in', _seen.join(','));
    final mine = stateOf(address);
    if (mine == 'want' || mine == 'asked') {
      // They write as a friend to someone who asked them: their yes was lost on the way.
      await _set(address, 'yes');
    } else if (mine != 'yes') {
      // Not a friend here: they are told, so what they write goes as a text again. These words are still kept:
      // they came sealed from someone encryption is on with.
      await _say(address, 'end');
    }
    await _port.storeIn(address, words, e.at);
    // And for this account's other devices: one closed when it came, or whose copy the relay gave to another.
    unawaited(_copy(address, e.id, words, e.at, out: false));
  }

  // --- this account's other devices -------------------------------------------------------------------------------------

  /// What a copy of a conversation with a friend by username is sent as, to this account's other devices (GMFB-21,
  /// Matt, Windows 0.12.5: "I sent a DM on my phone and it didn't sync the chat history across my mac and PC"). Each
  /// device kept only what it sent and what reached it: the relay hands a friend's message to the devices that are
  /// connected, and one kept for them to whichever comes first, and nothing that one device sent reached the others.
  ///
  /// So every message to or from a friend by username is sent on to the account's own name, sealed with the account's
  /// key; the relay gives it to every other device of the account that is connected and keeps it for those that are
  /// not. A device that takes a copy it hasn't seen keeps it and passes it on once, so one that was closed hears of it
  /// from whichever device got the copy the relay kept. The message's own name tells copies of one message apart.
  static const copyKind = 'mine';

  /// Sends a message with [address] (to them where [out], from them otherwise) to this account's other devices. Only
  /// friends by username: a phone-number friend's messages are the phone's, and its computer shows the phone's.
  Future<void> _copy(String address, String id, String words, int at, {required bool out}) async {
    if (!address.startsWith('@')) return;
    try {
      await _port.sendMine(Envelope(kind: copyKind, body: {'a': address, 't': words, 'i': id, 'at': at, 'o': out}));
    } catch (_) {}
  }

  /// A copy from another device of this account: kept with the conversation, once, and passed on.
  Future<void> _mine(Envelope e) async {
    final b = e.body;
    final address = b['a'], words = b['t'], id = b['i'], at = b['at'];
    if (address is! String || !address.startsWith('@') || words is! String || words.isEmpty || id is! String || at is! num) return;
    if (_seen.contains(id)) return;
    _seen.add(id);
    if (_seen.length > keepSeen) _seen.removeRange(0, _seen.length - keepSeen);
    _app?.set('friends_in', _seen.join(','));
    final out = b['o'] == true;
    if (out) {
      final row = await _port.storeOut(address, words, at: at.toInt());
      await _port.rowState(row, 'sent');
    } else {
      await _port.storeIn(address, words, at.toInt());
    }
    unawaited(_copy(address, id, words, at.toInt(), out: out));
  }

  // --- a new device's history (GMFB-53) -----------------------------------------------------------------------------------

  /// What a device asks its account's other devices for until one answers: the conversations with friends by username
  /// they hold (@kevin, GMFB-53: "Upon logging in on web, none of my messages appear in the sidebar and only my circles
  /// appear"). The account's backup carries friends and circles, never conversations, and the copies ([copyKind])
  /// carry only what is said from then on, so a device signed in on (a browser, an iPhone, a computer of its own) had its
  /// friends and an empty list. `{n, d, dn}`: this device's asking, its number on the account's list and its name.
  /// Sealed with the account's key as a copy is, by the relay, which keeps it for the devices that are away. Builds
  /// from before pass all four kinds over.
  static const historyAsk = 'mine-ask';

  /// The answer, for the device whose asking was `n` alone: `{n, a, r: [[words, when, 1 where ours], …]}`, a
  /// conversation (or part of one) each, then `{n, e, c, d}` to say it is all: `e` 1, or 2 where it was cut at
  /// [historyParts] (older conversations stay on the other device), `c` how many parts went, `d` the answering device's
  /// number. Sent even where there is nothing (`c` 0), which ends nothing by itself. Kept there once each
  /// ([FriendsPort.keepHistory]) and never passed on.
  static const historyKind = 'mine-past';

  /// The asker saying it has had an answer's end: `{n, d}`. Taken only from the device it answered, for that asking
  /// ([_historyHad]); the answering device then never answers that device again.
  static const historyGot = 'mine-got';

  /// The most messages of one conversation a device hands over or takes; the most words in one part, counted as the
  /// JSON that goes (a packet on the hub or the direct route is at most 60 KB sealed, HubCarrier.maxPacket, with the
  /// envelope, its sealing and forward secrecy's room besides); the most parts in one answer (the account's mailbox
  /// on the relay holds 200 packets and 1 MB for a device that is away, which the copies need too); and the most
  /// parts one asking takes in.
  static const historyMost = 300;
  static const historyBytes = 40 * 1024;
  static const historyParts = 12;
  static const historyTaken = 120;

  /// The pause between one part and the next, so an answer doesn't fill the relay's mailbox for an away asker at once.
  @visibleForTesting
  static Duration historyPace = const Duration(milliseconds: 150);

  /// Asked already this run ([_askHistory]); askings being answered now; what each asking has taken in, by address.
  bool _historyAsked = false;
  final Set<String> _answering = {};
  final Map<String, int> _takenRows = {};
  int _takenParts = 0;

  /// This device's asking: made once, kept with the choices so an answer kept on the relay while it was closed is
  /// still taken. Let go at sign-out (lib/account/account.dart forget), with the rest of `history_…`.
  String? _nonce;
  String get _myAsking {
    final app = _app;
    // Without the choices (a test): one for this run.
    if (app == null) return _nonce ??= _newNonce();
    final kept = app.choice('history_n', '');
    return kept.isNotEmpty ? kept : _newNonce();
  }

  String _newNonce() {
    final n = base64Url.encode(List<int>.generate(12, (_) => _rand.nextInt(256)));
    _app?.set('history_n', n);
    return n;
  }

  static final _rand = Random.secure();

  /// How long after the last asking the next is due, after [tries] askings with no answer: half a minute, doubling,
  /// twelve hours at most. Asked at each start that is due, until an answer's end comes.
  static Duration historyBackoff(int tries) => Duration(seconds: 30 * (1 << tries.clamp(0, 11))) > const Duration(hours: 12) ? const Duration(hours: 12) : Duration(seconds: 30 * (1 << tries.clamp(0, 11)));

  /// Asks this account's other devices for the conversations they hold, where no answer has ended yet and it is due.
  Future<void> _askHistory() async {
    if (_historyAsked || !_started || !_port.internet) return;
    if (_app?.flag('history_done', fallback: false) ?? false) return;
    final me = _port.thisDevice;
    if (me == null) return;
    final tries = int.tryParse(_app?.choice('history_tries', '') ?? '') ?? 0;
    final last = int.tryParse(_app?.choice('history_last', '') ?? '') ?? 0;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (last > 0 && now - last < historyBackoff(tries - 1).inMilliseconds) return;
    _historyAsked = true;
    try {
      // By the hub alone, which says which device sent it ([historyAsk]); the direct route can't.
      final d = await _port.sendMine(Envelope(kind: historyAsk, body: {'n': _myAsking, 'd': me.device}), hubOnly: true);
      if (d.sent) {
        _app?.set('history_tries', '${tries + 1}');
        _app?.set('history_last', '$now');
        return;
      }
    } catch (_) {}
    // Nothing took it (no account here yet, the relay not up): asked again as the routes change.
    _historyAsked = false;
  }

  /// What this device answered each device of the account (by its number on the list): `{n, h, at, got}`, the asking
  /// it answered, that device's name on the hub (which the hub vouched for), when, and whether it said it had it all.
  /// Kept with the choices, so "once per device" holds across a restart.
  Map<String, Map<String, Object?>> get _answered {
    try {
      return {
        for (final e in (jsonDecode(_app?.choice('history_answered', '{}') ?? '{}') as Map).entries)
          if (e.value is Map) '${e.key}': (e.value as Map).cast<String, Object?>(),
      };
    } catch (_) {
      return {};
    }
  }

  void _setAnswered(String device, Map<String, Object?> value) {
    final m = _answered..[device] = value;
    _app?.set('history_answered', jsonEncode(m));
  }

  /// Another device of this account asked: what is held here, for it alone (the review of GMFB-53, B1). The device it
  /// names (`d`, its number on the account's list) must be the one the hub says sent the asking ([Received.device]:
  /// its name on the hub, relay/lib/hub.dart toPeerFromDevice), as the account's list holds the two together
  /// (`acct-hello` with both, [FriendsPort.vouch]); so nobody holding the account's key, a removed device or one that
  /// saw the list can name a listed device and be answered in its place. Answered once per device (again after a day
  /// only where it never said it had the answer, [historyGot]), and said where the person sees their devices, under the
  /// name the list gives it ([historyNote]).
  Future<void> _answerHistory(Envelope e, String? from) async {
    final b = e.body;
    final n = b['n'], device = b['d'];
    final me = _port.thisDevice;
    if (from == null || from.isEmpty || n is! String || n.isEmpty || n == _myAsking || device is! String || device.isEmpty || me == null || device == me.device) return;
    final had = _answered[device];
    if (had?['got'] == true) return;
    final at = had?['at'];
    if (at is num && DateTime.now().millisecondsSinceEpoch - at.toInt() < const Duration(days: 1).inMilliseconds) return;
    if (!_answering.add(device)) return;
    try {
      final name = await _port.vouch(device, from);
      if (name == null) return;
      List<({String address, List<PastRow> rows})> held;
      try {
        held = await _port.history();
      } catch (_) {
        return;
      }
      // The newest conversations first: an answer cut at [historyParts] has what was said last.
      held.sort((x, y) => (y.rows.isEmpty ? 0 : y.rows.last.at).compareTo(x.rows.isEmpty ? 0 : x.rows.last.at));
      final parts = <Map<String, Object?>>[];
      for (final c in held) {
        final rows = c.rows.length > historyMost ? c.rows.sublist(c.rows.length - historyMost) : c.rows;
        var part = <List<Object>>[];
        var size = 0;
        for (final r in rows) {
          final row = _rowFitting(r);
          final bytes = utf8.encode(jsonEncode(row)).length + 1;
          if (size + bytes > historyBytes - 512 && part.isNotEmpty) {
            parts.add({'n': n, 'a': c.address, 'r': part});
            part = [];
            size = 0;
          }
          part.add(row);
          size += bytes;
        }
        if (part.isNotEmpty) parts.add({'n': n, 'a': c.address, 'r': part});
      }
      final going = parts.take(historyParts).toList();
      final end = {'n': n, 'e': parts.length > historyParts ? 2 : 1, 'c': going.length, 'd': me.device};
      for (final body in [...going, end]) {
        if (!await _sendPart(body)) return;
        if (historyPace > Duration.zero) await Future<void>.delayed(historyPace);
      }
      _setAnswered(device, {'n': n, 'h': from, 'at': DateTime.now().millisecondsSinceEpoch});
      if (going.isNotEmpty) {
        historyNote = 'History sent to ${name.trim().isEmpty ? 'a device' : name.trim()} on ${DateTime.now().toIso8601String().substring(0, 10)}';
        _app?.set('history_note', historyNote!);
      }
    } finally {
      _answering.remove(device);
    }
  }

  /// A message too long for a part of its own, cut on a letter's edge (never in the middle of one written as two code
  /// units) and said to be cut, where it is shown (the review of GMFB-53, D1).
  static const cutNote = '… (cut: the whole message is on your other device)';
  static List<Object> _rowFitting(PastRow r) {
    List<Object> rowOf(String t) => <Object>[t, r.at, r.o ? 1 : 0];
    int sizeOf(List<Object> row) => utf8.encode(jsonEncode(row)).length + 1;
    var row = rowOf(r.t);
    if (sizeOf(row) <= historyBytes - 512) return row;
    var runes = r.t.runes.toList();
    while (runes.isNotEmpty) {
      runes = runes.sublist(0, runes.length * 3 ~/ 4);
      row = rowOf(String.fromCharCodes(runes) + cutNote);
      if (sizeOf(row) <= historyBytes - 512) return row;
    }
    return rowOf(cutNote);
  }

  /// One part sent, tried three times a moment apart; false where none went (too big, the mailbox full, no route).
  Future<bool> _sendPart(Map<String, Object?> body) async {
    for (var tries = 0; tries < 3; tries++) {
      try {
        if ((await _port.sendMine(Envelope(kind: historyKind, body: body))).sent) return true;
      } catch (_) {}
      await Future<void>.delayed(Duration(milliseconds: 300 * (tries + 1)));
    }
    return false;
  }

  /// The last answer this device gave another of the account: "History sent to Maya's iPhone on 2026-11-23", for
  /// Settings › Devices (lib/ui/account_screens.dart), so a handover the person didn't make is seen.
  String? historyNote;

  /// What another device held, answering this device's asking: kept in the conversations, once each, within the bounds
  /// one asking may take in. Its end said back; and the asking ends once an answer that carried something has ended
  /// (`c` above 0), or every other device on the account's list has answered with nothing. An answer with nothing (a
  /// fresh browser that had the asking first) ends nothing by itself (the review of GMFB-53, C1). One cut at
  /// [historyParts] says so over the conversations (`history_partial`).
  Future<void> _takeHistory(Envelope e) async {
    final b = e.body;
    if (_catchUp != null && b['n'] == _catchUp) return _takeSince(b);
    if (b['n'] != _myAsking) return;
    final end = b['e'];
    if (end == 1 || end == 2) {
      final count = b['c'];
      final carried = (count is num && count > 0) || (count == null && _takenParts > 0);
      final me = _port.thisDevice;
      if (me != null) unawaited(_port.sendMine(Envelope(kind: historyGot, body: {'n': _myAsking, 'd': me.device}), hubOnly: true).then((_) {}, onError: (_) {}));
      if (end == 2) _app?.setFlag('history_partial', true);
      if (carried) {
        _app?.setFlag('history_done', true);
        return;
      }
      // Nothing in it: noted by who said it, and the asking goes on, unless every other listed device has said so.
      final who = b['d'];
      if (who is String && who.isNotEmpty) {
        final empty = {...(_app?.choice('history_empty', '') ?? '').split(',').where((x) => x.isNotEmpty), who};
        _app?.set('history_empty', empty.join(','));
        try {
          final listed = await _port.listedDevices();
          if (listed != null && me != null && listed.where((d) => d != me.device).every(empty.contains)) _app?.setFlag('history_done', true);
        } catch (_) {}
      }
      return;
    }
    final address = b['a'], rows = b['r'];
    if (address is! String || !address.startsWith('@') || rows is! List) return;
    if (++_takenParts > historyTaken) return;
    final room = historyMost - (_takenRows[address] ?? 0);
    if (room <= 0) return;
    final past = <PastRow>[
      for (final r in rows.take(room))
        if (r is List && r.length >= 3 && r[0] is String && (r[0] as String).isNotEmpty && r[1] is num) (t: r[0] as String, at: (r[1] as num).toInt(), o: r[2] == 1),
    ];
    if (past.isEmpty) return;
    _takenRows[address] = (_takenRows[address] ?? 0) + past.length;
    try {
      await _port.keepHistory(address, past);
    } catch (_) {}
  }

  // --- catching up on what was missed (Matt, 2026-11-25) -----------------------------------------------------------------

  /// What a device asks its account's other devices each time it comes back: what was said with friends since it was
  /// last in step (Matt, 2026-11-25: "messages are still not kept in sync across all devices, all my devices have
  /// different sidebars"). The copies ([copyKind]) reach the devices that are connected as a message goes, and the
  /// relay keeps one for those that are not only while none of the account's devices is connected at all: with a phone
  /// that is always connected, a computer that was closed never heard of anything said meanwhile, and [historyAsk] is
  /// answered once in a device's life. `{n, d, s}`: this asking, this device's number on the account's list, and the
  /// time to answer from. Answered as [historyKind] is, in parts under `n`, with no end said; builds from before pass
  /// it over.
  static const sinceAsk = 'mine-since';

  /// How far back a device's first catching up goes, how often it asks at most, how much earlier than its last
  /// catching up it asks from (clocks differ a little, and an answer takes a moment), and how soon one device is
  /// answered again.
  static const sinceBack = Duration(days: 14);
  static const sinceEvery = Duration(minutes: 10);
  static const sinceMargin = Duration(minutes: 2);
  static const sinceAnswerEvery = Duration(minutes: 2);

  /// This run's asking, when it was made, and what it has taken in.
  String? _catchUp;
  int _catchUpAt = 0;
  int _catchUpParts = 0;
  final Map<String, int> _catchUpRows = {};
  final Map<String, int> _sinceAnswered = {};

  /// Catches up from the start again, now: friends were just taken in from the account's kept copy
  /// (lib/account/account.dart takeIn), and what they said was passed over while they were nobody here.
  void catchUpAgain() {
    _app?.set('since_last', '');
    _catchUpAt = 0;
    unawaited(_askSince());
  }

  /// Asks this account's other devices for what was said since this device was last in step, where one is due.
  Future<void> _askSince() async {
    if (!_started || !_port.internet) return;
    final me = _port.thisDevice;
    if (me == null) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _catchUpAt < sinceEvery.inMilliseconds) return;
    final last = int.tryParse(_app?.choice('since_last', '') ?? '') ?? 0;
    final from = last > 0 ? max(last - sinceMargin.inMilliseconds, now - sinceBack.inMilliseconds) : now - sinceBack.inMilliseconds;
    final n = base64Url.encode(List<int>.generate(12, (_) => _rand.nextInt(256)));
    _catchUpAt = now;
    try {
      // By the hub alone, which says which device sent it, as [historyAsk] is.
      final d = await _port.sendMine(Envelope(kind: sinceAsk, body: {'n': n, 'd': me.device, 's': from}), hubOnly: true);
      if (d.sent) {
        _catchUp = n;
        _catchUpParts = 0;
        _catchUpRows.clear();
        // In step up to now, as far as this device can tell: the next asking is from here.
        _app?.set('since_last', '$now');
        return;
      }
    } catch (_) {}
    // Nothing took it: asked again as the routes change.
    _catchUpAt = 0;
  }

  /// Another device of this account is catching up: what is held here that was said since the time it names, for it
  /// alone. The device it names must be the one the hub says sent it and be on the account's list, as for
  /// [_answerHistory]; one device is answered at most every [sinceAnswerEvery], with [historyParts] parts at most.
  Future<void> _answerSince(Envelope e, String? from) async {
    final b = e.body;
    final n = b['n'], device = b['d'], since = b['s'];
    final me = _port.thisDevice;
    if (from == null || from.isEmpty || n is! String || n.isEmpty || n == _catchUp || device is! String || device.isEmpty || since is! num || me == null || device == me.device) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - (_sinceAnswered[device] ?? 0) < sinceAnswerEvery.inMilliseconds) return;
    if (!_answering.add('since $device')) return;
    try {
      if (await _port.vouch(device, from) == null) return;
      _sinceAnswered[device] = now;
      List<({String address, List<PastRow> rows})> held;
      try {
        held = await _port.history();
      } catch (_) {
        return;
      }
      final recent = [
        for (final c in held) (address: c.address, rows: [for (final r in c.rows) if (r.at >= since) r]),
      ]..removeWhere((c) => c.rows.isEmpty);
      // The conversations spoken in last first: an answer cut at [historyParts] has what was said last.
      recent.sort((x, y) => y.rows.last.at.compareTo(x.rows.last.at));
      final parts = <Map<String, Object?>>[];
      for (final c in recent) {
        var part = <List<Object>>[];
        var size = 0;
        for (final r in c.rows) {
          final row = _rowFitting(r);
          final bytes = utf8.encode(jsonEncode(row)).length + 1;
          if (size + bytes > historyBytes - 512 && part.isNotEmpty) {
            parts.add({'n': n, 'a': c.address, 'r': part});
            part = [];
            size = 0;
          }
          part.add(row);
          size += bytes;
        }
        if (part.isNotEmpty) parts.add({'n': n, 'a': c.address, 'r': part});
      }
      for (final body in parts.take(historyParts)) {
        if (!await _sendPart(body)) return;
        if (historyPace > Duration.zero) await Future<void>.delayed(historyPace);
      }
    } finally {
      _answering.remove('since $device');
    }
  }

  /// A part of an answer to this device's catching up: kept in its conversation, each message once
  /// ([FriendsPort.keepHistory]), within the bounds one asking may take in. Past messages: nothing is made unread.
  Future<void> _takeSince(Map<String, Object?> b) async {
    final address = b['a'], rows = b['r'];
    if (address is! String || !address.startsWith('@') || rows is! List) return;
    if (++_catchUpParts > historyTaken) return;
    final room = historyMost - (_catchUpRows[address] ?? 0);
    if (room <= 0) return;
    final past = <PastRow>[
      for (final r in rows.take(room))
        if (r is List && r.length >= 3 && r[0] is String && (r[0] as String).isNotEmpty && r[1] is num) (t: r[0] as String, at: (r[1] as num).toInt(), o: r[2] == 1),
    ];
    if (past.isEmpty) return;
    _catchUpRows[address] = (_catchUpRows[address] ?? 0) + past.length;
    try {
      await _port.keepHistory(address, past);
    } catch (_) {}
  }

  /// A device of the account says it had this device's answer whole: taken only for the asking this device answered it
  /// and only from that device, as the hub vouches (the review of GMFB-53, B2); then it is never answered again.
  void _historyHad(Envelope e, String? from) {
    final d = e.body['d'], n = e.body['n'];
    if (d is! String || d.isEmpty || n is! String || from == null || from.isEmpty) return;
    final had = _answered[d];
    if (had == null || had['n'] != n || had['h'] != from) return;
    _setAnswered(d, {...had, 'got': true});
  }

  /// The friend's app says it has the envelope [id]: it is not sent again, and its row is marked delivered.
  void _acked(String id) {
    final row = _rows.remove(id) ?? _out[id]?.row;
    if (_out.remove(id) != null) _saveOut();
    if (row != null) _port.rowState(row, 'delivered').catchError((_) {});
  }

  /// Reads what was waiting for an answer, and the ids already kept, from the app's choices.
  void _loadOut() {
    _out.clear();
    _seen
      ..clear()
      ..addAll((_app?.choice('friends_in', '') ?? '').split(',').where((x) => x.isNotEmpty));
    try {
      for (final j in jsonDecode(_app?.choice('friends_out', '[]') ?? '[]') as List) {
        final o = _Out.fromJson(j as Map);
        if (o != null) _out[o.id] = o;
      }
    } catch (_) {}
  }

  /// Keeps what is waiting for an answer, and starts or stops the timer that sends it again.
  void _saveOut() {
    _app?.set('friends_out', jsonEncode([for (final o in _out.values) o.toJson()]));
    _watchOut();
  }

  /// Looked at every ten seconds while anything waits for an answer, what is due going again (and at once whenever
  /// the routes change, [_changed]); nothing runs while nothing waits.
  void _watchOut() {
    if (_out.isEmpty) {
      _again?.cancel();
      _again = null;
    } else {
      _again ??= Timer.periodic(const Duration(seconds: 10), (_) => _resend());
    }
  }

  /// Sends again what is due ([all]: everything waiting), with the id it first went with, so the friend's app keeps
  /// it once and answers. What has waited [giveUpAfter] is said to have failed. Only ever to the install it first
  /// went to, while a record for that address still names it (a friend by username's other install as well): what was
  /// sealed for one key is never sealed again for another (a key changed since, or someone else listed under their
  /// address).
  Future<void> _resend({bool all = false}) async {
    if (!_started || _out.isEmpty || !_port.internet) return;
    final now = DateTime.now();
    var changed = false;
    for (final o in _out.values.toList()) {
      if (now.difference(o.first) > giveUpAfter) {
        _out.remove(o.id);
        changed = true;
        unawaited(_port.rowState(o.row, 'failed').catchError((_) {}));
        continue;
      }
      if (!all && now.isBefore(o.next)) continue;
      // Kept by a build from before the install was remembered with it: the one its record names now, from here on.
      final to = o.to ?? idOf(o.address);
      if (to == null || !_names(o.address, to)) continue;
      final peer = _port.peer(to);
      if (peer == null || peer.id != to) continue;
      o.to = to;
      o.tries++;
      // Waiting on this app's relay for theirs: an hour between copies, not minutes; the one that waits goes when it can.
      o.next = now.add(_port.waitingAtRelay(to) ? waitingResendAfter : resendAfter(o.tries));
      changed = true;
      try {
        final d = await _port.send(peer, Envelope(id: o.id, kind: 'text', body: {'t': o.words}, at: o.first.millisecondsSinceEpoch));
        if (d.acked) _acked(o.id);
      } catch (_) {}
    }
    if (changed) _saveOut();
  }

  /// What a route said when it refused a packet (`hub: their relay can't be reached from yours`), without the route's
  /// name; null where none said anything but that it was down.
  static String? _refusalIn(List<String> tried) {
    for (final t in tried) {
      final colon = t.indexOf(': ');
      if (colon <= 0) continue;
      final why = t.substring(colon + 2);
      if (why.contains('relay') && !why.contains('could not be reached') && !why.contains('not connected')) return why;
    }
    return null;
  }

  /// When what went out as [id] is next sent again, for a test; null where it is not waiting for an answer.
  @visibleForTesting
  DateTime? nextResendOf(String id) => _out[id]?.next;

  /// What is waiting for an answer, for a test.
  @visibleForTesting
  int get unanswered => _out.length;

  /// What went to [peerId] as [id] and is still waiting for an answer, as it went (the same name, words and time): a
  /// device of theirs said over a direct link that it never came, and it goes again straight (lib/net/ledger.dart).
  /// Null where it was answered, given up on, or went to someone else.
  Envelope? heldFor(String peerId, String id) {
    final o = _out[id];
    if (o == null || _port.peer(o.address)?.id != peerId) return null;
    return Envelope(id: o.id, kind: 'text', body: {'t': o.words}, at: o.first.millisecondsSinceEpoch);
  }

  // --- what goes ------------------------------------------------------------------------------------------------------

  /// Sends [words] to a friend by the routes. True when a route took them: they are kept with the conversation and
  /// nothing more is to be done. False when [address] is not a friend or no route that costs nothing is up: the
  /// caller sends them as a text.
  Future<bool> sendText(String address, String words) async {
    lastRefusal = null;
    if (!_started || !isFriend(address) || !_port.internet) return false;
    // To the install the friend's record names, by its id: never whoever else the routes hold under that address.
    final peer = _peerFor(address);
    if (peer == null) return false;
    // The envelope first, and the row stamped with its time: the copy to the account's other devices carries that time,
    // so every device holds the message at the same moment (GMFB-53: a history from two devices kept it twice).
    final envelope = Envelope(kind: 'text', body: {'t': words});
    final row = await _port.storeOut(address, words, at: envelope.at);
    Delivery d;
    try {
      d = await _port.send(peer, envelope);
    } catch (_) {
      d = Delivery(envelope.id);
    }
    if (!d.sent) {
      // A route that said why (their relay, or this app's, refused it) is what the conversation shows.
      lastRefusal = _refusalIn(d.tried);
      await _port.dropRow(row);
      return false;
    }
    if (d.acked) {
      await _port.rowState(row, 'delivered');
      _sentAs(envelope.id);
      unawaited(_copy(address, envelope.id, words, envelope.at, out: true));
      return true;
    }
    await _port.rowState(row, 'sent');
    _rows[envelope.id] = row;
    _sentAs(envelope.id);
    unawaited(_copy(address, envelope.id, words, envelope.at, out: true));
    // Handed on but not yet answered: it may have gone down a connection that had just died, so it goes again until
    // the friend's app says it has it.
    final first = DateTime.fromMillisecondsSinceEpoch(envelope.at);
    _out[envelope.id] = _Out(id: envelope.id, address: address, to: peer.id, words: words, row: row, first: first, next: DateTime.now().add(resendAfter(1)));
    _saveOut();
    if (d.handed == Handed.held) _wake(peer);
    return true;
  }

  /// What this device sent as [id] is known here, and kept with the choices as what came is: the account's other
  /// device passes its copy on once ([_mine]), and where that came back after the app had been closed (a phone, a
  /// moment after sending) the message was kept a second time.
  void _sentAs(String id) {
    _seen.add(id);
    if (_seen.length > keepSeen) _seen.removeRange(0, _seen.length - keepSeen);
    _app?.set('friends_in', _seen.join(','));
  }

  /// Whether a route that costs nothing is up now, for groups of friends too (groups.dart).
  bool get online => _port.internet;

  /// The wake, for a member of a group the relay server is keeping something for (groups.dart).
  void wake(Peer peer) => _wake(peer);

  /// One data text, with nothing in it and in the clear, to a friend the relay server is keeping something for:
  /// their phone says a message is waiting (android Friends.woken). It is a text on this phone's plan, so it goes
  /// at most every [wakeEvery] a person.
  ///
  /// Only to the number this phone's own record gives that install: the record encryption is on with at that number,
  /// whose key it is (found in review, 2026-11-23). Someone known only through a group has the number its admin wrote,
  /// and an admin could list made-up members under anyone's numbers for every member's phone to text on its own plan,
  /// telling whoever is at each number this phone's own. They are woken by the members whose records do know them (the
  /// admin who added them does), and have what was written when their app opens. A friend by username has no number to
  /// text (lib/standalone): the relay server keeps it until they come.
  void _wake(Peer peer) {
    final vouched = addressOf(peer.id);
    if (vouched == null || vouched.startsWith('@')) return;
    final last = _woke[peer.id];
    if (last != null && DateTime.now().difference(last) < wakeEvery) return;
    _woke[peer.id] = DateTime.now();
    // To the record's number, whatever address the routes have for them.
    final to = Peer(id: peer.id, key: peer.key, address: vouched, name: peer.name);
    _port.send(to, Envelope(kind: 'wake', ack: false), metered: true, sealed: false, only: {'sms'}).catchError((_) => const Delivery(''));
  }
}

/// The app's own: the routes as the app holds them (lib/net/net.dart) and the phone.
class _AppPort implements FriendsPort {
  _AppPort() {
    Net.instance.listen(_in.add);
  }

  final _in = StreamController<Received>.broadcast();
  final _acks = StreamController<String>.broadcast();
  StreamSubscription<String>? _boardAcks;
  Switchboard? _board;

  /// The switchboard is made as the routes are set up, and again where they are set up again.
  void _follow() {
    final board = Net.instance.board;
    if (identical(board, _board)) return;
    _boardAcks?.cancel();
    _board = board;
    _boardAcks = board?.acked.listen(_acks.add);
  }

  @override
  Peer? peer(String id) => Net.instance.byId(id);

  /// A route of live links (the direct route) counts only while it reaches someone: a link to a friend's device open
  /// now. Up and ready to dial is not reaching anyone, and a text then waited five seconds on it before going as SMS
  /// (second review, S5).
  @override
  bool get internet {
    _follow();
    final board = Net.instance.board;
    if (board == null || !Net.instance.on) return false;
    return board.carriers.any((c) => !c.traits.metered && c.state.value == CarrierState.up && (c is! LiveLinks || (c as LiveLinks).linkedToSomeone));
  }

  @override
  Future<Delivery> send(Peer peer, Envelope envelope, {bool metered = false, bool sealed = true, Set<String>? only}) {
    final board = Net.instance.board;
    if (board == null) return Future.value(Delivery(envelope.id, tried: const ['the routes are not set up']));
    return board.send(peer, envelope, metered: metered, sealed: sealed, only: only);
  }

  @override
  Stream<Received> get received => _in.stream;

  @override
  Stream<String> get acked {
    _follow();
    return _acks.stream;
  }

  @override
  Future<List<E2eState>> states() => Sms.instance.e2eList();

  /// The Android phone's alone (Sms.remote: a computer, an iPhone, a browser, paired or not).
  @override
  bool get numbers => !Sms.remote;

  @override
  bool knows(String id) => Buddies.instance.byId(id) != null;

  @override
  Future<void> setFriend(String address, String state) => Sms.instance.friendSet(address, state);

  @override
  Future<void> offerKeys(String address) => Sms.instance.e2eOffer(address);

  @override
  Future<int> storeOut(String address, String words, {int? at}) => Sms.instance.netTextOut(address, words, at: at);

  @override
  Future<Delivery> sendMine(Envelope envelope, {bool hubOnly = false}) async {
    final board = Net.instance.board;
    final me = await Net.instance.mine();
    if (board == null || me == null) return Delivery(envelope.id, tried: const ['no account here to send to']);
    // By the relay, which keeps it for the devices that are away; and straight to one that is linked, or to all of
    // them where the relay can't be reached (the direct route, lib/net/p2p; the local network route, lib/net/lan).
    return board.send(me, envelope, only: hubOnly ? const {'hub'} : const {'hub', 'p2p', 'lan'});
  }

  @override
  bool isMine(Peer peer) => peer.id == Net.instance.id && peer.key != null;

  @override
  Future<List<({String address, List<PastRow> rows})>> history() async => [
        for (final c in await Sms.instance.netHistory())
          if (c['a'] is String) (address: c['a'] as String, rows: [for (final r in (c['r'] as List? ?? const [])) if (r is List && r.length >= 3 && r[0] is String && r[1] is num) (t: r[0] as String, at: (r[1] as num).toInt(), o: r[2] == 1)]),
      ];

  @override
  ({String device, String name})? get thisDevice => Account.instance.address == null ? null : (device: Account.instance.device, name: Account.instance.profiles.deviceName);

  @override
  Future<String?> vouch(String device, String hub) => Account.instance.vouches(device, hub);

  @override
  Future<List<String>?> listedDevices() async {
    if (!Account.keepsWords) return null;
    try {
      return [for (final d in await Account.instance.devices()) d.id];
    } catch (_) {
      return null;
    }
  }

  @override
  Future<int> keepHistory(String address, List<PastRow> rows) => Sms.instance.netHistoryKeep(address, [for (final r in rows) [r.t, r.at, r.o ? 1 : 0]]);

  @override
  Future<void> rowState(int id, String state) => Sms.instance.netTextState(id, state);

  @override
  Future<void> dropRow(int id) => Sms.instance.netTextDrop(id);

  @override
  Future<void> storeIn(String address, String words, int at) => Sms.instance.netTextIn(address, words, at);

  @override
  Listenable get changed => Net.instance;

  @override
  bool waitingAtRelay(String id) => Net.instance.hub?.waitingFor.contains(id) ?? false;

  @override
  Future<bool> probe() async {
    HubLink? socket;
    try {
      socket = await dialHub(Net.instance.hubUrl).timeout(const Duration(seconds: 5));
      // A hub says hello first (relay/lib/hub.dart).
      final first = await socket.said.first.timeout(const Duration(seconds: 5));
      return first is String && first.contains('"hello"');
    } catch (_) {
      return false;
    } finally {
      try {
        await socket?.close();
      } catch (_) {}
    }
  }
}

/// Something sent to a friend and not answered yet ([Friends._resend]).
class _Out {
  _Out({required this.id, required this.address, this.to, required this.words, required this.row, required this.first, required this.next, this.tries = 1});
  final String id;
  final String address;

  /// The install it was sent to, by name: sent again only to that one. Null in what was kept by a build from before.
  String? to;
  final String words;

  // The phone's row for it, when it first went, when it goes next, and how many times it has gone.
  final int row;
  final DateTime first;
  DateTime next;
  int tries;

  Map<String, Object> toJson() => {'i': id, 'a': address, 'd': ?to, 'w': words, 'r': row, 'f': first.millisecondsSinceEpoch, 'n': next.millisecondsSinceEpoch, 't': tries};

  static _Out? fromJson(Map j) {
    final id = j['i'], address = j['a'], words = j['w'], row = j['r'], first = j['f'], next = j['n'];
    if (id is! String || address is! String || words is! String || row is! num || first is! num || next is! num) return null;
    return _Out(id: id, address: address, to: j['d'] is String ? j['d'] as String : null, words: words, row: row.toInt(), first: DateTime.fromMillisecondsSinceEpoch(first.toInt()), next: DateTime.fromMillisecondsSinceEpoch(next.toInt()), tries: (j['t'] as num?)?.toInt() ?? 1);
  }
}
