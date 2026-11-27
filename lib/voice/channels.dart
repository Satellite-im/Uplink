import '../circles/circles.dart' show Circles, CirclePerm;
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../app_state.dart';
import '../friends/buddies.dart';
import '../friends/groups.dart';
import '../me/me.dart';
import '../net/crypto.dart';
import '../net/hub_carrier.dart';
import '../net/net.dart';
import '../net/packet.dart';
import '../net/relay_choice.dart' show tidyRelayAddress;
import '../net/switchboard.dart';
import '../sms.dart';
import '../keys.dart';
import '../sounds.dart';
import '../circles/circles.dart';
import '../circles/sms_space.dart';
import '../desk_stamp.dart';
import 'captions.dart';
import 'friend_calls.dart';
import 'hangout.dart';
import 'mention_alerts.dart';
import 'roles.dart';
import 'leveler.dart';
import 'live_changer.dart';
import 'screen_sound.dart';
import 'soundboard.dart';
import 'spotify.dart';
import 'watch_together.dart';
import 'rtc.dart';
import 'open_space.dart';
import 'voice.dart';
import 'voice_settings.dart';

/// Someone calling a group: its channel, and who. Or, with [invite], a friend who invited this phone into a space.
@immutable
class VoiceRing {
  const VoiceRing(this.channel, this.from, this.at, {this.invite = false, this.offer = false, this.call, this.video = false, this.caller});
  final VoiceChannel channel;
  final String from;
  final DateTime at;

  /// A friend calling this device alone (lib/voice/friend_calls.dart, GMFB-28): the call's id, whether it is a video
  /// call, and the caller's install name.
  final String? call;
  final bool video;
  final String? caller;

  /// Not a call but an invite: a friend gave this phone [channel] (Voice.share), to join now or later.
  final bool invite;

  /// An invite that waited on the relay for this phone's number ([Voice.offers]): not among the spaces until Join is
  /// pressed, since anyone who knows a number can leave one.
  final bool offer;

  Map<String, Object> toJson() => {'c': channel.toJson(), 'f': from, 'at': at.millisecondsSinceEpoch};

  /// A kept offer read back ([Voice.offers]); always an invite and an offer.
  static VoiceRing? offerFromJson(Object? j) {
    if (j is! Map || j['f'] is! String || j['at'] is! int) return null;
    final c = VoiceChannel.fromJson(j['c']);
    return c == null ? null : VoiceRing(c, j['f'] as String, DateTime.fromMillisecondsSinceEpoch(j['at'] as int), invite: true, offer: true);
  }
}

/// The voice channels this device can see and the one it is in (lib/voice/voice.dart says what a channel is).
///
/// - **A group's channel** is always there for its members, open to hop in and out of.
/// - **Channels you make** have a name and are shared with friends you choose (by username, lib/friends/buddies.dart):
///   each is sent the seed, sealed, as an envelope of kind `voice` (`channel`).
/// - **Calling the group** sends each member a `voice` envelope (`ring`): their app says the group is calling, and
///   Join puts them in the channel.
///
/// Who is in each is shown without joining (the hub's `look`). On a phone the channels ride its own connection to the
/// hub; a computer, which speaks through its phone, connects with a key of its own for the voice alone.
class Voice extends ChangeNotifier {
  Voice._();
  static final Voice instance = Voice._();

  StreamSubscription<void>? _leaveCall;

  AppState? _app;

  /// The person's choices, once the app has started Voice: for what a call's plugins read.
  AppState? get app => _app;
  /// A paired computer's own connection to the hub, while it speaks under a key of its own ([separateKey]).
  HubCarrier? _ownHub;
  VoiceRoute? _route;
  final List<StreamSubscription<Object?>> _subs = [];

  /// Who is in each call room, by room, as the hub last said ([inChannel]).
  final Map<String, List<String>> _in = {};

  /// The channel this device is in, while it is.
  VoiceSession? session;
  RtcMedia? media;

  /// The call that went from this device to another of the person's, until it is brought back or put away (GMFB-50).
  late final MovedAway movedAway = MovedAway(bring: join);

  /// Someone calling a group, or a friend's invite into a space, until it is answered or put away.
  VoiceRing? ringing;

  /// Channels made here or shared by friends.
  List<VoiceChannel> own = [];

  /// The spaces of every circle this device is in (lib/circles/circles.dart sets them as its circles change): their
  /// chat rooms are held for previews and unread counts as a space of one's own is, but they are listed in their
  /// circle, not in Messages, and the phone and computer keep them in step as circles, not one by one.
  List<VoiceChannel> circled = [];

  /// Sets [circled] and looks again at what is held.
  void setCircled(List<VoiceChannel> spaces) {
    final before = circled.map((c) => '${c.seed}${c.kind.wire}${c.name}').join();
    circled = spaces;
    if (spaces.map((c) => '${c.seed}${c.kind.wire}${c.name}').join() != before) _look();
    // A space made read-only or opened again, or its circle's admins changed: its chat follows (into the room bound to
    // the owner's key, or out of it; lib/circles/welcome.dart).
    for (final c in spaces) {
      final held = _hangouts[c.seed];
      if (held != null) unawaited(held.setReadOnly(Circles.instance.readOnlyRoomFor(c)));
    }
  }

  /// What this device's spaces stand on, once the relay is connected: the circles' rooms go through it too.
  VoiceRoute? get route => _route;

  /// The seeds of channels removed on this device or its phone or computer, kept so that neither gives one back to
  /// the other (Matt, 2026-11-15: "Removing a hangout channel doesn't remove it for all devices": the computer still
  /// had it and, every few seconds, handed the phone it again). The newest [_goneKept].
  final List<String> _gone = [];
  static const _goneKept = 300;

  /// Whether the space with [seed] was removed here (or on this device's phone or computer).
  bool removed(String seed) => _gone.contains(seed);

  /// Spaces offered by invites that waited on the relay for this phone's number (lib/invites/pending_invites.dart),
  /// newest last, kept (`voice_offers`) until Join or a month. A friend's share puts a space among [own] at once, as
  /// it comes from a friend; one of these could be from anyone who knows the number, so nothing of it is joined,
  /// named or held until the person presses Join on its ring ([acceptOffer]).
  List<VoiceRing> offers = [];

  /// How long an offer waits, as the relay keeps its copy.
  static const offerLife = Duration(days: 30);

  /// Offers put off with Not now while the app has been open: raised again the next time it opens.
  final Set<String> _putOff = {};

  /// Keeps [c] as an offer from [from] and raises its ring where nothing else is ringing. True once it is held here,
  /// so the relay's copy can go: offered, or already among the spaces, or removed here.
  bool offerSpace(VoiceChannel c, String from) {
    if (own.any((o) => o.seed == c.seed) || circled.any((o) => o.seed == c.seed) || removed(c.seed)) return true;
    offers = [for (final o in offers) if (o.channel.seed != c.seed) o, VoiceRing(c, from, DateTime.now(), invite: true, offer: true)];
    _keepOffers();
    _putOff.remove(c.seed);
    _raiseOffer();
    return true;
  }

  void _keepOffers() => _app?.set('voice_offers', jsonEncode([for (final o in offers) o.toJson()]));

  /// The next offer not put off, on the ring, where nothing rings and its call is not the one this device is in.
  void _raiseOffer() {
    if (ringing != null) return;
    final next = offers.where((o) => !_putOff.contains(o.channel.seed) && session?.channel.room != o.channel.room && !own.any((c) => c.seed == o.channel.seed)).firstOrNull;
    if (next == null) return;
    ringing = next;
    notifyListeners();
  }

