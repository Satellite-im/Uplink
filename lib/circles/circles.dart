/// The circles this device is in, kept, gossiped and shared (lib/circles/circle.dart says what a circle is).
///
/// - **Kept** with the device's choices (`circles`), and the seeds of circles left (`circles_gone`) so the phone and
///   its computer don't hand one back to each other.
/// - **Gossiped** in each circle's own room on the hub ([CircleRoom]): coming in, a device asks for a newer manifest
///   than its own, and whoever has one says it; a change is said to everyone there. Each device keeps the newest one
///   that checks out (signed by the owner or an admin the owner granted).
/// - **Shared** with friends (an envelope of kind `voice`, `t: circle`, as a space is: lib/voice/channels.dart) or by
///   a link (Circle.link; site/join explains it in a browser).
/// - **The phone and its computer** keep the same circles: the phone's list goes with its spaces when the computer
///   asks (Voice.syncNow), and a circle made or changed on the computer goes to the phone (`op: circle`).
///
/// A circle's spaces are handed to Voice ([Voice.setCircled]), which holds each one's chat room as it does a space of
/// one's own, for previews and unread counts; they are listed in their circle, not in Messages.
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../app_state.dart';
import '../friends/buddies.dart';
import '../me/me.dart';
import '../net/crypto.dart';
import '../net/forward_secrecy.dart' show FsStore;
import '../net/hub_carrier.dart';
import '../net/net.dart';
import '../net/packet.dart';
import '../net/switchboard.dart';
import '../sms.dart';
import '../voice/channels.dart';
import '../voice/hangout.dart' show HangoutRoom;
import '../voice/voice.dart';
import 'circle.dart';
import 'circle_keys.dart';
import 'invite_word.dart';
import 'slow_mode.dart';
import 'welcome.dart';
import '../invites/link_relay.dart';

export 'slow_mode.dart';
export 'welcome.dart';

export 'circle.dart';
export 'circle_keys.dart';

/// Someone who has come into a circle (Circles.joined): its id, and the name they gave ('' where none).
@immutable
class CircleJoin {
  const CircleJoin(this.circle, this.id, this.name);
  final Circle circle;
  final String id;
  final String name;

  /// "Maya joined Night Owls".
  String get line => '${name.isNotEmpty ? name : 'Someone new'} joined ${circle.name}';
}

/// A circle offered to this device and not yet taken up: a friend's invite (Circles.share), or a circle's link opened
/// from outside the app. It waits, with Join and Not now, until it is joined or dismissed (Matt, 2026-11-17: "Finish the
/// missing pieces that went unfinished", of Circles: until then a friend's invite joined the circle at once, unasked,
/// and was never shown).
@immutable
class CircleInvite {
  const CircleInvite(this.circle, this.from, this.at, {this.later = false, this.link = false, this.fresh = false});

  /// The circle as the invite or link gave it: a link's has only its name until it is joined.
  final Circle circle;

  /// Who invited this device, as it knows them; empty for a link.
  final String from;
  final DateTime at;

  /// Not now was pressed: kept under Invites in the Circles tab, without the card or the banner.
  final bool later;

  /// The circle (its owner above all) came from a link, which a friend's invite for the same circle doesn't override.
  final bool link;

  /// Came since the app started, and not yet answered: the banner over everything says it. Not kept.
  final bool fresh;

  String get seed => circle.seed;

  /// How many spaces the circle has, where that is known: a link says only its name until the circle is joined.
  int? get spaceCount => circle.manifest.isSigned || circle.spaces.isNotEmpty ? circle.spaces.length : null;

  CircleInvite copyWith({Circle? circle, String? from, bool? later, bool? link, bool? fresh}) =>
      CircleInvite(circle ?? this.circle, from ?? this.from, at, later: later ?? this.later, link: link ?? this.link, fresh: fresh ?? this.fresh);

  /// As kept in `circle_invites`. [fresh] is left out, so no invite is new again after a restart.
  Map<String, Object?> toJson() => {'c': circle.toJson(), 'f': from, 'at': at.millisecondsSinceEpoch, if (later) 'l': 1, if (link) 'k': 1};

  static CircleInvite? fromJson(Object? j) {
    if (j is! Map) return null;
    final c = Circle.fromJson(j['c']);
    if (c == null) return null;
    return CircleInvite(c, j['f'] is String ? j['f'] as String : '', DateTime.fromMillisecondsSinceEpoch(j['at'] is int ? j['at'] as int : 0), later: j['l'] == 1, link: j['k'] == 1);
  }
}

/// [words] trimmed and cut to 100 characters, as a circle's, a space's or a heading's name is kept: a pasted page of
/// text as a name would make the manifest too big to pass on. Null stays null.
String? capName(String? words) {
  final w = words?.trim();
  if (w == null || w.length <= 100) return w;
  return w.substring(0, 100).trim();
}

/// The app's circles: those held, the invites waiting, each circle's room, and every change made to one (the top of
/// this file says how they are kept, gossiped and shared). Listeners are told when any of it changes.
class Circles extends ChangeNotifier {
  Circles._();
  static final Circles instance = Circles._();

  /// For a test: a manager of its own, with no device choices.
  @visibleForTesting
  factory Circles.forTest({NetSigner? signer, VoiceRoute? route, AppState? app}) {
    final c = Circles._()
      ..signerOverride = signer
      .._route = route;
    if (CircleKeys.enabled) c._wireKeys(CircleKeys.fresh());
    if (app != null) {
      c._app = app;
      c._load(app);
    }
    return c;
  }

  AppState? _app;
  VoiceRoute? _route;

  /// The circles this device is in, in the order they were joined.
  List<Circle> all = [];

  /// The seeds of circles left here or on the phone or computer, the newest [_goneKept].
  final List<String> _gone = [];
  static const _goneKept = 300;

  final Map<String, CircleRoom> _rooms = {};

  /// Circles offered to this device and not yet joined, the newest first: friends' invites and links opened from
  /// outside the app, until each is joined ([acceptInvite]) or dismissed ([dismissInvite]). Kept (`circle_invites`), so
  /// Not now keeps one for later, across launches.
  List<CircleInvite> invites = [];
  static const _invitesKept = 20;

  /// The invite the banner over everything shows: the newest that came since the app started and hasn't been answered.
  CircleInvite? get invite => invites.where((i) => i.fresh && !i.later).firstOrNull;

  /// The invite waiting for [seed]'s circle, where there is one.
  CircleInvite? inviteFor(String seed) => invites.where((i) => i.seed == seed).firstOrNull;

  /// For a test: what signs manifests in place of Voice's signer.
  @visibleForTesting
  NetSigner? signerOverride;

  NetSigner? get signer => signerOverride ?? Voice.instance.signer;

  /// This device's circle keys (GMFB-26, circle_keys.dart): kept in the secret store beside the account's words. Null
  /// where that store can't be read: every circle is then sealed with its seed's keys, as before.
  CircleKeys? keys;

  /// Makes [k] this device's keys, asking in a circle's room for the key a space of it couldn't open with. (A header
  /// is judged against the circle's manifest as it is taken, CircleKeys.take, which is handed the circle.)
  CircleKeys _wireKeys(CircleKeys k) {
    k.onMissing = (seed) => unawaited(_rooms[seed]?.askKey());
    return keys = k;
  }

  bool removed(String seed) => _gone.contains(seed);

  /// Reads what was kept, listens for friends' invites and follows Voice's relay. Once: later calls do nothing.
  Future<void> start(AppState app) async {
    if (_app != null) return;
    _app = app;
    _load(app);
    try {
      // Off as a whole where CircleKeys.enabled is: circles are then sealed with their seeds' keys, as before.
      if (CircleKeys.enabled) {
        final k = CircleKeys(secrets: _CircleSecrets(), device: HubCarrier.device);
        await k.load();
        CircleKeys.app = _wireKeys(k);
      }
    } catch (_) {}
    // Who a message's writer is now, for an edit to be theirs from any of their devices (lib/voice/hangout.dart).
    HangoutRoom.sameAs = sameAs;
    Net.instance.listen(_received);
    Voice.instance.addListener(_follow);
    _changed(keep: false);
    _follow();
  }

  /// Reads the device's choices: the circles, those left, who was seen, the joins, the system notes and the invites.
  /// Each group is read on its own, so one that can't be read doesn't lose the rest.
  void _load(AppState app) {
    try {
      all = [for (final j in jsonDecode(app.choice('circles', '[]')) as List) ?Circle.fromJson(j)];
      _gone.addAll((jsonDecode(app.choice('circles_gone', '[]')) as List).whereType<String>());
      final seen = jsonDecode(app.choice('circles_seen', '{}')) as Map;
      for (final e in seen.entries) {
        _seen['${e.key}'] = {for (final p in ((e.value as Map?) ?? const {}).entries) '${p.key}': '${p.value}'};
      }
      _was.addAll((jsonDecode(app.choice('circles_was', '{}')) as Map).map((k, v) => MapEntry('$k', '$v')));
      for (final e in (jsonDecode(app.choice('circles_last_join', '{}')) as Map).entries) {
        _lastJoin['${e.key}'] = {for (final p in ((e.value as Map?) ?? const {}).entries) if (p.value is int) '${p.key}': p.value as int};
      }
    } catch (_) {}
    try {
      _joinedAt.addAll((jsonDecode(app.choice('circles_joined_at', '{}')) as Map).map((k, v) => MapEntry('$k', v is int ? v : 0)));
      for (final e in (jsonDecode(app.choice('circles_joins', '{}')) as Map).entries) {
        _joins['${e.key}'] = {for (final p in ((e.value as Map?) ?? const {}).entries) '${p.key}': p.value is int ? p.value as int : 0};
      }
      _announce.addAll((jsonDecode(app.choice('circles_announce', '[]')) as List).whereType<String>());
    } catch (_) {}
    try {
      for (final e in (jsonDecode(app.choice('circles_system', '{}')) as Map).entries) {
        _notes['${e.key}'] = [for (final j in (e.value is List ? e.value as List : const [])) ?CircleSystemNote.fromJson(j)];
      }
    } catch (_) {}
    // A circle held from before joins were said: when this device came in is taken as now, so whoever came before is
    // not told of as coming now.
    final now = DateTime.now().millisecondsSinceEpoch;
    var dated = false;
    for (final c in all) {
      if (_joinedAt.containsKey(c.seed)) continue;
      _joinedAt[c.seed] = now;
      dated = true;
    }
    if (dated) app.set('circles_joined_at', jsonEncode(_joinedAt));
    try {
      // One for a circle joined meanwhile (on the phone or computer) has been answered.
      invites = [for (final j in jsonDecode(app.choice('circle_invites', '[]')) as List) ?CircleInvite.fromJson(j)].where((i) => bySeed(i.seed) == null).toList();
    } catch (_) {}
  }

  Circle? bySeed(String seed) => all.where((c) => c.seed == seed).firstOrNull;

  /// The circle [space] is a space of, where it is one.
  Circle? circleOf(VoiceChannel space) => space.circle == null ? null : bySeed(space.circle!);

  // --- what the lists show ------------------------------------------------------------------------------------------

  /// How many messages from others in [c]'s spaces came after this device last read each.
  int unread(Circle c) => c.channels.fold(0, (n, s) => n + Voice.instance.unreadIn(s));

  /// Every space of [c] is read to its newest message (Matt, 2026-11-23: "add a \"mark as read\" to the context menu for
  /// circles").
  void markRead(Circle c) {
    for (final s in c.channels) {
      Voice.instance.markRead(s);
    }
  }

  /// How many of those mention this device (Voice.mentionsIn).
  int mentions(Circle c) => c.channels.fold(0, (n, s) => n + Voice.instance.mentionsIn(s));

  /// Who is in a call in [c] now, by id, each once.
  List<String> inVoice(Circle c) => {for (final s in c.channels) if (s.hasVoice) ...Voice.instance.inChannel(s)}.toList();

