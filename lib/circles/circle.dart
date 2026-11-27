/// A circle: a group of people with a sidebar of their own spaces (Matt, 2026-11-17: "I think for now the full server
/// implementation is a bit much and the UI doesn't look like our own ... Let's do a circle for now, remove all of the
/// code related to the server UIs and make a new design for [circles]. We want it to be simpler and easier to digest
/// with it's own sidebar full of spaces each space should be able to act as a chat and a voice chat, or just a texting
/// space").
///
/// **Its identity is one seed**, 32 random bytes, as a space's is (lib/voice/voice.dart): the circle's room on the hub,
/// the token to join it and the key what is said in it is sealed with all come from it, so holding the seed is being
/// in the circle, and the hub sees only that some installs are in some room.
///
/// **What it holds is its manifest** ([CircleManifest]): its name, colour, icon and picture, and its list of spaces,
/// each with the space's own seed, name, kind, place and section. It is numbered and signed by the circle's owner (the
/// install that made it), or by an admin the owner granted, as a space's roster is (lib/voice/roles.dart), so anyone
/// may pass it on and only the owner and their admins can change it. Members keep the highest-numbered one that checks
/// out (lib/circles/circles.dart gossips it in the circle's room).
///
/// Each space of a circle is an ordinary space ([VoiceChannel]) whose owner is the circle's owner: its chat, its roles
/// and its call (a voice one's) are what any space has.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../net/crypto.dart';
import '../voice/voice.dart';
import '../invites/link_relay.dart';

/// The colours a circle may wear: the app's own hues (lib/kit/settings_css.dart `data-hue`), which every look in
/// lib/looks.dart settles into its own page.
const circleHues = ['blue', 'purple', 'coral', 'green', 'amber', 'indigo', 'orange', 'cyan', 'rose', 'mint', 'magenta', 'slate'];

/// A hue for a circle that has not said its own yet (joined by a link, before its manifest came): the same one on
/// every device, from its seed.
String hueOfSeed(String seed) {
  var h = 0;
  for (final c in seed.codeUnits) {
    h = (h * 31 + c) & 0x7fffffff;
  }
  return circleHues[h % circleHues.length];
}

/// The largest picture a manifest carries, as base64: small enough that the manifest still fits one packet on the hub
/// (64 KB) and one invite.
const circlePictureMax = 24000;

/// The largest banner a manifest carries, as base64: a wide picture behind the top of the circle's sidebar (Matt,
/// 2026-11-19: "make circles have a background image for the header like discord does"), small enough that it and a
/// picture still go round in one packet.
const circleBannerMax = 26000;

/// What a circle's roles can give (Matt, 2026-11-18: "Build custom roles"): changing the circle itself, its spaces and
/// its roles, inviting, and writing, talking and sharing files in its spaces. Kept by a letter each in the manifest.
enum CirclePerm {
  circle('c', 'Change the circle', 'Its name, picture, colour and icon'),
  spaces('s', 'Manage spaces', 'Add, rename, change, arrange and delete spaces'),
  roles('r', 'Manage roles', 'Make and change roles, and give them to people'),
  invite('i', 'Invite people', 'Bring people in, and see the invite link'),
  write('w', 'Write', 'Send messages in chat spaces'),
  voice('v', 'Talk', 'Join voice spaces and talk'),
  files('f', 'Share files', 'Add files in files spaces');

  const CirclePerm(this.wire, this.label, this.blurb);

  /// Its letter in the manifest, then its name and the line under it in the role editor.
  final String wire;
  final String label;
  final String blurb;

  /// Those that change the circle's manifest: whoever has one must be able to sign it, so a role with one also makes its
  /// holder an admin the owner granted (what every version of the app checks a manifest by).
  bool get signs => this == circle || this == spaces || this == roles;

  /// The permission a manifest's letter stands for; null for one this build doesn't know.
  static CirclePerm? of(Object? wire) => values.where((p) => p.wire == wire).firstOrNull;

  /// What everyone in a circle may do where its owner has said nothing else.
  static const everyoneDefault = {invite, write, voice, files};

  /// How the role editor groups them, as Discord's role page does (Matt, 2026-11-18: "closer to discord server
  /// settings"): the circle's own, then each kind of space's.
  static const groups = [
    ('General', [circle, spaces, roles, invite]),
    ('Text', [write]),
    ('Voice', [voice]),
    ('Files', [files]),
  ];

  /// What a space of [kind] can be told otherwise than the circle says, per role ([CircleOverride]; Matt, 2026-11-18:
  /// "tri toggles for permissions"): writing in a chat space, talking in a voice space, adding files in a files space, and
  /// inviting in every one; and writing in the chat a voice or files space has beside it, and adding a file to a chat
  /// space's messages (lib/ui/space_chat_files.dart asks for both).
  /// Never one that [signs]: whoever may change the circle can sign a manifest without the override anyway.
  static List<CirclePerm> inSpace(SpaceKind kind) => switch (kind) {
        SpaceKind.text => const [write, files, invite],
        SpaceKind.voice || SpaceKind.open => const [voice, write, invite],
        SpaceKind.files => const [files, write, invite],
      };

  /// Letters for [perms], in the enum's order: how roles and overrides write a set.
  static String lettersOf(Set<CirclePerm> perms) => [for (final p in values) if (perms.contains(p)) p.wire].join();
}

/// One of a space's three answers for a permission, for one role (Discord's channel overrides): taken away, as the
/// circle says, or given.
enum PermOverride {
  deny('Deny'),
  inherit('As the circle says'),
  allow('Allow');

  const PermOverride(this.label);
  final String label;
}

/// What a space says of one role (or of everyone) otherwise than the circle does: the permissions it gives there and
/// those it takes away. Written as `allow/deny` in letters ("w/f": may write, may not add files), so a circle of
/// many spaces and roles still fits its packet.
@immutable
class CircleOverride {
  const CircleOverride({this.allow = const {}, this.deny = const {}});
  final Set<CirclePerm> allow;
  final Set<CirclePerm> deny;

