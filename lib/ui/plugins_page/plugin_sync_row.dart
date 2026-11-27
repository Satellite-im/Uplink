import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../../account/account.dart';
import '../../app_state.dart';
import '../../art/app_icon.dart';
import '../../art/lucide.g.dart';
import '../../kit/settings_kit.dart';
import '../../plugins/plugin_sync.dart';

/// "Sync plugins across my devices" (GMFB-9, @kevin: "It would be convenient to sync plugins across devices at least
/// for the messaging apps and stuff"): in Settings › Plugins and under the Marketplace's Added. On unless switched off;
/// without an Uplink account it says so and nothing is synced (lib/plugins/plugin_sync.dart).
Widget pluginSyncSection(BuildContext context, AppState app) => ListenableBuilder(
      listenable: Listenable.merge([app, Account.instance]),
      builder: (context, _) {
        final account = Account.instance.signedIn;
        final on = app.choice(PluginSync.onKey, '') != 'off';
        return PaneSection(
          key: const ValueKey('plugin-sync'),
          title: 'Your devices',
          children: [
            SettingRow(
              icon: const AppIcon(Lucide.refreshCw, size: 18),
              label: 'Sync plugins across my devices',
              hint: Text(account
                  ? 'Plugins you add or remove here are added or removed on your other devices signed in to your Uplink account. Sign-ins stay on each device: a network added elsewhere asks you to sign in here.'
                  : 'Sign in to an Uplink account to sync which plugins are on across your devices.'),
              disabled: !account,
              control: GlacierSwitch(
                checked: account && on,
                ariaLabel: 'Sync plugins across my devices',
                onCheckedChange: account
                    ? (yes) {
                        app.set(PluginSync.onKey, yes ? 'on' : 'off');
                        PluginSync.instance.setEnabled(yes);
                      }
                    : null,
              ),
            ),
          ],
        );
      },
    );