  /// Ids that were someone's before they spoke as their identity, to the id they are now: a paired computer's key of its
  /// own ([carryOver]; Matt, 2026-11-19: each computer had been "a new matt" in every circle), said in each circle's
  /// room signed by that key, so every device lists the two as one person. Kept (`circles_was`).
  final Map<String, String> _was = {};

  /// The id [id] stands for now: itself, or the identity it was carried over to ([_was]), and on from there where that
  /// one was carried over in turn.
  String sameAs(String id) {
    var at = id;
    for (var hops = 0; hops < 8; hops++) {
      final next = _was[at];
      if (next == null || next == at || next == id) break;
      at = next;
    }
    return at;
  }

  /// A 'was' heard in [seed]'s circle: taken only for an id that means something there (seen in it, its owner or an
  /// admin), so nobody can fill this device with ids of keys made for the purpose; and at most [_wasKept] in all.
  void _heardWas(String seed, String old, String now) {
    final c = bySeed(seed);
    final known = (_seen[seed]?.containsKey(old) ?? false) || (c != null && (c.manifest.ownerId == old || c.manifest.granted(old)));
    if (!known || (_was.length >= _wasKept && !_was.containsKey(old))) return;
    _takeWas(old, now);
  }

  static const _wasKept = 500;

  /// Takes [old] as [now]'s from here on: out of every circle's members seen, its rows folded into [now]'s.
  void _takeWas(String old, String now) {
    if (old.isEmpty || now.isEmpty || old == now || _was[old] == now) return;
    _was[old] = now;
    var seen = false;
    for (final people in _seen.values) {
      if (people.remove(old) != null) seen = true;
    }
    _app?.set('circles_was', jsonEncode(_was));
    if (seen) _app?.keep('circles_seen', jsonEncode(_seen));
    notifyListeners();
  }

  /// Everyone this device has seen in each circle, by circle seed, then id, with the name they gave: who was here, wrote
  /// in a space or added a file, kept so they are still among its members once they have gone (Matt, 2026-11-18: "I
  /// still don't see memebers i added in the members list on mobile even though they are posting files").
  final Map<String, Map<String, String>> _seen = {};

  /// Who has been seen in [c], by id, with their name ('' where none was given).
  Map<String, String> seenIn(Circle c) => {for (final e in (_seen[c.seed] ?? const <String, String>{}).entries) e.key: bareName(e.value)};

  /// Keeps [people] (id to name) as seen in [c]; a name is kept over none, a newer over an older. Saved only where
  /// something is new, and told no one: it is asked while the members list is drawn.
  void noteSeen(Circle c, Map<String, String> people) {
    final have = _seen.putIfAbsent(c.seed, () => {});
    var changed = false;
    for (final e in people.entries) {
      if (e.key.isEmpty) continue;
      final had = have[e.key];
      final name = bareName(e.value);
      if (had == null || (name.isNotEmpty && name != had)) {
        have[e.key] = name.isNotEmpty ? name : (had ?? '');
        changed = true;
      }
    }
    if (changed) _app?.keep('circles_seen', jsonEncode(_seen));
  }

  /// How many are in [c]'s room now, this device among them; 0 before it is joined.
  int onlineIn(Circle c) {
    final r = _rooms[c.seed];
    return r == null || !r.opened ? 0 : r.present.length + 1;
  }

  /// Who else is in [c]'s room now, by id: the circle's settings list them among its people.
  Set<String> presentIn(Circle c) {
    final r = _rooms[c.seed];
    return r == null || !r.opened ? const {} : {...r.present};
  }

  /// [c]'s voice spaces with anyone in them now.
  List<VoiceChannel> liveSpaces(Circle c) => [for (final s in c.channels) if (s.hasVoice && Voice.instance.live(s)) s];

  // --- making and changing ------------------------------------------------------------------------------------------

  /// Whether this install may change [c]: its owner, or an admin the owner granted.
  bool canEdit(Circle c) {
    final s = signer;
    return s != null && c.manifest.canSign(s.id);
  }

  /// Makes a circle named [name] in [hue] with [icon], owned by this install, with a texting space and a voice space to
  /// start with (or [spaces]).
  Future<Circle?> make({required String name, String? hue, String icon = 'users', String? picture, List<CircleSpace>? spaces}) async {
    final s = signer;
    if (s == null) return null;
    final owner = NetCrypto.hex(s.publicKey);
    final seed = NetCrypto.hex(NetCrypto.randomBytes(32));
    final first = CircleManifest(
      owner: owner,
      version: 1,
      name: capName(name)!.isEmpty ? 'Circle' : capName(name)!,
      hue: hue != null && circleHues.contains(hue) ? hue : hueOfSeed(seed),
      icon: icon,
      picture: picture != null && picture.length <= circlePictureMax ? picture : null,
      spaces: spaces ?? [CircleSpace.make('General', kind: SpaceKind.text, order: 0), CircleSpace.make('Lounge', order: 1)],
    );
    final signed = await first.signedBy(s.id, s.publicKey, s.sign);
    final c = Circle(seed: seed, owner: owner, manifest: signed, mine: true);
    all = [...all, c];
    _changed();
    _toPhone(c);
    return c;
  }

  /// Changes [c]'s name, colour, icon, picture or banner. A picture or a banner is its stand-in ([picture],
  /// [banner]), with the file that is the whole of it where it went up ([pictureFile], [bannerFile]: SpaceFile.toJson).
  /// A new one, or none, takes the old one's file out with it.
  Future<bool> edit(Circle c, {String? name, String? hue, String? icon, String? picture, Map<String, Object?>? pictureFile, bool clearPicture = false, String? banner, Map<String, Object?>? bannerFile, bool clearBanner = false}) {
    if (hue != null && !circleHues.contains(hue)) return Future.value(false);
    if (picture != null && picture.length > circlePictureMax) return Future.value(false);
    if (banner != null && banner.length > circleBannerMax) return Future.value(false);
    final n = capName(name);
    final newBanner = banner != null || clearBanner, newPicture = picture != null || clearPicture;
    return _publish(c, (m) {
      final extra = !newBanner && !newPicture
          ? null
          : ({...m.extra}
            ..removeWhere((k, _) => (newBanner && (k == 'bn' || k == 'bf')) || (newPicture && k == 'pf'))
            ..addAll({
              'bn': ?banner,
              if (banner != null && bannerFile != null) 'bf': bannerFile,
              if (picture != null && pictureFile != null && !clearPicture) 'pf': {...pictureFile, 'of': CircleManifest.pictureMark(picture)},
            }));
      return m.next(name: n == null || n.isEmpty ? null : n, hue: hue, icon: icon, picture: picture, clearPicture: clearPicture, extra: extra);
    });
  }

  /// Gives [c] the invite word [word] (lib/circles/invite_word.dart), or takes its word away where null: claimed on the
  /// relay for the circle's link first, then said in its manifest so every member's app shows it. The old word is let
  /// go. Throws an [InviteRelayError] where the relay refuses (the word is taken), and a [StateError] where this device
  /// may not change the circle.
  Future<void> setInviteWord(Circle c, String? word, {InviteWords? words}) async {
    if (!can(c, CirclePerm.circle)) throw StateError('Your role in ${c.name} can\'t change it.');
    final w = words ?? InviteWords();
    final had = c.inviteWord;
    if (word != null) await w.claim(word, c.link);
    if (had != null && had != word) {
      try {
        await w.drop(had);
      } catch (_) {
        // Someone else's claim (another admin set it), or the relay away: it is let go a year after it was last set.
      }
    }
    final ok = await _publish(c, (m) => m.next(extra: {...m.extra}..remove('iw')..addAll({if (word != null) 'iw': word})));
    if (!ok) throw StateError('The circle couldn\'t be changed.');
  }

  /// Each word of a circle this device may change claimed again for its link, so the relay keeps it (it lets a word go
  /// a year after it was last set). A word another install holds is left as it is.
  Future<void> renewInviteWords({InviteWords? words}) async {
    final w = words ?? InviteWords();
    for (final c in all) {
      final word = c.inviteWord;
      if (word == null || !can(c, CirclePerm.circle)) continue;
      try {
        await w.claim(word, c.link);
      } catch (_) {}
    }
  }

  /// Adds a space named [name] of [kind] to [c], at the end of [section] (or of the list); gives it back.
  Future<CircleSpace?> addSpace(Circle c, String name, {SpaceKind kind = SpaceKind.voice, String? section, Map<String, Object?> extra = const {}}) async {
    final words = capName(name)!;
    final heading = capName(section);
    final last = c.manifest.spaces.fold(-1, (n, s) => s.order > n ? s.order : n);
    final space = CircleSpace.make(words.isEmpty ? kind.label : words, kind: kind, order: last + 1, section: heading == null || heading.isEmpty ? null : heading, extra: extra);
    final ok = await _publish(c, (m) => m.next(spaces: [...m.spaces, space]));
    return ok ? space : null;
  }

  /// Renames, retypes or moves a space of [c] under another heading ([clearSection]: under none).
  Future<bool> updateSpace(Circle c, String seed, {String? name, SpaceKind? kind, String? section, bool clearSection = false}) {
    if (c.space(seed) == null) return Future.value(false);
    final n = capName(name);
    return _publish(c, (m) => m.next(spaces: [
          for (final s in m.spaces) s.seed == seed ? s.copyWith(name: n == null || n.isEmpty ? null : n, kind: kind, section: capName(section), clearSection: clearSection) : s,
        ]));
  }

  /// Sets [seed]'s slow mode in [c] to [seconds] (one of [slowModeChoices]; 0 turns it off): each person may write
  /// there once in that many seconds, save those who manage spaces (Matt, 2026-11-19: "add ... slow mode").
  Future<bool> setSlowMode(Circle c, String seed, int seconds) {
    final space = c.space(seed);
    if (space == null || !slowModeChoices.contains(seconds)) return Future.value(false);
    return _publish(c, (m) => m.next(spaces: [
          for (final s in m.spaces) s.seed == seed ? s.copyWith(extra: {...s.extra, 'slow': seconds == 0 ? null : seconds}) : s,
        ]));
  }

  /// How long this install waits between messages in [space]: its slow mode, where this install doesn't manage spaces
  /// there; 0 outside a circle, with slow mode off, and for those who manage spaces.
  int slowModeFor(VoiceChannel space) {
    final c = circleOf(space);
    final s = c?.space(space.seed);
    if (c == null || s == null) return 0;
    final seconds = slowModeOf(s);
    return seconds == 0 || allows(space, CirclePerm.spaces) ? 0 : seconds;
  }

  // --- welcome, read-only and system spaces (Matt, 2026-11-20; lib/circles/welcome.dart) -----------------------------

  /// Makes [seed] read-only in [c] ([on]), or open to everyone again: only the owner and admins write there. The system
  /// space stops being one when it is opened again.
  Future<bool> setReadOnly(Circle c, String seed, bool on) {
    final space = c.space(seed);
    if (space == null || !can(c, CirclePerm.spaces)) return Future.value(false);
    return _publish(c, (m) => m.next(
          spaces: [for (final s in m.spaces) s.seed == seed ? s.copyWith(extra: {...s.extra}..remove('rdo')..addAll({if (on) 'rdo': true})) : s],
          extra: !on && m.systemSpace == seed ? m.withSystemSpace(null) : null,
        ));
  }

  /// Sets [c]'s welcome: its words ([text], '' for none) and the space newcomers land in ([space], null for none).
  Future<bool> setWelcome(Circle c, {required String text, required String? space}) {
    if (!can(c, CirclePerm.circle) || (space != null && c.space(space) == null)) return Future.value(false);
    return _publish(c, (m) => m.next(extra: m.withWelcome(text: text, space: space)));
  }