  /// Join on an offer's ring: the space goes among the spaces as a friend's share does, then its call is joined where
  /// it has one.
  Future<void> acceptOffer(VoiceRing r) async {
    final c = r.channel;
    offers = [for (final o in offers) if (o.channel.seed != c.seed) o];
    _keepOffers();
    if (identical(ringing, r)) ringing = null;
    // Pressed Join after it was removed: wanted again.
    _unmarkGone(c.seed);
    if (!own.any((o) => o.seed == c.seed)) {
      own = [...own, c];
      await _keep();
    }
    notifyListeners();
    // Its call is joined with it, where calls are (not in a browser yet: Sms.callsHere); its chat is there either way.
    if (c.hasVoice && Sms.callsHere) await join(c);
    _raiseOffer();
  }

  /// Notes [seed] as removed, newest last, and saves the list.
  void _markGone(String seed) {
    _gone.remove(seed);
    _gone.add(seed);
    if (_gone.length > _goneKept) _gone.removeRange(0, _gone.length - _goneKept);
    _app?.set('voice_gone', jsonEncode(_gone));
  }

  void _unmarkGone(String seed) {
    if (_gone.remove(seed)) _app?.set('voice_gone', jsonEncode(_gone));
  }

  /// The seeds of spaces archived here: out of Messages, in Archive with the archived conversations (Matt, 2026-11-17:
  /// "spaces outside of servers move to the main chat list and can be swiped to leave a space or delete / archive").
  final Set<String> _archived = {};

  bool archived(VoiceChannel c) => _archived.contains(c.seed);

  /// Archives [c] here, or brings it back to Messages.
  void archive(VoiceChannel c, bool on) {
    if (on ? !_archived.add(c.seed) : !_archived.remove(c.seed)) return;
    _app?.set('voice_archived', jsonEncode([..._archived]));
    notifyListeners();
  }

  /// How loud each person is played here, and who is silenced here, by their id: kept, and applied in every call with
  /// them (Matt, 2026-11-15: "press and hold on a user to habe options like muting changing volume levels").
  final Map<String, double> _volumes = {};
  final Set<String> _silenced = {};

  double volumeOf(String id) => _volumes[id] ?? 1.0;
  bool silenced(String id) => _silenced.contains(id);

  /// Sets how loud [id] is played here, 0 to 2 (1 as they send it): kept, and used at once in a call there is.
  void setVolume(String id, double v) {
    _volumes[id] = v.clamp(0.0, 2.0);
    media?.setPeerVolume(id, _volumes[id]!);
    _keepPeople();
  }

  /// Silences [id] for this device alone, or hears them again.
  void setSilenced(String id, bool on) {
    on ? _silenced.add(id) : _silenced.remove(id);
    media?.setPeerMuted(id, on);
    // And what the hangout's roster says on top (someone muted for everyone stays silent).
    _enforce();
    _keepPeople();
  }

  void _keepPeople() {
    _app?.set('voice_people', jsonEncode({'v': _volumes, 'm': _silenced.toList()}));
    notifyListeners();
  }

  /// When each channel (by room) last had someone in it, as this device saw: what the list sorts channels by among
  /// conversations (Matt, 2026-11-15: "a mixed view that shows them all intertwined sorted by recency").
  final Map<String, int> _seen = {};

  /// Someone is in [c] now (this device among them).
  bool live(VoiceChannel c) => inChannel(c).isNotEmpty || session?.channel.room == c.room;

  /// When [c] last had anyone in it: now while it does; null where never seen.
  DateTime? lastActive(VoiceChannel c) {
    if (live(c)) return DateTime.now();
    final at = _seen[c.room];
    return at == null ? null : DateTime.fromMillisecondsSinceEpoch(at);
  }

  /// Notes that [room] has someone in it now.
  void _saw(String room) {
    _seen[room] = DateTime.now().millisecondsSinceEpoch;
    _app?.keep('voice_seen', jsonEncode(_seen));
  }

  /// Loads what was kept in [app]'s choices (spaces, read marks, removals, offers, volumes) and begins following the
  /// relay, the groups and incoming `voice` envelopes. Only the first call loads anything.
  Future<void> start(AppState app) async {
    // The call notification's Leave (android CallService.kt).
    _leaveCall ??= Sms.instance.leaveCall.stream.listen((_) => unawaited(leave()));
    if (_app != null) return;
    _app = app;
    OpenSpaces.instance.app = app;
    try {
      own = [for (final j in jsonDecode(app.choice('voice_channels', '[]')) as List) ?VoiceChannel.fromJson(j)];
      _seen.addAll((jsonDecode(app.choice('voice_seen', '{}')) as Map).cast<String, int>());
      _readAt.addAll((jsonDecode(app.choice('voice_read', '{}')) as Map).map((k, v) => MapEntry('$k', (v as num).toInt())));
      _gone.addAll((jsonDecode(app.choice('voice_gone', '[]')) as List).whereType<String>());
      _archived.addAll((jsonDecode(app.choice('voice_archived', '[]')) as List).whereType<String>());
      final cutoff = DateTime.now().subtract(offerLife);
      offers = [for (final j in jsonDecode(app.choice('voice_offers', '[]')) as List) ?VoiceRing.offerFromJson(j)].where((o) => o.at.isAfter(cutoff) && !own.any((c) => c.seed == o.channel.seed)).toList();
      final people = jsonDecode(app.choice('voice_people', '{}')) as Map;
      _volumes.addAll(((people['v'] as Map?) ?? const {}).map((k, v) => MapEntry(k as String, (v as num).toDouble())));
      _silenced.addAll(((people['m'] as List?) ?? const []).cast<String>());
    } catch (_) {}
    // The relay its phone last said it uses, on a computer paired with one.
    if (Sms.paired) _phoneHub = hubFromPhone(app.choice(phoneHubName, ''));
    Net.instance.addListener(_follow);
    // A computer paired with a phone asks it for its spaces now and every 8 seconds.
    if (Sms.paired) {
      unawaited(syncNow());
      _sync?.cancel();
      _sync = Timer.periodic(const Duration(seconds: 8), (_) => syncNow());
    }
    Groups.instance.addListener(_look);
    Net.instance.listen(_received);
    _follow();
    _raiseOffer();
  }

  /// Every channel: each group's, then those made or shared; on a computer, the phone's too.
  List<VoiceChannel> get channels {
    final out = <VoiceChannel>[
      for (final g in Groups.instance.all)
        if (!g.gone) VoiceChannel.ofGroup(g.id, g.name),
      ..._phone,
      ...own,
      ...circled,
    ];
    final seen = <String>{};
    return [for (final c in out) if (seen.add(c.seed)) c];
  }

  // --- the phone and its computer, in step (Matt, 2026-11-15: "make sure voice chats are kept actively in sync
  // between mobile and desktop clients") ---------------------------------------------------------------------------

  /// On a computer: the phone's channels (its groups' and its own), as it last said, and its name and username, which
  /// the computer goes by in a call.
  List<VoiceChannel> _phone = [];
  String? _deskName, _deskUsername;
  Timer? _sync;

