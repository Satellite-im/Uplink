import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../net/crypto.dart';
import 'voice.dart' show SpaceKind;

/// Roles and permissions in a hangout, as Discord has them (Matt, 2026-11-15: "Implement a permissions system similar
/// to discord for hangouts ... make default roles such as admin, moderator, member").
///
/// **Who decides.** A hangout has an owner: the install that made it, named by its public key in the channel itself
/// (VoiceChannel.owner), so everyone who has the link knows it. The owner can do everything and can't be removed.
/// The owner makes admins; admins assign every other role, edit what each role may do, and remove or ban people.
///
/// **How everyone agrees.** What the roles are and who has which is one document, the [Roster], numbered and signed
/// by whoever last changed it. Anyone keeps the highest-numbered roster they can check: signed by the owner, or by an
/// admin whose being an admin the owner signed ([Roster.adminGrants]). So a newcomer can take the roster from anyone
/// in the hangout, and no one but the owner and their admins can make one that is believed. There is no server
/// deciding: the hub only carries sealed packets, and each device does what the roster says (lib/voice/hangout.dart).
enum Perm {
  speak('Speak', 'Be heard in voice'),
  video('Video', 'Turn on their camera'),
  chat('Send messages', 'Write in the space\'s chat'),
  invite('Invite', 'Copy the space\'s link for others'),
  muteOthers('Mute others', 'Mute someone for everyone'),
  removeMembers('Remove people', 'Put someone out; they can come back'),
  ban('Ban', 'Keep someone out for good'),
  manageMessages('Manage messages', 'Delete anyone\'s messages'),

  // A Files space's (Matt, 2026-11-17: "add full functionality for filesharing in a space when the space is designated
  // a Files Space"): members add files, moderators and admins rename or delete anyone's.
  uploadFiles('Add files', 'Add files to a Files space'),
  manageFiles('Manage files', 'Rename or delete anyone\'s files');

  const Perm(this.label, this.hint);
  final String label;
  final String hint;

  /// Only a Files space's roles carry these. A roster an older build checks must come out the same when it writes it
  /// again, and an older build drops a permission it doesn't know, so a voice or texting space's roles never name one
  /// (a new permission always goes at the end, and [Role.extra] keeps the ones this build doesn't know).
  static const files = {uploadFiles, manageFiles};

  /// The permissions a space of [kind] has.
  static Set<Perm> of(SpaceKind kind) => kind == SpaceKind.files ? values.toSet() : values.where((p) => !files.contains(p)).toSet();

  /// The permission with this name on the wire; null for one this build doesn't know.
  static Perm? named(String name) {
    for (final p in values) {
      if (p.name == name) return p;
    }
    return null;
  }
}

/// A role: its name, what it may do, and its place (a higher rank can act on a lower one, never on its own or above).
@immutable
class Role {
  const Role({required this.id, required this.name, required this.perms, required this.rank, this.extra = const [], this.color, this.rest = const {}});
  final String id;
  final String name;
  final Set<Perm> perms;

  /// Permissions named by a newer build that this one doesn't know: kept, after the known ones, so a roster written
  /// again comes out as it was signed.
  final List<String> extra;

  /// Admin 30, moderator 20, member 10; others in between or below.
  final int rank;

  /// The colour names are drawn in, as a Discord role's (Matt, 2026-11-17: "assign role colors like discord does"):
  /// `#rrggbb`, chosen on the role's page; null takes [defaultColor]. Written into the roster only where chosen, so a
  /// roster nobody coloured reads the same to a build from before colours.
  final String? color;

  /// What a newer build wrote on a role that this one doesn't know: kept and written back, so the roster still checks.
  final Map<String, Object?> rest;

  static const admin = 'admin', moderator = 'moderator', member = 'member';

  /// A stage's audience (GMFB-29): may write in the chat and listen, not speak or show video. Made as a stage is
  /// opened ([HangoutRoom.setStage]), and below a member.
  static const listener = 'listener';
  static const listenerRole = Role(id: listener, name: 'Listener', perms: {Perm.chat}, rank: 5);