  /// Makes [seed] [c]'s system space (null: none), read-only as it becomes one.
  Future<bool> setSystemSpace(Circle c, String? seed) {
    if (!can(c, CirclePerm.circle) || !can(c, CirclePerm.spaces) || (seed != null && c.space(seed) == null)) return Future.value(false);
    return _publish(c, (m) => m.next(
          spaces: seed == null ? null : [for (final s in m.spaces) s.seed == seed ? s.copyWith(extra: {...s.extra, 'rdo': true}) : s],
          extra: m.withSystemSpace(seed),
        ));
  }

  /// Whether [space] is a read-only space of its circle.
  bool isReadOnly(VoiceChannel space) {
    final s = circleOf(space)?.space(space.seed);
    return s != null && readOnlyOf(s);
  }

  /// Whether [id] may post in [space]: anyone outside a read-only space; inside one, the circle's owner and admins.
  bool mayPostIn(VoiceChannel space, String id) {
    final c = circleOf(space);
    final s = c?.space(space.seed);
    if (c == null || s == null || !readOnlyOf(s)) return true;
    return c.manifest.writesReadOnly(id) || c.manifest.writesReadOnly(sameAs(id));
  }

  /// [space]'s room on the relay where it is read-only (lib/circles/welcome.dart readOnlyRoomOf); null where it isn't.
  ReadOnlyRoom? readOnlyRoomFor(VoiceChannel space) {
    final c = circleOf(space);
    final s = c?.space(space.seed);
    return c == null || s == null ? null : readOnlyRoomOf(c.manifest, s);
  }

  /// The space newcomers to [c] land in: its welcome space, where it has one.
  VoiceChannel? landingOf(Circle c) {
    final seed = c.manifest.welcomeSpace;
    final s = seed == null ? null : c.space(seed);
    return s == null ? null : c.channelOf(s);
  }

  /// What [c]'s system space shows, oldest first: written here as it was heard (`circles_system`).
  List<CircleSystemNote> systemNotesIn(Circle c) => List.unmodifiable(_notes[c.seed] ?? const <CircleSystemNote>[]);
  final Map<String, List<CircleSystemNote>> _notes = {};
  static const _notesKept = 200;

  /// Writes [notes] in [seed]'s system space, each once, in order of time; the newest [_notesKept] are kept.
  void _note(String seed, Iterable<CircleSystemNote> notes) {
    final list = _notes.putIfAbsent(seed, () => []);
    var added = false;
    for (final n in notes) {
      if (list.contains(n)) continue;
      list.add(n);
      added = true;
    }
    if (!added) return;
    list.sort((a, b) => a.at.compareTo(b.at));
    while (list.length > _notesKept) {
      list.removeAt(0);
    }
    _app?.set('circles_system', jsonEncode({for (final e in _notes.entries) e.key: [for (final n in e.value) n.toJson()]}));
  }

  /// The name [id] goes by in [c], as far as this device knows.
  String _nameIn(Circle c, String id) => seenIn(c)[id] ?? seenIn(c)[sameAs(id)] ?? '';

  /// For a test: [notes] written in [c]'s system space.
  @visibleForTesting
  void noteForTest(Circle c, List<CircleSystemNote> notes) => _note(c.seed, notes);

  /// Takes a space out of [c]'s list, with what it said of each role. Its chat stays with whoever has it; it is just no
  /// longer the circle's.
  Future<bool> removeSpace(Circle c, String seed) {
    if (c.space(seed) == null) return Future.value(false);
    return _publish(c, (m) {
      final left = [for (final s in m.spaces) if (s.seed != seed) s];
      return m.next(spaces: left, extra: m.overrides.containsKey(seed) ? m.withOverrides(m.overrides, spaces: left) : null);
    });
  }

  /// Moves a space to [index] in [c]'s list (and under [section], where given): every space is numbered again in its
  /// new order.
  Future<bool> moveSpace(Circle c, String seed, int index, {String? section, bool clearSection = false}) {
    final list = c.spaces;
    final at = list.indexWhere((s) => s.seed == seed);
    if (at < 0) return Future.value(false);
    final moving = list.removeAt(at).copyWith(section: section, clearSection: clearSection);
    list.insert(index.clamp(0, list.length), moving);
    return _publish(c, (m) => m.next(spaces: [for (final (i, s) in list.indexed) s.copyWith(order: i)]));
  }

  /// Makes [id] an admin of [c], who may then change it too; the owner's alone to do. [as] signs in place of this
  /// install's identity: a paired computer's key from before it spoke as that identity, giving what it made then to it
  /// (Voice.carryOver).
  Future<bool> grantAdmin(Circle c, String id, {bool on = true, NetSigner? as}) async {
    final s = as ?? signer;
    if (s == null || s.id != c.manifest.ownerId) return false;
    final have = bySeed(c.seed) ?? c;
    final grants = {...have.manifest.adminGrants};
    if (on) {
      grants[id] = NetCrypto.hex(await s.sign(CircleManifest.grantMessage(c.owner, id)));
    } else {
      grants.remove(id);
    }
    // A new generation of the admin list, signed by the owner alone: it outranks every manifest signed under an older
    // list, so a removed admin's manifests (however high they numbered them) lose to this one, for new joiners too.
    final gv = have.manifest.grantsVersion + 1;
    final gs = NetCrypto.hex(await s.sign(CircleManifest.grantsMessage(c.owner, gv, grants)));
    final ok = await _publish(c, (m) => m.next(adminGrants: grants, grantsVersion: gv, grantsSig: gs, restart: true), as: as);
    // An admin made not one who made the circle's newest key: a member who comes later won't take their header (it is
    // judged as it is taken), so the owner makes a new key, which everyone takes (B1).
    if (ok && !on && keys?.newest(c.seed)?.by == id) await rotateKey(bySeed(c.seed) ?? c);
    return ok;
  }

  // --- roles (Matt, 2026-11-18: "Build custom roles") -----------------------------------------------------------------
  // A role that can change the circle, its spaces or its roles gives its holder the owner's admin grant too: every
  // version of the app checks a manifest by who signed it, so whoever may change the circle must be able to sign. Only
  // the owner can give that grant, so only the owner gives such a role; the finer permissions are this version's.

  /// What this install may do in [c].
  Set<CirclePerm> myPerms(Circle c) {
    final id = signer?.id;
    return id == null ? const {} : (bySeed(c.seed) ?? c).manifest.permsOf(id);
  }

  /// Whether this install may do [p] in [c] as its roles say ([allows] asks of one space, with its overrides).
  bool can(Circle c, CirclePerm p) => myPerms(c).contains(p);

  /// Whether this install may do [p] in [space]: always outside a circle; inside one, as its roles say and then as the
  /// space says of them (CircleManifest.permsIn: its overrides, Deny, As the circle says or Allow for each role). Every
  /// place that asks (writing in a chat, joining a call, adding a file, inviting) obeys a space's overrides by this.
  bool allows(VoiceChannel space, CirclePerm p) {
    final c = circleOf(space);
    final id = signer?.id;
    return c == null || id == null || c.manifest.permsIn(id, space.seed).contains(p);
  }

  /// Whether this install may change, move, give or take away [roleId] in [c]: one under their own highest role, or any
  /// for the owner (CircleManifest.mayManageRole).
  bool mayManageRole(Circle c, String roleId) {
    final id = signer?.id;
    return id != null && (bySeed(c.seed) ?? c).manifest.mayManageRole(id, roleId);
  }

  /// Adds [role] to [c] (at the bottom of the list, over everyone), or changes the one with its id. One that can change
  /// things is the owner's alone to give; one at or above this install's own highest role isn't theirs to change.
  Future<bool> saveRole(Circle c, CircleRole role) async {
    final have = bySeed(c.seed) ?? c;
    if (!can(have, CirclePerm.roles) || role.name.trim().isEmpty || !mayManageRole(have, role.id)) return false;
    final before = have.manifest.roles.where((r) => r.id == role.id).firstOrNull;
    final isOwner = signer?.id == have.manifest.ownerId;
    if (!isOwner && role.signs && !(before?.signs ?? false)) return false;
    final roles = before == null ? [...have.manifest.roles, role] : [for (final r in have.manifest.roles) r.id == role.id ? role : r];
    if (roles.length > circleRolesMax) return false;
    final holders = [for (final e in have.manifest.roleAssignments.entries) if (e.value.contains(role.id)) e.key];
    final ok = await _publish(have, (m) => m.next(extra: m.withRoles(roles: roles)));
    if (ok) await _grantsFor(have, holders);
    return ok;
  }

  /// Takes [roleId] out of [c], and from everyone who had it.
  Future<bool> deleteRole(Circle c, String roleId) async {
    final have = bySeed(c.seed) ?? c;
    if (!can(have, CirclePerm.roles) || !mayManageRole(have, roleId)) return false;
    final holders = [for (final e in have.manifest.roleAssignments.entries) if (e.value.contains(roleId)) e.key];
    final ok = await _publish(have, (m) {
      final left = [for (final r in m.roles) if (r.id != roleId) r];
      final roles = m.withRoles(roles: left, assignments: {for (final e in m.roleAssignments.entries) e.key: [for (final id in e.value) if (id != roleId) id]});
      // What each space said of it goes with it.
      final spoke = m.overrides.values.any((per) => per.containsKey(roleId));
      return m.next(extra: spoke ? CircleManifest(owner: m.owner, name: m.name, spaces: m.spaces, extra: roles).withOverrides(m.overrides, roles: left) : roles);
    });
    if (ok) await _grantsFor(have, holders);
    return ok;
  }

  /// Gives [member] exactly [roleIds] in [c] (none takes every role away). Each role given or taken away must be under
  /// this install's own highest (the owner's: any).
  Future<bool> setRolesOf(Circle c, String member, List<String> roleIds) async {
    final have = bySeed(c.seed) ?? c;
    if (!can(have, CirclePerm.roles) || member == have.manifest.ownerId) return false;
    final isOwner = signer?.id == have.manifest.ownerId;
    final giving = [for (final r in have.manifest.roles) if (roleIds.contains(r.id)) r];
    final had = have.manifest.rolesOf(member);
    final changed = {...giving.map((r) => r.id)}.difference({...had.map((r) => r.id)}).union({...had.map((r) => r.id)}.difference({...giving.map((r) => r.id)}));
    if (changed.any((id) => !mayManageRole(have, id))) return false;
    if (!isOwner && giving.any((r) => r.signs) != had.any((r) => r.signs)) return false;
    final ok = await _publish(have, (m) => m.next(extra: m.withRoles(assignments: {...m.roleAssignments, member: [for (final r in giving) r.id]})));
    if (ok) await _grantsFor(have, [member]);
    return ok;
  }

  /// Puts [c]'s roles in the [order] given (their ids, highest first; Matt, 2026-11-18: "permission hierarchy"). Only
  /// the roles under this install's own highest may move, and only among themselves (CircleManifest.mayOrder).
  Future<bool> orderRoles(Circle c, List<String> order) {
    final have = bySeed(c.seed) ?? c;
    final id = signer?.id;
    if (id == null || !have.manifest.mayOrder(id, order)) return Future.value(false);
    final byId = {for (final r in have.manifest.roles) r.id: r};
    if (order.indexed.every((e) => have.manifest.roles[e.$1].id == e.$2)) return Future.value(true);
    return _publish(have, (m) => m.next(extra: m.withRoles(roles: [for (final rid in order) ?byId[rid]])));
  }

  /// Moves [roleId] from its place to [index] in [c]'s list (0 the highest): a drag, or Move up / Move down.
  Future<bool> moveRole(Circle c, String roleId, int index) {
    final have = bySeed(c.seed) ?? c;
    final ids = [for (final r in have.manifest.roles) r.id];
    if (!ids.remove(roleId)) return Future.value(false);
    ids.insert(index.clamp(0, ids.length), roleId);
    return orderRoles(have, ids);
  }