  static const none = CircleOverride();

  bool get isEmpty => allow.isEmpty && deny.isEmpty;

  /// Its answer for [p]: a permission written both ways is denied, as a reader can't tell which was meant.
  PermOverride of(CirclePerm p) => deny.contains(p) ? PermOverride.deny : (allow.contains(p) ? PermOverride.allow : PermOverride.inherit);

  /// This override with [p] answered [s]: taken out of whichever set it was in, and put in the one [s] names.
  CircleOverride withState(CirclePerm p, PermOverride s) => CircleOverride(
        allow: {...allow.where((x) => x != p), if (s == PermOverride.allow) p},
        deny: {...deny.where((x) => x != p), if (s == PermOverride.deny) p},
      );

  String toWire() => '${CirclePerm.lettersOf(allow)}/${CirclePerm.lettersOf(deny)}';

  /// Reads `allow/deny` in letters; anything else is [none]. A letter on both sides is denied.
  static CircleOverride fromWire(Object? w) {
    if (w is! String || !w.contains('/')) return none;
    final at = w.indexOf('/');
    Set<CirclePerm> read(String s) => {for (final c in s.split('')) ?CirclePerm.of(c)};
    final deny = read(w.substring(at + 1));
    return CircleOverride(allow: read(w.substring(0, at)).difference(deny), deny: deny);
  }

  @override
  bool operator ==(Object other) => other is CircleOverride && setEquals(other.allow, allow) && setEquals(other.deny, deny);

  @override
  int get hashCode => Object.hash(Object.hashAllUnordered(allow), Object.hashAllUnordered(deny));
}

/// A role's hue where it gives its people's names no colour (Discord's default): any other build reads it as blue,
/// which it only writes back if it changes that role.
const circleRoleNoHue = 'none';

/// A role in a circle: its name and colour, and what it gives.
@immutable
class CircleRole {
  const CircleRole({required this.id, required this.name, this.hue = 'blue', this.perms = const {}});

  /// A new role, with a random id of its own.
  factory CircleRole.make(String name, {String hue = 'blue', Set<CirclePerm> perms = const {}}) => CircleRole(id: NetCrypto.hex(NetCrypto.randomBytes(6)), name: name, hue: hue, perms: perms);

  final String id;
  final String name;
  final String hue;
  final Set<CirclePerm> perms;

  /// Whether it gives anything that changes the manifest ([CirclePerm.signs]): its holders need the owner's admin
  /// grant, which only the owner gives.
  bool get signs => perms.any((p) => p.signs);

  CircleRole copyWith({String? name, String? hue, Set<CirclePerm>? perms}) => CircleRole(id: id, name: name ?? this.name, hue: hue ?? this.hue, perms: perms ?? this.perms);

  Map<String, Object?> toJson() => {'id': id, 'n': name, 'h': hue, 'p': [for (final p in CirclePerm.values) if (perms.contains(p)) p.wire]};

  /// The role [j] is; null without an id, or a name of 1 to 40 characters. A hue this build doesn't know reads as blue.
  static CircleRole? fromJson(Object? j) {
    if (j is! Map || j['id'] is! String || j['n'] is! String) return null;
    final name = (j['n'] as String).trim();
    if (name.isEmpty || name.length > 40) return null;
    return CircleRole(
      id: j['id'] as String,
      name: name,
      hue: j['h'] is String && (circleHues.contains(j['h']) || j['h'] == circleRoleNoHue) ? j['h'] as String : 'blue',
      perms: {for (final w in (j['p'] is List ? j['p'] as List : const [])) ?CirclePerm.of(w)},
    );
  }

  @override
  bool operator ==(Object other) => other is CircleRole && other.id == id && other.name == name && other.hue == hue && setEquals(other.perms, perms);

  @override
  int get hashCode => Object.hash(id, name, hue, Object.hashAllUnordered(perms));
}

/// At most this many roles in a circle.
const circleRolesMax = 30;

/// One space in a circle's list, as the manifest carries it: its seed, name, kind and place.
@immutable
class CircleSpace {
  const CircleSpace({required this.seed, required this.name, this.kind = SpaceKind.voice, this.order = 0, this.section, this.kindWire, this.extra = const {}});

  /// A new space, with a seed of its own.
  factory CircleSpace.make(String name, {SpaceKind kind = SpaceKind.voice, int order = 0, String? section, Map<String, Object?> extra = const {}}) =>
      CircleSpace(seed: NetCrypto.hex(NetCrypto.randomBytes(32)), name: name, kind: kind, order: order, section: section, extra: extra);

  /// The space's own seed (32 bytes in hex), as any space's: its rooms and key come from it.
  final String seed;
  final String name;
  final SpaceKind kind;

  /// Its place in the circle's list, lowest first.
  final int order;

  /// The heading it is listed under, or null for none.
  final String? section;

  /// Its kind's word as a newer build wrote it, where this build doesn't know it: written back as it came, so an admin
  /// here renaming or moving the space doesn't turn it into another kind for everyone. Meanwhile it is drawn as a
  /// [SpaceKind.text] space (a chat, no call), never offered a call it may not have.
  final String? kindWire;

  /// What a newer build wrote of the space that this one doesn't read, written back unchanged ([toJson]).
  final Map<String, Object?> extra;

  CircleSpace copyWith({String? name, SpaceKind? kind, int? order, String? section, bool clearSection = false, Map<String, Object?>? extra}) => CircleSpace(
        seed: seed,
        name: name ?? this.name,
        kind: kind ?? this.kind,
        order: order ?? this.order,
        section: clearSection ? null : (section ?? this.section),
        // A kind chosen here replaces the one this build couldn't read.
        kindWire: kind == null ? kindWire : null,
        extra: extra ?? this.extra,
      );