  /// The colours offered on a role's page: Discord's own role colours.
  static const palette = ['#1abc9c', '#2ecc71', '#3498db', '#9b59b6', '#e91e63', '#f1c40f', '#e67e22', '#e74c3c', '#95a5a6', '#607d8b'];

  /// A role's colour where none was chosen: admins red and moderators blue; members and others the text's own.
  static String? defaultColor(String id) => switch (id) { admin => '#e74c3c', moderator => '#3498db', _ => null };

  /// The colour its people's names are drawn in; null for the text's own.
  String? get shownColor => color ?? defaultColor(id);

  /// [noColor] takes a chosen colour away, which a null [color] can't.
  Role copyWith({String? name, Set<Perm>? perms, int? rank, String? color, bool noColor = false}) =>
      Role(id: id, name: name ?? this.name, perms: perms ?? this.perms, rank: rank ?? this.rank, extra: extra, color: noColor ? null : (color ?? this.color), rest: rest);

  /// As written into a roster. The order is fixed (unknown fields first, permissions in the enum's order, then the
  /// unknown ones), since a roster's signature covers these bytes.
  Map<String, Object> toJson() => {
        for (final e in rest.entries)
          if (e.value != null) e.key: e.value!,
        'id': id,
        'n': name,
        'p': [for (final p in Perm.values) if (perms.contains(p)) p.name, ...extra],
        'r': rank,
        'c': ?color,
      };

  static final _hex = RegExp(r'^#[0-9a-fA-F]{6}$');

  /// A role from a roster's JSON; null where a field it needs is missing. Unknown permissions and fields are kept in
  /// [extra] and [rest]; a colour that isn't `#rrggbb` is dropped.
  static Role? fromJson(Object? j) {
    if (j is! Map || j['id'] is! String || j['n'] is! String || j['r'] is! int || j['p'] is! List) return null;
    final names = [for (final p in j['p'] as List) '$p'];
    final c = j['c'];
    return Role(
      id: j['id'] as String,
      name: j['n'] as String,
      rank: j['r'] as int,
      perms: {for (final p in names) ?Perm.named(p)},
      extra: [for (final p in names) if (Perm.named(p) == null) p],
      color: c is String && _hex.hasMatch(c) ? c.toLowerCase() : null,
      rest: {for (final e in j.entries) if (!const {'id', 'n', 'p', 'r', 'c'}.contains(e.key)) '${e.key}': e.value},
    );
  }

  /// The three a voice or texting space starts with.
  static final defaults = defaultsFor(SpaceKind.voice);

  /// The three a space of [kind] starts with: in a Files space members add files too, and moderators and admins manage
  /// anyone's.
  static List<Role> defaultsFor(SpaceKind kind) {
    final files = kind == SpaceKind.files;
    return [
      Role(id: admin, name: 'Admin', rank: 30, perms: Perm.of(kind)),
      Role(id: moderator, name: 'Moderator', rank: 20, perms: {Perm.speak, Perm.video, Perm.chat, Perm.invite, Perm.muteOthers, Perm.removeMembers, Perm.manageMessages, if (files) Perm.uploadFiles, if (files) Perm.manageFiles}),
      Role(id: member, name: 'Member', rank: 10, perms: {Perm.speak, Perm.video, Perm.chat, Perm.invite, if (files) Perm.uploadFiles}),
    ];
  }

  @override
  bool operator ==(Object other) => other is Role && other.id == id && other.name == name && other.rank == rank && other.color == color && setEquals(other.perms, perms) && listEquals(other.extra, extra) && mapEquals(other.rest, rest);

  @override
  int get hashCode => Object.hash(id, name, rank, perms.length);
}

/// Who can do what in one hangout (the header).
@immutable
class Roster {
  const Roster({
    required this.owner,
    this.version = 0,
    this.roles = const [],
    this.assigned = const {},
    this.adminGrants = const {},
    this.banned = const {},
    this.muted = const {},
    this.newcomer = Role.member,
    this.by,
    this.byKey,
    this.sig,
  });

  /// The owner's public key, 33 bytes in hex (VoiceChannel.owner); empty for a hangout made before there were roles:
  /// then no one can change anything and everyone is a member.
  final String owner;
  final int version;
  final List<Role> roles;