  /// What the space [spaceSeed] of [c] says of [perm] for [roleId] (or everyone, CircleManifest.everyoneId): Deny,
  /// As the circle says, or Allow. For whoever may manage spaces, and only for everyone or a role under their own.
  Future<bool> setOverride(Circle c, String spaceSeed, String roleId, CirclePerm perm, PermOverride state) {
    final have = bySeed(c.seed) ?? c;
    final space = have.space(spaceSeed);
    if (space == null || !can(have, CirclePerm.spaces) || !CirclePerm.inSpace(space.kind).contains(perm)) return Future.value(false);
    if (roleId != CircleManifest.everyoneId && (!have.manifest.roles.any((r) => r.id == roleId) || !mayManageRole(have, roleId))) return Future.value(false);
    if (have.manifest.overrideOf(spaceSeed, roleId).of(perm) == state) return Future.value(true);
    return _publish(have, (m) {
      final all = {for (final e in m.overrides.entries) e.key: {...e.value}};
      final per = all[spaceSeed] ??= {};
      per[roleId] = (per[roleId] ?? CircleOverride.none).withState(perm, state);
      return m.next(extra: m.withOverrides(all));
    });
  }

  /// Puts every override [spaceSeed] has for [roleId] back to As the circle says.
  Future<bool> clearOverrides(Circle c, String spaceSeed, String roleId) {
    final have = bySeed(c.seed) ?? c;
    if (have.space(spaceSeed) == null || !can(have, CirclePerm.spaces)) return Future.value(false);
    if (roleId != CircleManifest.everyoneId && !mayManageRole(have, roleId)) return Future.value(false);
    if (have.manifest.overrideOf(spaceSeed, roleId).isEmpty) return Future.value(true);
    return _publish(have, (m) {
      final all = {for (final e in m.overrides.entries) e.key: {...e.value}};
      all[spaceSeed]?.remove(roleId);
      return m.next(extra: m.withOverrides(all));
    });
  }

  /// Turns the plugin [id] on or off for everyone in [c], with [choices] for the circle: only whoever may change the
  /// circle (its owner, or an admin with Change the circle).
  Future<bool> setPlugin(Circle c, String id, {required bool on, Map<String, Object?> choices = const {}}) {
    final have = bySeed(c.seed) ?? c;
    if (!can(have, CirclePerm.circle)) return Future.value(false);
    return _publish(have, (m) => m.next(extra: m.withPlugin(id, on: on, choices: choices)));
  }

  /// What [space]'s circle says of the plugin [id]: null outside a circle, or where it has said nothing.
  bool? pluginOnIn(VoiceChannel space, String id) => circleOf(space)?.manifest.pluginOn(id);

  /// Sets what everyone in [c] may do to [perms], less any that change the circle, its spaces or its roles; for
  /// whoever may manage roles.
  Future<bool> setEveryone(Circle c, Set<CirclePerm> perms) {
    final have = bySeed(c.seed) ?? c;
    if (!can(have, CirclePerm.roles)) return Future.value(false);
    return _publish(have, (m) => m.next(extra: m.withRoles(everyone: {for (final p in perms) if (!p.signs) p})));
  }

  /// The owner's admin grant for each of [ids], whose roles just changed, as their roles now ask: given where a role can
  /// change things, taken back where none does. Someone given roles is governed by them from then on; an admin made by
  /// hand and never given a role is not among [ids], and is left as they are.
  Future<void> _grantsFor(Circle c, List<String> ids) async {
    if (signer?.id != (bySeed(c.seed) ?? c).manifest.ownerId) return;
    for (final id in ids) {
      final m = (bySeed(c.seed) ?? c).manifest;
      final mine = m.rolesOf(id);
      final needs = mine.any((r) => r.signs);
      final has = m.granted(id);
      if (needs && !has) {
        await grantAdmin(c, id);
      } else if (!needs && has) {
        await grantAdmin(c, id, on: false);
      }
    }
  }

  /// [c]'s next manifest, made by [change], signed here, taken, and said to the circle and the phone. Refused (false)
  /// where it would not fit one packet on the hub, which a reader would drop on the floor: a member's copy would never
  /// change again, and the next launch here would lose the circle.
  Future<bool> _publish(Circle c, CircleManifest Function(CircleManifest m) change, {NetSigner? as}) async {
    final s = as ?? signer;
    final have = bySeed(c.seed) ?? c;
    // Never over what only a link said of it (unsigned, before its manifest came): with the owner's key on every device
    // of theirs now, a change made there would have been signed over the circle's real spaces and roles.
    if (s == null || !have.manifest.isSigned || !have.manifest.canSign(s.id)) return false;
    var draft = change(have.manifest);
    // Numbered to the top: the owner starts the numbers again under a new admin list (CircleManifest.versionCap).
    if (draft.version >= CircleManifest.versionCap) {
      if (s.id != have.manifest.ownerId) return false;
      final gv = have.manifest.grantsVersion + 1;
      final gs = NetCrypto.hex(await s.sign(CircleManifest.grantsMessage(have.owner, gv, draft.adminGrants)));
      draft = draft.next(grantsVersion: gv, grantsSig: gs, restart: true);
    }
    final signed = await draft.signedBy(s.id, s.publicKey, s.sign);
    if (!signed.fitsAPacket) return false;
    final next = have.merged(signed);
    if (next == null) return false;
    _put(next);
    _rooms[next.seed]?.say(next.manifest);
    _toPhone(next);
    return true;
  }

  /// What [old] (a paired computer's key from before it spoke as its identity: Voice.carryOver) was in each circle is
  /// [now]'s: [now] made an admin of every circle [old] owns, signed by [old] as their owner, and [old]'s id said to be
  /// [now]'s in every circle's room ('was', signed by [old] too). Each room is waited for, since a new admin list is
  /// said there and nowhere else. True once it has been done in every circle.
  Future<bool> carryOver(NetSigner old, String now) async {
    _takeWas(old.id, now);
    final oldKey = NetCrypto.hex(old.publicKey);
    var done = true;
    for (final c in [...all]) {
      final room = _rooms[c.seed];
      if (room == null || !await room.joined.timeout(const Duration(seconds: 20), onTimeout: () => false)) {
        done = false;
        continue;
      }
      final have = bySeed(c.seed) ?? c;
      if (have.owner == oldKey && !have.manifest.canSign(now) && !await grantAdmin(have, now, as: old)) done = false;
      room.sayWas(old.publicKey, await old.sign(CircleRoom.wasMessage(c.seed, now)));
    }
    return done;
  }

  // --- joining and leaving ------------------------------------------------------------------------------------------

  /// Comes into [c]: kept, its room joined (where its manifest comes from, if this one is only what a link said), and
  /// its spaces' chats held. One already here takes [c]'s manifest only where it is newer.
  Circle join(Circle c) {
    _unmarkGone(c.seed);
    // Joined some other way (its link pasted, or on the phone or computer): its invite has been answered.
    if (invites.any((i) => i.seed == c.seed)) _setInvites([for (final i in invites) if (i.seed != c.seed) i]);
    final have = bySeed(c.seed);
    if (have != null) {
      final next = have.merged(c.manifest);
      if (next != null) _put(next);
      return bySeed(c.seed)!;
    }
    all = [...all, c];
    _setJoined(c.seed);
    _cameInto(c.seed);
    _changed();
    // A join is said as one (circle-join), so a phone that had it as left takes it back rather than leaving it again
    // on the next sync, as a plain `circle` did.
    if (Sms.paired) unawaited(Sms.instance.voiceSync({'op': 'circle-join', 'c': c.toJson()}).catchError((_) => <String, dynamic>{}));
    return c;
  }

  /// Comes into the circle a link is; null where it is not a circle's link. For a link pasted into the app (+ New ›
  /// Join a circle by link), which is asking to join; one opened from outside the app is [offerLink].
  Circle? joinLink(String link) {
    final c = Circle.fromLink(link);
    if (c == null) return null;
    // An invite from a friend may have named another owner: the link is the one to go by.
    final waiting = inviteFor(c.seed);
    return join(waiting != null && waiting.circle.owner == c.owner ? (waiting.circle.merged(c.manifest) ?? waiting.circle) : c);
  }

  /// The first circle's link in [text] (the link alone, or an invite's words with it, as circleInviteWords writes
  /// them); null where there is none.
  static String? linkIn(String? text) {
    if (text == null) return null;
    // With the relay it names, where it names one (lib/invites/link_relay.dart).
    final m = RegExp('https://gogho\\.st/join/#c\\.[0-9a-f]{64}(?:\\.[A-Za-z0-9_-]*)?(?:\\.0[23][0-9a-f]{64})?${LinkRelay.pattern}').firstMatch(text);
    return m == null || Circle.fromLink(m.group(0)!) == null ? null : m.group(0);
  }

  /// A circle's link opened from outside the app (a tap on gogho.st/join/#c.…, or the link shared to the app): the
  /// circle itself where it is held already, to open; else an invite to it, to Join or put off, as a friend's is. Null
  /// where [link] is not a circle's.
  ({Circle? held, CircleInvite? invite})? offerLink(String link) {
    final c = Circle.fromLink(link);
    if (c == null) return null;
    final held = bySeed(c.seed);
    if (held != null) return (held: held, invite: null);
    return (held: null, invite: offer(c, from: '', link: true));
  }

  /// [c], offered by [from] (a friend's name, or empty for a link): waiting among [invites] until it is joined or
  /// dismissed. One already held only takes the offer's manifest where it is newer, and gives back null.
  ///
  /// Offered again, it comes back to the top as new, Not now or not. Where a link and a friend's invite name different
  /// owners for the same circle, the link is believed: the circle's owner decides whose list of spaces is taken.
  CircleInvite? offer(Circle c, {required String from, bool link = false}) {
    if (bySeed(c.seed) != null) {
      join(c);
      return null;
    }
    final had = inviteFor(c.seed);
    var circle = c;
    var linked = link;
    if (had != null) {
      if (had.link && !link && had.circle.owner != c.owner) {
        // A friend's invite naming another owner than the link did: the link's circle stays.
        circle = had.circle;
        linked = true;
      } else if (had.circle.owner == c.owner) {
        // The same circle: the newer of the two manifests.
        circle = c.merged(had.circle.manifest) ?? had.circle.merged(c.manifest) ?? (c.manifest.isSigned || !had.circle.manifest.isSigned ? c : had.circle);
        linked = link || had.link;
      }
    }
    // A link says nobody: the friend who sent it before stays named.
    final i = CircleInvite(circle, from.isNotEmpty ? from : (had?.from ?? ''), DateTime.now(), link: linked, fresh: true);
    final rest = [for (final x in invites) if (x.seed != c.seed) x];
    _setInvites([i, ...rest.take(_invitesKept - 1)]);
    return i;
  }

  /// Leaves [c]: off this device and its phone or computer. Its link brings it back.
  Future<void> leave(Circle c) async {
    _markGone(c.seed);
    all = [for (final x in all) if (x.seed != c.seed) x];
    final room = _rooms.remove(c.seed);
    if (room != null) await room.close();
    // Its keys go with it (GMFB-26).
    unawaited(keys?.forget(c.seed));
    if (Sms.paired) unawaited(Sms.instance.voiceSync({'op': 'circle-forget', 's': c.seed}).catchError((_) => <String, dynamic>{}));
    if (invites.any((i) => i.seed == c.seed)) _setInvites([for (final i in invites) if (i.seed != c.seed) i], tell: false);
    _changed();
  }

  /// Takes an invite up ([seed]'s, or the banner's): the circle joined, even one left before, and given back to open.
  /// Null where there is no such invite.
  Circle? acceptInvite([String? seed]) {
    final i = seed == null ? invite : inviteFor(seed);
    if (i == null) return null;
    _setInvites([for (final x in invites) if (x.seed != i.seed) x], tell: false);
    return join(i.circle);
  }

  /// Not now: [seed]'s invite (or the banner's) put off, kept under Invites in the Circles tab until it is joined or
  /// dismissed.
  void laterInvite([String? seed]) {
    final i = seed == null ? invite : inviteFor(seed);
    if (i == null) return;
    _setInvites([for (final x in invites) x.seed == i.seed ? x.copyWith(later: true, fresh: false) : x]);
  }