  /// The keys this build reads; whatever else a space carries is kept in [extra].
  static const _known = {'s', 'n', 'k', 'o', 'g'};

  Map<String, Object> toJson() => {
        for (final e in extra.entries)
          if (e.value != null) e.key: e.value!,
        's': seed,
        'n': name,
        if (kindWire != null) 'k': kindWire! else if (kind != SpaceKind.voice) 'k': kind.wire,
        'o': order,
        if (section != null && section!.isNotEmpty) 'g': section!,
      };

  /// The space [j] is; null without a seed of 64 hex letters or a name. A kind this build doesn't know is kept in
  /// [kindWire]; a name is cut to 100 characters.
  static CircleSpace? fromJson(Object? j) {
    if (j is! Map || j['s'] is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(j['s'] as String) || j['n'] is! String) return null;
    final name = (j['n'] as String).trim();
    if (name.isEmpty) return null;
    final section = j['g'] is String && (j['g'] as String).trim().isNotEmpty ? (j['g'] as String).trim() : null;
    final k = j['k'];
    final known = k == null || SpaceKind.values.any((x) => x.wire == k);
    return CircleSpace(
      seed: j['s'] as String,
      name: name.length > 100 ? name.substring(0, 100) : name,
      kind: known ? SpaceKind.of(k) : SpaceKind.text,
      kindWire: known ? null : '$k',
      order: j['o'] is int ? j['o'] as int : 0,
      section: section,
      extra: {for (final e in j.entries) if (!_known.contains(e.key)) '${e.key}': e.value},
    );
  }

  @override
  bool operator ==(Object other) => other is CircleSpace && other.seed == seed && other.name == name && other.kind == kind && other.order == order && other.section == section && other.kindWire == kindWire;

  @override
  int get hashCode => Object.hash(seed, name, kind, order, section, kindWire);
}

/// What a circle is and holds, numbered and signed ([trustedFor]).
///
/// The signature covers the body exactly as it was written ([raw], a JSON string), not as this build reads it, so a
/// manifest from a newer build with fields or kinds this one doesn't know still checks out here, and is passed on
/// unchanged.
@immutable
class CircleManifest {
  CircleManifest({
    required this.owner,
    required this.name,
    this.version = 0,
    this.hue = 'indigo',
    this.icon = 'users',
    this.picture,
    this.spaces = const [],
    this.adminGrants = const {},
    this.grantsVersion = 0,
    this.grantsSig,
    this.extra = const {},
    this.by,
    this.byKey,
    this.sig,
    String? raw,
  }) : raw = raw ?? jsonEncode(_body(owner, version, name, hue, icon, picture, spaces, adminGrants, grantsVersion, grantsSig, extra));

  /// The highest version a manifest may carry: a whole number a browser reads exactly (2^53). One at or above it is
  /// refused, so an admin can't publish the highest number there is and leave the owner no higher one to change the
  /// circle with; the owner starts the numbers again under a new admin list instead ([grantsVersion]).
  static const versionCap = 9007199254740992;

  /// The owner's public key (33 bytes in hex).
  final String owner;
  final int version;
  final String name;

  /// One of [circleHues].
  final String hue;

  /// A Lucide icon's name (lib/art), shown on the circle's face where it has no picture.
  final String icon;

  /// A small picture (base64, at most [circlePictureMax]: a JPEG, a PNG where it can be seen through, a WebP or PNG
  /// from a build before 0.12.52) in the icon's place; null for none. The part of the picture chosen, at full size, is
  /// [pictureFile].
  final String? picture;
  final List<CircleSpace> spaces;

  /// For each admin's id, the owner's signature that they are one ([grantMessage]): they may sign manifests too.
  final Map<String, String> adminGrants;

  /// The admin list's own number and the owner's signature over it ([grantsMessage]): made only by the owner, carried
  /// unchanged by every manifest an admin signs. Manifests are ordered by it first, then by [version], so once the
  /// owner removes an admin (a higher [grantsVersion]) nothing that admin signed before can win again, whatever its
  /// version, and a member who joins later takes the owner's. 0 with no signature: a circle from before it.
  final int grantsVersion;
  final String? grantsSig;

  /// What a newer build wrote in the body that this one doesn't read, written back unchanged when a manifest is made
  /// from this one ([next]).
  final Map<String, Object?> extra;

  /// Who signed this version: their id, their public key, their signature over [signed].
  final String? by;
  final String? byKey;
  final String? sig;

  /// The body as it was written and signed.
  final String raw;

  /// A circle's manifest before any has come: what its link or invite said, unsigned and numbered 0, so the first real
  /// one replaces it.
  factory CircleManifest.placeholder({required String owner, required String name, String? hue}) => CircleManifest(owner: owner, name: name, hue: hue ?? 'indigo');

  /// The body's keys this build reads; whatever else it carries is kept in [extra].
  static const _known = {'o', 'v', 'n', 'h', 'i', 'p', 'sp', 'g', 'gv', 'gs'};

  /// The body as it is written and signed: [extra] first, so a known field always wins over it, and the grants in
  /// order of id, so the same manifest is the same words on every device.
  static Map<String, Object?> _body(String owner, int version, String name, String hue, String icon, String? picture, List<CircleSpace> spaces, Map<String, String> grants, int gv, String? gs, Map<String, Object?> extra) => {
        ...extra,
        'o': owner,
        'v': version,
        'n': name,
        'h': hue,
        'i': icon,
        'p': ?picture,
        'sp': [for (final s in spaces) s.toJson()],
        'g': _sorted(grants),
        if (gv > 0) 'gv': gv,
        'gs': ?gs,
      };

  static Map<String, String> _sorted(Map<String, String> grants) => Map.fromEntries(grants.entries.toList()..sort((a, b) => a.key.compareTo(b.key)));