  /// Each person's role, by their id on the hub (NetCrypto.idOf their key). Anyone not named has [newcomer].
  final Map<String, String> assigned;

  /// For each admin, the owner's signature that they are one ([grantMessage]).
  final Map<String, String> adminGrants;

  /// Kept out for good, and muted for everyone.
  final Set<String> banned;
  final Set<String> muted;

  /// The role someone has until given another.
  final String newcomer;

  /// Who signed this version: their id, their public key, their signature over [signed].
  final String? by;
  final String? byKey;
  final String? sig;

  /// A hangout's first roster: the three roles (a Files space's with its own permissions), the owner alone.
  factory Roster.first(String owner, {SpaceKind kind = SpaceKind.voice}) => Roster(owner: owner, roles: Role.defaultsFor(kind));

  /// The owner's id on the hub, from their key; empty where there is no owner.
  /// Worked out once for a key and kept: every row of a space asks whose it is as it is drawn, and a hash in pure
  /// Dart for each was a tenth of what a space's page cost to build (docs/performance-audit.md, "Calls").
  String get ownerId => owner.isEmpty ? '' : (_ownerIds[owner] ??= NetCrypto.idOf(NetCrypto.unhex(owner)));
  static final Map<String, String> _ownerIds = {};

  bool get hasOwner => owner.isNotEmpty;

  /// The roles in force: a roster that names none has the three defaults.
  List<Role> get _roles => roles.isEmpty ? Role.defaults : roles;

  Role? roleById(String id) {
    for (final r in _roles) {
      if (r.id == id) return r;
    }
    return null;
  }

  /// The roles from the highest rank down.
  List<Role> get ranked => [..._roles]..sort((a, b) => b.rank.compareTo(a.rank));

  /// [id]'s role: the owner's is admin; an admin without the owner's grant is not one.
  Role roleOf(String id) {
    if (hasOwner && id == ownerId) return roleById(Role.admin) ?? Role.defaults.first;
    var named = assigned[id] ?? newcomer;
    // Named admin without the owner's grant: the newcomer's role instead.
    if (named == Role.admin && !_granted(id)) named = newcomer == Role.admin ? Role.member : newcomer;
    return roleById(named) ?? roleById(Role.member) ?? Role.defaults.last;
  }

  bool isOwner(String id) => hasOwner && id == ownerId;

  /// Whether [id] may do [p]. Banned people may do nothing; muted ones may not speak.
  bool can(String id, Perm p) {
    if (isOwner(id)) return true;
    if (banned.contains(id)) return false;
    if (p == Perm.speak && muted.contains(id)) return false;
    // A hangout from before roles: everyone as a member was then.
    if (!hasOwner) return Role.defaults.last.perms.contains(p);
    return roleOf(id).perms.contains(p);
  }

  /// Whether [id] may make and sign rosters: the owner and the admins they made.
  bool canManage(String id) => isOwner(id) || (hasOwner && roleOf(id).id == Role.admin);

  /// Whether [actor] may act on [target] (mute, remove, ban, change their role): above them, and never the owner.
  bool outranks(String actor, String target) {
    if (actor == target || isOwner(target)) return false;
    if (isOwner(actor)) return true;
    return roleOf(actor).rank > roleOf(target).rank;
  }

  // --- signing ---------------------------------------------------------------------------------------------------

  /// What the owner signs to make [id] an admin of the hangout whose owner key this is.
  static List<int> grantMessage(String owner, String id) => utf8.encode('ghost-hangout admin|$owner|$id');

  /// Whether [id] holds the owner's signature making them an admin.
  bool _granted(String id) {
    final g = adminGrants[id];
    if (g == null || !hasOwner) return false;
    return NetCrypto.verifyOnce(NetCrypto.unhex(owner), grantMessage(owner, id), NetCrypto.unhex(g));
  }

  /// Everything but who signed it, with maps and sets sorted so the same roster always encodes to the same bytes.
  Map<String, Object?> _body() => {
        'o': owner,
        'v': version,
        'roles': [for (final r in roles) r.toJson()],
        'a': Map.fromEntries(assigned.entries.toList()..sort((a, b) => a.key.compareTo(b.key))),
        'g': Map.fromEntries(adminGrants.entries.toList()..sort((a, b) => a.key.compareTo(b.key))),
        'b': banned.toList()..sort(),
        'm': muted.toList()..sort(),
        'n': newcomer,
      };

