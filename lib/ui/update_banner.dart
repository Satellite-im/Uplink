import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../app_state.dart';
import '../art/app_icon.dart';
import '../art/lucide.g.dart';
import '../kit/settings_type.dart';
import '../sms.dart';
import 'common.dart';

/// At the top of the list of conversations, above its title and search, while a newer Uplink is waiting
/// (Matt, 2026-11-14: "move the update banner on desktop and mobile to show at the top of the sidebar above where it
/// says messages and has the search bar"): what version, Update now, and a cross. It is part of the list's column, so
/// it pushes the title down rather than lying over anything, and where the list stands beside a pane (a computer, a
/// folding phone opened out) it is as wide as the list. It used to hang over every page's content under its header.
/// The look itself is asked for as each page opens ([UpdateWatch]); this draws what it found. Put away with its
/// cross, it stays away for that version and comes back for the next.
class UpdateCard extends StatefulWidget {
  const UpdateCard({super.key});

  @override
  State<UpdateCard> createState() => _UpdateCardState();
}

class _UpdateCardState extends State<UpdateCard> {
  UpdateState _update = const UpdateState();
  StreamSubscription<UpdateState>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = Sms.instance.updates.stream.listen((u) {
      if (mounted) setState(() => _update = u);
    });
    Sms.instance.update().then((u) {
      if (mounted) setState(() => _update = u);
    }).catchError((_) {});
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  /// What the card says, or null where there is nothing to say: no newer version, or one being looked for.
  /// [short] leaves the app's name out, for a column too narrow for it.
  static String? line(UpdateState u, {bool short = false}) {
    final version = u.available;
    if (version == null || version.isEmpty) return null;
    final what = short ? version : 'Uplink $version';
    return switch (u.phase) {
      'available' => '$what is out',
      'ready' => '$what is ready to install',
      'downloading' => 'Getting $what${u.progress == null ? '' : ' · ${(u.progress! * 100).round()}%'}',
      'installing' => 'Installing $what…',
      _ => null,
    };
  }

  @override
  Widget build(BuildContext context) {
    final app = AppState.of(context);
    final t = context.tokens;
    final words = line(_update);
    final show = words != null && app.choice('update_dismissed', '') != _update.available;
    final busy = _update.phase == 'downloading' || _update.phase == 'installing';
    const white = Color(0xFFFFFFFF);
    return AnimatedSize(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child: !show
          ? const SizedBox(width: double.infinity)
          : LayoutBuilder(builder: (context, box) {
              // In a column that narrow the app's name is left out, so the words and the button still fit.
              final narrow = box.maxWidth < t.lenOf('24rem');
              final said = line(_update, short: narrow);
              return Padding(
                // As wide as the search field and the cards under it.
                padding: EdgeInsetsDirectional.fromSTEB(t.space(2), t.space(2), t.space(2), 0),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    // Indigo to violet to pink: the one thing on the page that is not the page's own colours.
                    gradient: const LinearGradient(begin: AlignmentDirectional.centerStart, end: AlignmentDirectional.centerEnd, colors: [Color(0xFF4F5BD5), Color(0xFF8B5CF6), Color(0xFFEC4899)]),
                    borderRadius: BorderRadius.circular(t.radius('xl')),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(t.radius('xl')),
                    child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      Padding(
                        padding: EdgeInsetsDirectional.fromSTEB(t.space(3), t.space(2), t.space(1), t.space(2)),
                        child: Row(children: [
                          Container(
                            width: t.lenOf('2rem'),
                            height: t.lenOf('2rem'),
                            decoration: const BoxDecoration(shape: BoxShape.circle, color: Color(0x33FFFFFF)),
                            alignment: Alignment.center,
                            child: AppIcon(busy ? Lucide.download : Lucide.sparkles, size: 16, color: white, wash: false),
                          ),
                          SizedBox(width: t.space(2)),
                          Expanded(child: Text(said ?? '', maxLines: 2, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('sm'), weight: 'semibold', color: white, height: 1.25))),
                          if (!busy)
                            GlacierPressable(
                              onPressed: () => _update.phase == 'ready' ? Sms.instance.updateInstall() : Sms.instance.updateCheck(install: true),
                              semanticLabel: 'Update now',
                              builder: (context, state) => Container(
                                margin: EdgeInsetsDirectional.only(start: t.space(2)),
                                padding: EdgeInsets.symmetric(horizontal: t.space(3), vertical: t.space(2)),
                                decoration: BoxDecoration(color: white.withValues(alpha: state.pressed ? 0.8 : 1), borderRadius: BorderRadius.circular(t.lenOf('1rem'))),
                                child: Text('Update now', style: pageText(t, t.fontSize('sm'), weight: 'bold', color: const Color(0xFF4F3FC4))),
                              ),
                            ),
                          // Put away at any time, a download going on behind it or not: it stays away for this
                          // version and comes back for the next.
                          IconTap(icon: Lucide.x, label: 'Not now', size: 18, box: t.lenOf('2.5rem'), color: white, onPressed: () => app.set('update_dismissed', _update.available ?? '')),
                        ]),
                      ),
                      if (_update.phase == 'downloading')
                        Align(
                          alignment: AlignmentDirectional.centerStart,
                          child: FractionallySizedBox(widthFactor: (_update.progress ?? 0.04).clamp(0.04, 1.0), child: Container(height: 3, color: white)),
                        ),
                    ]),
                  ),
                ),
              );
            }),
    );
  }
}

/// Asks for a look for a newer version each time a page opens or is come back to. Android answers no oftener than
/// every five minutes (Updater.pageCheck), so walking through the app is one question to the site, not one a page.
class UpdateWatch extends NavigatorObserver {
  void _look(Route<dynamic>? route) {
    if (route is PageRoute) Sms.instance.updateOnPage().catchError((_) {});
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) => _look(route);

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) => _look(previousRoute);
}