  /// Puts [seed]'s invite (or the banner's) away for good: the circle isn't joined. A friend sending it again brings it
  /// back.
  void dismissInvite([String? seed]) {
    final i = seed == null ? invite : inviteFor(seed);
    if (i == null) return;
    _setInvites([for (final x in invites) if (x.seed != i.seed) x]);
  }

  /// [seed]'s invite seen where it waits (its banner pressed, to show the Circles tab): no banner for it any more, but
  /// it is not put off, so its card stays at the top of the tab.
  void seenInvite(String seed) {
    if (inviteFor(seed)?.fresh != true) return;
    _setInvites([for (final x in invites) x.seed == seed ? x.copyWith(fresh: false) : x]);
  }

  /// [seed]'s invite answered elsewhere: the circle joined or left on the paired phone or computer (answerDesk,
  /// fromPhone), so this device shows no card or banner for a circle it already holds or has left (Matt, 2026-11-17:
  /// "Finish the missing pieces that went unfinished"). Before, only Join here cleared it, and the other device kept the
  /// card, and the Circles tab's count, until its next launch.
  void _answered(String seed) {
    if (invites.any((i) => i.seed == seed)) _setInvites([for (final i in invites) if (i.seed != seed) i]);
  }

  /// Puts [next] in place of [invites] and keeps them; [tell] is false where the caller tells listeners itself.
  void _setInvites(List<CircleInvite> next, {bool tell = true}) {
    invites = next;
    _app?.set('circle_invites', jsonEncode([for (final i in invites) i.toJson()]));
    if (tell) notifyListeners();
  }

  /// Notes [seed] as left, newest last, so the paired phone or computer doesn't hand the circle back.
  void _markGone(String seed) {
    _gone.remove(seed);
    _gone.add(seed);
    if (_gone.length > _goneKept) _gone.removeRange(0, _gone.length - _goneKept);
    _app?.set('circles_gone', jsonEncode(_gone));
  }

  /// Takes [seed] off those left: the circle was joined again.
  void _unmarkGone(String seed) {
    if (_gone.remove(seed)) _app?.set('circles_gone', jsonEncode(_gone));
  }

  /// Puts [c] in place of the one held with its seed.
  void _put(Circle c) {
    // What changed that the system space tells of: removals, admins made and unmade.
    final was = bySeed(c.seed);
    if (was != null && was.manifest.isSigned && c.manifest.isSigned && !identical(was.manifest, c.manifest)) {
      _note(c.seed, systemNotesBetween(was.manifest, c.manifest, nameOf: (id) => _nameIn(c, id), at: DateTime.now().millisecondsSinceEpoch));
    }
    all = [for (final x in all) x.seed == c.seed ? c : x];
    _rooms[c.seed]?.circle = c;
    _changed();
    // Put out of it by its owner or an admin (banned), or kicked since this device came in: it leaves, and says so once.
    final me = signer?.id;
    final kickedAt = me == null ? null : c.manifest.kicked[me];
    if (me != null && c.manifest.isSigned && (c.manifest.removed.contains(me) || (kickedAt != null && kickedAt > joinedAt(c.seed)))) {
      removedFrom.value = c.manifest.name;
      unawaited(leave(c));
    }
  }

  /// Told by the owner or an admin that this device's identity is banned from [seed]'s circle: it leaves, and says so.
  void _bannedFrom(String seed) {
    final c = bySeed(seed);
    if (c == null) return;
    removedFrom.value = c.manifest.name;
    unawaited(leave(c));
  }

  /// For a test: [c] in place of the one held, as a newer manifest heard in its room puts it.
  @visibleForTesting
  void putForTest(Circle c) => _put(c);

  /// The name of the circle this device was last put out of, for the screens to say so; null after.
  final ValueNotifier<String?> removedFrom = ValueNotifier(null);

  /// Puts [id] out of [c] (Matt, 2026-11-19: "add the ability to remove members from a circle as an admin"), or lets
  /// them back ([back]): the owner or an admin, as [CircleManifest.mayRemove] says. An admin put out stops being one.
  Future<bool> removeMember(Circle c, String id, {bool back = false}) async {
    final s = signer;
    final have = bySeed(c.seed) ?? c;
    if (s == null || (!back && !have.manifest.mayRemove(s.id, id)) || (back && !have.manifest.canSign(s.id))) return false;
    if (!back && have.manifest.granted(id) && !await grantAdmin(have, id, on: false)) return false;
    final ok = await _publish(bySeed(c.seed) ?? have, (m) => m.next(extra: m.withRemoved(id, back: back)));
    // Banned: a new key for the circle, which they are not given (GMFB-26).
    if (ok && !back) await rotateKey(bySeed(c.seed) ?? have);
    return ok;
  }

  /// Kicks [id] out of [c] now: their app leaves it, and they may come back by an invite or the link. Who may kick is
  /// who may remove ([CircleManifest.mayRemove]); an admin kicked stops being one.
  Future<bool> kickMember(Circle c, String id) async {
    final s = signer;
    final have = bySeed(c.seed) ?? c;
    if (s == null || !have.manifest.mayRemove(s.id, id)) return false;
    if (have.manifest.granted(id) && !await grantAdmin(have, id, on: false)) return false;
    final ok = await _publish(bySeed(c.seed) ?? have, (m) => m.next(extra: m.withKicked(id, DateTime.now().millisecondsSinceEpoch)));
    // Kicked: a new key too, given to them again only once they come back openly (mayHaveKey).
    if (ok) await rotateKey(bySeed(c.seed) ?? have);
    return ok;
  }

  /// Makes [c] a new key and hands it, sealed, to every member's device whose inbox this device has heard and who may
  /// have it ([mayHaveKey]); devices not heard ask for it as they come. False where this device may not (not the owner
  /// or an admin) or has no keys.
  Future<bool> rotateKey(Circle c) async {
    final k = keys, s = signer;
    // Not made by any device yet (CircleKeys.makes): taken where a device that makes them hands one over.
    if (k == null || s == null || !CircleKeys.makes) return false;
    final room = _rooms[c.seed];
    final to = [for (final i in room?.inboxes.values ?? const <CircleInbox>[]) if (mayHaveKey(c.seed, i.id)) i];
    final said = await k.rotate(c, s, to);
    if (said == null) return false;
    for (final m in said) {
      room?.sayPlain(m, keep: true);
    }
    return true;
  }

  /// Whether [id] may be handed [seed]'s circle's key: someone the circle has seen openly (its owner, an admin, this
  /// identity's own devices, or someone seen come in or write: [noteSeen], a join heard), not banned, and not kicked
  /// since they last said they came. Someone who only slipped into the room with its token, unseen (a banned member
  /// under a new key, say), is not: to be given it they must come in as anyone does, which every member is told of.
  bool mayHaveKey(String seed, String id) {
    final c = bySeed(seed);
    if (c == null) return false;
    final m = c.manifest;
    final who = sameAs(id);
    if (m.removed.contains(id) || m.removed.contains(who)) return false;
    final seen = id == signer?.id || m.canSign(id) || m.canSign(who) || [id, who].any((x) => (_seen[seed]?.containsKey(x) ?? false) || (_joins[seed]?.containsKey(x) ?? false) || (_lastJoin[seed]?.containsKey(x) ?? false));
    if (!seen) return false;
    final kicked = m.kicked[id] ?? m.kicked[who];
    if (kicked == null) return true;
    final came = _lastJoin[seed]?[who] ?? _lastJoin[seed]?[id] ?? 0;
    return came > kicked;
  }

  /// For someone kicked who came back: when they came (ms), so they are handed only keys made after; 0 for anyone else.
  int _epochsAfter(String seed, String id) {
    final m = bySeed(seed)?.manifest;
    final who = sameAs(id);
    if (m == null || (m.kicked[id] ?? m.kicked[who]) == null) return 0;
    return _lastJoin[seed]?[who] ?? _lastJoin[seed]?[id] ?? 0;
  }

  /// When each member last said they came into each circle (ms), by seed then id (`circles_last_join`), for
  /// [mayHaveKey]: kept, so someone kicked who came back is still let have the key after a restart (finding 5).
  final Map<String, Map<String, int>> _lastJoin = {};

  /// When this device came into the circle with [seed] (ms since the epoch); 0 where it was before this was kept.
  int joinedAt(String seed) {
    if (_joinTimes.containsKey(seed)) return _joinTimes[seed]!;
    try {
      final j = jsonDecode(_app?.choice('circles_joined', '{}') ?? '{}') as Map;
      return j[seed] is int ? j[seed] as int : 0;
    } catch (_) {
      return 0;
    }
  }

  /// Join times this run, before or without the device's choices to keep them in.
  final Map<String, int> _joinTimes = {};

  /// Notes now as when this device came into [seed] (`circles_joined`): a kick counts only if it is later ([_put]).
  void _setJoined(String seed) {
    _joinTimes[seed] = DateTime.now().millisecondsSinceEpoch;
    final app = _app;
    if (app == null) return;
    Map<String, Object?> j;
    try {
      j = (jsonDecode(app.choice('circles_joined', '{}')) as Map).cast<String, Object?>();
    } catch (_) {
      j = {};
    }
    j[seed] = _joinTimes[seed];
    app.set('circles_joined', jsonEncode(j));
  }

  /// Whether [id] was put out of the circle [space] is in: not heard there (lib/voice/channels.dart).
  bool putOutOf(VoiceChannel space, String id) => circleOf(space)?.manifest.removed.contains(id) ?? false;

  /// Kept, handed to Voice, the rooms followed, and told.
  void _changed({bool keep = true}) {
    if (keep) _app?.set('circles', jsonEncode([for (final c in all) c.toJson()]));
    // The install's own hub dialled while there are circles, even one with no spaces yet: its room is how its list comes
    // (a paired computer's key of its own dials its own: Voice.separateKey).
    if (_app != null && !Voice.separateKey) unawaited(Net.instance.want('circles', all.isNotEmpty));
    Voice.instance.setCircled([for (final c in all) ...c.channels]);
    _openRooms();
    notifyListeners();
  }

  // --- sharing ------------------------------------------------------------------------------------------------------

  /// Gives [c] to [friends], with its manifest, as a space is given (Voice.share). Gives back those it could not reach.
  Future<List<Buddy>> share(Circle c, List<Buddy> friends) async {
    final me = Me.instance;
    final by = me.shownName.isEmpty ? 'Someone' : me.shownName;
    final missed = <Buddy>[];
    for (final f in friends) {
      final peer = Net.instance.byId(f.id);
      if (peer == null) {
        missed.add(f);
        continue;
      }
      try {
        final d = await Net.instance.send(peer, Envelope(kind: 'voice', body: inviteBody(c, by)));
        if (!d.sent) missed.add(f);
      } catch (_) {
        missed.add(f);
      }
    }
    return missed;
  }

  /// What an invite into [c] says: its seed, owner, name and manifest, and who sent it.
  static Map<String, Object?> inviteBody(Circle c, String by) => {'t': 'circle', 's': c.seed, 'o': c.owner, 'n': c.name, 'm': c.manifest.toJson(), 'by': by};

  /// The circle an invite's [body] gives; null where it is not one. Its manifest is taken where it checks out, else
  /// just its name until the real one comes from the circle's room.
  static Circle? fromInvite(Map<String, Object?> body) {
    if (body['t'] != 'circle' || body['s'] is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(body['s'] as String)) return null;
    final seed = body['s'] as String;
    final owner = body['o'] is String && RegExp(r'^0[23][0-9a-f]{64}$').hasMatch(body['o'] as String) ? body['o'] as String : '';
    final m = CircleManifest.fromJson(body['m']);
    final name = body['n'] is String && (body['n'] as String).trim().isNotEmpty ? (body['n'] as String).trim() : (m?.name ?? 'Circle');
    return Circle(seed: seed, owner: owner, manifest: m != null && m.trustedFor(owner) ? m : CircleManifest.placeholder(owner: owner, name: name, hue: hueOfSeed(seed)));
  }

