import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../net/crypto.dart';
import 'circle.dart';

/// Welcome messages, a welcome space and read-only spaces (Matt, 2026-11-20: "add - Welcome messages for new members and
/// allow setting a "welcome" channel as well as read only channels for system messages and admin / moderation
/// announcements").
///
/// - **The welcome** is words whoever may change the circle writes, kept in its signed manifest (`wl`: `t` the words,
///   `s` the welcome space's seed), so every member's app has it. A newcomer's app opens the circle on the welcome space,
///   and that space's chat starts with the welcome as a card addressed to whoever reads it ("{name}" in the words is
///   their name). Nothing is sent for it: every app draws it from the manifest, so it is never missing for someone who
///   joined while the admins were away.
/// - **A read-only space** (`rdo` in the space's entry) is one where only the owner and the admins (those the owner
///   granted, which every role that can change the circle, its spaces or its roles makes its holder) may write. It is
///   held three ways: the box is not offered to anyone else; every member's app drops what anyone else says there;
///   and its room on the relay is bound to the owner's key ([readOnlyRoomOf]), where the hub itself refuses to keep
///   anyone else's words or pass them to other members (relay/lib/hub.dart), so a changed app can't post either.
/// - **The system space** (`sy`, a space's seed) is a read-only space where each member's app writes, for that member
///   alone, the circle's comings and goings: who joined, who was kicked or banned, who was made or stopped being an admin, as
///   they are heard ([CircleSystemNote]). Admins' announcements are written there, or in any read-only space, as
///   ordinary messages.

/// The most a welcome may say.
const circleWelcomeMax = 1000;

/// What a newcomer is called in a welcome that says "{name}" where they have given no name.
const welcomeNoName = 'friend';

/// Whether [space] is read-only.
bool readOnlyOf(CircleSpace space) => space.extra['rdo'] == true;

/// What a manifest says of its welcome and its system space, read from fields of its own that an older build keeps
/// and passes on unread.
extension CircleWelcome on CircleManifest {
  /// The welcome's field (`wl`) as a map; empty where the manifest has none.
  Map<String, Object?> get _wl => extra['wl'] is Map ? (extra['wl'] as Map).cast<String, Object?>() : const {};

  /// The welcome's words, trimmed; '' where it has none.
  String get welcomeText {
    final t = _wl['t'];
    if (t is! String) return '';
    final words = t.trim();
    return words.length > circleWelcomeMax ? words.substring(0, circleWelcomeMax) : words;
  }

  /// The space newcomers land in and where the welcome is shown: one of the circle's spaces, or null.
  String? get welcomeSpace {
    final s = _wl['s'];
    return s is String && spaces.any((x) => x.seed == s) ? s : null;
  }

  /// The space the circle's comings and goings are written in: one of its read-only spaces, or null.
  String? get systemSpace {
    final s = extra['sy'];
    return s is String && spaces.any((x) => x.seed == s && readOnlyOf(x)) ? s : null;
  }

  /// The manifest's `extra` with the welcome's words and space as given ([text] '' and [space] null: none).
  Map<String, Object?> withWelcome({required String text, required String? space}) {
    final words = text.trim();
    final out = {...extra}..remove('wl');
    if (words.isNotEmpty || space != null) {
      out['wl'] = {if (words.isNotEmpty) 't': words.length > circleWelcomeMax ? words.substring(0, circleWelcomeMax) : words, 's': ?space};
    }
    return out;
  }

  /// The manifest's `extra` with [space] as the system space (null: none).
  Map<String, Object?> withSystemSpace(String? space) => {...extra}..remove('sy')..addAll({'sy': ?space});

  /// Whether [id] may write in a read-only space: the owner, or an admin the owner granted (who may sign the manifest).
  bool writesReadOnly(String id) => canSign(id);
}

/// The welcome's words for [name] (the newcomer's own, or "friend").
String welcomeFor(String text, String name) => text.replaceAll('{name}', name.trim().isEmpty ? welcomeNoName : name.trim());

/// A read-only space's room on the relay: its name is made from 16 bytes only the space's members know and the circle
/// owner's public key, so the hub can check whose it is ([ReadOnlyRoom.join]'s `ro`, relay/lib/hub.dart Hub.anchoredName).
@immutable
class ReadOnlyRoom {
  const ReadOnlyRoom({required this.room, required this.base, required this.owner, this.grantsVersion = 0, this.grants = const {}, this.grantsSig});

  /// The room's name (16 bytes in hex).
  final String room;

  /// What its name is made from besides the owner's key (16 bytes in hex).
  final String base;

  /// The circle owner's public key (33 bytes in hex).
  final String owner;

  /// The circle's admin list, as its manifest carries it, for the hub to know who besides the owner may post.
  final int grantsVersion;
  final Map<String, String> grants;
  final String? grantsSig;

