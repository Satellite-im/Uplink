import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../../art/app_icon.dart';
import '../../art/lucide.g.dart';
import '../../kit/settings_type.dart';
import '../../ui/settings.dart';
import '../../ui/shell.dart';
import '../../ui/update_banner.dart';
import '../desk.dart';
import 'desk_settings.dart';
import 'wizard.dart';

/// The Mac's frame, with a phone paired or on its own: the app's one frame (lib/ui/shell.dart), as the phone has it, with what is the
/// Mac's own handed to it. Matt, 2026-11-14: "Unify the UI experience to match on desktop and mac as well the
/// desktop app should get all featues its missing from mobile and thr mobile app should gain the nav from desktop".
///
/// The list, the pane beside it, the navigation pill at the list's foot and every page are the phone's own screens;
/// what they ask is answered through the link to the phone (lib/desktop/remote.dart). This used to be a list of the
/// Mac's own, which read the conversations a second way and had fallen behind the phone's (no swiping, no choosing
/// several, no deleting). The Mac's own are three: how the phone is connected, kept with the list; what the pane
/// says with nothing open; and its sections of Settings (desk_settings.dart), which is otherwise the phone's too
/// (Matt, 2026-11-14: "desktop and mobile should also share the same settings pages").
class DeskShell extends StatefulWidget {
  const DeskShell({super.key});

  @override
  State<DeskShell> createState() => _DeskShellState();
}

class _DeskShellState extends State<DeskShell> {
  /// The computer's own sections of Settings, made once the link is in reach.
  DeskSettings? _settings;

  // The two sources handed to Settings, and taken out of it again when this goes.
  List<SettingsSection> _first() => _settings!.first();
  List<SettingsSection> _after() => _settings!.after();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_settings != null) return;
    // The Mac's own sections stand in Settings while a phone is paired: the phone before the app's own, what is
    // the Mac app's after them.
    final scope = DeskScope.of(context);
    final settings = _settings = DeskSettings(link: scope.link, calls: scope.calls, updates: scope.updates, envPeers: scope.envPeers);
    SettingsSources.add(_first, first: true, watch: settings.watch);
    SettingsSources.add(_after);
  }

  @override
  void dispose() {
    SettingsSources.remove(_first);
    SettingsSources.remove(_after);
    _settings?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // How the phone is connected is said in Settings › Your phone, not under the list's search (Matt, 2026-11-14:
    // "move the "connected to the relay" into the settings only"): the line is there only while the phone can't be
    // reached, which needs saying where you are.
    final scope = DeskScope.of(context);
    return ListenableBuilder(
      listenable: scope.link,
      builder: (context, _) => AppShell(
        // With no phone linked there is nothing to be connected to (lib/desktop/main.dart).
        status: scope.link.via != null || scope.link.phone == null ? null : LinkStatus(link: scope.link, waiting: scope.calls.waiting),
        nothing: (context) => const _Nothing(),
        // Each page that opens in the pane asks for a look for a newer version, as on the phone.
        paneObservers: _observers,
      ),
    );
  }

  final _observers = [UpdateWatch()];
}

/// The pane before a conversation is chosen.
class _Nothing extends StatelessWidget {
  const _Nothing();

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final scope = DeskScope.of(context);
    return ColoredBox(
      color: t.color('glacier-bg'),
      child: Center(
        child: ListenableBuilder(
          listenable: scope.link,
          builder: (context, _) => Column(mainAxisSize: MainAxisSize.min, children: [
            AppIcon(Lucide.ghost, size: 40, color: t.color('app-ink-4')),
            SizedBox(height: t.space(3)),
            Text('Choose a conversation', style: pageText(t, t.fontSize('lg'), weight: 'semibold', color: t.color('app-ink-2'))),
            SizedBox(height: t.space(1)),
            Text(
              scope.link.phone == null ? '' : 'Paired with ${scope.link.phone!.name}. What you send goes through it, sealed between the two.',
              textAlign: TextAlign.center,
              style: pageText(t, t.fontSize('sm'), color: t.color('app-ink-3')),
            ),
          ]),
        ),
      ),
    );
  }
}