  /// On the phone: what a paired computer asks (android DartAsk "voice"): every channel, the name to go by, and a
  /// channel the computer made, to keep here too.
  Future<Object?> answerDesk(Map<String, Object?> what) async {
    switch (what['op']) {
      case 'add':
        final c = VoiceChannel.fromJson({'s': what['s'], 'n': what['n'], 'o': what['o'], 'k': what['k']});
        // One removed here is not given back by a computer that had not heard yet.
        if (c != null && removed(c.seed)) return {'ok': false, 'gone': true};
        if (c != null && !own.any((o) => o.seed == c.seed)) {
          own = [...own, c.copyWith(mine: true)];
          await _keep();
        }
        return {'ok': true};
      case 'forget':
        if (what['s'] is String) _markGone(what['s'] as String);
        if (session != null && session!.channel.seed == what['s']) await leave();
        own = [for (final o in own) if (o.seed != what['s']) o];
        await _keep();
        return {'ok': true};
      case 'circle' || 'circle-join' || 'circle-forget':
        // A circle the computer made or changed, or left (lib/circles/circles.dart).
        return Circles.instance.answerDesk(what);
      default:
        final me = Me.instance;
        // In a word where the computer has all of this already ([stampedFor]): it asks every eight seconds.
        return stampedFor(what['have'], {
          // A circle's spaces go with their circle ('circles'), not one by one.
          'channels': [
            for (final c in channels)
              if (c.circle == null) {'s': c.seed, 'n': c.name, if (c.group != null) 'g': c.group, if (c.mine) 'm': 1, if (c.owner.isNotEmpty) 'o': c.owner, if (c.kind != SpaceKind.voice) 'k': c.kind.wire},
          ],
          ...Circles.instance.forDesk(),
          // What was removed, here or from a computer, for every computer to take away too.
          'gone': _gone,
          'name': me.shownName,
          if (me.username != null) 'u': me.username,
          // The relay this phone uses, where it is not Uplink's own: its computer's own connection for spaces
          // goes to the same one (GMFB-25; [takePhoneHub]). Never one hosted from an app, which only this phone's
          // routes can dial.
          if (!Net.instance.onDefaultHub && Net.instance.hubUrl.startsWith('ws')) 'hub': Net.instance.hubUrl,
        });
    }
  }

  /// On a computer: the mark the phone gave its list last ([stampedFor]), said back so that an unchanged list comes as
  /// a word; and when the whole list was last had. Null: from a phone that gives no marks, asked in full each time.
  String? _phoneStamp;
  DateTime? _phoneFullAt;

  /// The whole list is asked for at least this often whatever the mark says: taking it in is also what hands the
  /// phone a channel made here that it never heard of, and tells it again of one removed here while it was away.
  static const deskFullEvery = Duration(minutes: 2);

  /// On a computer: asks the phone for its channels now, and every few seconds while the app is open.
  Future<void> syncNow() async {
    if (!Sms.paired) return;
    try {
      final now = DateTime.now();
      final full = _phoneStamp == null || _phoneFullAt == null || now.difference(_phoneFullAt!) >= deskFullEvery;
      final got = await Sms.instance.voiceSync({'op': 'list', if (!full) 'have': _phoneStamp});
      // Nothing has changed on the phone since the list this computer has.
      if (got['same'] == 1) return;
      _phoneStamp = got['stamp'] is String ? got['stamp'] as String : null;
      _phoneFullAt = now;
      // Removed on the phone: removed here too, and never handed back to it.
      final phoneGone = (got['gone'] as List? ?? const []).whereType<String>().toSet();
      var dropped = false;
      for (final s in phoneGone) {
        if (!removed(s)) _markGone(s);
        if (own.any((o) => o.seed == s)) {
          own = [for (final o in own) if (o.seed != s) o];
          dropped = true;
          if (session?.channel.seed == s) unawaited(leave());
        }
      }
      if (dropped) _app?.set('voice_channels', jsonEncode([for (final c in own) c.toJson()]));
      final list = <VoiceChannel>[];
      for (final j in (got['channels'] as List? ?? const [])) {
        if (j is! Map || j['s'] is! String || j['n'] is! String || (j['s'] as String).length != 64) continue;
        // Removed here while the phone was away: it is told again, and not shown meanwhile.
        if (removed(j['s'] as String)) {
          unawaited(Sms.instance.voiceSync({'op': 'forget', 's': j['s']}).catchError((_) => <String, dynamic>{}));
          continue;
        }
        final c = VoiceChannel.fromJson(j);
        if (c == null) continue;
        list.add(VoiceChannel(seed: c.seed, name: c.name, group: j['g'] as String?, mine: c.mine, owner: c.owner, kind: c.kind));
      }
      final name = got['name'] is String ? got['name'] as String : null;
      final changed = dropped || list.map((c) => '${c.seed}${c.name}${c.kind.wire}').join() != _phone.map((c) => '${c.seed}${c.name}${c.kind.wire}').join() || name != _deskName;
      _phone = list;
      _deskName = name;
      _deskUsername = got['u'] as String?;
      takePhoneHub(got['hub']);
      // Channels made here that the phone does not have yet go to it.
      for (final c in own) {
        if (!list.any((p) => p.seed == c.seed) && !removed(c.seed)) unawaited(Sms.instance.voiceSync(_deskAdd(c)).catchError((_) => <String, dynamic>{}));
      }
      // And the phone's circles, each kept at its newest list of spaces (lib/circles/circles.dart).
      Circles.instance.fromPhone(got);
      if (changed) _look();
    } catch (_) {
      // The phone is away or older: the computer keeps what it last heard.
    }
  }

  /// On a computer paired with a phone: the relay the phone said it uses ([hubFromPhone]), where it is not Uplink's
  /// own; null for ours. Kept with the choices, so the next start dials it before the phone has answered.
  String? _phoneHub;
  static const phoneHubName = 'voice_phone_hub';

  /// The relay this computer's own connection for spaces goes to while it speaks under a key of its own
  /// ([separateKey]): the phone's, as it last said, else Uplink's.
  @visibleForTesting
  String get pairedHubUrl => _phoneHub ?? Net.defaultHub;

  /// What a phone's answer names as its relay, as a hub's address this computer can dial; null where it names none, or
  /// what it says is no such address (then Uplink's is used, as it always was).
  static String? hubFromPhone(Object? said) {
    if (said is! String || said.length > 300) return null;
    final url = tidyRelayAddress(said);
    return url == null || url.isEmpty || url == Net.defaultHub || !url.startsWith('ws') ? null : url;
  }

  /// The phone said which relay it uses ([said], its answer's `hub`): a computer's spaces were on Uplink's
  /// relay whatever relay its phone used, so the two were in different rooms under the same names (GMFB-25). Where it
  /// is another than this computer's own connection is to, that connection is closed and one made to the phone's.
  void takePhoneHub(Object? said) {
    final url = hubFromPhone(said);
    if (url == _phoneHub) return;
    _phoneHub = url;
    _app?.set(phoneHubName, url ?? '');
    final had = _ownHub;
    if (had == null || had.url == pairedHubUrl) return;
    _ownHub = null;
    unawaited(had.stop());
    _follow();
  }

  /// What the phone is told of a space made on a computer.
  static Map<String, Object?> _deskAdd(VoiceChannel c) => {'op': 'add', 's': c.seed, 'n': c.name, if (c.owner.isNotEmpty) 'o': c.owner, if (c.kind != SpaceKind.voice) 'k': c.kind.wire};

  /// Who is in [channel] now, as the hub says.
  List<String> inChannel(VoiceChannel channel) => _in[channel.room] ?? const [];

  /// The id this device is in channels as.
  String? get me => _route?.me;

  /// Whether this device's spaces and circles stand on a key of its own rather than on the identity its friends and its
  /// Uplink account know it by: only on a computer paired with a phone that has not yet taken on the phone's identity
  /// (lib/desktop/own_calls.dart), which has no other to speak as until the handover. Everywhere else, a paired
  /// computer that has taken it on or signed in to an account included, they are that identity's (Matt, 2026-11-19:
  /// "when i join a server on my other logged in machines it's joining as a new matt every time instead of reusing my
  /// existing keys and owner account, when I login on ghost i should have the same identity across all devices"):
  /// every paired computer used to be in each circle and space as someone new, under a key made for it alone
  /// (`voice_key`), and never their owner.
  static bool get separateKey => Sms.followsPhone;

