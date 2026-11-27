import '../me/cosmetics.dart';
import 'dart:async';
import '../games/game_activity.dart';
import '../names.dart';
import 'dart:convert';
import 'dart:io';
import '../platform_info.dart';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../files/file_kinds.dart';
import '../files/files_model.dart';
import '../mentions.dart';
import '../net/crypto.dart';
import '../net/hub_carrier.dart';
import 'channels.dart' show AppHangoutStore;
import '../circles/welcome.dart' show ReadOnlyRoom;
import '../circles/circle_keys.dart';
import 'roles.dart';
import 'voice.dart';
import '../me/me.dart' show Me;
import '../me/pictures.dart';
import 'plugin_note.dart';
import 'space_reactions.dart';
import 'polls.dart';

export 'plugin_note.dart';
export 'space_reactions.dart';
export 'polls.dart';

/// A hangout's chat, and its roles kept and enforced (Matt, 2026-11-15: "Implement a permissions system similar to
/// discord for hangouts and add a chat to hangouts so the whole group can send messages to the hangout as well as
/// voice and video, make default roles such as admin, moderator, member").
///
/// **Its room.** Beside the call's room each hangout has a chat room on the hub (VoiceChannel.chatRoom), sealed with
/// the same key, which anyone looking at the hangout is in, in the call or not. Everything here goes through it:
/// messages, deletions, the roster (lib/voice/roles.dart) and what moderators do.
///
/// **History.** Each device keeps the last [keep] messages it saw ([HangoutStore]); coming in, it asks for what it
/// missed and the one there with the lowest id answers, so one copy comes back, not one from each. The roster comes
/// the same way, from anyone whose is newer and checks out. The hub keeps too, sealed, what a latecomer must have (a
/// message, an edit, a deletion, a vote, the roster, the description: [_say] with keep), for one whose app was closed.
///
/// **Enforcement.** Each device does what the roster says of what it hears: a message from someone who may not write
/// is not shown, a deletion by someone who may not delete is ignored, someone muted for everyone is silenced on every
/// device ([onRoster]: lib/voice/channels.dart), someone banned is not answered at all, and a device told to leave by
/// someone above it with the right to remove people leaves.
class HangoutRoom extends ChangeNotifier {
  /// Someone not heard here at all besides the banned: put out of the circle this space is in (Voice sets it).
  bool Function(String id)? shut;

  /// Who may post here, where not everyone may: a circle's read-only space lets its owner and admins alone (Matt,
  /// 2026-11-20; lib/circles/welcome.dart). Null: everyone the roster lets. What anyone else says is dropped.
  bool Function(String id)? mayPost;

  /// A read-only space's room on the relay, bound to its circle owner's key, where the hub itself refuses anyone but the
  /// owner and admins ([setReadOnly]); null for the space's ordinary room.
  ReadOnlyRoom? get readOnly => _readOnly;
  ReadOnlyRoom? _readOnly;

  /// The room on the relay this chat is in: its read-only one, else the space's own. Messages are kept on the device
  /// under the space's own either way, so a space made read-only keeps what was said in it.
  String get hubRoom => _readOnly?.room ?? channel.chatRoom;

  /// The room [open] joined, left by [close].
  String? _inRoom;

  /// Makes this a read-only space's chat ([ro]), or an ordinary one again (null): into the other room where it is open;
  /// the relay told of a new admin list where only that changed.
  Future<void> setReadOnly(ReadOnlyRoom? ro) async {
    if (ro == _readOnly) return;
    final moved = (ro?.room ?? channel.chatRoom) != hubRoom;
    _readOnly = ro;
    if (!opened) return;
    if (moved) {
      await close();
      await open();
    } else if (ro != null && route is ReadOnlyRoute) {
      (route as ReadOnlyRoute).anchor(ro.room, ro.grantsJson);
    }
    notifyListeners();
  }

  HangoutRoom({required this.channel, required this.route, required this.name, this.username, this.signer, HangoutStore? store})
      : store = store ?? MemoryHangoutStore() {
    roster = this.store.roster(channel.chatRoom) ?? Roster.first(channel.owner, kind: channel.kind);
    // A kept roster for another owner is not this space's: start from the first.
    if (roster.owner != channel.owner) roster = Roster.first(channel.owner, kind: channel.kind);
    messages = this.store.messages(channel.chatRoom);
    _loadAbout();
    _loadVotes();
    _loadReactions();
    _loadUnsaid();
  }

  /// The most messages a device keeps of one space's chat, and hands over to one that asks what it missed.
  static const keep = 300;

  /// The space: replaced, same seed, when the circle it is in changes its kind ([updateChannel]).
  VoiceChannel channel;
  final VoiceRoute route;
  final HangoutStore store;

  /// What this install signs rosters with; null where it can't (it then changes nothing).
  final NetSigner? signer;

  /// The circle keys a circle's space is sealed with (GMFB-26, lib/circles/circle_keys.dart): the app's own unless a
  /// test gives its own. A space of no circle, or none here, is sealed with its seed's key alone, as before.
  CircleKeys? get circleKeys => _circleKeys ?? CircleKeys.app;
  set circleKeys(CircleKeys? k) => _circleKeys = k;
  CircleKeys? _circleKeys;

  /// [clear] sealed for this space: under the circle's newest key held, for a circle's space. Null where a newer key
  /// of the circle is known than this device holds: never sealed under an older one, which someone put out may hold
  /// (GMFB-26 review, finding 3); the caller keeps it until the key comes.
  Uint8List? _seal(List<int> clear) {
    final circle = channel.circle, k = circleKeys;
    return circle == null || k == null ? NetCrypto.seal(channel.key, clear) : k.seal(circle, channel.key, 'space', clear);
  }

  /// [bytes] opened for this space: under an epoch of the circle's key, or the seed's key. One under a key this device
  /// lacks is kept, opened again when the key comes, and the key asked for (finding 4).
  Uint8List? _open(Uint8List bytes, String from, {bool reaction = false}) {
    final circle = channel.circle, k = circleKeys;
    if (circle == null || k == null) return NetCrypto.open(channel.key, bytes);
    final o = k.open(circle, channel.key, 'space', bytes);
    if (o.clear == null && o.unknown) {
      _unread.add((from: from, bytes: bytes, reaction: reaction));
      if (_unread.length > 200) _unread.removeAt(0);
      k.missing(circle);
    }
    return o.clear;
  }

  /// What came under a key this device lacks, and what it would have said: both wait for the key.
  final List<({String from, Uint8List bytes, bool reaction})> _unread = [];
  final List<({Map<String, Object?> what, bool keep, bool reaction})> _unsaid = [];

  /// The most kept to be said: past it the oldest goes.
  static const mostUnsaid = 100;

  /// What waits is kept with the space's other things (`:u`), so a restart doesn't lose it (B5).
  void _keepUnsaid() {
    final st = store;
    if (st is HangoutVotesStore) (st as HangoutVotesStore).keepVotes('${channel.chatRoom}:u', jsonEncode([for (final w in _unsaid) {'w': w.what, 'k': w.keep, 'r': w.reaction}]));
  }

  /// Reads back what was waiting to be said when the app last ran.
  void _loadUnsaid() {
    final st = store;
    if (st is! HangoutVotesStore) return;
    try {
      for (final j in jsonDecode((st as HangoutVotesStore).votesOf('${channel.chatRoom}:u') ?? '[]') as List) {
        if (j is Map && j['w'] is Map) _unsaid.add((what: (j['w'] as Map).cast<String, Object?>(), keep: j['k'] == true, reaction: j['r'] == true));
      }
    } catch (_) {}
  }

  /// Queues [what] until the circle's key comes.
  void _wait(Map<String, Object?> what, {bool keep = false, bool reaction = false}) {
    _unsaid.add((what: what, keep: keep, reaction: reaction));
    if (_unsaid.length > mostUnsaid) _unsaid.removeAt(0);
    _keepUnsaid();
    final circle = channel.circle;
    if (circle != null) circleKeys?.missing(circle);
    notifyListeners();
  }

  /// Whether what is said here waits for the circle's new key: the screen says so.
  bool get waitingForKey => _unsaid.isNotEmpty || (channel.circle != null && (circleKeys?.lacking(channel.circle!) ?? false));

  /// The circle's key came: what waited is said, and what couldn't be read is read.
  void _keyCame() {
    final circle = channel.circle, k = circleKeys;
    // With no circle keys (switched off, or a space of no circle), what a build with them on left waiting goes now,
    // under the seed's key, rather than wait for a key that never comes (third review, item 4).
    if (circle != null && k != null && k.lacking(circle)) return;
    final said = [..._unsaid];
    _unsaid.clear();
    _keepUnsaid();
    for (final w in said) {
      w.reaction ? _sendReaction(w.what) : _say(w.what, keep: w.keep);
    }
    final unread = [..._unread];
    _unread.clear();
    for (final u in unread) {
      u.reaction ? _heardReaction(u.from, u.bytes) : _heard(u.from, u.bytes);
    }
    notifyListeners();
  }
  String name;
  String? username;

  late Roster roster;
  late List<HangoutMessage> messages;

  /// Who is in the chat room now, with what they said of themselves.
  final Map<String, HangoutPerson> present = {};

  /// The username each install here has said it goes by, kept after it leaves: one person's phone and paired computer
  /// are two installs here under one username.
  final Map<String, String> usernames = {};

  /// Whether [m] mentions the person on this device: this install, or another install of theirs (their phone, their
  /// computer), known by saying the same username as this one does (Matt, 2026-11-19: "Add mentions support to spaces
  /// and circles with the @user prefix").
  bool mentionsMe(HangoutMessage m) {
    if (m.mentions.isEmpty || m.from == me) return false;
    final mine = username;
    // Written by another install of this person's: not a mention to be told of.
    if (mine != null && mine.isNotEmpty && usernames[m.from] == mine) return false;
    return m.mentions.any((x) => x.id == me || (mine != null && mine.isNotEmpty && usernames[x.id] == mine));
  }

  /// Set when someone with the right to told this device to leave, or it was banned: why.
  String? putOut;
  bool opened = false;

  /// Told when the roster changes, to do what it says in the call (who is heard, who is seen).
  void Function(Roster roster)? onRoster;

  /// Told of the messages the chat takes in that it did not have, sent here or heard (a mention's notification:
  /// lib/voice/mention_alerts.dart).
  void Function(List<HangoutMessage> fresh)? onFresh;