  /// An envelope from the network: a friend's circle invite is put among [invites]; anything else is passed over.
  void _received(Received r) {
    if (r.envelope.kind != 'voice' || r.envelope.body['t'] != 'circle') return;
    // Only from a friend.
    if (Buddies.instance.byId(r.peer.id)?.state != 'yes') return;
    final c = fromInvite(r.envelope.body.cast<String, Object?>());
    if (c == null) return;
    final from = Buddies.instance.byId(r.peer.id)?.shown ?? '${r.envelope.body['by'] ?? 'A friend'}';
    // Waits, said on screen with Join and Not now, rather than joined at once: the circle's room is not entered (where
    // its members would see this device) until the person says so, and a circle left before is not brought back by a
    // friend sending it again. One already held takes the invite's manifest where it is newer.
    offer(c, from: from);
  }

  // --- the phone and its computer, in step ---------------------------------------------------------------------------

  /// On the phone: what goes to a paired computer with its spaces (Voice.answerDesk's list).
  Map<String, Object?> forDesk() => {'circles': [for (final c in all) c.toJson()], 'circles_gone': _gone};

  /// On the phone: a circle a computer made or changed ([what] `op: circle`, `c`), or left (`op: circle-forget`, `s`).
  Future<Object?> answerDesk(Map<String, Object?> what) async {
    if (what['op'] == 'circle-forget') {
      final c = what['s'] is String ? bySeed(what['s'] as String) : null;
      if (c != null) {
        await leave(c);
      } else if (what['s'] is String) {
        _markGone(what['s'] as String);
        _answered(what['s'] as String);
      }
      return {'ok': true};
    }
    final c = Circle.fromJson(what['c']);
    if (c == null) return {'ok': false};
    // Joined on the computer: a circle left before is taken back here too.
    if (what['op'] == 'circle-join') _unmarkGone(c.seed);
    if (removed(c.seed)) return {'ok': false, 'gone': true};
    final have = bySeed(c.seed);
    // Joined (or held) on the computer: its invite here is answered too, card and banner.
    _answered(c.seed);
    if (have == null) {
      all = [...all, c.copyWith(mine: true)];
      _changed();
    } else {
      final next = have.merged(c.manifest);
      if (next != null) _put(next);
    }
    return {'ok': true};
  }

  /// On a computer: the phone's circles, from its answer to Voice.syncNow. Each takes the newer manifest, the phone's or
  /// this one's; one the phone left is left here; one made here goes to the phone.
  void fromPhone(Map<String, dynamic> got) {
    if (got['circles'] is! List) return;
    var changed = false;
    for (final s in (got['circles_gone'] as List? ?? const []).whereType<String>()) {
      if (!removed(s)) {
        _markGone(s);
        changed = true;
      }
      _answered(s);
      final c = bySeed(s);
      if (c != null) {
        all = [for (final x in all) if (x.seed != s) x];
        unawaited(_rooms.remove(s)?.close());
        changed = true;
      }
    }
    final phone = <String>{};
    for (final j in got['circles'] as List) {
      final c = Circle.fromJson(j);
      if (c == null) continue;
      phone.add(c.seed);
      // The phone holds it and hasn't it as left: it is the one to go by, so a mark of leaving here (a circle left
      // here, then joined again on the phone) gives way, rather than telling the phone to leave it again.
      if (removed(c.seed)) {
        _unmarkGone(c.seed);
        changed = true;
      }
      final have = bySeed(c.seed);
      _answered(c.seed);
      if (have == null) {
        all = [...all, c];
        changed = true;
      } else {
        final next = have.merged(c.manifest);
        if (next != null) {
          all = [for (final x in all) x.seed == c.seed ? next : x];
          _rooms[c.seed]?.circle = next;
          changed = true;
        } else if (have.manifest.version > c.manifest.version) {
          _toPhone(have);
        }
      }
    }
    for (final c in all) {
      if (!phone.contains(c.seed)) _toPhone(c);
    }
    // Only when something did change: every sync (8 s) rewrote every circle and rebuilt every list that shows one.
    if (changed) _changed();
  }

  /// The circles another device of this account is in and this one is not, taken in from the account's kept copy
  /// (lib/account/account.dart takeIn; Matt, 2026-11-25: "all my devices have different sidebars"). A device learned
  /// the account's circles once, as it signed in, so one joined on another device afterwards never came here. Held as
  /// a circle the phone told a computer of is ([answerDesk]): nothing is said in it of anyone joining. One left on this
  /// device stays left, and one held here takes the newer of the two pages. How many were taken in.
  int fromAccount(List<Object?> circles) {
    var taken = 0, changed = false;
    for (final j in circles) {
      final c = Circle.fromJson(j);
      if (c == null || removed(c.seed)) continue;
      final have = bySeed(c.seed);
      if (have == null) {
        _answered(c.seed);
        all = [...all, c];
        taken++;
        changed = true;
      } else {
        final next = have.merged(c.manifest);
        if (next != null) {
          all = [for (final x in all) x.seed == c.seed ? next : x];
          _rooms[c.seed]?.circle = next;
          changed = true;
        }
      }
    }
    if (changed) _changed();
    return taken;
  }

  /// On a computer: [c] to the phone, to keep too.
  void _toPhone(Circle c) {
    if (!Sms.paired) return;
    unawaited(Sms.instance.voiceSync({'op': 'circle', 'c': c.toJson()}).catchError((_) => <String, dynamic>{}));
  }

  // --- the rooms ----------------------------------------------------------------------------------------------------

  /// The relay came or went (Voice's route): each circle's room joined on the new one.
  void _follow() {
    final route = Voice.instance.route;
    if (identical(route, _route)) return;
    _route = route;
    for (final r in _rooms.values) {
      unawaited(r.close());
    }
    _rooms.clear();
    _openRooms();
    // What a paired computer made under a key of its own, given to the identity it speaks as now.
    if (route != null) unawaited(Voice.instance.carryOver());
  }

  /// Opens a room on the relay for each circle that has none, and closes the rooms of circles no longer held.
  void _openRooms() {
    // A circle no longer here: its room left.
    for (final seed in [..._rooms.keys]) {
      if (bySeed(seed) == null) unawaited(_rooms.remove(seed)!.close());
    }
    final route = _route;
    if (route == null) return;
    for (final c in all) {
      if (_rooms.containsKey(c.seed)) continue;
      final room = _rooms[c.seed] = CircleRoom(
        circle: c,
        route: route,
        onManifest: _heard,
        onWas: (old, now) => _heardWas(c.seed, old, now),
        onJoined: (from, name, at) => _heardJoined(c.seed, from, name, at),
        keys: keys,
        signerOf: () => signer,
        mayHaveKey: (id) => mayHaveKey(c.seed, id),
        onOut: () => _bannedFrom(c.seed),
        onSplit: () => unawaited(rotateKey(bySeed(c.seed) ?? c)),
        epochsAfter: (id) => _epochsAfter(c.seed, id),
      );
      unawaited(room.open().catchError((_) {}));
      if (_announce.contains(c.seed)) unawaited(_sayJoined(room));
    }
  }

  // --- who joins ----------------------------------------------------------------------------------------------------

  /// When this device came into each circle (ms), by seed (`circles_joined_at`): only those who join after it are told
  /// of, not everyone who came before, whose joins the hub hands over with what it kept.
  final Map<String, int> _joinedAt = {};

  /// Who has been told of as joining each circle, by seed, then id, with when (`circles_joins`): each once, however
  /// often the hub hands the join over again, and whichever of their devices said it.
  final Map<String, Map<String, int>> _joins = {};
  static const _joinsKept = 400;

  /// Circles this device came into and has not yet said so in (`circles_announce`): said as soon as its room is in.
  final Set<String> _announce = {};

  /// A join is told of only this long after it was said: one kept by the hub while this device was away for longer is
  /// old news, taken in quietly.
  static const joinNews = Duration(days: 3);

  /// Someone new in one of this device's circles (Matt, 2026-11-19: "add join notifications for memebers in circles"):
  /// the notification on a phone, a toast in the app (lib/main.dart, lib/ui/shell.dart).
  final StreamController<CircleJoin> _joined = StreamController.broadcast();
  Stream<CircleJoin> get joined => _joined.stream;

  /// Who has joined [c] since this device was in it, with when (ms), newest last.
  Map<String, int> joinsIn(Circle c) => Map.unmodifiable(_joins[c.seed] ?? const <String, int>{});

  /// Notes when this device came into [seed], and that it has still to say so in the circle's room ([_sayJoined]).
  void _cameInto(String seed) {
    _joinedAt[seed] = DateTime.now().millisecondsSinceEpoch;
    _announce.add(seed);
    _app?.set('circles_joined_at', jsonEncode(_joinedAt));
    _app?.set('circles_announce', jsonEncode([..._announce]));
  }

  /// Says in [room] that this device's person has come in, kept by the hub for whoever is away; once.
  Future<void> _sayJoined(CircleRoom room) async {
    if (!await room.joined.timeout(const Duration(seconds: 30), onTimeout: () => false)) return;
    final seed = room.circle.seed;
    if (!_announce.remove(seed)) return;
    final name = Voice.instance.myName;
    room.sayJoined(name, _joinedAt[seed] ?? DateTime.now().millisecondsSinceEpoch);
    _app?.set('circles_announce', jsonEncode([..._announce]));
  }

  /// [from] said they joined [seed]'s circle as [name] at [at] (ms).
  void _heardJoined(String seed, String from, String name, int at) {
    final c = bySeed(seed);
    if (c == null) return;
    final id = sameAs(from);
    final last = _lastJoin.putIfAbsent(seed, () => {});
    if (at > (last[id] ?? 0)) {
      last[id] = at;
      // The one who came longest ago goes first (B10), not the first written.
      while (last.length > _joinsKept) {
        last.remove(last.entries.reduce((a, b) => b.value < a.value ? b : a).key);
      }
      _app?.keep('circles_last_join', jsonEncode(_lastJoin));
    }
    final mine = {Voice.instance.me, if (signer != null) signer!.id};
    if (mine.contains(from) || mine.contains(id) || c.manifest.removed.contains(id) || c.manifest.removed.contains(from)) return;
    final heard = _joins.putIfAbsent(seed, () => {});
    final clean = bareName(name);
    if (clean.isNotEmpty) noteSeen(c, {id: clean});
    if (heard.containsKey(id)) return;
    _note(seed, [CircleSystemNote(kind: SystemNoteKind.joined, id: id, name: clean, at: at)]);
    heard[id] = at;
    while (heard.length > _joinsKept) {
      heard.remove(heard.keys.first);
    }
    _app?.set('circles_joins', jsonEncode(_joins));
    final now = DateTime.now().millisecondsSinceEpoch;
    // Before this device came in, or long ago: taken in, not told of. The circle's owner never joins it.
    if (at <= (_joinedAt[seed] ?? now) || now - at > joinNews.inMilliseconds || id == c.manifest.ownerId) return;
    notifyListeners();
    _joined.add(CircleJoin(c, id, clean));
  }

  /// For a test: [from] heard joining [c] as [name] at [at].
  @visibleForTesting
  void heardJoined(Circle c, String from, String name, int at) => _heardJoined(c.seed, from, name, at);

  /// A newer manifest heard in a circle's room.
  void _heard(Circle c, CircleManifest m) {
    final have = bySeed(c.seed);
    final next = have?.merged(m);
    if (next == null) return;
    _put(next);
    _toPhone(next);
  }

  /// For a test: [c]'s room, where it is open.
  @visibleForTesting
  CircleRoom? roomOf(Circle c) => _rooms[c.seed];

