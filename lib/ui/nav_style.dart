/// How the app is got round (Matt, 2026-11-19: "work on a unified navigation across the whole app instead of it
/// changing navigations on every page ... a few different options including a navigation rail version of the app. It
/// should include the circles icons like discord and slack does ... give me a setting in developer settings to switch
/// between the different views"). Chosen in Settings › Developer; lib/ui/shell.dart draws it.
library;

import '../app_state.dart';
import '../art/app_icon.dart';
import '../art/lucide.g.dart';

/// The ways round the app, each with the name, the line and the icon Settings › Developer shows for it.
enum NavStyle {
  /// As it was: the pill, which a circle swaps for its own dock, which Settings and the Marketplace hide on a phone,
  /// and which a space's call beside the list gives way to.
  classic('Changing dock', 'The earlier way: the pill becomes a circle\'s own dock inside a circle and goes away under Settings and the Marketplace on a phone.', Lucide.repeat),

  /// The app's own pill, the same six rings on every page: a circle's places are in its menu, under its name.
  dock('One dock', 'The same pill on every page: New, Messages, Contacts, Archive, Marketplace and Settings. A circle\'s members, new spaces and settings are in its menu, under its name.', Lucide.layoutGrid),

  /// A column at the window's left on every page, as Discord's and Slack's: Home, each circle's face, a way to start
  /// or join one, and the app's places at its foot.
  rail('Rail with circles', 'A column down the left of every page, as Discord and Slack have: Home, your circles as their faces, then New, Contacts, Archive, Marketplace and Settings at the foot.', Lucide.panelLeft);

  const NavStyle(this.label, this.description, this.icon);
  final String label;
  final String description;
  final LucideIcon icon;

  static const pref = 'dev_nav_style';

  /// What a device that never chose has: the rail (Matt, 2026-11-19, asked which new installs should get: "Rail with
  /// circles").
  static const fallback = NavStyle.rail;

  /// The one chosen on this device, kept under [pref] by name; [fallback] where none, or a name no longer known.
  static NavStyle of(AppState app) {
    final name = app.choice(pref, '');
    for (final s in values) {
      if (s.name == name) return s;
    }
    return fallback;
  }

  /// Every page has the same navigation: no circle's dock swapped in, nothing hidden under Settings.
  bool get unified => this != NavStyle.classic;
}