  /// Told of the words between an SMS space's texting phone and its members' phones, each a map whose `t` is `sms?`
  /// or `sms#` (lib/circles/sms_space.dart): said to one device alone, never kept, ignored by an older build.
  void Function(String from, Map<String, dynamic> said)? onSignal;

  /// Says [what] to the chat room, for [onSignal]'s words: with `to`, to that one person's devices alone.
  void signal(Map<String, Object?> what) => _say(what);

  final List<StreamSubscription<Object?>> _subs = [];

  String get me => route.me;

  /// Whether this device's person may do [p] here, by the roster.
  bool can(Perm p) => roster.can(me, p);

  /// Joins the chat room on the hub, says who this is, and asks those here for what was missed (messages since the
  /// newest held, a newer roster, a newer description). Does nothing where already open.
  Future<void> open() async {
    if (opened) return;
    opened = true;
    putOut = roster.banned.contains(me) ? 'You were banned from this space.' : null;
    final at = _inRoom = hubRoom;
    final circle = channel.circle, keys = circleKeys;
    if (circle != null && keys != null) _subs.add(keys.taken.where((s) => s == circle).listen((_) => _keyCame()));
    _subs.add(route.packets.where((p) => p.room == at).listen((p) => _heard(p.from, p.bytes)));
    _subs.add(route.events.where((e) => e.room == at).listen(_event));
    // Reactions as packets of their own (relay/lib/hub.dart toRoomReaction): nothing else is taken from one.
    if (route is ReactionRoute) _subs.add((route as ReactionRoute).reactionPackets.where((p) => p.room == at).listen((p) => _heardReaction(p.from, p.bytes)));
    final List<String> there;
    try {
      final ro = _readOnly;
      final r = route is ReadOnlyRoute ? route as ReadOnlyRoute : null;
      there = ro != null && r != null ? await r.joinReadOnly(at, channel.chatToken, ro.join) : await route.join(at, channel.chatToken);
    } catch (_) {
      // Not in yet (the relay server slow to answer): in as soon as it is, when [_event] hears who is here.
      _dropped = true;
      return;
    }
    _in = true;
    for (final id in there) {
      present[id] = present[id] ?? HangoutPerson(id);
    }
    _hi(ask: true);
    _say({'t': 'sync?', 'since': messages.isEmpty ? 0 : messages.last.at, 'v': roster.version, 'av': _about?.version ?? 0});
    // What waited from before a restart goes now, where the key is here.
    if (_unsaid.isNotEmpty) _keyCame();
    notifyListeners();
  }

  /// Leaves the chat room. What is held (messages, roster) stays, for the list and the next [open].
  Future<void> close() async {
    if (!opened) return;
    opened = false;
    _in = false;
    route.leave(_inRoom ?? hubRoom);
    _inRoom = null;
    // Taken out first: an open() while these are cancelled starts a list of its own.
    final subs = [..._subs];
    _subs.clear();
    for (final s in subs) {
      await s.cancel();
    }
    present.clear();
    notifyListeners();
  }

  /// Said again when this device goes in or out of the call, or its name changes.
  void sayMe({bool? inVoice}) {
    if (inVoice != null) _inVoice = inVoice;
    _hi();
  }

  /// This device is in the space's call now: said in its 'hi' (`a`).
  bool _inVoice = false;

  /// The song this device plays to the space's call as its DJ (lib/voice/spotify.dart), said in its 'hi' (`mp`) so the
  /// circle's list shows it to whoever is not in the call; '' for none. Said again only as it changes.
  String _music = '';
  void sayMusic(String song) {
    final cut = String.fromCharCodes(song.runes.take(HangoutPerson.musicMost));
    if (cut == _music) return;
    _music = cut;
    _hi();
  }

  /// What this device shows the space's call, said in its 'hi' (`pv`: 'c' its camera, 's' its screen) while it is in
  /// the call, so the circle's list marks it for whoever is not in the call (GMFB-66: "show what users are streaming
  /// and or sharing video"); '' for neither. Said again only as it changes. A build from before reads no `pv`.
  String _picture = '';
  void sayPicture({required bool camera, required bool screen}) {
    final now = screen ? 's' : (camera ? 'c' : '');
    if (now == _picture) return;
    _picture = now;
    _hi();
  }

  /// The song someone in the call plays to it, as they last said; null for none.
  String? get musicInCall {
    for (final p in present.values) {
      if (p.inVoice && p.music.isNotEmpty) return p.music;
    }
    return null;
  }

  /// Says who this is. [ask]: on coming in, those here answer with theirs. The relay tells the room someone came only
  /// with their first device, so a person's second device (one identity on a phone and its computer) was greeted by
  /// nobody and saw those here without their names until they spoke.
  void _hi({bool ask = false}) {
    final me = Me.instance;
    _say({'t': 'hi', 'n': name, if (username != null) 'u': username, 'a': _inVoice, if (_inVoice && _music.isNotEmpty) 'mp': _music, if (_inVoice && _picture.isNotEmpty) 'pv': _picture, if (ask) 'q': true, if (me.status.isNotEmpty) 'st': me.status, if (me.picture.isNotEmpty) 'ph': ProfilePictures.hashOf(me.picture), if (GamePresence.instance.forSpaces != null) 'ga': GamePresence.instance.forSpaces!.toJson(), if (!me.cosmetics.isEmpty) 'cx': me.cosmetics.toJson()});
  }

  /// Pictures asked for and not yet answered, by whose: one asking at a time for each person.
  final Map<String, Completer<String?>> _askedPictures = {};

  /// [id]'s profile picture: the one kept here where it is theirs now, else asked of them (`pic?`, answered `pic` by
  /// the person alone); null where they have none, or no answer comes within a few seconds.
  Future<String?> pictureOf(String id) async {
    final hash = present[id]?.pictureHash ?? '';
    // Here and saying no picture: none, whatever was kept from before (they took theirs away).
    if (present.containsKey(id) && hash.isEmpty) return null;
    final kept = ProfilePictures.instance.of(id, hash: hash.isEmpty ? null : hash);
    if (kept != null || hash.isEmpty) return kept;
    final asked = _askedPictures[id] ??= Completer<String?>();
    _say({'t': 'pic?', 'to': id});
    try {
      return await asked.future.timeout(const Duration(seconds: 6));
    } on TimeoutException {
      return null;
    } finally {
      _askedPictures.remove(id);
    }
  }

  /// When each newcomer was last greeted ([_greet]): once, whether they came with their first device or said hi asking.
  final Map<String, DateTime> _greeted = {};

  /// Says who this is for the newcomer [id], once in ten seconds for each.
  void _greet(String id) {
    final at = _greeted[id];
    if (at != null && DateTime.now().difference(at) < const Duration(seconds: 10)) return;
    _greeted[id] = DateTime.now();
    _hi();
  }

  // --- chat --------------------------------------------------------------------------------------------------------

  /// Writes [text] to the hangout; false where this device may not.
  bool send(String text, {List<Mention> mentions = const [], SpaceReply? reply, String? thread}) => sendWith(text: text, mentions: mentions, reply: reply, thread: thread);

  /// The chat itself: every message but those in a thread (GMFB-36).
  List<HangoutMessage> get timeline => [for (final m in messages) if (m.thread == null) m];

  /// The messages in [root]'s thread, oldest first.
  List<HangoutMessage> threadOf(String root) => [for (final m in messages) if (m.thread == root) m];

  /// How many are in each thread, by the message it hangs from, and the newest of each: for the line under it.
  Map<String, ({int count, HangoutMessage last})> get threads {
    final out = <String, ({int count, HangoutMessage last})>{};
    for (final m in messages) {
      final root = m.thread;
      if (root == null) continue;
      final had = out[root];
      out[root] = (count: (had?.count ?? 0) + 1, last: m);
    }
    return out;
  }

  /// Whether this device may write here at all: the roster's Send messages, and not put out. Files and stickers are
  /// part of writing (Matt, 2026-11-18): whoever may write may send them (in a circle its roles say more:
  /// lib/ui/space_chat_files.dart spaceMayAttach).
  bool get mayWrite => can(Perm.chat) && putOut == null && (mayPost?.call(me) ?? true);

  /// Whether [id] may post here (the roster aside): everyone but where [mayPost] says otherwise.
  bool _posts(String id) => mayPost?.call(id) ?? true;

  /// Writes [text], with [files] that are up already or a [sticker], to the hangout; false where this device may not or
  /// there is nothing to send. [id]: the one an [OutgoingMessage] was shown under.
  /// [mentions]: who is meant by an "@Name" in [text], counted in [text] as given (lib/mentions.dart).
  /// [note]: a plugin's, for it to draw as a card over [text] (lib/voice/plugin_note.dart); only with words alone.
  /// [reply]: the message this answers (GMFB-13), shown over it as a quote.
  /// [thread]: the message whose thread this goes in (GMFB-36); it quotes that message where nothing else is answered.
  bool sendWith({String text = '', List<SpaceFile> files = const [], String? sticker, bool voice = false, String? id, List<Mention> mentions = const [], PluginChatNote? note, SpaceReply? reply, String? thread}) {
    var words = text.trim();
    if (sticker != null && !HangoutMessage.stickerPattern.hasMatch(sticker)) return false;
    final extra = files.isNotEmpty || sticker != null;
    if ((words.isEmpty && !extra) || !mayWrite) return false;
    final most = extra ? HangoutMessage.mostWordsWith : 4000;
    if (words.length > most) words = words.substring(0, most);
    final m = fitted(HangoutMessage(
      id: id ?? NetCrypto.hex(NetCrypto.randomBytes(8)),
      from: me,
      name: name,
      text: words,
      at: DateTime.now().millisecondsSinceEpoch,
      files: sticker != null ? const [] : files.take(HangoutMessage.mostFiles).toList(),
      sticker: sticker,
      voice: voice && files.length == 1 && sticker == null,
      // Counted in the words as sent: trimmed, and cut short where too long (a mention past the cut goes).
      mentions: Mention.checked(Mention.trimmed(mentions, text), words),
      note: extra ? null : note,
      reply: reply ?? (thread == null ? null : _quoteOf(thread)),
      thread: thread,
    ));
    _add([m]);
    _say({'t': 'msg', ...m.toJson()}, keep: true);
    return true;
  }

  /// The quote of the message [id], where it is held here.
  SpaceReply? _quoteOf(String id) {
    final m = messages.where((x) => x.id == id).firstOrNull;
    return m == null ? null : SpaceReply.of(m);
  }

  // --- polls (Matt, 2026-11-19: "add Polls as a default feature"; lib/voice/polls.dart) --------------------------------