  /// What this install signs with on the hub: its hangouts' rosters, and the key it owns hangouts by. The install's
  /// identity (the phone's, a computer's that took it on, an account's); a paired computer's key of its own only while
  /// it has none ([separateKey]).
  NetSigner? get signer {
    final r = _route;
    if (r is HubVoiceRoute) return r.hub.signer;
    if (separateKey && _app != null) return (_ownHub ??= _macHub()).signer;
    return Net.instance.hub?.signer;
  }

  /// The public key (hex) this install owns spaces and circles by.
  String? get ownerKey {
    final s = signer;
    return s == null ? null : NetCrypto.hex(s.publicKey);
  }

  /// A name for [id]: a friend's, a group member's, or what they said in the call.
  String nameOf(String id) {
    if (id == me) return 'You';
    final said = bareName(session?.members[id]?.name ?? '');
    if (said.isNotEmpty) return said;
    final b = Buddies.instance.byId(id);
    if (b != null) return b.shown;
    for (final g in Groups.instance.all) {
      final m = g.member(id);
      if (m != null) return bareName(m.label);
    }
    return 'Someone';
  }

  /// Takes up the hub there is now (the install's, or a paired computer's own): a route over it, and who is in each
  /// channel followed. Does nothing while the hub is the one already in use.
  void _follow() {
    final HubCarrier? hub;
    if (separateKey) {
      // Dialled only once there is a channel to see.
      if (channels.isEmpty && _ownHub == null) return;
      hub = _ownHub ??= _macHub();
      unawaited(hub.start());
    } else {
      hub = Net.instance.hub;
    }
    if (hub == null || (_route is HubVoiceRoute && identical((_route as HubVoiceRoute).hub, hub))) return;
    for (final s in _subs) {
      s.cancel();
    }
    _subs.clear();
    final route = _route = HubVoiceRoute(hub);
    _subs.add(route.looks.listen((l) {
      _in[l.room] = l.members;
      movedAway.looked(l.room, l.members);
      if (l.members.isNotEmpty) _saw(l.room);
      notifyListeners();
    }));
    _look();
  }

  /// A paired computer's key of its own for the hub while it has no identity to speak as ([separateKey]), kept with its
  /// choices (and kept after, for [carryOver]).
  HubCarrier _macHub() {
    final app = _app!;
    var scalar = app.choice('voice_key', '');
    final NetKeys keys;
    if (scalar.length == 64) {
      keys = NetKeys.fromScalar(NetCrypto.unhex(scalar));
    } else {
      keys = NetKeys.generate();
      app.set('voice_key', NetCrypto.hex(keys.scalar));
    }
    // On the relay its phone uses (GMFB-25), which is Uplink's unless the phone said another.
    return HubCarrier(url: pairedHubUrl, signer: KeysSigner(keys));
  }

  /// [carryOver] is running: a second asking meanwhile does nothing.
  bool _carrying = false;

  /// What this install was under another key is this identity's (Matt, 2026-11-19: "I should have the same identity
  /// across all devices"). Two such keys: a paired computer's own (`voice_key`, from when it spoke under a key of its own:
  /// [separateKey]), and the identity an install had before signing in to an account (`was_key`, kept beside the words by
  /// Account.finish). A circle or space made under one is owned by it, and every circle it was in lists it as someone
  /// else. So, once for each, that key makes this identity an admin of what it owns, signed as their owner, and says in
  /// every circle's room that its id is this identity's. The keys are kept for nothing else. Asked each time the circles'
  /// rooms are joined (Circles._follow).
  Future<void> carryOver() async {
    final app = _app;
    final now = signer;
    if (app == null || now == null || separateKey || _carrying) return;
    _carrying = true;
    try {
      final olds = <String>[if (Sms.paired) app.choice('voice_key', ''), (await Sms.instance.secretRead(wasKey)) ?? ''];
      // Each time the rooms are joined, not once: the hub keeps a room's notes a week at most, and someone coming in
      // later learns the old id is this identity's only from a note said again. What was given already is not again.
      for (final scalar in olds) {
        if (scalar.length != 64) continue;
        final old = KeysSigner(NetKeys.fromScalar(NetCrypto.unhex(scalar)));
        if (old.id != now.id) await _carry(old, now.id);
      }
    } catch (_) {
      // Asked again the next time the rooms are joined.
    } finally {
      _carrying = false;
    }
  }

  /// Where Account.finish keeps the identity an install had before it signed in ([carryOver]).
  static const wasKey = 'was_key';

  /// [carryOver] for one old key; true once it is done everywhere.
  Future<bool> _carry(NetSigner old, String now) async {
    // Each circle, and its members told the old id is this identity's (lib/circles/circles.dart).
    var done = await Circles.instance.carryOver(old, now);
    // And each space of its own (not a circle's) made under it: its chat held while its roster is signed and said.
    final oldKey = NetCrypto.hex(old.publicKey);
    for (final c in [...own]) {
      if (c.circle != null || c.owner != oldKey) continue;
      final room = await hold(c);
      if (room == null) {
        done = false;
        continue;
      }
      try {
        if (!await room.grantAdminAs(old, now)) done = false;
      } finally {
        await release(c);
      }
    }
    return done;
  }

  /// The channels changed: asks the hub who is in each one with a call, and holds each space's chat ([_listenAll]).
  void _look() {
    if (separateKey && _ownHub == null && channels.isNotEmpty) return _follow();
    final route = _route;
    if (route == null) return;
    // The install's own hub dialled for the channels too while there are any (a key of its own dials its own, above).
    if (!separateKey) unawaited(Net.instance.want('voice', channels.isNotEmpty));
    // Only a space with a call is looked at: a texting or Files space has no call room to ask about.
    for (final c in channels) {
      if (c.hasVoice) route.look(c.room, c.token);
    }
    _listenAll();
    notifyListeners();
  }

  // --- every space's chat, listened to while the app runs (Matt, 2026-11-17: spaces in the chats list "with a preview
  // of the last message sent in the space"; he chose staying connected over a preview of what this device last saw) ---

  /// The spaces whose chat rooms this device stays in for the list: held once each ([hold]).
  final Set<String> _listening = {};

  /// When this device last read each space's chat, by its seed (ms): what its unread count counts from.
  final Map<String, int> _readAt = {};

  /// Holds the chat of every space there is and lets go of those that are gone.
  void _listenAll() {
    if (_route == null) return;
    final want = {for (final c in channels) if (c.hangout) c.seed: c};
    for (final seed in [..._listening]) {
      if (want.containsKey(seed)) continue;
      _listening.remove(seed);
      final room = _hangouts[seed];
      if (room != null) unawaited(release(room.channel));
    }
    for (final c in want.values) {
      // A circle's space made another kind (or renamed): its room, held already, follows, so its roles and its
      // call match what it now is (HangoutRoom.updateChannel).
      final held = _hangouts[c.seed];
      if (held != null && (held.channel.kind != c.kind || held.channel.name != c.name)) held.updateChannel(c);
      if (!_listening.add(c.seed)) continue;
      // A space first listened to starts read: what was said in it before is not news.
      if (!_readAt.containsKey(c.seed)) {
        _readAt[c.seed] = lastMessage(c)?.at ?? DateTime.now().millisecondsSinceEpoch;
        _app?.keep('voice_read', jsonEncode(_readAt));
      }
      unawaited(hold(c).catchError((_) => null));
    }
  }