  /// The bytes a signature covers: everything but the signature, in one order.
  List<int> get signed => utf8.encode('ghost-hangout roster|${jsonEncode({..._body(), 'by': by, 'k': byKey})}');

  Map<String, Object?> toJson() => {..._body(), 'by': by, 'k': byKey, 's': sig};

  /// A roster as it was sent or kept; null where the owner or version is missing. Reading it proves nothing: check
  /// [trustedFor] before believing it.
  static Roster? fromJson(Object? j) {
    if (j is! Map || j['o'] is! String || j['v'] is! int) return null;
    final roles = <Role>[for (final r in (j['roles'] as List? ?? const [])) ?Role.fromJson(r)];
    return Roster(
      owner: j['o'] as String,
      version: j['v'] as int,
      roles: roles,
      assigned: (j['a'] as Map? ?? const {}).map((k, v) => MapEntry('$k', '$v')),
      adminGrants: (j['g'] as Map? ?? const {}).map((k, v) => MapEntry('$k', '$v')),
      banned: {for (final b in (j['b'] as List? ?? const [])) '$b'},
      muted: {for (final m in (j['m'] as List? ?? const [])) '$m'},
      newcomer: j['n'] is String ? j['n'] as String : Role.member,
      by: j['by'] as String?,
      byKey: j['k'] as String?,
      sig: j['s'] as String?,
    );
  }

  /// Whether this roster is one to believe for a hangout whose owner key is [owner]: for that owner, signed by the key
  /// it names, by the owner or an admin the owner made, making no admin the owner didn't, with the owner still owner.
  bool trustedFor(String owner) {
    if (owner.isEmpty || this.owner != owner) return false;
    final by = this.by, key = byKey, sig = this.sig;
    if (by == null || key == null || sig == null) return false;
    final k = NetCrypto.unhex(key);
    if (NetCrypto.idOf(k) != by) return false;
    if (!NetCrypto.verify(k, signed, NetCrypto.unhex(sig))) return false;
    if (!canManage(by)) return false;
    // Every admin named has the owner's grant; the owner is never banned or muted.
    for (final e in assigned.entries) {
      if (e.value == Role.admin && !_granted(e.key)) return false;
    }
    if (banned.contains(ownerId) || muted.contains(ownerId)) return false;
    if (roleById(Role.admin) == null || roleById(newcomer) == null || newcomer == Role.admin) return false;
    return true;
  }

  /// The next version, changed by [change], to be signed by its author ([signedBy]).
  Roster next({List<Role>? roles, Map<String, String>? assigned, Map<String, String>? adminGrants, Set<String>? banned, Set<String>? muted, String? newcomer}) => Roster(
        owner: owner,
        version: version + 1,
        roles: roles ?? this.roles,
        assigned: assigned ?? this.assigned,
        adminGrants: adminGrants ?? this.adminGrants,
        banned: banned ?? this.banned,
        muted: muted ?? this.muted,
        newcomer: newcomer ?? this.newcomer,
      );

  /// This roster as [id] (with [publicKey]) signs it, with [sign] the signer.
  Future<Roster> signedBy(String id, Uint8List publicKey, Future<Uint8List> Function(List<int>) sign) async {
    final unsigned = Roster(
      owner: owner,
      version: version,
      roles: roles,
      assigned: assigned,
      adminGrants: adminGrants,
      banned: banned,
      muted: muted,
      newcomer: newcomer,
      by: id,
      byKey: NetCrypto.hex(publicKey),
    );
    final s = await sign(unsigned.signed);
    return Roster(
      owner: owner,
      version: version,
      roles: roles,
      assigned: assigned,
      adminGrants: adminGrants,
      banned: banned,
      muted: muted,
      newcomer: newcomer,
      by: id,
      byKey: NetCrypto.hex(publicKey),
      sig: NetCrypto.hex(s),
    );
  }
}