  /// Each poll's votes: by the poll's id, then by the voter's id.
  final Map<String, Map<String, PollVote>> _votes = {};

  /// The most polls whose votes are kept, newest first ([_keepVotes]): older polls' votes go.
  static const pollsKept = 200;

  /// Asks [question] with [poll]'s answers; false where this device may not write here or it is not a poll.
  bool sendPoll(String question, PollSpec poll) {
    var q = question.trim();
    if (q.isEmpty || poll.options.length < PollSpec.least || !mayWrite) return false;
    if (q.length > PollSpec.questionMost) q = q.substring(0, PollSpec.questionMost);
    final m = HangoutMessage(id: NetCrypto.hex(NetCrypto.randomBytes(8)), from: me, name: name, text: q, at: DateTime.now().millisecondsSinceEpoch, poll: poll);
    _add([m]);
    _say({'t': 'msg', ...m.toJson()}, keep: true);
    return true;
  }

  /// Votes for [choices] (answers' indexes) in [poll]; none takes this person's vote back. False where it can't be.
  bool vote(HangoutMessage poll, List<int> choices) {
    final spec = poll.poll;
    if (spec == null || !mayWrite) return false;
    final chosen = PollVote.valid(spec, choices);
    final v = PollVote(chosen, DateTime.now().millisecondsSinceEpoch);
    _takeVote(poll.id, me, v);
    _say({'t': 'vote', 'p': poll.id, 'c': chosen, 'at': v.at}, keep: true);
    _keepVotes();
    notifyListeners();
    return true;
  }

  /// [poll]'s answers counted, each person once (by their username, where they said it, across their devices).
  PollTally tally(HangoutMessage poll) => tallyPoll(poll.poll!, _votes[poll.id] ?? const {}, personOf: _personOf, me: me);

  /// What a vote by [id] is counted under: their username where they said one (`u:` and it, lowercase), so one
  /// person's devices count once; else the id itself.
  String _personOf(String id) {
    final u = id == me ? Me.instance.username : usernames[id];
    return u == null || u.isEmpty ? id : 'u:${u.toLowerCase()}';
  }

  /// [v] as [voter]'s vote in [poll], where it is later than the one had.
  bool _takeVote(String poll, String voter, PollVote v) {
    final of = _votes[poll] ??= {};
    final had = of[voter];
    if (had != null && had.at >= v.at) return false;
    of[voter] = v;
    return true;
  }

  // --- reactions (Matt, 2026-11-20: "add reactions after done to spaces and circles"; space_reactions.dart) ---------

  /// Who put which emoji on which message here.
  final reactions = SpaceReactions();

  /// Whether this device may react here: whoever may be in the chat, in a read-only space too (only posting is held
  /// back there); not someone put out.
  bool get mayReact => putOut == null && roster.can(me, Perm.chat);

  /// [m]'s reactions as drawn, this person's (on any of their devices) marked.
  List<ReactionTally> reactionsOn(HangoutMessage m) => reactions.of(m.id, me, same: samePerson);

  /// Puts [emoji] on [m], or takes it off where this person has it there; false where this device may not react.
  bool react(HangoutMessage m, String emoji) {
    if (!mayReact || !messages.any((x) => x.id == m.id)) return false;
    final on = !reactionsOn(m).any((r) => r.emoji == emoji && r.mine);
    final at = DateTime.now().millisecondsSinceEpoch;
    if (!reactions.take(m.id, me, emoji, on: on, at: at)) return false;
    final what = {'t': 'react', 'id': m.id, 'e': emoji, 'on': on, 'at': at};
    _sendReaction(what);
    _keepReactions();
    notifyListeners();
    return true;
  }

  /// Sends a reaction: as one where the relay takes them, else as a kept packet; waits for the circle's key where it
  /// lacks it, as a reaction still (B10).
  void _sendReaction(Map<String, Object?> what) {
    final r = route;
    if (opened && r is ReactionRoute && (r as ReactionRoute).takesReactions) {
      final sealed = _seal(utf8.encode(jsonEncode(what)));
      if (sealed == null) return _wait(what, reaction: true);
      try {
        (r as ReactionRoute).sendReaction(_inRoom ?? hubRoom, sealed);
      } catch (_) {}
    } else {
      // A relay from before keeps it as any kept packet (and in a read-only room refuses it from a reader).
      _say(what, keep: true);
    }
  }

  /// A packet that came as a reaction: taken only as one.
  void _heardReaction(String from, Uint8List bytes) {
    final clear = _open(bytes, from, reaction: true);
    if (clear == null) return;
    try {
      final m = (jsonDecode(utf8.decode(clear)) as Map).cast<String, dynamic>();
      if (m['t'] == 'react') _takeReaction(from, m);
    } catch (_) {}
  }

  /// A 'react' said by [from]: taken where it is well formed and they may be in the chat (not banned, not put out of
  /// the circle).
  void _takeReaction(String from, Map<String, dynamic> m) {
    final id = m['id'], e = m['e'], at = m['at'];
    if (id is! String || e is! String || at is! int || roster.banned.contains(from) || (shut?.call(from) ?? false) || !roster.can(from, Perm.chat)) return;
    if (reactions.take(id, from, e, on: m['on'] == true, at: at)) {
      _keepReactions();
      notifyListeners();
    }
  }

  void _keepReactions() {
    final s = store;
    // Kept with the polls' votes, under a key of their own.
    if (s is HangoutVotesStore) (s as HangoutVotesStore).keepVotes('${channel.chatRoom}:r', jsonEncode(reactions.toJson()));
  }

  void _loadReactions() {
    final s = store;
    if (s is! HangoutVotesStore) return;
    try {
      reactions.takeAll(jsonDecode((s as HangoutVotesStore).votesOf('${channel.chatRoom}:r') ?? '{}'));
    } catch (_) {}
  }

  /// One vote said by [from] ('vote'), taken where they may write here.
  void _heardVote(String from, Map<String, dynamic> m) {
    final poll = m['p'], c = m['c'], at = m['at'];
    if (poll is! String || c is! List || at is! int || !roster.can(from, Perm.chat)) return;
    if (_takeVote(poll, from, PollVote([for (final x in c.take(PollSpec.most)) if (x is int) x], at))) {
      _keepVotes();
      notifyListeners();
    }
  }

  /// Many polls' votes at once, as a device hands them over with its history ([_votesOf]): each taken as one heard.
  void _heardVotes(Object? all) {
    if (all is! Map) return;
    var any = false;
    for (final p in all.entries.take(pollsKept)) {
      if (p.key is! String || p.value is! Map) continue;
      for (final v in (p.value as Map).entries) {
        final vote = PollVote.fromJson(v.value);
        if (v.key is String && vote != null && roster.can(v.key as String, Perm.chat)) any = _takeVote(p.key as String, v.key as String, vote) || any;
      }
    }
    if (any) {
      _keepVotes();
      notifyListeners();
    }
  }

  /// The votes of the polls among [of], as a `votes` answer carries them.
  Map<String, Object> _votesOf(Iterable<HangoutMessage> of) => {
        for (final m in of)
          if (m.poll != null && (_votes[m.id]?.isNotEmpty ?? false)) m.id: {for (final e in _votes[m.id]!.entries) e.key: e.value.toJson()},
      };

  /// Saves the votes, where the store keeps them: those of at most [pollsKept] polls.
  void _keepVotes() {
    final s = store;
    if (s is! HangoutVotesStore) return;
    // The newest polls' votes, those of polls still here first.
    final here = {for (final m in messages) if (m.poll != null) m.id};
    final ids = [..._votes.keys.where(here.contains), ..._votes.keys.where((k) => !here.contains(k))].reversed.take(pollsKept);
    (s as HangoutVotesStore).keepVotes(channel.chatRoom, jsonEncode({for (final id in ids) id: {for (final e in _votes[id]!.entries) e.key: e.value.toJson()}}));
  }

  void _loadVotes() {
    final s = store;
    if (s is! HangoutVotesStore) return;
    try {
      final all = jsonDecode((s as HangoutVotesStore).votesOf(channel.chatRoom) ?? '{}');
      if (all is! Map) return;
      for (final p in all.entries) {
        if (p.value is! Map) continue;
        for (final v in (p.value as Map).entries) {
          final vote = PollVote.fromJson(v.value);
          if (vote != null) _takeVote('${p.key}', '${v.key}', vote);
        }
      }
    } catch (_) {}
  }

  /// The most of a message's sealed words that go in one of the hub's packets (60 KB), with room for the sealing.
  static const wireMost = 52 * 1024;

  /// [messages] as they go in a `hist` answer, in lots that each go in one packet.
  static List<List<Map<String, Object>>> histLots(Iterable<HangoutMessage> messages) {
    final lots = <List<Map<String, Object>>>[];
    var lot = <Map<String, Object>>[];
    var bytes = 0;
    for (final x in messages) {
      final j = x.toJson()..['f'] = x.from;
      final n = utf8.encode(jsonEncode(j)).length + 1;
      if (lot.isNotEmpty && bytes + n > wireMost - 128) {
        lots.add(lot);
        lot = [];
        bytes = 0;
      }
      lot.add(j);
      bytes += n;
    }
    if (lot.isNotEmpty) lots.add(lot);
    return lots;
  }

  /// [m], its files' small pictures let go of, the biggest first, until it goes in one packet ([wireMost]).
  static HangoutMessage fitted(HangoutMessage m) {
    int size(HangoutMessage x) => utf8.encode(jsonEncode({'t': 'msg', ...x.toJson()})).length;
    var files = m.files;
    while (size(m.copyWith(files: files)) > wireMost) {
      final withThumb = [for (final f in files) if (f.thumb != null) f];
      if (withThumb.isEmpty) break;
      final biggest = withThumb.reduce((a, b) => a.thumb!.length >= b.thumb!.length ? a : b);
      files = [for (final f in files) f == biggest ? f.withoutThumb() : f];
    }
    return m.copyWith(files: files);
  }

  /// Messages with files on their way up (Matt, 2026-11-18): shown under the rest until they are sent.
  final List<OutgoingMessage> outgoing = [];

