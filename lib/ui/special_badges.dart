/// Special badges (Matt, 2026-11-19: "allow me to see all users who signed up on the relay and issue special badges and
/// souls"): given from the admin page (lib/ui/admin_page.dart) and kept by the relay (relay/lib/handles.dart
/// `specialBadges`), drawn beside a person's name where the verified-number badge is, and named on their profile card.
/// Who has which comes with the verified-number answer (Me.badges), so drawing them asks the relay nothing more.
library;

import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../art/app_icon.dart';
import '../art/lucide.g.dart';
import '../kit/settings_type.dart';
import '../me/me.dart';
import 'plugins_page/plugin_art.dart' show PluginHues;

/// One badge: its id on the relay, what it is called, its icon and colour.
@immutable
class SpecialBadge {
  const SpecialBadge(this.id, this.name, this.about, this.icon, this.hue);
  final String id;
  final String name;
  final String about;
  final LucideIcon icon;
  final String hue;
}

/// A bug and a heart, which the app's sets don't carry (Phosphor's, by tool/phosphor.mjs).
const _bug = LucideIcon.phosphor('bug', 'M208,128v16a80,80,0,0,1-160,0V128Z', 'M144,92a12,12,0,1,1,12,12A12,12,0,0,1,144,92ZM100,80a12,12,0,1,0,12,12A12,12,0,0,0,100,80Zm116,64A87.76,87.76,0,0,1,213,167l22.24,9.72A8,8,0,0,1,232,192a7.89,7.89,0,0,1-3.2-.67L207.38,182a88,88,0,0,1-158.76,0L27.2,191.33A7.89,7.89,0,0,1,24,192a8,8,0,0,1-3.2-15.33L43,167A87.76,87.76,0,0,1,40,144v-8H16a8,8,0,0,1,0-16H40v-8a87.76,87.76,0,0,1,3-23L20.8,79.33a8,8,0,1,1,6.4-14.66L48.62,74a88,88,0,0,1,158.76,0l21.42-9.36a8,8,0,0,1,6.4,14.66L213,89.05a87.76,87.76,0,0,1,3,23v8h24a8,8,0,0,1,0,16H216ZM56,120H200v-8a72,72,0,0,0-144,0Zm64,95.54V136H56v8A72.08,72.08,0,0,0,120,215.54ZM200,144v-8H136v79.54A72.08,72.08,0,0,0,200,144Z');
const _heart = LucideIcon.phosphor('heart', 'M232,102c0,66-104,122-104,122S24,168,24,102A54,54,0,0,1,78,48c22.59,0,41.94,12.31,50,32,8.06-19.69,27.41-32,50-32A54,54,0,0,1,232,102Z', 'M178,40c-20.65,0-38.73,8.88-50,23.89C116.73,48.88,98.65,40,78,40a62.07,62.07,0,0,0-62,62c0,70,103.79,126.66,108.21,129a8,8,0,0,0,7.58,0C136.21,228.66,240,172,240,102A62.07,62.07,0,0,0,178,40ZM128,214.8C109.74,204.16,32,155.69,32,102A46.06,46.06,0,0,1,78,56c19.45,0,35.78,10.36,42.6,27a8,8,0,0,0,14.8,0c6.82-16.67,23.15-27,42.6-27a46.06,46.06,0,0,1,46,46C224,155.61,146.24,204.15,128,214.8Z');

/// The badges there are, in the order they are drawn (the relay's `specialBadges`).
const specialBadges = [
  SpecialBadge('team', 'Uplink team', 'Makes Uplink', Lucide.ghost, 'indigo'),
  SpecialBadge('founder', 'Founder', 'Here from the very start', Lucide.crown, 'amber'),
  SpecialBadge('bughunter', 'Bug hunter', 'Found and reported bugs', _bug, 'coral'),
  SpecialBadge('alpha', 'Alpha tester', 'Tried it before anyone else', Lucide.flaskConical, 'purple'),
  SpecialBadge('helper', 'Helper', 'Helps others find their way', Lucide.sparkles, 'teal'),
  SpecialBadge('supporter', 'Supporter', 'Supports Uplink', _heart, 'rose'),
];

/// The badge with this id; null for one this build doesn't know.
SpecialBadge? specialBadge(String id) => specialBadges.where((b) => b.id == id).firstOrNull;

/// [ids] in the order [specialBadges] draws them, unknown ones left out.
List<SpecialBadge> specialBadgesOf(Iterable<String> ids) => [for (final b in specialBadges) if (ids.contains(b.id)) b];

