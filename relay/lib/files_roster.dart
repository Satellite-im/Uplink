import 'dart:convert';

import 'p256.dart';
import 'sha256.dart';

/// A Files space's roster as the relay checks it, to let a moderator's delete free the file's blob (Matt, 2026-11-17:
/// "Finish the missing pieces that went unfinished" (of Circles and Files spaces, released in 0.9.2)). Before, only
/// whoever added a file or the space's owner could have the relay let its blob go, so a moderator's delete took the
/// file off everyone's list while the sealed blob stayed downloadable, and counted against the space, for up to ninety
/// days.
///
/// A device asking for a delete it may make as a moderator or an admin sends the roster it holds: the exact bytes the
/// roster's author signed (the app's Roster.signed, lib/voice/roles.dart) and the signature. The relay believes it the
/// way every device does (Roster.trustedFor): for the owner key the relay already holds for the space (taken only from
/// the owner's own signed request), signed by the key it names, which is the owner or an admin whose being one the
/// owner signed, naming no admin the owner didn't. It then asks of it what the app's RosterRules does of a delete:
/// whether the asker has Manage files and a higher role than the uploader, and is not banned.
///
/// What it sees: the roster itself (who has which role by their hub id, the roles' names and permissions, who is
/// banned or muted), which it already half knows, since it is the hub those ids talk through. Never a file, a name of
/// one, the seed or any key that opens anything.
///
/// Old rosters: a demoted moderator still holds the roster from when they were one, signed and true then. So the relay
/// keeps the highest version it has believed for each space, the hash of that version's bytes and its admins
/// (relay/lib/files.dart's `_rosterOf`), and refuses an older roster, another at the same version, and one that skips
/// ahead signed by someone who isn't the owner or one of those admins: an admin's grant can't be taken back, so a
/// demoted admin could otherwise sign their way back in at any version. The owner's and admins' devices say each new
/// version as they open the space (`rv`), without the roster itself.
class FilesRoster {
  FilesRoster._(this.version, this.owner, this.by, this._roles, this._assigned, this._banned, this._newcomer, this._granted);

  /// What a roster's signature covers starts with these words (roles.dart's Roster.signed).
  static const _prefix = 'ghost-hangout roster|';

  /// The most admins a roster may name for the relay to check their grants (each is a signature to check).
  static const mostAdmins = 64;

  final int version;

  /// The owner's hub id, and the hub id of who signed it.
  final String owner;
  final String by;

  // The roles by their id; each member's role id, by hub id; who is banned; the role someone not named has; and the
  // admins whose grant from the owner checked out.
  final Map<String, _Role> _roles;
  final Map<String, String> _assigned;
  final Set<String> _banned;
  final String _newcomer;
  final Set<String> _granted;

  /// The admins it names, each with the owner's grant.
  Set<String> get admins => {..._granted};

  /// The hub id of a public key: the first 16 bytes of its SHA-256, in hex (the app's NetCrypto.idOf).
  static String idOf(List<int> key) => hexOf(sha256(key).sublist(0, 16));

  /// The bytes of lower-case hex; a FormatException for anything else.
  static List<int> unhex(String text) => _unhex(text);

  static List<int> _unhex(String text) {
    if (text.length.isOdd || !RegExp(r'^[0-9a-f]*$').hasMatch(text)) throw const FormatException('not hex');
    return [for (var i = 0; i < text.length; i += 2) int.parse(text.substring(i, i + 2), radix: 16)];
  }