  /// Sends [picked] (files on this device) up, sealed, with [text], and the message once they are all there; null where
  /// this device may not write here or nothing could be read. [voice]: the one file is a voice message.
  OutgoingMessage? sendFiles(List<({String path, bool owned})> picked, ChatUploads uploads, {String text = '', bool voice = false, List<Mention> mentions = const [], SpaceReply? reply}) {
    if (!mayWrite) return null;
    final files = <OutgoingFile>[];
    for (final p in picked.take(HangoutMessage.mostFiles)) {
      int size;
      try {
        size = File(p.path).lengthSync();
      } catch (_) {
        continue;
      }
      final cleaned = SpaceFile.cleanName(p.path.split(PlatformInfo.pathSeparator).last.split('/').last);
      final name = cleaned.isEmpty ? 'File' : cleaned;
      files.add(OutgoingFile(path: p.path, name: name, size: size, mime: FileKind.mimeOf(name), owned: p.owned));
    }
    if (files.isEmpty) return null;
    var words = text.trim();
    if (words.length > HangoutMessage.mostWordsWith) words = words.substring(0, HangoutMessage.mostWordsWith);
    final o = OutgoingMessage(id: NetCrypto.hex(NetCrypto.randomBytes(8)), text: words, files: files, at: DateTime.now().millisecondsSinceEpoch, voice: voice && files.length == 1, mentions: Mention.trimmed(mentions, text), reply: reply);
    outgoing.add(o);
    notifyListeners();
    unawaited(_push(o, uploads));
    return o;
  }

  /// [o] tried again where it failed.
  void retry(OutgoingMessage o, ChatUploads uploads) {
    if (!outgoing.contains(o)) return;
    o.error = null;
    for (final f in o.files) {
      f.error = null;
    }
    notifyListeners();
    unawaited(_push(o, uploads));
  }

  /// [o] not sent after all: its files stopped and let go of.
  void discard(OutgoingMessage o, ChatUploads uploads) {
    if (!outgoing.remove(o)) return;
    for (final f in o.files) {
      if (f.file == null) uploads.drop(f);
    }
    notifyListeners();
  }

  /// Sends up each of [o]'s files not yet up, all at once, then the message itself once every one is there. A file
  /// that fails keeps its error for [retry]; nothing is sent where [o] was discarded meanwhile.
  Future<void> _push(OutgoingMessage o, ChatUploads uploads) async {
    // Each file's small picture its share of what a message may carry: a few pictures each get a clear one, ten a
    // smaller one each, and the message still goes in one packet ([fitted] lets go of any that would not).
    final thumbMost = math.min(SpaceFile.maxThumb, (24 * 1024) ~/ o.files.length);
    await Future.wait([
      for (final f in o.files)
        if (f.file == null)
          () async {
            try {
              f.file = await uploads.uploadForChat(channel, f, byName: name, thumbMost: thumbMost, moved: notifyListeners);
              f.error = null;
              f.waiting = null;
            } catch (e) {
              f.error = e.toString().isEmpty ? 'It didn\'t go up.' : e.toString();
            }
            if (outgoing.contains(o)) notifyListeners();
          }(),
    ]);
    if (!outgoing.contains(o) || o.files.any((f) => f.file == null)) return;
    if (sendWith(id: o.id, text: o.text, files: [for (final f in o.files) f.file!], voice: o.voice, mentions: o.mentions, reply: o.reply)) {
      outgoing.remove(o);
    } else {
      o.error = putOut ?? 'Your role can\'t send messages here.';
    }
    notifyListeners();
  }

  /// Who [id] is now, where one person had more than one id (a paired computer's key of its own before it took on the
  /// phone's identity: Circles.sameAs). Set by lib/circles/circles.dart; itself otherwise.
  static String Function(String id) sameAs = (id) => id;

  /// Whether [a] and [b] are one person's: the same id, or ids carried over to the same identity.
  static bool samePerson(String a, String b) => a == b || sameAs(a) == sameAs(b);

  /// Whether this device may edit [m]: its writer's, on any of their devices (one identity on every device), and only
  /// words, never a poll, a sticker or a plugin's note. Nobody else, whatever their role.
  bool canEdit(HangoutMessage m) => m.editable && samePerson(m.from, me) && mayWrite;

  /// [m]'s words made [text] (with who its "@Name"s in it mean), on every device in the room and kept for whoever is
  /// away; false where this device may not, or nothing changed.
  bool edit(HangoutMessage m, String text, {List<Mention> mentions = const []}) {
    if (!canEdit(m)) return false;
    var words = text.trim();
    if (words.isEmpty && m.files.isEmpty) return false;
    final most = m.files.isNotEmpty ? HangoutMessage.mostWordsWith : 4000;
    if (words.length > most) words = words.substring(0, most);
    if (words == m.text) return false;
    // Always later than the message and its last edit, whatever this device's clock says: the newest edit wins.
    final at = math.max(DateTime.now().millisecondsSinceEpoch, (m.edited ?? m.at) + 1);
    final checked = Mention.checked(Mention.trimmed(mentions, text), words);
    _applyEdit(m.id, words, checked, at);
    _say({'t': 'edit', 'id': m.id, 'x': words, if (checked.isNotEmpty) 'mn': [for (final x in checked) x.toJson()], 'ed': at}, keep: true);
    return true;
  }

  /// Edits heard before the message they change, by its id, at most [_pendingEditsKept]: applied as it comes.
  final Map<String, ({String from, String text, List<Mention> mentions, int at})> _pendingEdits = {};
  static const _pendingEditsKept = 200;

  /// Deletions heard before the message they take away, by its id, and who said them, at most [_pendingEditsKept]: the
  /// message is passed over as it comes, where whoever said it may delete it (found in the third review of relays that
  /// talk, 2026-11-23: a relay hands a room's kept messages over a piece at a time, and a deletion said live meanwhile
  /// could come first, and was passed over, the message then shown).
  final Map<String, String> _pendingDeletes = {};

  /// Whether [m] was deleted before it came, by someone who may: the deletion is used up by it.
  bool _deletedEarly(HangoutMessage m) {
    final by = _pendingDeletes[m.id];
    if (by == null || !(m.from == by || roster.isOwner(by) || (roster.can(by, Perm.manageMessages) && roster.outranks(by, m.from)))) return false;
    _pendingDeletes.remove(m.id);
    return true;
  }

  /// [id]'s words made [text] at [at], where that is newer than what it has.
  void _applyEdit(String id, String text, List<Mention> mentions, int at) {
    messages = [
      for (final x in messages)
        if (x.id == id && at > (x.edited ?? 0)) ...[x.copyWith(text: text, mentions: mentions, edited: at)] else x,
    ];
    final changed = messages.any((x) => x.id == id && x.edited == at);
    if (!changed) return;
    store.keepMessages(channel.chatRoom, messages);
    notifyListeners();
  }

  /// Whether this device may delete [m]: its own, or anyone's with Manage messages.
  bool canDelete(HangoutMessage m) => m.from == me || (can(Perm.manageMessages) && roster.outranks(me, m.from)) || roster.isOwner(me);

  /// Deletes [m] here and for everyone (kept by the hub for whoever is away), where this device may.
  void delete(HangoutMessage m) {
    if (!canDelete(m)) return;
    _drop(m.id);
    _say({'t': 'del', 'id': m.id}, keep: true);
  }

  /// Takes in messages sent here or heard: those not held are added in order of time, the newest [keep] are kept and
  /// saved, and [onFresh] is told of the new ones.
  void _add(Iterable<HangoutMessage> fresh) {
    // A message held already that comes again edited later than this device has it (a device's history): its words
    // taken. Its writer's own edit, as the history has it from them.
    for (final m in fresh) {
      final held = messages.where((x) => x.id == m.id).firstOrNull;
      if (held != null && (m.edited ?? 0) > (held.edited ?? 0) && held.editable && samePerson(held.from, m.from)) _applyEdit(m.id, m.text, m.mentions, m.edited!);
    }
    final have = {for (final m in messages) m.id};
    var more = [for (final m in fresh) if (have.add(m.id)) m];
    if (_pendingDeletes.isNotEmpty) more = [for (final m in more) if (!_deletedEarly(m)) m];
    if (more.isEmpty) return;
    // An edit that came before the message it changes (the hub hands over what it kept in its own order).
    if (_pendingEdits.isNotEmpty) {
      more = [
        for (final m in more)
          if (_pendingEdits.remove(m.id) case final e? when m.editable && samePerson(m.from, e.from) && e.at > (m.edited ?? 0))
            m.copyWith(text: e.text, mentions: e.mentions, edited: e.at)
          else
            m,
      ];
    }
    // By when they were written, and two written in the same millisecond by id: each device kept those in the order it
    // happened to hear them, so the writer saw its own first and everyone else the other's (hangout_test's chat case
    // caught the two devices disagreeing).
    messages = [...messages, ...more]..sort((a, b) => a.at != b.at ? a.at.compareTo(b.at) : a.id.compareTo(b.id));
    if (messages.length > keep) messages = messages.sublist(messages.length - keep);
    store.keepMessages(channel.chatRoom, messages);
    notifyListeners();
    onFresh?.call(more);
  }

  /// Takes the message with [id] out of what is held, and saves.
  void _drop(String id) {
    final before = messages.length;
    messages = [for (final m in messages) if (m.id != id) m];
    if (messages.length == before) return;
    store.keepMessages(channel.chatRoom, messages);
    notifyListeners();
  }

  // --- roles and moderation -------------------------------------------------------------------------------------

  /// Whether this device may change the roster: the owner or an admin, with a key to sign it with.
  bool get canManage => roster.canManage(me) && signer != null;

  /// Gives [id] [roleId]. Making an admin is the owner's alone: it carries the owner's signature that they are one.
  Future<bool> setRole(String id, String roleId) async {
    if (!canManage || !roster.outranks(me, id)) return false;
    final role = roster.roleById(roleId);
    if (role == null) return false;
    final grants = {...roster.adminGrants};
    if (roleId == Role.admin) {
      if (!roster.isOwner(me)) return false;
      grants[id] = NetCrypto.hex(await signer!.sign(Roster.grantMessage(roster.owner, id)));
    } else {
      grants.remove(id);
      // An admin gives out only roles below their own.
      if (!roster.isOwner(me) && role.rank >= roster.roleOf(me).rank) return false;
    }
    final assigned = {...roster.assigned, id: roleId};
    return _publish(roster.next(assigned: assigned, adminGrants: grants));
  }