  /// The newest message in [c]'s chat this device has; null where none (or a group's channel, whose chat is its texts).
  HangoutMessage? lastMessage(VoiceChannel c) {
    if (!c.hangout) return null;
    final room = _hangouts[c.seed];
    if (room != null) return room.messages.lastOrNull;
    final app = _app;
    return app == null ? null : AppHangoutStore(app).messages(c.chatRoom).lastOrNull;
  }

  /// How many of [c]'s messages from others came after this device last read it.
  int unreadIn(VoiceChannel c) {
    final room = _hangouts[c.seed];
    if (room == null) return 0;
    final since = _readAt[c.seed] ?? 0;
    return room.messages.where((m) => m.at > since && m.from != room.me).length;
  }

  /// How many of [c]'s unread messages ([unreadIn]) mention this device (Matt, 2026-11-19: "Add mentions support to
  /// spaces and circles with the @user prefix"): what an "@" on its unread mark counts.
  int mentionsIn(VoiceChannel c) {
    final room = _hangouts[c.seed];
    if (room == null) return 0;
    final since = _readAt[c.seed] ?? 0;
    return room.messages.where((m) => m.at > since && m.from != room.me && room.mentionsMe(m)).length;
  }

  /// [c]'s chat is read to its newest message.
  void markRead(VoiceChannel c) {
    final at = lastMessage(c)?.at ?? DateTime.now().millisecondsSinceEpoch;
    if ((_readAt[c.seed] ?? 0) >= at) return;
    _readAt[c.seed] = at;
    _app?.keep('voice_read', jsonEncode(_readAt));
    MentionAlerts.instance?.read(c);
    notifyListeners();
  }

  /// Saves [own] and looks again at what is held.
  Future<void> _keep() async {
    _app?.set('voice_channels', jsonEncode([for (final c in own) c.toJson()]));
    _look();
  }

  /// Makes a channel of this phone's, named [name], for chat and voice, texting or files ([kind]).
  Future<VoiceChannel> make(String name, {SpaceKind kind = SpaceKind.voice}) async {
    // This install owns it: its key is in the hangout, so everyone with the link knows whose roles to believe.
    final c = VoiceChannel.make(name.trim().isEmpty ? (kind == SpaceKind.voice ? 'Voice' : kind.label) : name.trim(), owner: ownerKey ?? '', kind: kind);
    own = [...own, c];
    await _keep();
    // Made on a computer: the phone keeps it too.
    if (Sms.paired) unawaited(Sms.instance.voiceSync(_deskAdd(c)).catchError((_) => <String, dynamic>{}));
    return c;
  }

  /// Removes [c] from this device (leaving its call first) and tells a paired phone to remove it too; marked gone so
  /// neither hands it back.
  Future<void> forget(VoiceChannel c) async {
    if (session?.channel.room == c.room) await leave();
    _markGone(c.seed);
    own = [for (final o in own) if (o.seed != c.seed) o];
    _phone = [for (final o in _phone) if (o.seed != c.seed) o];
    if (Sms.paired) unawaited(Sms.instance.voiceSync({'op': 'forget', 's': c.seed}).catchError((_) => <String, dynamic>{}));
    _route?.unlook(c.room);
    await _keep();
  }

  /// Gives [c] to [friends]: they can see who is in it and hop in, and their app says who invited them (`by`, this
  /// phone's name). Gives back those it could not reach (no way to them now, or the send failed). A group's channel is
  /// its members' alone: given to no one.
  Future<List<Buddy>> share(VoiceChannel c, List<Buddy> friends) async {
    if (c.group != null) return friends;
    final by = _myName.isNotEmpty ? _myName : 'Someone';
    final missed = <Buddy>[];
    for (final f in friends) {
      final peer = Net.instance.byId(f.id);
      if (peer == null) {
        missed.add(f);
        continue;
      }
      try {
        final d = await Net.instance.send(peer, Envelope(kind: 'voice', body: {'t': 'channel', 's': c.seed, 'n': c.name, if (c.owner.isNotEmpty) 'o': c.owner, if (c.kind != SpaceKind.voice) 'k': c.kind.wire, 'by': by}));
        if (!d.sent) missed.add(f);
      } catch (_) {
        missed.add(f);
      }
    }
    return missed;
  }

  /// Rings everyone in [group]: their apps say the group is calling.
  Future<int> ring(Group group) async {
    var told = 0;
    final name = Me.instance.shownName.isEmpty ? 'Someone' : Me.instance.shownName;
    for (final m in group.others) {
      final peer = Net.instance.byId(m.id);
      if (peer == null) continue;
      final d = await Net.instance.send(peer, Envelope(kind: 'voice', body: {'t': 'ring', 'g': group.id, 'n': name}), urgent: true);
      if (d.sent) told++;
    }
    // Ringing out until someone comes in (VoiceSession: someone joining stops it), the call is left, or half a minute.
    if (told > 0) {
      Sounds.instance.loop(UiSound.ringOut);
      _ringOutEnds?.cancel();
      _ringOutEnds = Timer(_ringTime, () => Sounds.instance.stopLoop(UiSound.ringOut));
    }
    return told;
  }

  Timer? _ringOutEnds, _ringInEnds, _ringClears;

  /// How long a group's call rings, here or out.
  static const _ringTime = Duration(seconds: 30);

  /// Ringing here while [ringing] is, half a minute at most.
  void _ringIn(bool on) {
    _ringInEnds?.cancel();
    if (!on) return Sounds.instance.stopLoop(UiSound.ringIn);
    Sounds.instance.loop(UiSound.ringIn);
    _ringInEnds = Timer(_ringTime, () => Sounds.instance.stopLoop(UiSound.ringIn));
  }

  /// A `voice` envelope from someone: a space a friend shared (`channel`), or a group calling (`ring`).
  void _received(Received r) {
    if (r.envelope.kind != 'voice') return;
    final b = r.envelope.body;
    switch (b['t']) {
      case 'channel':
        // Only from a friend.
        if (Buddies.instance.byId(r.peer.id)?.state != 'yes') return;
        final c = VoiceChannel.fromJson({'s': b['s'], 'n': b['n'], 'o': b['o'], 'k': b['k']});
        if (c == null) return;
        // Said on screen, Join and Not now, unless already in its call or a group is calling (Matt, 2026-11-16:
        // invites into spaces).
        // The name this phone keeps for the friend first: the sender's own word for itself after.
        final ring = ringing;
        if (session?.channel.room != c.room && (ring == null || ring.invite || DateTime.now().difference(ring.at) >= _ringTime)) {
          ringing = VoiceRing(c, Buddies.instance.byId(r.peer.id)?.shown ?? '${b['by'] ?? nameOf(r.peer.id)}', DateTime.now(), invite: true);
          notifyListeners();
        }
        if (own.any((o) => o.seed == c.seed)) return;
        // Shared again by a friend, after it was removed: wanted again.
        _unmarkGone(c.seed);
        own = [...own, c];
        unawaited(_keep());
      case 'call' || 'cancel' || 'decline' || 'answered':
        // Calling one friend (lib/voice/friend_calls.dart, GMFB-28). Not rung where a call can't be answered: a page
        // in a browser, which has no calls yet (Sms.callsHere); the account's other devices ring as they did.
        if (!Sms.callsHere) return;
        FriendCalls.instance.received(r, mine: r.peer.id == Net.instance.id);
      case 'ring':
        if (!Sms.callsHere) return;
        final g = Groups.instance.all.where((g) => g.id == b['g'] && !g.gone).firstOrNull;
        if (g == null || g.member(r.peer.id) == null) return;
        final ring = ringing = VoiceRing(VoiceChannel.ofGroup(g.id, g.name), '${b['n'] ?? nameOf(r.peer.id)}', DateTime.now());
        // Not while already in that call.
        if (session?.channel.room != ring.channel.room) _ringIn(true);
        // Put away when unanswered for as long as it rings.
        _ringClears?.cancel();
        _ringClears = Timer(_ringTime, () {
          if (identical(ringing, ring)) dismissRing();
        });
        notifyListeners();
    }
  }