  /// The roster in [signed] (with its author's [sig], 64 bytes r then s), where it is one to believe for a space whose
  /// owner key is [owner] (hex, 33 bytes); null where it is not.
  static FilesRoster? check({required String owner, required List<int> signed, required List<int> sig}) {
    if (owner.isEmpty) return null;
    try {
      final text = utf8.decode(signed);
      if (!text.startsWith(_prefix)) return null;
      final m = jsonDecode(text.substring(_prefix.length));
      if (m is! Map || m['o'] != owner || m['v'] is! int) return null;
      final ownerKey = _unhex(owner);
      final ownerId = idOf(ownerKey);
      final by = m['by'], key = m['k'];
      if (by is! String || key is! String) return null;
      final k = _unhex(key);
      if (idOf(k) != by) return null;
      if (!P256.verify(k, signed, sig)) return null;

      // The roles as named; none at all is the app's defaults for a voice space, whose roles have no Files permissions.
      final roles = <String, _Role>{};
      for (final r in (m['roles'] as List? ?? const [])) {
        if (r is! Map || r['id'] is! String || r['r'] is! int || r['p'] is! List) continue;
        roles[r['id'] as String] = _Role(r['r'] as int, {for (final p in r['p'] as List) '$p'});
      }
      if (roles.isEmpty) {
        roles.addAll({'admin': _Role(30, const {}), 'moderator': _Role(20, const {}), 'member': _Role(10, const {})});
      }
      final assigned = <String, String>{for (final e in (m['a'] as Map? ?? const {}).entries) '${e.key}': '${e.value}'};
      final grants = <String, String>{for (final e in (m['g'] as Map? ?? const {}).entries) '${e.key}': '${e.value}'};
      final banned = {for (final b in (m['b'] as List? ?? const [])) '$b'};
      final muted = {for (final b in (m['m'] as List? ?? const [])) '$b'};
      final newcomer = m['n'] is String ? m['n'] as String : 'member';

      // Every admin named has the owner's grant (roles.dart's grantMessage), checked once each.
      final admins = {for (final e in assigned.entries) if (e.value == 'admin') e.key};
      if (admins.length > mostAdmins) return null;
      final granted = <String>{};
      for (final id in admins) {
        final g = grants[id];
        if (g == null) return null;
        if (!P256.verify(ownerKey, utf8.encode('ghost-hangout admin|$owner|$id'), _unhex(g))) return null;
        granted.add(id);
      }
      if (banned.contains(ownerId) || muted.contains(ownerId)) return null;
      if (!roles.containsKey('admin') || !roles.containsKey(newcomer) || newcomer == 'admin') return null;
      final roster = FilesRoster._(m['v'] as int, ownerId, by, roles, assigned, banned, newcomer, granted);
      // Signed by the owner or an admin the owner made.
      if (by != ownerId && roster._roleOf(by).id != 'admin') return null;
      return roster;
    } catch (_) {
      return null;
    }
  }

  /// The role [id] has: the owner is always admin; someone named admin without the owner's grant is a newcomer; a role
  /// the roster doesn't have is member.
  ({String id, _Role role}) _roleOf(String id) {
    if (id == owner) return (id: 'admin', role: _roles['admin']!);
    var named = _assigned[id] ?? _newcomer;
    if (named == 'admin' && !_granted.contains(id)) named = _newcomer == 'admin' ? 'member' : _newcomer;
    final role = _roles[named] ?? _roles['member'];
    if (role != null) return (id: _roles.containsKey(named) ? named : 'member', role: role);
    return (id: 'member', role: _Role(10, const {}));
  }

  /// Whether [actor] may remove a file [uploader] added, as the app's RosterRules.mayChange has it: never while banned;
  /// their own, or the owner; else Manage files and a higher role than the uploader's (the owner's files, nobody's).
  bool mayRemove(String actor, String uploader) {
    if (_banned.contains(actor)) return false;
    if (actor == uploader || actor == owner) return true;
    if (!_roleOf(actor).role.perms.contains('manageFiles')) return false;
    if (uploader == owner) return false;
    return _roleOf(actor).role.rank > _roleOf(uploader).role.rank;
  }
}

/// A role: its rank (a higher one outranks a lower) and the permissions it gives, by name.
class _Role {
  _Role(this.rank, this.perms);
  final int rank;
  final Set<String> perms;
}