  /// Makes [id] an admin, signed by [owner] where that is this space's owner: a paired computer giving what it made
  /// under a key of its own to the identity it speaks as now (Voice.carryOver). True where nothing is left to do.
  Future<bool> grantAdminAs(NetSigner owner, String id) async {
    if (!roster.isOwner(owner.id) || roster.canManage(id)) return true;
    // Not in the room yet: said now it would go nowhere (the relay drops a room's packet from outside it), so not done.
    if (!opened || _dropped) return false;
    final grants = {...roster.adminGrants, id: NetCrypto.hex(await owner.sign(Roster.grantMessage(roster.owner, id)))};
    final next = roster.next(assigned: {...roster.assigned, id: Role.admin}, adminGrants: grants);
    final signed = await next.signedBy(owner.id, owner.publicKey, owner.sign);
    if (!signed.trustedFor(channel.owner)) return false;
    _take(signed);
    _say({'t': 'roster', 'r': signed.toJson()}, keep: true);
    return true;
  }

  /// Whether this device may mute [id] for everyone and unmute them: its role has Mute others, and is above theirs
  /// (so never oneself: someone muted can't lift it).
  bool canMuteForAll(String id) => can(Perm.muteOthers) && roster.outranks(me, id);

  /// Mutes [id] for everyone, or lets them speak again.
  Future<bool> muteForAll(String id, bool on) async {
    if (!canMuteForAll(id)) return false;
    // A mute stands in the roster when an admin makes it; a moderator's is said to the room and held while they are.
    if (canManage) {
      // A moderator's mute still held is lifted by whoever is above them too (GMFB-49): an admin's switch only wrote
      // the roster, which never named them, so it stayed on and they stayed silent. Said as a moderator says it.
      if (!on && heldMutes.contains(id)) {
        _say({'t': 'mute', 'who': id, 'on': false});
        _applyMute(id, false);
        if (!roster.muted.contains(id)) return true;
      }
      final muted = {...roster.muted};
      on ? muted.add(id) : muted.remove(id);
      return _publish(roster.next(muted: muted));
    }
    // Said to everyone (not to them alone): every device holds it.
    _say({'t': 'mute', 'who': id, 'on': on});
    _applyMute(id, on);
    return true;
  }

  /// Moderators' mutes, held on each device while it is in the hangout.
  final Set<String> heldMutes = {};

  /// Holds or lifts a moderator's mute of [id], and has the call do it ([onRoster]).
  void _applyMute(String id, bool on) {
    on ? heldMutes.add(id) : heldMutes.remove(id);
    onRoster?.call(roster);
    notifyListeners();
  }

  /// Whether [id] may be heard: the roster, and any mute a moderator said.
  bool heard(String id) => roster.can(id, Perm.speak) && !heldMutes.contains(id);

  /// Whether [id] is muted for everyone (GMFB-49): by an admin in the roster, or by a moderator while they are here.
  /// Apart from muting oneself, and from a role that may not speak.
  bool mutedForAll(String id) => roster.muted.contains(id) || heldMutes.contains(id);

  /// Why this device may not unmute, for its mute button to say (GMFB-49); null where it may.
  String? get micLockedWhy {
    if (heard(me)) return null;
    if (mutedForAll(me)) return 'A moderator muted you for everyone. Only a moderator can unmute you.';
    if (listens(me)) return 'You\'re listening. Raise your hand to ask to speak.';
    return 'Your role can\'t speak in this space.';
  }

  /// Tells the newcomer [to] of the moderators' mutes held here (GMFB-49): they were said once, to whoever was there
  /// then, so someone who came later heard a muted person whose app let them talk. Said by each device that could
  /// have made the mute itself, since the newcomer believes it from no one else.
  void _tellMutes(String to) {
    if (!can(Perm.muteOthers)) return;
    for (final id in heldMutes) {
      if (roster.outranks(me, id)) _say({'t': 'mute', 'to': to, 'who': id, 'on': true});
    }
  }

  /// Puts [id] out of the hangout now; they can come back.
  bool remove(String id) {
    if (!can(Perm.removeMembers) || !roster.outranks(me, id)) return false;
    _say({'t': 'kick', 'to': id});
    present.remove(id);
    notifyListeners();
    return true;
  }

  /// Bans [id]: kept out for good (in the roster), and put out now.
  Future<bool> ban(String id, {bool on = true}) async {
    if (!can(Perm.ban) || !roster.outranks(me, id) || !canManage) return false;
    final banned = {...roster.banned};
    on ? banned.add(id) : banned.remove(id);
    final ok = await _publish(roster.next(banned: banned));
    if (ok && on) {
      _say({'t': 'kick', 'to': id});
      present.remove(id);
    }
    return ok;
  }

  /// [c], the same space with its kind (or name) changed by its circle: kept here so what the space may do follows it.
  /// Made a Files space, members may add files and moderators and admins manage them, as a new Files space's roles
  /// have; made another kind, the Files permissions go. A roster no one has signed yet is the kind's first roster; a
  /// signed one is changed and signed here where this install may manage it (else by whoever may, as they see it).
  void updateChannel(VoiceChannel c) {
    if (c.seed != channel.seed) return;
    final was = channel.kind;
    channel = c;
    if (c.kind != was) {
      if (roster.version == 0 && roster.sig == null) {
        _take(Roster.first(c.owner, kind: c.kind));
      } else if (canManage) {
        final defaults = {for (final r in Role.defaultsFor(c.kind)) r.id: r};
        final roles = [
          for (final r in roster.ranked)
            r.copyWith(perms: c.kind == SpaceKind.files ? {...r.perms, ...?defaults[r.id]?.perms.intersection(Perm.files)} : r.perms.difference(Perm.files)),
        ];
        unawaited(_publish(roster.next(roles: roles)));
      }
    }
    notifyListeners();
  }

  /// Changes what [role] may do, or its name or rank; or adds it where it is new. Admin keeps every permission.
  Future<bool> saveRole(Role role) async {
    if (!canManage) return false;
    // Only what a space of this kind has: a voice or texting space's roles never name a Files permission (Perm.files).
    final fixed = role.id == Role.admin ? role.copyWith(perms: Perm.of(channel.kind), rank: 30) : role.copyWith(perms: role.perms.intersection(Perm.of(channel.kind)), rank: role.rank.clamp(1, 29));
    final roles = [for (final r in roster.ranked) r.id == role.id ? fixed : r];
    if (!roles.any((r) => r.id == role.id)) roles.add(fixed);
    return _publish(roster.next(roles: roles));
  }

  /// Takes away a role (not admin, not the one newcomers get); whoever had it goes back to the newcomers' role.
  Future<bool> deleteRole(String roleId) async {
    if (!canManage || roleId == Role.admin || roleId == roster.newcomer) return false;
    final roles = [for (final r in roster.ranked) if (r.id != roleId) r];
    final assigned = {for (final e in roster.assigned.entries) if (e.value != roleId) e.key: e.value};
    return _publish(roster.next(roles: roles, assigned: assigned));
  }

  // --- a stage (GMFB-29, from the Uplink gap review: "A stage/stream mode: some people speak, many listen, with a
  // listener count") ---------------------------------------------------------------------------------------------

  /// Whether the space is a stage: whoever comes in listens, and speaks only once someone who manages it lets them.
  bool get stage => roster.newcomer == Role.listener;

  /// Makes the space a stage, or an ordinary space again. On: a Listener role (chat, no voice or video) is what
  /// newcomers get, and whoever has no other role listens. Off: everyone who was listening is a member again.
  Future<bool> setStage(bool on) async {
    if (!canManage || on == stage) return false;
    final roles = roster.roleById(Role.listener) == null ? [...roster.ranked, Role.listenerRole] : roster.ranked;
    if (on) return _publish(roster.next(roles: roles, newcomer: Role.listener));
    final assigned = {for (final e in roster.assigned.entries) if (e.value != Role.listener) e.key: e.value};
    return _publish(roster.next(roles: roles, newcomer: Role.member, assigned: assigned));
  }

  /// Whether [id] listens on this stage rather than speaks: may neither speak nor show video.
  bool listens(String id) => stage && !roster.can(id, Perm.speak) && !roster.can(id, Perm.video);

  /// Brings [id] up to speak (a member) or back to the audience (a listener), as someone who manages the stage.
  Future<bool> setSpeaker(String id, bool on) => setRole(id, on ? Role.member : Role.listener);

  /// The role people have until given another.
  Future<bool> setNewcomer(String roleId) async {
    if (!canManage || roleId == Role.admin || roster.roleById(roleId) == null) return false;
    return _publish(roster.next(newcomer: roleId));
  }

  /// Signs [next] as this device, takes it, and says it to the room (kept by the hub for whoever is away). False where
  /// there is no key to sign with or the signed roster would not be believed.
  Future<bool> _publish(Roster next) async {
    final s = signer;
    if (s == null) return false;
    final signed = await next.signedBy(me, s.publicKey, s.sign);
    if (!signed.trustedFor(channel.owner)) return false;
    _take(signed);
    _say({'t': 'roster', 'r': signed.toJson()}, keep: true);
    return true;
  }

  /// Makes [r] the roster in force (the caller has checked it): saved, the description checked against it again, and
  /// the call told.
  void _take(Roster r) {
    roster = r;
    store.keepRoster(channel.chatRoom, r);
    // A description by someone this roster no longer makes owner or admin goes from under the name: it stayed there
    // on every device after its writer was demoted (Matt, 2026-11-17: "Finish the missing pieces that went
    // unfinished"). It waits, in case they are made one again.
    final shown = _about;
    if (shown != null && !shown.trustedFor(channel.chatRoom, r)) {
      _about = null;
      if (shown.version > (_waitingAbout?.version ?? 0)) _waitingAbout = shown;
    }
    // An about signed by an admin can come before the roster that makes them one: tried again now.
    final waiting = _waitingAbout;
    if (waiting != null && waiting.trustedFor(channel.chatRoom, r)) {
      _waitingAbout = null;
      _takeAbout(waiting);
    }
    if (r.banned.contains(me)) {
      putOut = 'You were banned from this space.';
    }
    onRoster?.call(r);
    notifyListeners();
  }

  // --- the description ---------------------------------------------------------------------------------------------

  /// What the space is for, as its owner or an admin wrote it, shown under its name in the header (Matt, 2026-11-17:
  /// "make the text header for spaces show the icon and the name and an area for a description of the channel").
  /// Null where no one has written one, or it was cleared.
  String? get about => (_about?.text ?? '').isEmpty ? null : _about!.text;

  /// The description in force, signed; an empty one is a cleared one, kept for its version.
  SpaceAbout? _about;

  /// The newest about heard that the roster doesn't yet trust (its admin's roster not here yet).
  SpaceAbout? _waitingAbout;