  /// What the owner signs for generation [gv] of the admin list [grants].
  static List<int> grantsMessage(String owner, int gv, Map<String, String> grants) => utf8.encode('ghost-circle grants|$owner|$gv|${jsonEncode(_sorted(grants))}');

  /// Whether the admin list is the owner's: its generation signed by the owner, or (generation 0) a circle from before
  /// generations, whose single grants are checked one by one ([granted]).
  bool get grantsTrusted {
    if (grantsVersion == 0) return true;
    final gs = grantsSig;
    if (gs == null || owner.isEmpty) return false;
    try {
      return NetCrypto.verifyOnce(NetCrypto.unhex(owner), grantsMessage(owner, grantsVersion, adminGrants), NetCrypto.unhex(gs));
    } catch (_) {
      return false;
    }
  }

  /// The manifest as a room message would carry it fits one hub packet (64 KB), with room for the seal round it.
  bool get fitsAPacket => raw.length <= 60000 && utf8.encode(jsonEncode({'t': 'circle', 'm': toJson()})).length <= 60000;

  bool get isSigned => sig != null;

  /// The owner's id on the hub, from their key; '' for a circle with no owner.
  String get ownerId => owner.isEmpty ? '' : NetCrypto.idOf(NetCrypto.unhex(owner));

  /// The spaces in their order: by [CircleSpace.order], then by name.
  List<CircleSpace> get ordered => [...spaces]..sort((a, b) => a.order != b.order ? a.order.compareTo(b.order) : a.name.toLowerCase().compareTo(b.name.toLowerCase()));

  /// The headings, in the order their first space comes; null (no heading) where a space has none.
  List<String?> get sections {
    final out = <String?>[];
    for (final s in ordered) {
      if (!out.contains(s.section)) out.add(s.section);
    }
    return out;
  }

  /// What the owner signs to make [id] an admin of the circle whose owner key this is.
  static List<int> grantMessage(String owner, String id) => utf8.encode('ghost-circle admin|$owner|$id');

  /// Whether [id] has the owner's grant in this manifest.
  bool granted(String id) {
    final g = adminGrants[id];
    if (g == null || owner.isEmpty || !grantsTrusted) return false;
    try {
      return NetCrypto.verifyOnce(NetCrypto.unhex(owner), grantMessage(owner, id), NetCrypto.unhex(g));
    } catch (_) {
      return false;
    }
  }

  /// Whether [id] may sign a manifest: the owner, or an admin they granted.
  bool canSign(String id) => id.isNotEmpty && (id == ownerId || granted(id));

  // --- roles (Matt, 2026-11-18: "Build custom roles") -----------------------------------------------------------------
  // Kept in fields of the manifest's own ('ro' the roles, 'ra' who has which, 're' what everyone may do), signed with
  // the rest. A version from before roles keeps and passes them on but does not read them: there whoever may sign the
  // manifest (the owner and admins) may change everything, as before.

  /// The circle's roles, in their order (the first the highest).
  List<CircleRole> get roles {
    final seen = <String>{};
    final list = extra['ro'] is List ? extra['ro'] as List : const [];
    return [for (final r in list.take(circleRolesMax)) if (CircleRole.fromJson(r) case final x? when seen.add(x.id)) x];
  }

  /// Each person's roles, by their id: the ids of roles that exist.
  Map<String, List<String>> get roleAssignments {
    final known = {for (final r in roles) r.id};
    final a = extra['ra'] is Map ? extra['ra'] as Map : const {};
    return {
      for (final e in a.entries)
        if (e.value is List) '${e.key}': [for (final id in e.value as List) if (id is String && known.contains(id)) id],
    }..removeWhere((_, v) => v.isEmpty);
  }

  /// What everyone in the circle may do.
  Set<CirclePerm> get everyone => extra['re'] is List ? {for (final w in extra['re'] as List) ?CirclePerm.of(w)} : CirclePerm.everyoneDefault;

  /// [id]'s roles, in the circle's order.
  List<CircleRole> rolesOf(String id) {
    final mine = roleAssignments[id] ?? const [];
    return [for (final r in roles) if (mine.contains(r.id)) r];
  }

  /// What [id] may do: everything for the owner, and for an admin given no role (an admin as before roles); otherwise
  /// what everyone may, and what their roles give. One of [CirclePerm.signs] needs the owner's grant too, which signing
  /// the manifest is checked by.
  Set<CirclePerm> permsOf(String id) {
    if (id.isEmpty) return const {};
    if (id == ownerId) return CirclePerm.values.toSet();
    if (removed.contains(id)) return const {};
    final mine = rolesOf(id);
    if (granted(id) && mine.isEmpty) return CirclePerm.values.toSet();
    final all = {...everyone, for (final r in mine) ...r.perms};
    if (!granted(id)) all.removeWhere((p) => p.signs);
    return all;
  }

  /// Its banner (`bn`, base64, at most [circleBannerMax]: a JPEG, a PNG from a build before 0.12.52); null for none,
  /// where the sidebar's top wears its colour.
  String? get banner => extra['bn'] is String && (extra['bn'] as String).length <= circleBannerMax ? extra['bn'] as String : null;

  /// Its invite word (`iw`, Matt, 2026-11-19: "add the custom invite code word as a default feature"): gogho.st/c/<word>,
  /// held on the relay for the circle's link (lib/circles/invite_word.dart). Null where it has none; a build from before
  /// reads none.
  String? get inviteWord => extra['iw'] is String && (extra['iw'] as String).length <= 32 ? extra['iw'] as String : null;