  /// A friend's call ringing here ([FriendCalls]) for [time] at most; [onUnanswered] where it rang out.
  void ringFor(VoiceRing ring, Duration time, {required void Function() onUnanswered}) {
    ringing = ring;
    if (session?.channel.room != ring.channel.room) _ringIn(true);
    _ringClears?.cancel();
    _ringClears = Timer(time, () {
      if (!identical(ringing, ring)) return;
      clearRing(ring);
      onUnanswered();
    });
    unawaited(Sms.instance.ringIncoming(ring.from, video: ring.video).catchError((_) {}));
    notifyListeners();
  }

  /// [ring] put away without an answer from here (called off, answered on another device).
  void clearRing(VoiceRing ring) {
    if (!identical(ringing, ring)) return;
    _ringClears?.cancel();
    ringing = null;
    _ringIn(false);
    unawaited(Sms.instance.ringEnded().catchError((_) {}));
    _raiseOffer();
    notifyListeners();
  }

  void dismissRing() {
    _ringClears?.cancel();
    // An offer put off is kept, and raised again when the app next opens; the next one waiting comes up now.
    final r = ringing;
    if (r != null && r.offer) _putOff.add(r.channel.seed);
    // A friend's call: Decline, and the caller is told (GMFB-28).
    if (r != null && r.call != null) {
      FriendCalls.instance.decline(r);
      unawaited(Sms.instance.ringEnded().catchError((_) {}));
    }
    ringing = null;
    _ringIn(false);
    _raiseOffer();
    notifyListeners();
  }

  // --- hangouts: chat and roles (lib/voice/hangout.dart, lib/voice/roles.dart) -----------------------------------

  /// Each space's chat and roles, by its seed, once made ([hangoutFor]).
  final Map<String, HangoutRoom> _hangouts = {};

  /// How many holders each space's chat room has ([hold], [release]): it closes when the last lets go.
  final Map<String, int> _holds = {};

  /// Says who this device is again in every space's chat it holds: its game began or ended (lib/games/game_activity.dart).
  void sayMeEverywhere() {
    for (final room in _hangouts.values) {
      room.sayMe();
    }
  }

  /// [c]'s chat and roles where they are made already; null where not (nothing is made).
  HangoutRoom? heldHangout(VoiceChannel c) => _hangouts[c.seed];

  /// [c]'s chat and roles: made on first need, kept for as long as the app runs (its messages and roster are kept
  /// with the device's choices between runs). Null for a group's channel, or before the relay is connected.
  HangoutRoom? hangoutFor(VoiceChannel c) {
    if (!c.hangout) return null;
    final have = _hangouts[c.seed];
    if (have != null) return have;
    final route = _route;
    if (route == null) return null;
    final room = HangoutRoom(
      channel: c,
      route: route,
      name: _myName,
      username: _deskName == null ? Me.instance.username : _deskUsername,
      signer: signer,
      store: _app == null ? null : AppHangoutStore(_app!),
    );
    room.onRoster = (_) => _enforce();
    // In a circle's space, whoever the circle put out is not heard (Circles.removeMember).
    room.shut = (id) => Circles.instance.putOutOf(c, id);
    // In a circle's read-only space, only its owner and admins are heard, and its room is the one bound to the owner's
    // key, where the relay holds everyone else to it too (Matt, 2026-11-20; lib/circles/welcome.dart).
    room.mayPost = (id) => Circles.instance.mayPostIn(room.channel, id);
    unawaited(room.setReadOnly(Circles.instance.readOnlyRoomFor(c)));
    // Someone mentioning this device: its notification (lib/voice/mention_alerts.dart).
    room.onFresh = (fresh) {
      MentionAlerts.instance?.heard(room, fresh, readAt: _readAt[c.seed] ?? 0, nameOf: nameOf);
      // An SMS space this phone texts for: what is written there goes out by text (lib/circles/sms_space.dart).
      SmsSpaces.instance.heard(room, fresh);
    };
    // An SMS space's phone asking members' phones for their numbers, and their answers (lib/circles/sms_space.dart).
    room.onSignal = (from, said) => SmsSpaces.instance.signal(room, from, said);
    room.addListener(() => SmsSpaces.instance.roomChanged(room));
    room.addListener(notifyListeners);
    return _hangouts[c.seed] = room;
  }

  /// The hangout open in the conversation's place (the pane) while not in its call: VoiceScreen shows it (Matt,
  /// 2026-11-15: "clicking on a voice chat should show me the chat in the normal spot and connected participants with
  /// a "join" button").
  VoiceChannel? viewing;

  void view(VoiceChannel? c) {
    viewing = c;
    notifyListeners();
  }

  /// For a picture or a test: [room] as its hangout's, with no relay.
  @visibleForTesting
  void putHangout(HangoutRoom room) => _hangouts[room.channel.seed] = room;

  @visibleForTesting
  void clearHangouts() => _hangouts.clear();

  /// For a picture or a test: who the relay says is in [room], as a look would ([members] empty clears it).
  @visibleForTesting
  void putLook(String room, List<String> members) {
    members.isEmpty ? _in.remove(room) : _in[room] = members;
    movedAway.looked(room, members);
    notifyListeners();
  }

  /// For a test: what this device has read, forgotten.
  @visibleForTesting
  void clearRead() => _readAt.clear();

  /// Opens [c]'s chat room while something shows it (its page, or the call): [release] when done.
  Future<HangoutRoom?> hold(VoiceChannel c) async {
    final room = hangoutFor(c);
    if (room == null) return null;
    _holds[c.seed] = (_holds[c.seed] ?? 0) + 1;
    room.name = _myName;
    await room.open();
    return room;
  }

  /// Lets go of one [hold] on [c]'s chat room; the room closes with the last.
  Future<void> release(VoiceChannel c) async {
    final n = (_holds[c.seed] ?? 1) - 1;
    if (n > 0) {
      _holds[c.seed] = n;
      return;
    }
    _holds.remove(c.seed);
    await _hangouts[c.seed]?.close();
  }

  String get _myName => _deskName != null ? bareName(_deskName!) : Me.instance.shownName;

  /// The name this device goes by in spaces and circles.
  String get myName => _myName;

  /// Does in the call what the hangout's roster says: who is heard (not muted for everyone, allowed to speak, not
  /// silenced here), whether this device may speak or show video, and leaving when put out.
  void _enforce() {
    final s = session, m = media;
    if (s == null || m == null) return;
    final room = s.channel.hangout ? _hangouts[s.channel.seed] : null;
    for (final id in s.members.keys) {
      m.setPeerMuted(id, _silenced.contains(id) || (room != null && !room.heard(id)));
    }
    if (room == null) return;
    if (room.putOut != null) {
      unawaited(leave());
      return;
    }
    s.locked = !room.heard(room.me);
    if (s.locked && !s.muted) s.setMuted(true);
    // Brought up to speak on a stage: the hand goes down. And the connections the stage now wants (GMFB-29).
    if (!s.locked && s.hand) s.raiseHand(false);
    s.relink();
    s.videoLocked = !room.can(Perm.video);
    if (s.videoLocked && s.video) unawaited(s.setVideo(false));
    if (s.videoLocked && s.screen) unawaited(s.setScreen(false));
  }