  /// Writes [text] as the space's description, for everyone in it; false where this install may not (only the owner
  /// and admins, as with the roster).
  Future<bool> setAbout(String text) async {
    final s = signer;
    if (s == null || !canManage) return false;
    final words = text.trim();
    final next = await SpaceAbout.sign(channel.chatRoom, words.length > SpaceAbout.most ? words.substring(0, SpaceAbout.most) : words, (_about?.version ?? 0) + 1, me, s.publicKey, s.sign);
    if (!next.trustedFor(channel.chatRoom, roster)) return false;
    _takeAbout(next);
    _say({'t': 'about', 'a': next.toJson()}, keep: true);
    return true;
  }

  /// A description heard: taken where it is newer than the one in force and the roster trusts its writer; held back
  /// where the roster doesn't yet.
  void _heardAbout(Object? j) {
    final a = SpaceAbout.fromJson(j);
    if (a == null) return;
    // Two admins writing the same version at once: the one whose signature sorts last, on every device alike, rather
    // than whichever each heard first.
    final cur = _about;
    if (cur == null ? a.version <= 0 : (a.version < cur.version || (a.version == cur.version && a.sig.compareTo(cur.sig) <= 0))) return;
    if (a.trustedFor(channel.chatRoom, roster)) {
      _takeAbout(a);
    } else if (a.version > (_waitingAbout?.version ?? 0)) {
      _waitingAbout = a;
    }
  }

  /// Makes [a] the description in force, and saves it.
  void _takeAbout(SpaceAbout a) {
    _about = a;
    if (_waitingAbout != null && _waitingAbout!.version <= a.version) _waitingAbout = null;
    _keepAbout(a);
    notifyListeners();
  }

  /// The about is kept beside the roster, but not in it: an older build rebuilds a roster's signed bytes from the
  /// fields it knows, so a new field there would have 0.9.2 refuse every roster. The app's store has no slot for it,
  /// so it goes under a key of its own in the same choices (`hangout_<room>_about`), which keep any key.
  static String _aboutKey(String room) => 'hangout_${room}_about';

  void _keepAbout(SpaceAbout a) {
    final s = store, words = jsonEncode(a.toJson());
    if (s is HangoutAboutStore) {
      (s as HangoutAboutStore).keepAbout(channel.chatRoom, words);
    } else if (s is AppHangoutStore) {
      s.app.set(_aboutKey(channel.chatRoom), words);
    }
  }

  /// Reads the kept description back: in force where the kept roster trusts it, waiting where not.
  void _loadAbout() {
    final s = store;
    String? words;
    if (s is HangoutAboutStore) {
      words = (s as HangoutAboutStore).aboutOf(channel.chatRoom);
    } else if (s is AppHangoutStore) {
      words = s.app.choice(_aboutKey(channel.chatRoom), '');
    }
    if (words == null || words.isEmpty) return;
    try {
      final a = SpaceAbout.fromJson(jsonDecode(words));
      if (a == null) return;
      a.trustedFor(channel.chatRoom, roster) ? _about = a : _waitingAbout = a;
    } catch (_) {}
  }

  // --- the room ------------------------------------------------------------------------------------------------------

  /// The relay dropped this device out of the room ([RoomEvent.closed]); it puts it back in on reconnecting.
  bool _dropped = false;

  /// Whether this device is in the room on the relay server now: asked for, answered, and not dropped since. Until it
  /// is, a chat with nothing in it is not known to be empty (lib/ui/hangout_screen.dart draws it in bones).
  bool get reached => _in && !_dropped;
  bool _in = false;

  /// What the hub says of the room: this device dropped out of it or back in it, or someone came or went.
  void _event(RoomEvent e) {
    if (e.closed) {
      _dropped = true;
      present.clear();
    } else if (e.members != null && _dropped) {
      // Back in after the relay dropped and came back, or in at last after an answer that came late: who is here now,
      // and what was said meanwhile.
      _dropped = false;
      _in = true;
      present.clear();
      for (final id in e.members!) {
        present[id] = HangoutPerson(id);
      }
      _hi(ask: true);
      _say({'t': 'sync?', 'since': messages.isEmpty ? 0 : messages.last.at, 'v': roster.version, 'av': _about?.version ?? 0});
    } else if (e.came != null) {
      present[e.came!] = HangoutPerson(e.came!);
      // Who is here and what they call themselves, for the newcomer.
      _greet(e.came!);
      _tellMutes(e.came!);
    } else if (e.went != null) {
      present.remove(e.went);
      heldMutes.remove(e.went);
    }
    notifyListeners();
  }

  /// Says [what] to everyone in the chat room. [keep]: the hub keeps it for whoever comes in later (a message, a
  /// deletion, the roster, the description), so a phone that was closed when it was said still has it (Matt, 2026-11-18:
  /// "I can't see their messages in spaces within a circle").
  void _say(Map<String, Object?> what, {bool keep = false}) {
    if (!opened) return;
    try {
      final sealed = _seal(utf8.encode(jsonEncode(what)));
      if (sealed == null) return _wait(what, keep: keep);
      final r = route;
      if (keep && r is HubVoiceRoute) {
        r.sendKept(_inRoom ?? hubRoom, sealed);
      } else {
        r.send(_inRoom ?? hubRoom, sealed);
      }
    } catch (_) {}
  }

  /// Whether this device is the one to answer [asker]: the lowest id of those here besides them.
  bool _answers(String asker) {
    // In a read-only space the relay passes what a reader asks to those who may post alone: one of them answers.
    final ids = [me, ...present.keys.where((id) => id != asker && _posts(id))]..sort();
    return ids.first == me;
  }

  /// A packet from the chat room: opened with the space's key (anything that doesn't open is dropped) and acted on by
  /// its kind `t`. Every right is checked here against the roster, since the hub checks none.
  void _heard(String from, Uint8List bytes) {
    final clear = _open(bytes, from);
    if (clear == null) return;
    Map<String, dynamic> m;
    try {
      m = (jsonDecode(utf8.decode(clear)) as Map).cast<String, dynamic>();
    } catch (_) {
      return;
    }
    final to = m['to'];
    if (to != null && to != me) {
      // Others told to leave are gone from here too.
      if (m['t'] == 'kick' && roster.can(from, Perm.removeMembers) && roster.outranks(from, '$to')) {
        present.remove('$to');
        notifyListeners();
      }
      return;
    }
    // Someone banned is not heard at all.
    if (roster.banned.contains(from) || (shut?.call(from) ?? false)) return;
    switch (m['t']) {
      case 'hi':
        // Another device of this identity is this person, not someone else here (counted with "here" otherwise).
        if (from == me) return;
        present[from] = HangoutPerson(from,
            name: bareName('${m['n'] ?? ''}'),
            username: m['u'] is String ? m['u'] as String : null,
            inVoice: m['a'] == true,
            guest: m['g'] == true,
            // The song they play to the call as its DJ: a guest is never one.
            music: m['mp'] is String && m['a'] == true && m['g'] != true ? String.fromCharCodes((m['mp'] as String).runes.take(HangoutPerson.musicMost)) : '',
            // What they show the call (GMFB-66): only while they are in it.
            camera: m['a'] == true && m['pv'] == 'c',
            screen: m['a'] == true && m['pv'] == 's',
            status: m['st'] is String ? String.fromCharCodes((m['st'] as String).runes.take(Me.statusMost)) : '',
            pictureHash: m['ph'] is String ? m['ph'] as String : '',
            // What they are playing, as their greeting says now (lib/games/game_activity.dart): none said, none.
            game: GameActivity.fromJson(m['ga']),
            // What their profile wears (lib/me/cosmetics.dart): ids alone, drawn from the art this build has.
            cosmetics: Cosmetics.fromJson(m['cx']) ?? Cosmetics.none);
        if (m['u'] is String && (m['u'] as String).isNotEmpty) usernames[from] = m['u'] as String;
        notifyListeners();
        // Come in asking who is here (a person's second device, whom the relay announces to nobody): told, once.
        if (m['q'] == true) _greet(from);
      case 'pic?':
        // Someone looking at this person's profile (it came to them alone: `to` above).
        // `p` the small one, for builds from before 0.10.4; `pp` the sharp one shown, for the rest.
        final mine = Me.instance.picture, sharp = Me.instance.pictureSharp;
        if (mine.isNotEmpty) _say({'t': 'pic', 'to': from, 'p': mine, if (sharp != mine) 'pp': sharp});
      case 'pic':
        final p = m['p'], pp = m['pp'];
        if (p is String) {
          ProfilePictures.instance.keep(from, pp is String && pp.isNotEmpty ? pp : p, markOf: p);
          final asked = _askedPictures[from];
          if (asked != null && !asked.isCompleted) asked.complete(ProfilePictures.instance.of(from));
        }
      case 'sms?' || 'sms#':
        onSignal?.call(from, m);
      case 'msg':
        final msg = HangoutMessage.fromJson(m, from);
        if (msg != null && roster.can(from, Perm.chat) && _posts(from)) _add([msg]);
      case 'vote':
        if (_posts(from)) _heardVote(from, m);
      case 'votes':
        _heardVotes(m['v']);
      case 'react':
        _takeReaction(from, m);
      case 'reacts':
        if (reactions.takeAll(m['r'], may: (id) => roster.can(id, Perm.chat) && !roster.banned.contains(id) && !(shut?.call(id) ?? false))) {
          _keepReactions();
          notifyListeners();
        }
      case 'edit':
        // Only its writer's own word, from any of their devices: an edit from anyone else is no edit.
        final id = '${m['id']}', text = m['x'], at = m['ed'];
        if (text is! String || at is! int || !_posts(from)) return;
        final words = text.trim();
        final mentions = Mention.checked(Mention.listFromJson(m['mn'], text), words);
        final msg = messages.where((x) => x.id == id).firstOrNull;
        if (msg == null) {
          if (_pendingEdits.length < _pendingEditsKept) _pendingEdits[id] = (from: from, text: words, mentions: mentions, at: at);
        } else if (msg.editable && samePerson(msg.from, from)) {
          _applyEdit(id, words, mentions, at);
        }
      case 'del':
        final id = '${m['id']}';
        final msg = messages.where((x) => x.id == id).firstOrNull;
        if (msg == null) {
          // Before the message it takes away: held for it.
          if (_pendingDeletes.length < _pendingEditsKept) _pendingDeletes[id] = from;
        } else if (msg.from == from || roster.isOwner(from) || (roster.can(from, Perm.manageMessages) && roster.outranks(from, msg.from))) {
          _drop(id);
        }
      case 'sync?':
        if (_answers(from)) {
          final since = m['since'] is int ? m['since'] as int : 0;
          final missed = [for (final x in messages) if (x.at > since) x];
          // In as many packets as it takes: one packet holds 60 KB, and a message with files carries their small
          // pictures, so what was missed all in one could be too big to go at all.
          for (final lot in histLots(missed.take(keep))) {
            _say({'t': 'hist', 'to': from, 'm': lot});
          }
          // Every vote in the polls it has, after them: an older build has no case for `votes` and passes over it.
          final votes = _votesOf(messages);
          if (votes.isNotEmpty) _say({'t': 'votes', 'to': from, 'v': votes});
          // And the reactions on what it has: an older build has no case for `reacts` and passes over it.
          final reacts = reactions.toJson({for (final x in messages) x.id});
          if (reacts.isNotEmpty) _say({'t': 'reacts', 'to': from, 'r': reacts});
        }
        // The roster comes from everyone who has a newer one, not the one answerer: it is small, and checked by its
        // signature whoever sends it.
        if (roster.sig != null && (m['v'] is! int || roster.version > (m['v'] as int))) _say({'t': 'roster', 'to': from, 'r': roster.toJson()});
        // The description the same way, after the roster that trusts its writer. An older build's sync? has no `av`
        // and gets it anyway; it has no case for `about` and passes over it (this switch has no default).
        final a = _about;
        if (a != null && (m['av'] is! int || a.version > (m['av'] as int))) _say({'t': 'about', 'to': from, 'a': a.toJson()});
      case 'hist':
        _add([
          for (final j in (m['m'] as List? ?? const []))
            // In a read-only space, only what its owner and admins wrote, whoever passes it on.
            if (j is Map && j['f'] is String && _posts(j['f'] as String)) ?HangoutMessage.fromJson(j.cast<String, dynamic>(), j['f'] as String),
        ]);
      case 'roster':
        final r = Roster.fromJson(m['r']);
        if (r != null && r.version > roster.version && r.trustedFor(channel.owner)) _take(r);
      case 'about':
        _heardAbout(m['a']);
      case 'mute':
        if (roster.can(from, Perm.muteOthers) && roster.outranks(from, '${m['who']}')) _applyMute('${m['who']}', m['on'] == true);
      case 'kick':
        if (roster.can(from, Perm.removeMembers) && roster.outranks(from, me)) {
          putOut = roster.banned.contains(me) ? 'You were banned from this space.' : 'You were removed from this space.';
          onRoster?.call(roster);
          notifyListeners();
        }
    }
  }