  /// Its banner at full size (`bf`; Matt, 2026-11-19: "when uploading a banner from camera roll it's not uploading
  /// the full resolution image"): the part of the picture chosen, cut at the picture's own resolution (the whole
  /// picture, from a build before 0.12.52), sealed on the relay under the circle's own seed as a chat's file is
  /// (Circle.bannerChannel), named here with its key. [banner] is its small stand-in, shown until it is here. The
  /// entry is as a Files space's carries a file (SpaceFile.toJson), so lib/files reads it; null for none.
  Map<String, Object?>? get bannerFile => extra['bf'] is Map ? (extra['bf'] as Map).cast<String, Object?>() : null;

  /// Its picture at full size (`pf`; Matt, 2026-11-27: "uploading the pictures for banners and the circle profile
  /// picture should use a cropping / zooming tool and upload at full resolution"): the part chosen, cut at the
  /// picture's own resolution and kept on the relay as the banner's is. [picture] is its stand-in, drawn wherever
  /// the face is no larger than the stand-in is sharp at, and until this is here.
  ///
  /// The entry says which stand-in it is the whole of (`of`, [pictureMark]). A build from before 0.12.52 changes
  /// the picture without knowing of this entry and passes it on as it was: belonging to another picture, it is null.
  Map<String, Object?>? get pictureFile {
    final f = extra['pf'], p = picture;
    if (f is! Map || p == null || f['of'] != pictureMark(p)) return null;
    return f.cast<String, Object?>();
  }

  /// What a full picture says of the stand-in it belongs to ([pictureFile]): a few bytes of its hash.
  static String pictureMark(String picture) => NetCrypto.hex(NetCrypto.sha256(utf8.encode(picture)).sublist(0, 6));

  /// Who was put out of the circle by its owner or an admin (`rm`, ids; Matt, 2026-11-19: "add the ability to remove
  /// members from a circle as an admin"). Every member's app leaves them out: not listed, not heard in its spaces or
  /// calls, and their own app leaves the circle and keeps out of it. A build from before reads none, as it would any
  /// field it does not know. The owner is never among them.
  Set<String> get removed => {for (final x in (extra['rm'] is List ? extra['rm'] as List : const [])) if (x is String && x != ownerId) x};

  /// Whether [by] may put [id] out: the owner anyone but themselves; an admin anyone neither the owner nor an admin.
  bool mayRemove(String by, String id) {
    if (id.isEmpty || by == id || id == ownerId || !canSign(by)) return false;
    return by == ownerId || !granted(id);
  }

  /// Who was kicked, and when (ms since the epoch, on the kicker's clock): their app leaves the circle if it joined before
  /// then, and may come back by an invite or the link, unlike someone [removed] (banned), who is kept out (Matt,
  /// 2026-11-20: "I can't seem to kick users or ban them from circles"). Kept in the manifest's own field 'kk'.
  Map<String, int> get kicked {
    final k = extra['kk'] is Map ? extra['kk'] as Map : const {};
    return {for (final e in k.entries) if (e.value is int && '${e.key}' != ownerId) '${e.key}': e.value as int};
  }

  /// The next version's fields with [id] kicked at [at].
  Map<String, Object?> withKicked(String id, int at) {
    final now = {...kicked, id: at};
    return {...extra, 'kk': Map.fromEntries(now.entries.toList()..sort((a, b) => a.key.compareTo(b.key)))};
  }

  /// The next version's fields with [id] put out ([removed]), or let back ([back]).
  Map<String, Object?> withRemoved(String id, {bool back = false}) {
    final now = {...removed};
    back ? now.remove(id) : now.add(id);
    return {...extra, 'rm': [...now]..sort()};
  }

  /// The next version's fields of roles: [roles], [assignments] and [everyone] in place of these.
  Map<String, Object?> withRoles({List<CircleRole>? roles, Map<String, List<String>>? assignments, Set<CirclePerm>? everyone}) => {
        ...extra,
        if (roles != null) 'ro': [for (final r in roles.take(circleRolesMax)) r.toJson()],
        if (assignments != null) 'ra': {for (final e in (Map.fromEntries(assignments.entries.toList()..sort((a, b) => a.key.compareTo(b.key)))).entries) if (e.value.isNotEmpty) e.key: e.value},
        if (everyone != null) 're': [for (final p in CirclePerm.values) if (everyone.contains(p)) p.wire],
      };

  // --- plugins for the whole circle (Matt, 2026-11-19: "Some plugins should be serverside / cirlce side as well") ---
  // Kept in a field of the manifest's own ('pl': each plugin's id, and its choices for the circle), signed with the rest,
  // so whoever may change the circle turns a plugin on for everyone in it. A build from before keeps and passes it on.

  /// What the circle says of each plugin, by its id: its choices for the circle, with 'on' true where it is on.
  Map<String, Map<String, Object?>> get plugins {
    final pl = extra['pl'] is Map ? extra['pl'] as Map : const {};
    return {
      for (final e in pl.entries)
        if (e.value is Map) '${e.key}': (e.value as Map).map((k, v) => MapEntry('$k', v)),
    };
  }

  /// Whether the circle has turned the plugin [id] on; null where it has said nothing of it.
  bool? pluginOn(String id) {
    final p = plugins[id];
    return p == null ? null : p['on'] == true;
  }

  /// The next version's fields with the plugin [id] turned [on], its choices [choices] added (or kept).
  Map<String, Object?> withPlugin(String id, {required bool on, Map<String, Object?> choices = const {}}) {
    final all = plugins;
    all[id] = {...?all[id], ...choices, 'on': on};
    final sorted = Map.fromEntries(all.entries.toList()..sort((a, b) => a.key.compareTo(b.key)));
    return {...extra, 'pl': sorted};
  }

  // --- the roles' order (Matt, 2026-11-18: "permission hierarchy") ------------------------------------------------
  // The order is the roles list's own ('ro', the first the highest), as Discord's role list, with everyone ("@everyone")
  // always under the last. A build from before the order keeps the list as it came and adds a new role at its end
  // (the lowest), so nothing new is written for it: older builds just don't hold anyone to it.

