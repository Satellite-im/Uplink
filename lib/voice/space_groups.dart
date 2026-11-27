import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../app_state.dart';
import '../net/crypto.dart';

/// Groups of spaces in the Spaces tab, named by the person (Matt, 2026-11-16: "add grouping options to spaces so we
/// can group all of a servers spaces under one group"): each a heading the spaces under it can be folded away beneath.
/// Spaces in no group stand at the top, as before. A linked Discord server is a group of its own (lib/voice/discord.dart),
/// not one of these.
///
/// Kept with the device's choices (`space_groups`): the groups in order, which space is in which (by its seed), and which
/// are folded.
@immutable
class SpaceGroup {
  const SpaceGroup(this.id, this.name);
  final String id;
  final String name;

  Map<String, String> toJson() => {'id': id, 'n': name};
}

/// This device's groups of spaces: makes, renames, deletes and folds them, puts spaces in them, and saves each change.
class SpaceGroups extends ChangeNotifier {
  SpaceGroups._();
  static final instance = SpaceGroups._();

  AppState? _app;
  List<SpaceGroup> _groups = const [];
  /// Which group each space is in: a space's seed to its group's id.
  final Map<String, String> _of = {};
  final Set<String> _folded = {};

  List<SpaceGroup> get groups => _groups;

  /// Loads what was kept in [app]'s choices; a space filed under a group that is gone is left in none. Only the first
  /// call does anything.
  void start(AppState app) {
    if (_app != null) return;
    _app = app;
    try {
      final j = jsonDecode(app.choice('space_groups', '{}')) as Map;
      _groups = [
        for (final g in (j['groups'] as List? ?? const []))
          if (g is Map && g['id'] is String && g['n'] is String) SpaceGroup(g['id'] as String, g['n'] as String),
      ];
      final ids = {for (final g in _groups) g.id};
      for (final e in ((j['of'] as Map?) ?? const {}).entries) {
        if (ids.contains(e.value)) _of['${e.key}'] = '${e.value}';
      }
      _folded.addAll([for (final f in (j['folded'] as List? ?? const [])) '$f']);
    } catch (_) {}
    notifyListeners();
  }

  @visibleForTesting
  void reset() {
    _app = null;
    _groups = const [];
    _of.clear();
    _folded.clear();
  }

  void _keep() {
    _app?.set('space_groups', jsonEncode({'groups': [for (final g in _groups) g.toJson()], 'of': _of, 'folded': _folded.toList()}));
    notifyListeners();
  }

  /// The group [seed]'s space is in, or null.
  String? groupOf(String seed) => _of[seed];

  SpaceGroup? byId(String id) => _groups.where((g) => g.id == id).firstOrNull;

  /// A new group named [name]; its id.
  String make(String name) {
    final id = NetCrypto.hex(NetCrypto.randomBytes(6));
    _groups = [..._groups, SpaceGroup(id, name.trim().isEmpty ? 'Group' : name.trim())];
    _keep();
    return id;
  }

  void rename(String id, String name) {
    if (name.trim().isEmpty) return;
    _groups = [for (final g in _groups) g.id == id ? SpaceGroup(id, name.trim()) : g];
    _keep();
  }

  /// Takes the group away; its spaces go back to the top.
  void delete(String id) {
    _groups = [for (final g in _groups) if (g.id != id) g];
    _of.removeWhere((_, g) => g == id);
    _folded.remove(id);
    _keep();
  }

  /// Puts [seed]'s space in [groupId], or in no group.
  void move(String seed, String? groupId) {
    if (groupId == null || byId(groupId) == null) {
      _of.remove(seed);
    } else {
      _of[seed] = groupId;
    }
    _keep();
  }

  /// Whether the group with [id] (one of these, or a Discord server's `discord:<guild>`) is folded away.
  bool folded(String id) => _folded.contains(id);

  /// Folds the group with [id] away, or opens it again.
  void fold(String id, bool on) {
    on ? _folded.add(id) : _folded.remove(id);
    _keep();
  }
}