  /// For a test: everything forgotten.
  @visibleForTesting
  Future<void> clear() async {
    // Forgotten at once, before the rooms close: a test that does not wait for this (or the next test's first frame)
    // must not find the last one's circles and invites still there.
    final rooms = [..._rooms.values];
    _rooms.clear();
    all = [];
    _gone.clear();
    invites = [];
    _joinedAt.clear();
    _joins.clear();
    _lastJoin.clear();
    _announce.clear();
    _notes.clear();
    Voice.instance.setCircled(const []);
    notifyListeners();
    for (final r in rooms) {
      await r.close();
    }
  }
}

/// A circle's own room on the hub, where its manifest goes round: sealed with the circle's key, so the hub carries it
/// without reading it.
///
/// - Coming in, a device says the version it has (`sync?`); each device with a newer one answers, the lowest id first
///   and the rest a moment later, unless they hear it answered meanwhile (every member hears what is said to one).
/// - A change is said to everyone (`circle`).
/// - What is heard is checked by [Circle.merged] before it is taken ([onManifest]).
/// - The circle's key (GMFB-26, circle_keys.dart): each device says its inbox (`ik`, kept by the hub), a new key goes
///   round in boxes for those inboxes (`rk`, `kb`), and a device without the newest asks for it (`k?`), answered by
///   one that has it as `sync?` is. These four are sealed with the seed's key, since they are what a device without the
///   newest key must read; everything else is sealed with the newest key held ([CircleKeys.seal]).
class CircleRoom {
  CircleRoom({required this.circle, required this.route, required this.onManifest, this.onWas, this.onJoined, this.keys, this.signerOf, this.mayHaveKey, this.onOut, this.onSplit, this.epochsAfter});

  /// For an id: only keys whose header was made after this (ms) may be handed to them (someone kicked who came back:
  /// when they came); 0 for any.
  final int Function(String id)? epochsAfter;

  /// Told that two admins changed the circle's key at once (two believed headers for its newest epoch): the owner or
  /// an admin changes it again (review finding 7).
  final void Function()? onSplit;

  /// What this device would have said and couldn't, for want of the circle's newest key: said once it comes (finding 3).
  final List<({Map<String, Object?> what, bool keep})> _waiting = [];

  /// The most kept waiting: past it the oldest goes.
  static const mostWaiting = 100;

  /// Packets heard under a key this device lacks: opened again once it comes (finding 4). The newest [mostUnread].
  final List<({String from, Uint8List bytes})> _unread = [];
  static const mostUnread = 200;

  /// Whether this device is waiting for the circle's newest key before it can say anything here.
  final ValueNotifier<bool> waitingForKey = ValueNotifier(false);

  /// When each id last asked for the key (`k?`): answered at most every ten seconds (finding 10).
  final Map<String, DateTime> _askedBy = {};

  /// The most inboxes kept for one id (finding 10).
  static const mostInboxes = 8;

  /// Told the owner or an admin said this device's identity is banned (`out`): what it is sent where it asks for the
  /// circle while banned, since the manifest that says so is sealed under a key it no longer gets.
  final void Function()? onOut;

  /// What the owner or an admin signs to tell [id] they are banned from [seed]'s circle, at [at] (ms).
  static List<int> outMessage(String seed, String id, int at) => utf8.encode('ghost-circle out v1|$seed|$id|$at');

  /// When each banned id was last told so here: at most once a minute each.
  final Map<String, DateTime> _toldOut = {};

  /// This device's circle keys; none (a test from before) seals everything with the seed's key, as before.
  final CircleKeys? keys;

  /// This device's identity, which signs its inbox: asked for each time, since it may come after the room is made.
  final NetSigner? Function()? signerOf;
  NetSigner? get signer => signerOf?.call();

  /// Whether [id] may be handed the circle's key: not banned, not kicked since they last came in.
  final bool Function(String id)? mayHaveKey;

  /// The inboxes heard in the room, by `id:device`: who a new key is sealed to.
  final Map<String, CircleInbox> inboxes = {};

  /// When this device last asked for the key, and the newest epoch it knew of then ([_askKey]).
  DateTime? _askedKey;
  int _askedFor = 0;

  /// The circle as it stands here: changed by its manager as its manifest changes.
  Circle circle;
  final VoiceRoute route;
  final void Function(Circle circle, CircleManifest manifest) onManifest;

  /// Told an id that was someone else's before they spoke as their identity, and theirs now (`was`).
  final void Function(String old, String now)? onWas;

  /// Told someone said they joined the circle: their id (stamped by the relay), the name they gave, and when (ms).
  final void Function(String from, String name, int at)? onJoined;

  final Completer<bool> _in = Completer();

  /// True once this device is in the room (what is said goes nowhere before); false if it is closed first.
  Future<bool> get joined => _in.future;

  /// Who else is in the room now, by id.
  final Set<String> present = {};
  final List<StreamSubscription<Object?>> _subs = [];

  /// Answers to a `sync?` waiting their turn to be said, by who asked.
  final Map<String, Timer> _answering = {};
  bool opened = false;

  /// Out of the room (the relay dropped it, or the join failed) until the relay says who is there again.
  bool _dropped = false;

  String get me => route.me;

  /// How long each device after the first waits before answering, so one answer usually does.
  static const step = Duration(milliseconds: 250);

  /// Joins the room on the relay and asks for a newer manifest. Where the relay can't be reached, [_event] finishes
  /// the join when it says who is there.
  Future<void> open() async {
    if (opened) return;
    opened = true;
    final k = keys;
    if (k != null) _subs.add(k.taken.where((seed) => seed == circle.seed).listen((_) => _keyCame()));
    final room = circle.room;
    _subs.add(route.packets.where((p) => p.room == room).listen((p) => _heard(p.from, p.bytes)));
    _subs.add(route.events.where((e) => e.room == room).listen(_event));
    final List<String> there;
    try {
      there = await route.join(room, circle.token);
    } catch (_) {
      // Not in yet: in as soon as the relay server answers, when [_event] hears who is here.
      _dropped = true;
      return;
    }
    present.addAll(there);
    if (!_in.isCompleted) _in.complete(true);
    _ask();
    unawaited(_keysOnComing());
  }

  /// In the room: this device's inbox said (kept, for whoever changes the key while it is away), and the newest key
  /// asked for where a newer one is known than this device holds.
  Future<void> _keysOnComing() async {
    final k = keys, s = signer;
    if (k == null || s == null || s.id != me) return;
    try {
      // Kept by the relay once a day at most (its room keeps 300 packets); live otherwise, for whoever is here.
      final keep = k.keepInboxNow(circle.seed);
      _sayPlain(await k.inboxSaid(circle.seed, s), keep: keep);
      if (keep) k.keptInbox(circle.seed);
      if (k.lacking(circle.seed)) await _askKey();
    } catch (_) {}
  }

  /// Asks for the newest key: a space of this circle heard something it couldn't open.
  Future<void> askKey() => _askKey();

  /// A key came: what waited goes, and what couldn't be read is read.
  void _keyCame() {
    final k = keys;
    if (k == null || k.lacking(circle.seed)) return;
    final said = [..._waiting];
    _waiting.clear();
    waitingForKey.value = false;
    for (final w in said) {
      _say(w.what, keep: w.keep);
    }
    final unread = [..._unread];
    _unread.clear();
    for (final u in unread) {
      _heard(u.from, u.bytes);
    }
    // Those who asked while this device was behind too, and haven't been answered since.
    // Answered as any asking is: staggered by id, dropped where someone else's answer is heard first (B10).
    final asked = [..._askedOf.values];
    _askedOf.clear();
    for (final a in asked) {
      if (!(mayHaveKey?.call(a.inbox.id) ?? !circle.manifest.removed.contains(a.inbox.id))) continue;
      final ids = [me, ...present.where((id) => id != a.inbox.id && id != me)]..sort();
      final name = 'k:${a.inbox.id}:${a.inbox.device}';
      _answering.remove(name)?.cancel();
      _answering[name] = Timer(step * ids.indexOf(me).clamp(0, 12) + Duration(milliseconds: _random.nextInt(200)), () {
        _answering.remove(name);
        for (final m in k.handOnSince(circle, a.inbox, a.since, after: a.after)) {
          _sayPlain(m);
        }
      });
    }
  }

  final _random = math.Random();

  /// Tells [from], who holds epoch [theirs] of the key, the newest header held where it is newer and they may have the
  /// key, so they know to ask. As the manifest is answered: the lowest id here first, the rest a step later unless they
  /// hear the header said meanwhile (some here may hold no key: an old build, a listener).
  void _hint(String from, int theirs) {
    final held = keys?.current(circle.seed);
    if (held == null || theirs >= held.epoch || !(mayHaveKey?.call(from) ?? !circle.manifest.removed.contains(from))) return;
    final ids = [me, ...present.where((id) => id != from && id != me)]..sort();
    _answering.remove('h:${held.epoch}')?.cancel();
    _answering['h:${held.epoch}'] = Timer(step * ids.indexOf(me).clamp(0, 12), () {
      _answering.remove('h:${held.epoch}');
      _sayPlain({'t': 'kb', 'h': held.toJson(), 'x': const []});
    });
  }

  /// Who asked for the key while this device lacked it too, by `id:device`, with the newest epoch they held.
  final Map<String, ({CircleInbox inbox, int since, int after})> _askedOf = {};

  /// Asks for the circle's newest key, with this device's inbox; at most every half a minute.
  Future<void> _askKey() async {
    final k = keys, s = signer;
    if (k == null || s == null || s.id != me) return;
    final now = DateTime.now();
    // At most every half minute for the same newest epoch; at once for a newer one.
    final want = k.newest(circle.seed)?.epoch ?? 0;
    if (_askedKey != null && want <= _askedFor && now.difference(_askedKey!) < const Duration(seconds: 30)) return;
    _askedKey = now;
    _askedFor = want;
    try {
      _sayPlain({'t': 'k?', 'ke': k.current(circle.seed)?.epoch ?? 0, 'ik': await k.inboxSaid(circle.seed, s)});
    } catch (_) {}
  }

  /// Leaves the room and drops every answer waiting to be said; [joined] says false if it never got in.
  Future<void> close() async {
    if (!opened) return;
    opened = false;
    if (!_in.isCompleted) _in.complete(false);
    route.leave(circle.room);
    for (final t in _answering.values) {
      t.cancel();
    }
    _answering.clear();
    final subs = [..._subs];
    _subs.clear();
    for (final s in subs) {
      await s.cancel();
    }
    present.clear();
  }

  /// Says [m] to everyone in the room.
  /// Sealed with the seed's key (second review, B5): a device behind on the circle's key must still hear the circle
  /// change and be told it was put out, and say it came, or it waits on a key nobody will give it.
  void say(CircleManifest m) => _sayPlain({'t': 'circle', 'm': m.toJson()}, keep: true);

  /// Asks for a newer manifest, saying which of the circle's key epochs this device holds (`ke`, GMFB-26).
  void _ask() => _sayPlain({'t': 'sync?', 'v': circle.manifest.version, 'gv': circle.manifest.grantsVersion, if (keys != null) 'ke': keys!.current(circle.seed)?.epoch ?? 0});

  /// Whether this device's manifest is newer than one at [gv] and [v], as CircleManifest.follows orders them: the admin
  /// list's generation first (a new admin list numbers its versions again from 1), then the version.
  bool _newerThan(int gv, int v) {
    final m = circle.manifest;
    return m.grantsVersion != gv ? m.grantsVersion > gv : m.version > v;
  }

  /// What an old key signs to say its id is [now]'s in [seed]'s circle ([sayWas]).
  static List<int> wasMessage(String seed, String now) => utf8.encode('ghost-circle was|$seed|$now');

  /// Says that [oldKey]'s id is this device's identity's now, with [sig] by [oldKey] ([wasMessage]): kept by the hub,
  /// so whoever comes in later folds the two together too.
  void sayWas(Uint8List oldKey, Uint8List sig) => _say({'t': 'was', 'k': NetCrypto.hex(oldKey), 'sig': NetCrypto.hex(sig)}, keep: true);