  /// Where [id] stands: the owner above every role (-2), an admin made by hand with no role just under them (-1, as
  /// before roles: they can do everything), then the place of their highest role, and everyone else under every role
  /// ([roles]'s length).
  int rankOf(String id) {
    if (id.isNotEmpty && id == ownerId) return -2;
    final mine = roleAssignments[id] ?? const [];
    final list = roles;
    final at = list.indexWhere((r) => mine.contains(r.id));
    if (at >= 0) return at;
    if (granted(id)) return -1;
    return list.length;
  }

  /// Whether [actor] may change, move, give or take away the role [roleId]: the owner any; someone who may manage roles
  /// only one under their own highest, never theirs or one above it (Discord's rule). A role not yet in the list is a
  /// new one, made at the bottom.
  bool mayManageRole(String actor, String roleId) {
    if (actor.isEmpty) return false;
    if (actor == ownerId) return true;
    if (!permsOf(actor).contains(CirclePerm.roles)) return false;
    final at = roles.indexWhere((r) => r.id == roleId);
    return at < 0 || rankOf(actor) < at;
  }

  /// Whether [actor] may put the roles in the [order] given (their ids, highest first): every role they may not manage
  /// stays where it is, and none goes above them.
  bool mayOrder(String actor, List<String> order) {
    final list = roles;
    if (order.length != list.length || !setEquals(order.toSet(), {for (final r in list) r.id})) return false;
    if (actor == ownerId) return true;
    if (!permsOf(actor).contains(CirclePerm.roles)) return false;
    final top = rankOf(actor);
    for (var i = 0; i < list.length; i++) {
      if (i <= top && order[i] != list[i].id) return false;
    }
    return true;
  }

  /// How many people have [roleId].
  int holdersOf(String roleId) => roleAssignments.values.where((ids) => ids.contains(roleId)).length;

  /// The hue [id]'s name is drawn in: their highest role's that has one (Discord's rule); null for none.
  String? nameHueOf(String id) => rolesOf(id).where((r) => r.hue != circleRoleNoHue && circleHues.contains(r.hue)).firstOrNull?.hue;

  // --- each space's overrides (Matt, 2026-11-18: "tri toggles for permissions") --------------------------------------
  // In a field of the manifest's own ('po'): for each space's seed, for each role's id (or [everyoneId]), what the space
  // gives and takes away there ([CircleOverride], `allow/deny` in letters). Signed with the rest. A build from before
  // them (0.9.2 to 0.9.18) keeps and passes the field on, but doesn't read it: there a space allows what the circle's
  // roles do, as before.

  /// The id everyone's override is kept under (Discord's @everyone).
  static const everyoneId = '@';

  /// Every space's overrides: by its seed, then by role id (or [everyoneId]); roles that are gone are left out.
  Map<String, Map<String, CircleOverride>> get overrides {
    final po = extra['po'];
    if (po is! Map) return const {};
    final known = {everyoneId, for (final r in roles) r.id};
    final out = <String, Map<String, CircleOverride>>{};
    for (final e in po.entries) {
      if (e.value is! Map) continue;
      final per = <String, CircleOverride>{
        for (final r in (e.value as Map).entries)
          if (known.contains('${r.key}') && !CircleOverride.fromWire(r.value).isEmpty) '${r.key}': CircleOverride.fromWire(r.value),
      };
      if (per.isNotEmpty) out['${e.key}'] = per;
    }
    return out;
  }

  /// What [space] says of [roleId] (or [everyoneId]).
  CircleOverride overrideOf(String space, String roleId) => overrides[space]?[roleId] ?? CircleOverride.none;

  /// The next version's field of overrides: [o] in place of these, with empty ones, spaces that are gone and roles that
  /// are gone left out (the field goes altogether when nothing is left).
  Map<String, Object?> withOverrides(Map<String, Map<String, CircleOverride>> o, {List<CircleSpace>? spaces, List<CircleRole>? roles}) {
    final seeds = {for (final s in spaces ?? this.spaces) s.seed};
    final known = {everyoneId, for (final r in roles ?? this.roles) r.id};
    final kept = <String, Map<String, String>>{};
    for (final seed in o.keys.toList()..sort()) {
      if (!seeds.contains(seed)) continue;
      final per = {
        for (final id in o[seed]!.keys.toList()..sort())
          if (known.contains(id) && !o[seed]![id]!.isEmpty) id: o[seed]![id]!.toWire(),
      };
      if (per.isNotEmpty) kept[seed] = per;
    }
    return {...extra, 'po': kept}..removeWhere((k, v) => k == 'po' && kept.isEmpty);
  }

  /// What [id] may do in the space [spaceSeed], as Discord works a channel out: their permissions in the circle
  /// ([permsOf]: everyone's and their roles'); then the space's word for everyone, what it takes away and then what
  /// it gives; then its words for their roles together, what any takes away and then what any gives (so one role's
  /// Allow outweighs another's Deny, and either outweighs everyone's). Only what a space of its kind can say is changed
  /// ([CirclePerm.inSpace]). The owner, and anyone who may sign the circle's manifest (an admin, or a role that manages
  /// the circle, its spaces or roles), is never held back by a space: they could take the override away themselves.
  Set<CirclePerm> permsIn(String id, String spaceSeed) {
    final base = permsOf(id);
    if (id.isEmpty || canSign(id)) return base;
    final space = spaces.where((s) => s.seed == spaceSeed).firstOrNull;
    final per = overrides[spaceSeed];
    if (space == null || per == null) return base;
    final open = CirclePerm.inSpace(space.kind).toSet();
    final out = {...base};
    final all = per[everyoneId];
    if (all != null) {
      out.removeAll(all.deny.intersection(open));
      out.addAll(all.allow.intersection(open));
    }
    final mine = [for (final r in rolesOf(id)) ?per[r.id]];
    out.removeAll({for (final o in mine) ...o.deny}.intersection(open));
    out.addAll({for (final o in mine) ...o.allow}.intersection(open));
    return out;
  }