  /// Hops into [c], leaving any other first.
  Future<void> join(VoiceChannel c, {bool video = false}) async {
    // Not in a browser yet (Sms.callsHere): the screens there offer no way in, and this holds whatever they miss.
    if (!Sms.callsHere) throw StateError('Calls aren\'t in the browser yet.');
    final route = _route;
    if (route == null) throw StateError('The relay server isn\'t connected.');
    // A texting or Files space has no call (SpaceKind).
    if (!c.hasVoice) throw StateError('${c.name} is a ${c.kind.label.toLowerCase()} space, with no voice.');
    // In a circle, as its roles say (lib/circles: CirclePerm.voice).
    if (!Circles.instance.allows(c, CirclePerm.voice)) throw StateError('Your role in this circle can\'t talk in voice spaces.');
    if (session?.channel.room == c.room) return;
    // Pressed again while it is being come into: the one coming in is enough.
    if (joining?.room == c.room) return;
    // Said at once, before anything is waited for: leaving another call, opening the chat's room and starting the
    // microphone each take a moment (seconds on a Mac), and the press showed nothing until they were done.
    joining = c;
    notifyListeners();
    try {
      await _join(c, route, video: video);
    } finally {
      if (identical(joining, c)) {
        joining = null;
        notifyListeners();
      }
    }
  }

  /// The call being come into, from the press until it is joined or has failed ([join]): what the screens say
  /// "Connecting…" for (lib/voice/call_wait.dart).
  VoiceChannel? joining;

  Future<void> _join(VoiceChannel c, VoiceRoute route, {required bool video}) async {
    await leave();
    // In a call here again, this one or another: the note that one moved away has had its answer (GMFB-50).
    movedAway.dismiss();
    if (ringing?.channel.room == c.room) {
      // A friend's call answered here: this account's other devices stop ringing (GMFB-28).
      final r = ringing!;
      if (r.call != null) {
        FriendCalls.instance.answered(r);
        unawaited(Sms.instance.ringEnded().catchError((_) {}));
      }
      ringing = null;
      _ringIn(false);
    }
    final settings = _app == null ? const VoiceSettings() : VoiceSettings.of(_app!);
    // The relay's TURN server, as the hub handed it out with the last room joined: a call falls back on it where the
    // two devices can't reach each other directly (relay/lib/turn.dart).
    final m = media = RtcMedia(settings: settings, relay: route is HubVoiceRoute ? () => route.hub.callRelay : null);
    // Sharing the screen on the phone: the call's service takes on the media projection kind between the person
    // agreeing and the capture starting, as Android 14 asks (android CallService.kt; GMFB-27).
    m.screenService = (sharing) => Sms.instance.callStarted(c.name, video: session?.video ?? false, screen: sharing);
    for (final e in _volumes.entries) {
      m.setPeerVolume(e.key, e.value);
    }
    for (final id in _silenced) {
      m.setPeerMuted(id, true);
    }
    final name = _deskName != null ? bareName(_deskName!) : Me.instance.shownName;
    final s = session = VoiceSession(channel: c, route: route, media: m, name: name, username: _deskName == null ? Me.instance.username : _deskUsername, kbps: settings.sendKbps, stereo: settings.sendStereo);
    // Taken over by another device of this identity coming into the call (VoiceSession.join): this one leaves it, as
    // Leave does, and says so until the person answers (GMFB-50: "a "would you like to reconnect" notification could
    // be nice"). It never comes back by itself: only Bring it back here does that.
    s.onMovedAway = () async {
      if (!identical(session, s)) return;
      await leave();
      movedAway.moved(c);
    };
    // An open space's floor is followed from here, before the chat is held and the relay has answered: the floor is
    // on the screen at once, saying it is connecting, and not the normal call until the relay answers (Matt,
    // 2026-11-23: "the open space is just showing up as a normal call for me and it took a really long time to load").
    OpenSpaces.instance.follow();
    // And the call itself is on the screen at once, saying what it is waiting for, where it used to show only once
    // the chat's room had been opened (which waits for the relay server).
    notifyListeners();
    // A hangout's chat and roles while in its call: whoever is banned is not answered, and the roster is done.
    final room = await hold(c);
    // Left while its room was being opened (Leave pressed on "Connecting…"): nothing more of it is started. Leaving
    // has let go of the room already.
    if (!identical(session, s)) return;
    if (room != null) {
      if (room.putOut != null) {
        session = null;
        media = null;
        OpenSpaces.instance.follow();
        await release(c);
        throw StateError(room.putOut!);
      }
      s.refuse = (id) => room.roster.banned.contains(id) || Circles.instance.putOutOf(c, id);
      // On a stage two listeners make no connection (GMFB-29).
      s.listens = (id) => room.listens(id == s.route.me ? room.me : id);
      room.sayMe(inVoice: true);
    }
    _saw(c.room);
    s.addListener(notifyListeners);
    s.addListener(_enforce);
    // Its camera or its screen shown to the call is said in the space's room too (GMFB-66).
    s.addListener(_sayPicture);
    // A friend this device is calling came in: it stops ringing out (GMFB-28).
    if (FriendCalls.isCall(c)) s.addListener(() => s.members.isNotEmpty ? FriendCalls.instance.joined(c) : null);
    notifyListeners();
    try {
      final withVideo = video && (room == null || room.can(Perm.video));
      // On the phone the call goes on with the screen locked: its service holds the microphone and keeps the phone
      // awake until the call ends (android CallService.kt; Matt, 2026-11-15: "voice chat stops working when the phone
      // is locked").
      await Sms.instance.callStarted(c.name, video: withVideo);
      // Left meanwhile: the call's service was told it ended after it was told it began, so it has stopped.
      if (!identical(session, s)) return;
      await s.join(withVideo: withVideo);
      // Left while it was coming in: the call has undone what it had started (VoiceSession.join).
      if (!identical(session, s)) return;
      // Push to talk (lib/keys.dart): in with the microphone off, on only while its key is held.
      if (Keys.instance.pushToTalk) s.setMuted(true, quiet: true);
      _enforce();
      // The call's captions follow it: this device writes out its own voice while anyone wants them (captions.dart).
      CallCaptions.instance.follow();
      // And what the call watches together (watch_together.dart).
      WatchTogether.instance.follow();
      // And its soundboard (soundboard.dart).
      Soundboard.instance.follow();
      // And the music played to it (spotify.dart).
      SpotifyMusic.instance.follow();
      // And the sound of a screen shared in it (screen_sound.dart).
      ScreenSound.instance.follow();
      SpotifyMusic.instance.removeListener(_sayMusic); // Once, however often a call is come into.
      SpotifyMusic.instance.addListener(_sayMusic);
      _sayMusic();
      // And the auto leveler (leveler.dart).
      AutoLeveler.instance.follow();
      // And the voice changer, live, where it is on (live_changer.dart).
      unawaited(LiveChanger.instance.follow());
    } catch (e) {
      // Its own failing, not that of a call left meanwhile (and another perhaps come into since, which stays).
      if (identical(session, s)) await leave();
      rethrow;
    }
  }

  /// The settings as they stand (Settings › Voice), and a device chosen: kept, and used in the call there is.
  VoiceSettings get settings => _app == null ? const VoiceSettings() : VoiceSettings.of(_app!);

  /// Settings › Voice and video changed: what can change in a call there is changes now (RtcMedia.applyLive).
  Future<void> settingsChanged() async {
    final m = media;
    if (m is RtcMedia) await m.applyLive(settings);
  }

  // The microphone and the speaker chosen in Settings: kept with the system's name for them (to find one again whose
  // id has changed), and switched to at once in a call there is. An empty id is the system's own.
  Future<void> useInput(String deviceId, {String name = ''}) async {
    _app?.set('voice_input', deviceId);
    _app?.set('voice_input_name', deviceId.isEmpty ? '' : name);
    await media?.setInput(deviceId, name: name);
    notifyListeners();
  }