  /// Says this device's person came into the circle as [name] at [at] (ms): kept by the hub, so whoever is away is told
  /// when they are back.
  void sayJoined(String name, int at) => _sayPlain({'t': 'joined', 'n': name, 'at': at}, keep: true);

  /// [keep]: a change to the circle is kept by the hub for whoever comes in later. Sealed with the newest key held.
  void _say(Map<String, Object?> what, {bool keep = false}) {
    final clear = utf8.encode(jsonEncode(what));
    final k = keys;
    if (k == null) return _send(NetCrypto.seal(circle.key, clear), keep: keep);
    final sealed = k.seal(circle.seed, circle.key, 'circle', clear);
    if (sealed == null) {
      // A newer key is known than this device holds: kept until it comes, never sealed under the older one.
      _waiting.add((what: what, keep: keep));
      if (_waiting.length > mostWaiting) _waiting.removeAt(0);
      waitingForKey.value = true;
      unawaited(_askKey());
      return;
    }
    _send(sealed, keep: keep);
  }

  /// Says [what], sealed with the seed's key alone: what a device without the newest key must read (an inbox, a new key
  /// in boxes, asking for it).
  void sayPlain(Map<String, Object?> what, {bool keep = false}) => _sayPlain(what, keep: keep);

  void _sayPlain(Map<String, Object?> what, {bool keep = false}) => _send(NetCrypto.seal(circle.key, utf8.encode(jsonEncode(what))), keep: keep);

  /// Sends what is already sealed to the circle's room; with [keep], for the hub to hold for members who are away.
  void _send(Uint8List sealed, {bool keep = false}) {
    if (!opened) return;
    try {
      final r = route;
      if (keep && r is HubVoiceRoute) {
        r.sendKept(circle.room, sealed);
      } else {
        r.send(circle.room, sealed);
      }
    } catch (_) {}
  }

  /// Keeps [i] among the inboxes, at most [mostInboxes] for one id (the oldest go).
  void _keepInbox(CircleInbox i) {
    final name = '${i.id}:${i.device}';
    inboxes.remove(name);
    inboxes[name] = i;
    final theirs = [for (final e in inboxes.entries) if (e.value.id == i.id) e.key];
    for (final n in theirs.take((theirs.length - mostInboxes).clamp(0, theirs.length))) {
      inboxes.remove(n);
    }
  }

  void _event(RoomEvent e) {
    if (e.closed) {
      _dropped = true;
      present.clear();
    } else if (e.members != null && _dropped) {
      // Back in after the relay dropped: whatever changed meanwhile.
      _dropped = false;
      present
        ..clear()
        ..addAll(e.members!);
      if (!_in.isCompleted) _in.complete(true);
      _ask();
      unawaited(_keysOnComing());
    } else if (e.came != null) {
      present.add(e.came!);
    } else if (e.went != null) {
      present.remove(e.went);
      _answering.remove(e.went)?.cancel();
    }
  }

  /// Opens what [from] said with the circle's key and acts on its kind: `sync?`, `circle`, `joined` or `was`.
  void _heard(String from, Uint8List bytes) {
    final o = keys?.open(circle.seed, circle.key, 'circle', bytes) ?? (clear: NetCrypto.open(circle.key, bytes), unknown: false);
    final clear = o.clear;
    if (clear == null) {
      // Sealed under a key this device hasn't got: kept, to be read once it comes, and asked for.
      if (o.unknown) {
        _unread.add((from: from, bytes: bytes));
        if (_unread.length > mostUnread) _unread.removeAt(0);
        unawaited(_askKey());
      }
      return;
    }
    Map<String, dynamic> m;
    try {
      m = (jsonDecode(utf8.decode(clear)) as Map).cast<String, dynamic>();
    } catch (_) {
      return;
    }
    switch (m['t']) {
      case 'out':
        // Banned, as the owner or an admin says, in the last ten minutes. Only with circle keys on (with them off the
        // manifest says it, as before).
        final k = m['k'], sig = m['sig'], at = m['at'];
        if (keys == null || m['to'] != me || k is! String || sig is! String || at is! int || (DateTime.now().millisecondsSinceEpoch - at).abs() > const Duration(minutes: 10).inMilliseconds) return;
        try {
          final key = NetCrypto.unhex(k);
          if (NetCrypto.idOf(key) == from && circle.manifest.canSign(from) && NetCrypto.verify(key, outMessage(circle.seed, me, at), NetCrypto.unhex(sig))) onOut?.call();
        } catch (_) {}
      case 'ik':
        if (keys == null) return;
        final i = CircleKeys.inboxOf(circle.seed, from, m);
        if (i != null) _keepInbox(i);
      case 'rk' || 'kb':
        final k = keys;
        if (k == null) return;
        // Boxes for others answer their asking, and a header said tells whoever asked of it: not said again here. Only
        // on the word of someone who may hold the key, so nobody else can hush the answers.
        final fromHolder = mayHaveKey?.call(from) ?? !circle.manifest.removed.contains(from);
        for (final b in (fromHolder && m['x'] is List ? m['x'] as List : const [])) {
          if (b is Map) {
            _answering.remove('k:${b['i']}:${b['d']}')?.cancel();
            // Answered with the newest key: no need to answer them later.
            final e = m['h'] is Map ? (m['h'] as Map)['e'] : null;
            if (e is int && e >= (k.newest(circle.seed)?.epoch ?? 0)) _askedOf.remove('${b['i']}:${b['d']}');
          }
        }
        final said = CircleEpoch.fromJson(m['h']);
        if (fromHolder && said != null && said.trusted(circle.manifest)) {
          for (final name in [..._answering.keys.where((n) => n.startsWith('h:') && (int.tryParse(n.substring(2)) ?? 0) <= said.epoch)]) {
            _answering.remove(name)?.cancel();
          }
        }
        k.take(circle, me, m);
        if (k.lacking(circle.seed)) unawaited(_askKey());
        // Two admins changed it at once: changed again only by the device that made the losing header, after a random
        // wait, if it is still split then, and once per epoch (B3). Another device of the same identity didn't make it.
        if (k.shouldChangeAgain(circle.seed) && signer != null && circle.manifest.canSign(me)) {
          final n = k.newest(circle.seed)!.epoch;
          _answering['split:$n'] ??= Timer(Duration(milliseconds: 300 + _random.nextInt(2000)), () {
            _answering.remove('split:$n');
            if (k.shouldChangeAgain(circle.seed) && k.newest(circle.seed)!.epoch == n) {
              k.changingAgain(circle.seed);
              onSplit?.call();
            }
          });
        }
      case 'k?':
        final k = keys;
        final i = CircleKeys.inboxOf(circle.seed, from, m['ik']);
        if (k == null || i == null) return;
        // At most every ten seconds from each device (B10).
        final asked = _askedBy['$from:${i.device}'];
        if (asked != null && DateTime.now().difference(asked) < const Duration(seconds: 10)) return;
        _askedBy['$from:${i.device}'] = DateTime.now();
        _keepInbox(i);
        if (!(mayHaveKey?.call(from) ?? !circle.manifest.removed.contains(from))) return;
        final since = m['ke'] is int ? m['ke'] as int : 0;
        // Someone kicked who came back: only keys made after they came (B9).
        final after = epochsAfter?.call(from) ?? 0;
        // Behind too: answered once this device has the key (it may come before anyone else answers).
        if (k.current(circle.seed) == null || k.lacking(circle.seed)) {
          _askedOf['${i.id}:${i.device}'] = (inbox: i, since: since, after: after);
          while (_askedOf.length > 50) {
            _askedOf.remove(_askedOf.keys.first);
          }
          return;
        }
        // As `sync?` is answered: the lowest id here first, the rest a step later unless they hear it answered.
        final ids = [me, ...present.where((id) => id != from && id != me)]..sort();
        final name = 'k:${i.id}:${i.device}';
        _answering.remove(name)?.cancel();
        _answering[name] = Timer(step * ids.indexOf(me).clamp(0, 12), () {
          _answering.remove(name);
          // Every epoch after the asker's newest, oldest first. None they may have (kicked, and come back since the
          // newest was made): the owner or an admin makes a new one, which they are in.
          final handed = k.handOnSince(circle, i, since, after: after);
          for (final a in handed) {
            _sayPlain(a);
          }
          if (handed.isEmpty && after > 0 && circle.manifest.canSign(me)) onSplit?.call();
        });
      case 'sync?':
        // Banned and asking (come back by the link): told so, signed, since the manifest that says so is sealed under a
        // key they are no longer given. At most once a minute each.
        final s = signer;
        if (keys != null && s != null && s.id == me && circle.manifest.removed.contains(from) && circle.manifest.canSign(me)) {
          final last = _toldOut[from];
          if (last == null || DateTime.now().difference(last) > const Duration(minutes: 1)) {
            _toldOut[from] = DateTime.now();
            final at = DateTime.now().millisecondsSinceEpoch;
            unawaited(s.sign(outMessage(circle.seed, from, at)).then((sig) => _sayPlain({'t': 'out', 'to': from, 'at': at, 'k': NetCrypto.hex(s.publicKey), 'sig': NetCrypto.hex(sig)})).catchError((_) {}));
          }
        }
        // A device holding an older epoch of the key than this one (a build that says `ke`): told the newest header, so
        // it knows to ask for the key with its inbox. Answered as the manifest is: the lowest id here first, the rest a
        // step later unless they hear the header said meanwhile (some here may hold no key: an old build, a listener).
        if (m['ke'] is int) _hint(from, m['ke'] as int);
        final v = m['v'] is int ? m['v'] as int : 0;
        // Without 'gv' (an older build), the generation it has is taken to be this one's, as it always was.
        final gv = m['gv'] is int ? m['gv'] as int : circle.manifest.grantsVersion;
        if (!circle.manifest.isSigned || !_newerThan(gv, v)) return;
        // The lowest id of those here answers at once, the next a step later, and so on.
        final ids = [me, ...present.where((id) => id != from && id != me)]..sort();
        final wait = step * ids.indexOf(me).clamp(0, 12);
        _answering.remove(from)?.cancel();
        _answering[from] = Timer(wait, () {
          _answering.remove(from);
          _sayPlain({'t': 'circle', 'to': from, 'm': circle.manifest.toJson()});
        });
      case 'circle':
        final got = CircleManifest.fromJson(m['m']);
        if (got == null) return;
        // Answered by someone else, as new as what this device would say: no need to say it too.
        final to = m['to'];
        if (to is String && to != me && !_newerThan(got.grantsVersion, got.version)) _answering.remove(to)?.cancel();
        if (got.follows(circle.manifest, circle.owner)) onManifest(circle, got);
      case 'joined':
        final at = m['at'] is int ? m['at'] as int : 0;
        onJoined?.call(from, m['n'] is String ? m['n'] as String : '', at);
        // Someone who came (back) openly may be let have the key now: told of the newest header, so they ask.
        _hint(from, 0);
      case 'was':
        // An id that was [from]'s before it spoke as its identity: taken only on the old key's own word, which names
        // [from] (stamped by the relay) and this circle.
        final k = m['k'], sig = m['sig'];
        if (k is! String || sig is! String) return;
        try {
          final key = NetCrypto.unhex(k);
          if (NetCrypto.verify(key, wasMessage(circle.seed, from), NetCrypto.unhex(sig))) onWas?.call(NetCrypto.idOf(key), from);
        } catch (_) {}
    }
  }
}

/// Where this device's circle keys are kept: the Keychain, Android's vault, as the account's words are (Sms.secretKeep).
class _CircleSecrets implements FsStore {
  @override
  Future<String?> read(String name) => Sms.instance.secretRead(name);
  @override
  Future<void> write(String name, String value) => Sms.instance.secretKeep(name, value);
}