  /// The bytes a signature covers.
  List<int> get signed => utf8.encode('ghost-circle manifest|$raw|${by ?? ''}|${byKey ?? ''}');

  /// As it goes round and is kept: the body as written, who signed it, their key and the signature.
  Map<String, Object?> toJson() => {'b': raw, 'by': by, 'k': byKey, 's': sig};

  /// The manifest [j] is; null where it is not one. Every field is checked for its type before it is used, since
  /// anyone in the circle, or a friend's invite, can send anything: a wrong one makes it no manifest, never an error
  /// in the room's listener.
  static CircleManifest? fromJson(Object? j) {
    if (j is! Map || j['b'] is! String) return null;
    final raw = j['b'] as String;
    if (raw.length > 60000) return null;
    final Object? b;
    try {
      b = jsonDecode(raw);
    } catch (_) {
      return null;
    }
    if (b is! Map || b['o'] is! String || b['v'] is! int || b['n'] is! String) return null;
    final version = b['v'] as int;
    final gv = b['gv'] is int ? b['gv'] as int : 0;
    if (version < 0 || version >= versionCap || gv < 0 || gv >= versionCap) return null;
    for (final f in ['by', 'k', 's']) {
      if (j[f] != null && j[f] is! String) return null;
    }
    final hue = b['h'] is String && circleHues.contains(b['h']) ? b['h'] as String : 'indigo';
    final picture = b['p'] is String && (b['p'] as String).length <= circlePictureMax ? b['p'] as String : null;
    final seen = <String>{};
    final sp = b['sp'] is List ? b['sp'] as List : const [];
    final g = b['g'] is Map ? b['g'] as Map : const {};
    return CircleManifest(
      owner: b['o'] as String,
      version: version,
      name: (b['n'] as String).trim().isEmpty ? 'Circle' : (b['n'] as String).trim(),
      hue: hue,
      icon: b['i'] is String ? b['i'] as String : 'users',
      picture: picture,
      // A space named twice is listed once.
      spaces: [for (final s in sp) if (CircleSpace.fromJson(s) case final x? when seen.add(x.seed)) x],
      adminGrants: {for (final e in g.entries) if (e.value is String) '${e.key}': e.value as String},
      grantsVersion: gv,
      grantsSig: b['gs'] is String ? b['gs'] as String : null,
      extra: {for (final e in b.entries) if (!_known.contains(e.key)) '${e.key}': e.value},
      by: j['by'] as String?,
      byKey: j['k'] as String?,
      sig: j['s'] as String?,
      raw: raw,
    );
  }

  /// Whether this manifest is one to believe for a circle whose owner key is [owner]: for that owner, signed by the key
  /// it names, by the owner or an admin the owner granted.
  bool trustedFor(String owner) {
    if (owner.isEmpty || this.owner != owner) return false;
    final by = this.by, key = byKey, sig = this.sig;
    if (by == null || key == null || sig == null) return false;
    try {
      final k = NetCrypto.unhex(key);
      if (NetCrypto.idOf(k) != by) return false;
      if (!NetCrypto.verify(k, signed, NetCrypto.unhex(sig))) return false;
    } catch (_) {
      return false;
    }
    return canSign(by);
  }

  /// Whether this may take [current]'s place in a circle owned by [owner]: newer, to be believed, and, signed by an
  /// admin, naming the same admins (only the owner makes or unmakes them).
  ///
  /// Newer is by the admin list's generation first, then by version ([grantsVersion]): an admin can't raise the
  /// generation, so the owner's change of admins outranks anything signed under the list before it. An admin's
  /// manifest carries the admin list as it stands, unchanged.
  bool follows(CircleManifest current, String owner) {
    if (!trustedFor(owner) || version >= versionCap) return false;
    final newer = grantsVersion != current.grantsVersion ? grantsVersion > current.grantsVersion : version > current.version;
    if (!newer) return false;
    if (by == ownerId || !current.isSigned) return true;
    return grantsVersion == current.grantsVersion && mapEquals(adminGrants, current.adminGrants);
  }

  /// The next version with [name], [hue], [icon], [picture] (or none, with [clearPicture]), [spaces] and [adminGrants]
  /// changed, to be signed ([signedBy]).
  ///
  /// A new admin list comes with its generation and the owner's signature ([grantsVersion], [grantsSig]); with
  /// [restart] the versions start again at 1 under it (it outranks every version of the list before).
  CircleManifest next({String? name, String? hue, String? icon, String? picture, bool clearPicture = false, List<CircleSpace>? spaces, Map<String, String>? adminGrants, int? grantsVersion, String? grantsSig, bool restart = false, Map<String, Object?>? extra}) => CircleManifest(
        owner: owner,
        version: restart ? 1 : version + 1,
        name: name ?? this.name,
        hue: hue ?? this.hue,
        icon: icon ?? this.icon,
        picture: clearPicture ? null : (picture ?? this.picture),
        spaces: spaces ?? this.spaces,
        adminGrants: adminGrants ?? this.adminGrants,
        grantsVersion: grantsVersion ?? this.grantsVersion,
        grantsSig: grantsVersion != null ? grantsSig : this.grantsSig,
        extra: extra ?? this.extra,
      );

