/// What a pack's button may ask of the app: the screen's own host, with every verb held to what the pack declared and
/// to the conversation the button was offered on. A refused call does nothing, and is told to the pack's registry and
/// to whoever keeps its errors, so a developer sees what their pack tried.
library;

import 'package:flutter/widgets.dart';

import '../../sms.dart';
import '../plugin.dart';
import 'format.dart';
import 'pack_plugin.dart';

/// How often a pack has spoken and copied lately. One GatedHost is made per press, so these live with the pack's
/// plugin, as an Expando keeps them, not with the host.
class _Lately {
  DateTime? said;
  final copied = <DateTime>[];
}

final Expando<_Lately> _lately = Expando('pack lately');

/// Made for one press of one button of [plugin]'s (PackPlugin._run): each verb goes on to [inner] only where the pack
/// lists its permission, within its limits, and for the conversation the button was offered on.
class GatedHost implements PluginHost {
  GatedHost(this.inner, {required this.plugin, required this.thread, Future<bool> Function(String url)? openLink}) : _openLink = openLink;
  final PluginHost inner;
  final PackPlugin plugin;
  final int thread;                                   // the conversation the action was offered on
  final Future<bool> Function(String url)? _openLink;

  static const _sayEvery = Duration(milliseconds: 1500);
  static const _copiesAMinute = 10;

  _Lately get _seen => _lately[plugin] ??= _Lately();

  bool _may(PackPermission p) => plugin.pack.permissions.contains(p);

  // Nothing else happens: the pack's registry hears of it (the Developer log, a pack in development's own list), and
  // its owner is told (InstalledPlugins does nothing more with a refusal: the error is its record).
  void _refuse(String verb) {
    plugin.onTrouble?.call(plugin, 'refused $verb');
    plugin.onError(plugin, StateError('$verb refused for ${plugin.id}'));
  }

  @override
  PluginPrefs get prefs => inner.prefs;

  /// Cut to 80; at most once every 1.5 s per pack, else dropped.
  @override
  void say(String words) {
    final now = plugin.clock();
    final said = _seen.said;
    if (said != null && now.difference(said) < _sayEvery) return _refuse('say');
    _seen.said = now;
    inner.say(_cut(words, 80));
  }

  /// Needs copy; cut to 200; at most 10 a minute per pack.
  @override
  void copy(String text, {String? say}) {
    if (!_may(PackPermission.copy)) return _refuse('copy');
    final now = plugin.clock();
    final copied = _seen.copied..removeWhere((t) => now.difference(t) >= const Duration(minutes: 1));
    if (copied.length >= _copiesAMinute) return _refuse('copy');
    copied.add(now);
    inner.copy(_cut(text, 200), say: say == null ? null : _cut(say, 80));
  }

  /// Refused: a pack's button never opens another conversation.
  @override
  void open(int thread) => _refuse('open');

  /// Needs markread; only the conversation it was offered on.
  @override
  Future<void> markRead(int thread) async {
    if (!_may(PackPermission.markRead) || thread != this.thread) return _refuse('markread');
    await inner.markRead(thread);
  }

  /// Needs move; only the conversation it was offered on, into Messages (null) or one of the pack's own tabs.
  @override
  void move(int thread, String? section) {
    if (!_may(PackPermission.move) || thread != this.thread || (section != null && !plugin.ownTabs.contains(section))) return _refuse('move');
    inner.move(thread, section);
  }

  /// Needs write; cut to 300. Nothing is sent: it goes into what the person is writing.
  @override
  void write(String text) {
    if (!_may(PackPermission.write)) return _refuse('write');
    inner.write(_cut(text, 300));
  }

  /// Refused: a pack has no pages of its own.
  @override
  void present(WidgetBuilder page) => _refuse('present');

  /// Refused: a pack never deletes.
  @override
  Future<void> deleteThread(int thread) async => _refuse('deleteThread');

  @override
  Future<void> reload() => inner.reload();

  /// Needs links; only the pack's one link; Sms.instance.openLink unless given.
  Future<void> openLink(String url) async {
    final links = plugin.pack.links;
    if (!_may(PackPermission.links) || links.isEmpty || url != links.first) return _refuse('link');
    await (_openLink ?? Sms.instance.openLink)(url);
  }
}

// [s] cut to [n] UTF-16 units at most, never between the two halves of a surrogate pair.
String _cut(String s, int n) {
  if (s.length <= n) return s;
  final last = s.codeUnitAt(n - 1);
  return s.substring(0, last >= 0xD800 && last <= 0xDBFF ? n - 1 : n);
}