  @override
  void dispose() {
    unawaited(close());
    super.dispose();
  }
}

/// Someone in a hangout's chat room, as they said they are.
@immutable
class HangoutPerson {
  const HangoutPerson(this.id, {this.name = '', this.username, this.inVoice = false, this.guest = false, this.music = '', this.camera = false, this.screen = false, this.status = '', this.pictureHash = '', this.game, this.cosmetics = Cosmetics.none});
  final String id;
  final String name;
  final String? username;

  /// How they are now, and a mark of their picture (ProfilePictures.hashOf), as their greeting said; '' for none. The
  /// picture itself is asked of them when someone looks at their profile ([HangoutRoom.pictureOf]).
  final String status;
  final String pictureHash;

  /// What they said they are playing, when they last greeted the room; null for nothing.
  final GameActivity? game;

  /// What their profile wears, as their greeting said.
  final Cosmetics cosmetics;
  final bool inVoice;
  final bool guest;

  /// The song they play to the space's call (lib/voice/spotify.dart), in words; '' for none.
  final String music;

  /// In the space's call with their camera on, or sharing their screen there (`pv` in their greeting, GMFB-66): for the
  /// lists of who is in a call as seen from outside it. Never both: a shared screen is sent in the camera's place.
  final bool camera, screen;
  static const musicMost = 120;
}

/// One message in a hangout's chat: words, and since 2026-11-18 files, a sticker or a voice message with them (Matt,
/// 2026-11-18: "I also want full support for uploading attachements gifs stickers etc like we support in other chats").
///
/// **On the wire** `{id, x, at, n}`, and with something besides words `w` (the words), `a` (the files, each a
/// [SpaceFile]'s description less who and when, which the message says), `st` (a sticker's name, `love-03`: the
/// sticker is in every app already, so nothing goes up) and `vo` (the one file is a voice message). A build from before
/// reads only `x`, so there it is a line saying what came ([fallback]: "📎 photo.jpg", "Sticker"), the words under it.
///
/// Since 2026-11-19 `mn`, who its words mention ([Mention]: `[start, length, id]` each, counted in the words): a build
/// from before reads the "@Name" in the words as words, and so does anyone where a mention does not check out.
///
/// **The files** are sealed and kept on the relay under the space's own seed, as a Files space's are
/// (lib/files/files_store.dart, [ChatUploads]), but never written in its list: only the message knows of them.
@immutable
class HangoutMessage {
  const HangoutMessage({required this.id, required this.from, required this.name, required this.text, required this.at, this.files = const [], this.sticker, this.voice = false, this.mentions = const [], this.poll, this.note, this.edited, this.reply, this.thread});
  final String id;

  /// Who wrote it (their id on the hub, as the hub said), and the name they wrote it under.
  final String from;
  final String name;

  /// The words: all of it for a message of words, any that went with files or a sticker otherwise (often none).
  final String text;

  /// When, in milliseconds since 1970, by the writer's clock.
  final int at;

  /// Pictures, videos, GIFs and any other files with it, at most [mostFiles]; who added them is [from].
  final List<SpaceFile> files;

  /// A sticker the app carries, by its name (stickerName in lib/stickers.dart).
  final String? sticker;

  /// Its one file is a voice message, recorded in the chat.
  final bool voice;

  /// Who its words mention, by where each "@Name" is in [text]; only ones that check out against it (Mention.checked).
  final List<Mention> mentions;

  /// A poll, whose question is [text] (lib/voice/polls.dart); null for any other message.
  final PollSpec? poll;

  /// What a plugin is saying, for it to draw as a card (lib/voice/plugin_note.dart); [text] is the same in words, which
  /// is what a build without the plugin shows. Since 2026-11-19 (`pn`).
  final PluginChatNote? note;

  /// When its writer last changed its words (ms), or null where never (`ed`; Matt, 2026-11-20: "I'd like to be able to
  /// edit messages sent in circles from any computer or phone connected to the account that sent it").
  final int? edited;

  /// The message it answers, as it was when answered (`rp`; GMFB-13, @jerbo: "Please add a reply feature for messages
  /// sent in group chats so I can specifically call out an individual"): a build from before shows the words alone.
  final SpaceReply? reply;

  /// The message whose thread this is in, by its id (`th`; GMFB-36, from the Uplink gap review: threads were promised
  /// in Uplink #1434): shown in that thread's panel, not in the chat. It quotes that message too ([reply]), so a build
  /// from before shows it in the chat as a reply to it.
  final String? thread;

  /// Whether it may be edited at all: words, or files with words; not a poll, a sticker or a plugin's note.
  bool get editable => poll == null && sticker == null && note == null && !voice;

  /// Whether it mentions [id].
  bool mentionsOf(String id) => Mention.names(mentions, id);

  /// The most files one message carries, and the most words beside them (the message, its small pictures and its words
  /// twice over, in [fallback] and `w`, must go in one of the hub's packets).
  static const mostFiles = 10;
  static const mostWordsWith = 2000;

  /// A sticker's name as it travels: its pack and its number.
  static final stickerPattern = RegExp(r'^[a-z]{1,24}-[0-9a-z_]{1,24}$');

  /// Something besides words.
  bool get extras => files.isNotEmpty || sticker != null || poll != null;

  /// What came, in a line: what a build from before shows, and a preview where there are no words.
  String get what {
    if (sticker != null) return 'Sticker';
    if (poll != null) return '📊 Poll';
    if (voice) return '🎤 Voice message';
    if (files.isEmpty) return '';
    final names = [for (final f in files) f.name];
    if (names.length <= 3) return '📎 ${names.join(', ')}';
    return '📎 ${names.take(2).join(', ')} and ${names.length - 2} more';
  }

  /// `x` for a build from before attachments: what came, and the words under it.
  String get fallback => !extras ? text : (text.isEmpty ? what : '$what\n$text');

  /// The message in a line, for a list's preview: its words, or what came.
  /// Record call's line without its emoji (GMFB-43): the chat draws an icon there, and a preview is words alone.
  String get summary => !extras ? (PluginChatNote.recordingLine(text)?.words ?? text) : (text.isEmpty ? what : '$what · $text');

  /// The same message with its files, or its words, mentions and time of editing, changed.
  HangoutMessage copyWith({List<SpaceFile>? files, String? text, List<Mention>? mentions, int? edited}) => HangoutMessage(
        id: id,
        from: from,
        name: name,
        text: text ?? this.text,
        at: at,
        files: files ?? this.files,
        sticker: sticker,
        voice: voice,
        mentions: mentions ?? this.mentions,
        poll: poll,
        note: note,
        edited: edited ?? this.edited,
        reply: reply,
        thread: thread,
      );

  /// As said in the room (the class comment has the fields). Who wrote it is not in it: the hub says who sent it.
  Map<String, Object> toJson() => {
        'id': id,
        'x': fallback,
        'at': at,
        'n': name,
        if (extras) 'w': text,
        // Who added each file and when are the message's own, so they are not said again for every one.
        if (files.isNotEmpty) 'a': [for (final f in files) f.toJson()..remove('u')..remove('at')],
        'st': ?sticker,
        if (voice && files.isNotEmpty) 'vo': 1,
        if (mentions.isNotEmpty) 'mn': [for (final m in mentions) m.toJson()],
        if (poll != null) 'pl': poll!.toJson(),
        if (note != null) 'pn': note!.toJson(),
        'ed': ?edited,
        if (reply != null) 'rp': reply!.toJson(),
        'th': ?thread,
      };