  /// This manifest as [id] (with [publicKey]) signs it, with [sign] the signer.
  Future<CircleManifest> signedBy(String id, Uint8List publicKey, Future<Uint8List> Function(List<int>) sign) async {
    final unsigned = CircleManifest(owner: owner, version: version, name: name, hue: hue, icon: icon, picture: picture, spaces: spaces, adminGrants: adminGrants, grantsVersion: grantsVersion, grantsSig: grantsSig, extra: extra, by: id, byKey: NetCrypto.hex(publicKey), raw: raw);
    final s = await sign(unsigned.signed);
    return CircleManifest(owner: owner, version: version, name: name, hue: hue, icon: icon, picture: picture, spaces: spaces, adminGrants: adminGrants, grantsVersion: grantsVersion, grantsSig: grantsSig, extra: extra, by: id, byKey: NetCrypto.hex(publicKey), sig: NetCrypto.hex(s), raw: raw);
  }
}

/// A circle this device is in.
@immutable
class Circle {
  const Circle({required this.seed, required this.owner, required this.manifest, this.mine = false});

  /// 32 bytes in hex: the circle's room, token and key come from it.
  final String seed;

  /// The owner's public key (33 bytes in hex): whose manifests to believe. Empty where it was made with no key, and
  /// then no one can change it.
  final String owner;
  final CircleManifest manifest;

  /// Made on this device.
  final bool mine;

  String get name => manifest.name;
  String get hue => manifest.hue;
  String get icon => manifest.icon;
  String? get picture => manifest.picture;
  Map<String, Object?>? get pictureFile => manifest.pictureFile;
  String? get banner => manifest.banner;
  String? get inviteWord => manifest.inviteWord;

  /// Its spaces, in their order.
  List<CircleSpace> get spaces => manifest.ordered;

  // The circle's room on the hub, the token to join it, and the key what is said there is sealed with: each made
  // from the seed, so holding the seed is all it takes.
  Uint8List get _seed => NetCrypto.unhex(seed);
  String get room => NetCrypto.hex(NetCrypto.derive(_seed, 'circle room').sublist(0, 16));
  String get token => NetCrypto.hex(NetCrypto.derive(_seed, 'circle token'));
  Uint8List get key => NetCrypto.derive(_seed, 'circle key');

  /// Where the circle's own files are kept on the relay (its banner and its picture at full size, its soundboard's
  /// sounds): a space of no kind anyone opens, its seed the circle's, so whoever is in the circle can fetch what is there.
  VoiceChannel get bannerChannel => VoiceChannel(seed: seed, name: name, kind: SpaceKind.files, owner: owner, circle: seed);

  /// [space] as a space of this circle: owned by the circle's owner, marked as the circle's.
  VoiceChannel channelOf(CircleSpace space) => VoiceChannel(seed: space.seed, name: space.name, kind: space.kind, owner: owner, circle: seed);

  /// Every space of the circle, as spaces.
  List<VoiceChannel> get channels => [for (final s in spaces) channelOf(s)];

  /// The space of this circle whose seed is [seed], where it has one.
  CircleSpace? space(String seed) => manifest.spaces.where((s) => s.seed == seed).firstOrNull;

  Circle copyWith({CircleManifest? manifest, bool? mine}) => Circle(seed: seed, owner: owner, manifest: manifest ?? this.manifest, mine: mine ?? this.mine);

  /// This circle with [incoming] as its manifest, where it may follow the one held ([CircleManifest.follows]); null
  /// where it may not.
  Circle? merged(CircleManifest incoming) => incoming.follows(manifest, owner) ? copyWith(manifest: incoming) : null;

  /// A link to the circle, for anyone to open in the app (site/join explains it in a browser). The `c.` tells it from a
  /// space's link; the seed is after the #, which a browser never sends to any server. The owner's key follows the
  /// name, so whoever opens it knows whose list of spaces to believe.
  ///
  /// Made while the app uses a relay other than Uplink's own, it ends with that relay's host after an `@`
  /// (lib/invites/link_relay.dart; GMFB-25): a circle is rooms on one relay, and whoever opens the link has to know which.
  String get link => LinkRelay.mark('https://gogho.st/join/#c.$seed.${base64Url.encode(utf8.encode(name)).replaceAll('=', '')}${owner.isEmpty ? '' : '.$owner'}');

  /// The circle a [link] (or its part after the #) is, with a manifest of just its name until the real one comes; null
  /// where it is not a circle's.
  static Circle? fromLink(String link) {
    // The relay it names, where it names one, is whoever opens it to look at ([LinkRelay.elsewhere]): not part of what
    // the circle is.
    link = LinkRelay.split(link).link;
    final hash = link.contains('#') ? link.substring(link.indexOf('#') + 1) : link;
    final m = RegExp(r'^c\.([0-9a-f]{64})(?:\.([A-Za-z0-9_-]*))?(?:\.(0[23][0-9a-f]{64}))?$').firstMatch(hash);
    if (m == null) return null;
    var name = 'Circle';
    try {
      final b = m.group(2) ?? '';
      if (b.isNotEmpty) name = utf8.decode(base64Url.decode(base64Url.normalize(b)));
    } catch (_) {}
    final seed = m.group(1)!, owner = m.group(3) ?? '';
    return Circle(seed: seed, owner: owner, manifest: CircleManifest.placeholder(owner: owner, name: name.trim().isEmpty ? 'Circle' : name.trim(), hue: hueOfSeed(seed)));
  }

  Map<String, Object?> toJson() => {'s': seed, 'o': owner, 'm': manifest.toJson(), if (mine) 'mine': 1};

  /// The circle [j] is, as kept on the device or sent between a phone and its computer; null where its seed or
  /// manifest isn't one, or the manifest names another owner.
  static Circle? fromJson(Object? j) {
    if (j is! Map || j['s'] is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(j['s'] as String)) return null;
    final owner = j['o'] is String && RegExp(r'^0[23][0-9a-f]{64}$').hasMatch(j['o'] as String) ? j['o'] as String : '';
    final m = CircleManifest.fromJson(j['m']);
    if (m == null || m.owner != owner) return null;
    return Circle(seed: j['s'] as String, owner: owner, manifest: m, mine: j['mine'] == 1);
  }
}