/// Who has which badge, as the relay last said with its verified-number answer: by `i:<id>` and `u:<username>`.
class SpecialBadges extends ChangeNotifier {
  SpecialBadges() {
    Me.onSpecial ??= (ids, names, byId, byName, showById, showByName) =>
        instance.heard(ids: ids, names: names, byId: byId, byName: byName, showById: showById, showByName: showByName);
  }

  static SpecialBadges instance = SpecialBadges();

  final Map<String, List<String>> _known = {};

  /// What the relay said of [ids] and [names] it was asked of: those with badges, and none for the rest.
  void heard({
    required List<String> ids,
    required List<String> names,
    Map<String, List<String>> byId = const {},
    Map<String, List<String>> byName = const {},
    Map<String, String> showById = const {},
    Map<String, String> showByName = const {},
  }) {
    var changed = false;
    void show(String key, String? now) {
      if (_shown[key] != now) changed = true;
      if (now == null) {
        _shown.remove(key);
      } else {
        _shown[key] = now;
      }
    }

    for (final i in ids) {
      show('i:$i', showById[i]);
    }
    for (final n in names) {
      show('u:${n.toLowerCase()}', showByName[n.toLowerCase()]);
    }
    void put(String key, List<String> now) {
      final had = _known[key];
      if (had == null || had.join(',') != now.join(',')) changed = true;
      _known[key] = now;
    }

    for (final i in ids) {
      put('i:$i', byId[i] ?? const []);
    }
    for (final n in names) {
      put('u:${n.toLowerCase()}', byName[n.toLowerCase()] ?? byName[n] ?? const []);
    }
    if (changed) notifyListeners();
  }

  /// The one badge each shows beside their name, as the relay said: by `i:<id>` and `u:<username>`.
  final Map<String, String> _shown = {};

  /// The badge [id] (or the person with [username]) shows beside their name: the one they chose, else their highest;
  /// this person's own for [me]. Null for none.
  SpecialBadge? shownOf(String id, {String? username, bool me = false}) {
    final all = of(id, username: username, me: me);
    if (all.isEmpty) return null;
    final u = username == null || username.isEmpty ? null : 'u:${username.toLowerCase()}';
    final chosen = me ? Me.instance.showcase : (_shown['i:$id'] ?? (u == null ? null : _shown[u]));
    return all.where((b) => b.id == chosen).firstOrNull ?? all.first;
  }

  /// The badges [id] (or the person with [username]) has, as far as is known; this person's own for [me].
  List<SpecialBadge> of(String id, {String? username, bool me = false}) {
    if (me) return specialBadgesOf(Me.instance.special);
    final u = username == null || username.isEmpty ? null : 'u:${username.toLowerCase()}';
    return specialBadgesOf({...?_known['i:$id'], if (u != null) ...?_known[u]});
  }

  @visibleForTesting
  void reset() {
    _known.clear();
    _shown.clear();
  }
}

/// The one badge a person shows beside their name (their choice, else their highest), its icon; nothing where they have
/// none (Matt, 2026-11-20: "allow the user to choose one badge to showcase next to their names don't show them all").
class SpecialBadgeMarks extends StatelessWidget {
  const SpecialBadgeMarks({super.key, required this.id, this.username, this.me = false, this.size = 14});
  final String id;
  final String? username;
  final bool me;
  final double size;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([SpecialBadges.instance, if (me) Me.instance]),
      builder: (context, _) {
        final b = SpecialBadges.instance.shownOf(id, username: username, me: me);
        if (b == null) return const SizedBox.shrink();
        final t = context.tokens;
        return Padding(
          key: ValueKey('special-${b.id}-$id'),
          padding: EdgeInsetsDirectional.only(start: t.space(1)),
          child: Semantics(label: b.name, child: AppIcon(b.icon, size: size, color: PluginHues.of(t, b.hue).accent)),
        );
      },
    );
  }
}

/// A badge as a chip, named, for a profile card and the admin page: its icon on its colour's wash, and its name.
class SpecialBadgeChip extends StatelessWidget {
  const SpecialBadgeChip({super.key, required this.badge, this.on = true});
  final SpecialBadge badge;
  final bool on;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final hues = PluginHues.of(t, badge.hue);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: t.space(2), vertical: t.space(1)),
      decoration: BoxDecoration(
        color: on ? hues.wash : const Color(0x00000000),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: on ? hues.accent.withValues(alpha: 0.4) : t.color('app-rule')),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        AppIcon(badge.icon, size: 14, color: on ? hues.accent : t.color('app-ink-3')),
        SizedBox(width: t.space(1)),
        Text(badge.name, style: pageText(t, t.fontSize('xs'), weight: 'semibold', color: on ? t.color('app-ink') : t.color('app-ink-3'))),
      ]),
    );
  }
}