  Future<void> useOutput(String deviceId, {String name = ''}) async {
    _app?.set('voice_output', deviceId);
    _app?.set('voice_output_name', deviceId.isEmpty ? '' : name);
    await media?.setOutput(deviceId, name: name);
    notifyListeners();
  }

  /// The camera, kept and switched to as the microphone is (GMFB-68). One that will not open leaves the call as it was.
  Future<void> useCamera(String deviceId, {String name = ''}) async {
    _app?.set('voice_camera', deviceId);
    _app?.set('voice_camera_name', deviceId.isEmpty ? '' : name);
    try {
      await media?.setCamera(deviceId, name: name);
    } catch (e) {
      debugPrint('voice: camera $deviceId not opened: $e');
    }
    notifyListeners();
  }

  /// Says in the space's room what this device plays to its call as the DJ, or that it plays nothing (spotify.dart): for
  /// the circle's list of whoever is not in the call.
  void _sayMusic() {
    final s = session, m = SpotifyMusic.instance;
    if (s == null) return;
    _hangouts[s.channel.seed]?.sayMusic(m.mine ? m.state?.now?.song.shown ?? '' : '');
  }

  /// Says in the space's room that this device has its camera on in the call, or shares its screen there, as that
  /// changes: for the mark beside it in the circle's list of whoever is not in the call (GMFB-66).
  void _sayPicture() {
    final s = session;
    if (s == null) return;
    _hangouts[s.channel.seed]?.sayPicture(camera: s.video && !s.screen, screen: s.screen);
  }

  /// What [id] ('me' for this device) shows [c]'s call: their camera, or their screen (GMFB-66: "show what users are
  /// streaming and or sharing video"). As the call itself says where this device is in it; from outside it, as their
  /// greeting in the space's room says (HangoutPerson.camera), which a build from before never does.
  ({bool camera, bool screen}) pictureOf(VoiceChannel c, String id) {
    final s = session;
    if (s != null && s.channel.room == c.room) {
      if (id == 'me') return (camera: s.video && !s.screen, screen: s.screen);
      final m = s.members[id];
      return (camera: m != null && m.video && !m.screen, screen: m?.screen ?? false);
    }
    final p = _hangouts[c.seed]?.present[id];
    return (camera: p?.camera ?? false, screen: p?.screen ?? false);
  }

  /// Leaves the call this device is in, if any: ends the phone's call service, the captions and watching together,
  /// and lets go of the hangout's chat held for the call.
  Future<void> leave() async {
    final s = session;
    session = null;
    CallCaptions.instance.follow();
    WatchTogether.instance.follow();
    Soundboard.instance.follow();
    SpotifyMusic.instance.removeListener(_sayMusic);
    SpotifyMusic.instance.follow();
    ScreenSound.instance.follow();
    if (s != null) _hangouts[s.channel.seed]?.sayMusic('');
    OpenSpaces.instance.follow();
    Sounds.instance.stopLoop(UiSound.ringOut);
    media = null;
    AutoLeveler.instance.follow();
    unawaited(LiveChanger.instance.follow());
    if (s != null) unawaited(Sms.instance.callEnded());
    // A call to a friend not answered yet is called off (GMFB-28).
    if (s != null) FriendCalls.instance.left(s.channel);
    if (s == null) {
      // Nothing to leave here; a call still being closed ([_leaving]) is waited for, so that the next is not come into
      // while the last still holds the microphone.
      try {
        await _leaving;
      } catch (_) {}
      notifyListeners();
      return;
    }
    s.removeListener(notifyListeners);
    s.removeListener(_enforce);
    s.removeListener(_sayPicture);
    // Out of the call on the screen at once. Closing its connections and letting go of the microphone takes seconds
    // on a Mac (Apple's audio engine), and until that was done the call stood there as if Leave had not been pressed
    // (Matt, 2026-11-24: "on the macbook air it lagged on the call end").
    final room = _hangouts[s.channel.seed];
    room?.sayPicture(camera: false, screen: false);
    room?.sayMe(inVoice: false);
    notifyListeners();
    final before = _leaving;
    final closing = _leaving = () async {
      try {
        await before;
      } catch (_) {}
      await s.leave();
      if (room != null) await release(s.channel);
    }();
    try {
      await closing;
    } finally {
      if (identical(_leaving, closing)) _leaving = null;
    }
    notifyListeners();
  }

  /// The last call left, while it is still being closed ([leave]).
  Future<void>? _leaving;
}

/// A call this device was in until another of the person's devices came into it, and when it went (GMFB-50).
class MovedCall {
  const MovedCall(this.channel, this.at);
  final VoiceChannel channel;
  final DateTime at;
}

/// The note that a call moved from this device to another of the person's (GMFB-50, Kevin: "If you are on your pc
/// talking in a call and switch to your phone a "would you like to reconnect" notification could be nice. Maybe a
/// sticky toast notification?"). It holds the call from [moved] until the person brings it back ([bringBack]) or puts
/// the note away ([dismiss]), and lets go of it by itself when the call is over ([looked]: nobody left in its room)
/// or after [keep], when the offer is stale. The screens only draw what it holds (lib/ui/call_moved_note.dart).
class MovedAway extends ValueNotifier<MovedCall?> {
  MovedAway({required this.bring, this.keep = const Duration(minutes: 10)}) : super(null);

  /// Joins the call again from this device, which moves it back here (Voice.join).
  final Future<void> Function(VoiceChannel channel) bring;

  /// How long the note stays when nobody answers it.
  final Duration keep;
  Timer? _ends;

  /// The call in [channel] was taken over by another of this person's devices just now.
  void moved(VoiceChannel channel) {
    _ends?.cancel();
    value = MovedCall(channel, DateTime.now());
    _ends = Timer(keep, dismiss);
  }

  /// Puts the note away: it is not shown again for this move.
  void dismiss() {
    _ends?.cancel();
    _ends = null;
    value = null;
  }

  /// Who the relay says is in [room] now: with nobody left the call is over, and there is nothing to bring back.
  void looked(String room, List<String> members) {
    if (members.isEmpty && value?.channel.room == room) dismiss();
  }

  /// Bring it back here: the note goes, and this device joins the call again. Whatever stops the join is thrown.
  Future<void> bringBack() async {
    final c = value?.channel;
    if (c == null) return;
    dismiss();
    await bring(c);
  }
}

/// A hangout's chat and roster kept with the device's choices (`hangout_<room>_m`, `hangout_<room>_r`).
class AppHangoutStore implements HangoutStore, HangoutVotesStore {
  AppHangoutStore(this.app);
  final AppState app;

  @override
  String? votesOf(String room) => app.choice('hangout_${room}_v', '');

  @override
  void keepVotes(String room, String votes) => app.set('hangout_${room}_v', votes);

  @override
  List<HangoutMessage> messages(String room) {
    try {
      final list = jsonDecode(app.choice('hangout_${room}_m', '[]')) as List;
      return [for (final j in list) if (j is Map && j['f'] is String) ?HangoutMessage.fromJson(j.cast<String, dynamic>(), j['f'] as String)];
    } catch (_) {
      return const [];
    }
  }

  @override
  void keepMessages(String room, List<HangoutMessage> messages) => app.keep('hangout_${room}_m', jsonEncode([for (final m in messages) m.toStored()]));

  @override
  Roster? roster(String room) {
    try {
      return Roster.fromJson(jsonDecode(app.choice('hangout_${room}_r', '')));
    } catch (_) {
      return null;
    }
  }

  @override
  void keepRoster(String room, Roster roster) => app.set('hangout_${room}_r', jsonEncode(roster.toJson()));
}