  /// What a join says of it, and what an `anchor` says when the admin list changes.
  Map<String, Object?> get join => {'base': base, 'owner': owner, ...grantsJson};
  Map<String, Object?> get grantsJson => {'gv': grantsVersion, 'g': grants, 'gs': ?grantsSig};

  @override
  bool operator ==(Object other) => other is ReadOnlyRoom && other.room == room && other.owner == owner && other.grantsVersion == grantsVersion && mapEquals(other.grants, grants) && other.grantsSig == grantsSig;

  @override
  int get hashCode => Object.hash(room, owner, grantsVersion, grantsSig, grants.length);
}

/// [space]'s room on the relay in [m]'s circle, where it is read-only; null where it isn't, or the circle has no owner.
ReadOnlyRoom? readOnlyRoomOf(CircleManifest m, CircleSpace space) {
  if (!readOnlyOf(space) || !RegExp(r'^0[23][0-9a-f]{64}$').hasMatch(m.owner)) return null;
  final base = NetCrypto.derive(NetCrypto.unhex(space.seed), 'read-only room').sublist(0, 16);
  final name = NetCrypto.hex(NetCrypto.sha256([...utf8.encode('ghost-ro|'), ...base, ...NetCrypto.unhex(m.owner)]).sublist(0, 16));
  return ReadOnlyRoom(room: name, base: NetCrypto.hex(base), owner: m.owner, grantsVersion: m.grantsVersion, grants: m.adminGrants, grantsSig: m.grantsSig);
}

/// What happened in a circle, written in its system space by this device for its person ([CircleWelcome.systemSpace]).
enum SystemNoteKind {
  joined('j'),
  removed('r'),
  kicked('k'),
  admin('a'),
  unadmin('u');

  const SystemNoteKind(this.wire);

  /// Its letter where notes are kept; a letter this build doesn't know is no kind.
  final String wire;
  static SystemNoteKind? of(Object? w) => values.where((k) => k.wire == w).firstOrNull;
}

/// One line in a circle's system space: what happened, to whom, and when. Kept on this device (Circles._note).
@immutable
class CircleSystemNote {
  const CircleSystemNote({required this.kind, required this.id, required this.name, required this.at});
  final SystemNoteKind kind;

  /// Whom it is of: their id, and the name they went by ('' where none was heard).
  final String id;
  final String name;

  /// When (ms since 1970).
  final int at;

  /// In words, as the system space shows it.
  String get line {
    final who = name.isEmpty ? 'Someone' : name;
    return switch (kind) {
      SystemNoteKind.joined => '$who joined the circle',
      SystemNoteKind.removed => '$who was banned from the circle',
      SystemNoteKind.kicked => '$who was kicked from the circle',
      SystemNoteKind.admin => '$who is now an admin',
      SystemNoteKind.unadmin => '$who is no longer an admin',
    };
  }

  Map<String, Object?> toJson() => {'k': kind.wire, 'i': id, 'n': name, 'at': at};

  static CircleSystemNote? fromJson(Object? j) {
    if (j is! Map || j['i'] is! String || j['at'] is! int) return null;
    final kind = SystemNoteKind.of(j['k']);
    if (kind == null) return null;
    return CircleSystemNote(kind: kind, id: j['i'] as String, name: j['n'] is String ? j['n'] as String : '', at: j['at'] as int);
  }

  @override
  bool operator ==(Object other) => other is CircleSystemNote && other.kind == kind && other.id == id && other.at == at;

  @override
  int get hashCode => Object.hash(kind, id, at);
}

/// What changed between [was] and [now] of one circle that its system space tells of: who was banned (removed), who was
/// kicked, who was made an admin, who stopped being one. [nameOf] gives a name for an id.
List<CircleSystemNote> systemNotesBetween(CircleManifest was, CircleManifest now, {required String Function(String id) nameOf, required int at}) {
  final out = <CircleSystemNote>[];
  for (final id in now.removed.difference(was.removed)) {
    out.add(CircleSystemNote(kind: SystemNoteKind.removed, id: id, name: nameOf(id), at: at));
  }
  final kickedBefore = was.kicked;
  for (final e in now.kicked.entries) {
    if ((kickedBefore[e.key] ?? -1) >= e.value || now.removed.contains(e.key)) continue;
    out.add(CircleSystemNote(kind: SystemNoteKind.kicked, id: e.key, name: nameOf(e.key), at: at));
  }
  final before = {for (final id in was.adminGrants.keys) if (was.granted(id)) id};
  final after = {for (final id in now.adminGrants.keys) if (now.granted(id)) id};
  for (final id in after.difference(before)) {
    out.add(CircleSystemNote(kind: SystemNoteKind.admin, id: id, name: nameOf(id), at: at));
  }
  for (final id in before.difference(after)) {
    if (now.removed.contains(id)) continue;
    out.add(CircleSystemNote(kind: SystemNoteKind.unadmin, id: id, name: nameOf(id), at: at));
  }
  return out;
}