  /// From what [from] said: its id, words and time; null where it is not a message. A message whose files and sticker
  /// can't be read is shown as a build from before shows it, by its `x`.
  static HangoutMessage? fromJson(Map<String, dynamic> j, String from) {
    if (j['id'] is! String || j['x'] is! String || j['at'] is! int) return null;
    final at = j['at'] as int;
    final name = j['n'] is String ? bareName(j['n'] as String) : '';
    final files = <SpaceFile>[
      if (j['a'] is List)
        for (final a in (j['a'] as List).take(mostFiles))
          if (a is Map) ?SpaceFile.fromJson({...a, 'u': name}, by: from, at: at),
    ];
    final st = j['st'];
    final sticker = st is String && stickerPattern.hasMatch(st) ? st : null;
    // A poll is its question and answers alone: no files or sticker with it.
    final poll = sticker == null && files.isEmpty ? PollSpec.fromJson(j['pl']) : null;
    final extras = files.isNotEmpty || sticker != null || poll != null;
    final raw = extras ? (j['w'] is String ? j['w'] as String : '') : j['x'] as String;
    final text = raw.trim();
    if (text.isEmpty && (!extras || poll != null)) return null;
    final most = poll != null ? PollSpec.questionMost : (extras ? mostWordsWith : 4000);
    final kept = text.length > most ? text.substring(0, most) : text;
    // Counted in the words as they came, then in the words as kept: trimmed and cut short, a mention past the cut goes.
    final lead = raw.length - raw.trimLeft().length;
    final mentions = Mention.listFromJson(j['mn'], raw).map((m) => m.moved(-lead)).toList();
    return HangoutMessage(
      id: j['id'] as String,
      from: from,
      name: name,
      text: kept,
      at: at,
      files: sticker != null ? const [] : files,
      sticker: sticker,
      voice: j['vo'] == 1 && files.length == 1 && sticker == null,
      mentions: Mention.checked(mentions, kept),
      poll: poll,
      // A plugin's note is words with a card over them: never with files, a sticker or a poll.
      note: extras ? null : PluginChatNote.fromJson(j['pn']),
      edited: j['ed'] is int ? j['ed'] as int : null,
      reply: SpaceReply.fromJson(j['rp']),
      thread: j['th'] is String && (j['th'] as String).isNotEmpty && (j['th'] as String).length <= 64 && j['th'] != j['id'] ? j['th'] as String : null,
    );
  }

  /// As kept on the device and handed over in a history: [toJson] with who wrote it (`f`).
  Map<String, Object> toStored() => {...toJson(), 'f': from};
}

/// A file on its way up for a message in a space's chat ([OutgoingMessage]): where it is here, and how far it has got.
class OutgoingFile {
  OutgoingFile({required this.path, required this.name, required this.size, required this.mime, this.owned = false});

  /// Where it is on this device; [owned]: a copy the app made (a phone's pick, a recording), let go once it is up.
  final String path;
  final bool owned;
  final String name;
  final int size;
  final String mime;

  /// From 0 to 1, as it goes up.
  double progress = 0;

  /// What it waits for (the relay, out of reach), while it waits: it goes on by itself.
  String? waiting;

  /// Why it stopped, where it did; and whether a try again could mend that.
  String? error;
  bool retryable = true;

  /// Once it is all there: what the message carries of it.
  SpaceFile? file;

  /// What [ChatUploads] keeps of it between tries.
  Object? handle;

  FileKind get kind => FileKind.of(name, mime);
}

/// A message with files, shown in the chat while they go up (Matt, 2026-11-18): sent once all of them are there, kept
/// with a try again where one fails. Only on this device, and only while the app is open.
class OutgoingMessage {
  OutgoingMessage({required this.id, required this.text, required this.files, required this.at, this.voice = false, this.mentions = const [], this.reply});
  final String id;

  /// The message it answers, where it does (GMFB-13).
  final SpaceReply? reply;
  final String text;

  /// Who [text] mentions, counted in [text].
  final List<Mention> mentions;
  final List<OutgoingFile> files;
  final int at;
  final bool voice;

  /// Why it wasn't sent, where all its files went up and the message itself was refused.
  String? error;

  /// Whether it stopped (the message refused, or any file), and whether trying again could mend it.
  bool get failed => error != null || files.any((f) => f.error != null);
  bool get retryable => error == null && files.every((f) => f.error == null || f.retryable);

  /// How far all of it has got, by size.
  double get progress {
    final total = files.fold<int>(0, (n, f) => n + f.size);
    if (total <= 0) return files.every((f) => f.file != null) ? 1 : 0;
    return files.fold<double>(0, (n, f) => n + (f.file != null ? 1 : f.progress) * f.size) / total;
  }
}

/// What sends a chat's files up, sealed, into the space's own storage on the relay (FilesStore in the app; a test's
/// own in a test).
abstract class ChatUploads {
  /// [f] up into [c]'s storage: its description once it is all there, with a small picture of no more than
  /// [thumbMost] bytes where it is a picture or a video. [moved] is told as it goes; it fails with why where it stops,
  /// and asked again for the same [f], goes on from where it got to.
  Future<SpaceFile> uploadForChat(VoiceChannel c, OutgoingFile f, {required String byName, required int thumbMost, required void Function() moved});

  /// Stops [f] and lets go of what of it is on the relay.
  void drop(OutgoingFile f);
}

/// A space's description: its words, numbered and signed by the owner or an admin, as the roster is but apart from it
/// ([HangoutRoom.about]). On the wire, in the space's chat room: `{t: about, a: {d, v, by, k, s}}`.
@immutable
class SpaceAbout {
  const SpaceAbout({required this.text, required this.version, required this.by, required this.byKey, required this.sig});

  /// Up to this many characters.
  static const most = 300;

  final String text;
  final int version;

  /// Who signed it: their id on the hub, their public key (hex), their signature (hex) over [signedBytes].
  final String by;
  final String byKey;
  final String sig;

  /// The bytes signed: domain-separated, and naming the space's chat room so an about can't be carried to another.
  static List<int> signedBytes(String room, String text, int version, String by, String byKey) =>
      utf8.encode('ghost-hangout about|${jsonEncode({'c': room, 'd': text, 'v': version, 'by': by, 'k': byKey})}');

  /// A description signed with [sign], by the holder of [publicKey] whose id is [by].
  static Future<SpaceAbout> sign(String room, String text, int version, String by, Uint8List publicKey, Future<Uint8List> Function(List<int>) sign) async {
    final key = NetCrypto.hex(publicKey);
    final s = await sign(signedBytes(room, text, version, by, key));
    return SpaceAbout(text: text, version: version, by: by, byKey: key, sig: NetCrypto.hex(s));
  }

  Map<String, Object> toJson() => {'d': text, 'v': version, 'by': by, 'k': byKey, 's': sig};

  /// From its JSON; null where a field is missing, the words are over [most], or the version is below 1. Not yet
  /// checked: see [trustedFor].
  static SpaceAbout? fromJson(Object? j) {
    if (j is! Map || j['d'] is! String || j['v'] is! int || j['by'] is! String || j['k'] is! String || j['s'] is! String) return null;
    if ((j['d'] as String).length > most || (j['v'] as int) < 1) return null;
    return SpaceAbout(text: j['d'] as String, version: j['v'] as int, by: j['by'] as String, byKey: j['k'] as String, sig: j['s'] as String);
  }

  /// Whether to believe it in the space whose chat room is [room], by [roster]: signed by the key it names, and that
  /// key the owner's or an admin's the owner made (Roster.canManage, which checks the owner's grant).
  bool trustedFor(String room, Roster roster) {
    if (!roster.hasOwner) return false;
    try {
      final k = NetCrypto.unhex(byKey);
      if (NetCrypto.idOf(k) != by) return false;
      if (!NetCrypto.verify(k, signedBytes(room, text, version, by, byKey), NetCrypto.unhex(sig))) return false;
    } catch (_) {
      return false;
    }
    return roster.canManage(by);
  }
}

/// A store that keeps a space's polls' votes too (JSON: poll's id, then voter's id, to [PollVote.toJson]).
abstract class HangoutVotesStore {
  String? votesOf(String room);
  void keepVotes(String room, String votes);
}

/// A store that keeps a space's description too ([SpaceAbout] as JSON). The app's store ([AppHangoutStore]) does it
/// under a key of its own instead, until it takes this on.
abstract class HangoutAboutStore {
  String? aboutOf(String room);
  void keepAbout(String room, String about);
}

/// Where a device keeps a hangout's chat and roster between visits.
abstract class HangoutStore {
  List<HangoutMessage> messages(String room);
  void keepMessages(String room, List<HangoutMessage> messages);
  Roster? roster(String room);
  void keepRoster(String room, Roster roster);
}

/// A store that keeps everything in memory only: what a room has where it is given none, and what tests use.
class MemoryHangoutStore implements HangoutStore, HangoutAboutStore, HangoutVotesStore {
  final Map<String, String> _votes = {};
  @override
  String? votesOf(String room) => _votes[room];
  @override
  void keepVotes(String room, String votes) => _votes[room] = votes;
  final Map<String, List<HangoutMessage>> _messages = {};
  final Map<String, Roster> _rosters = {};
  final Map<String, String> _abouts = {};
  @override
  String? aboutOf(String room) => _abouts[room];
  @override
  void keepAbout(String room, String about) => _abouts[room] = about;
  @override
  List<HangoutMessage> messages(String room) => _messages[room] ?? const [];
  @override
  void keepMessages(String room, List<HangoutMessage> messages) => _messages[room] = messages;
  @override
  Roster? roster(String room) => _rosters[room];
  @override
  void keepRoster(String room, Roster roster) => _rosters[room] = roster;
}


/// The message a space's message answers (GMFB-13), as it was when answered: its id, who wrote it and the start of its
/// words, so the quote shows even where the message itself has gone or was never loaded here.
@immutable
class SpaceReply {
  const SpaceReply({required this.id, required this.from, required this.name, required this.text});
  final String id;
  final String from;
  final String name;

  /// At most [most] characters of its words (or what it was, where it had none: "Sticker", "Photo").
  final String text;

  /// The longest the quoted words are kept; longer ones end in an ellipsis.
  static const most = 140;

  /// The quote of [m].
  factory SpaceReply.of(HangoutMessage m) {
    final words = m.summary.replaceAll(RegExp(r'\s+'), ' ').trim();
    return SpaceReply(id: m.id, from: m.from, name: m.name, text: words.length > most ? '${words.substring(0, most - 1)}…' : words);
  }

  Map<String, Object> toJson() => {'id': id, 'f': from, 'n': name, 'x': text};

  static SpaceReply? fromJson(Object? j) {
    if (j is! Map || j['id'] is! String || j['x'] is! String) return null;
    final text = (j['x'] as String).trim();
    final id = j['id'] as String;
    if (id.isEmpty || id.length > 64) return null;
    return SpaceReply(
      id: id,
      from: j['f'] is String ? j['f'] as String : '',
      name: j['n'] is String ? bareName(j['n'] as String) : '',
      text: text.length > most ? '${text.substring(0, most - 1)}…' : text,
    );
  }
}
