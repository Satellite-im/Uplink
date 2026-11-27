/// The dock while a circle is open (Matt, 2026-11-17: "add a 'home' button on the dock while on the space and
/// transform all the icons inside the dock to be related to the circle instead of the whole app"): Home first, back
/// to the conversations with the circle closed, then the circle's own places. The frame (lib/ui/shell.dart) swaps
/// these in for the app's own rings while a circle is in the list's place, on a phone and a computer alike, and
/// answers them (AppShellState's circle dock). It wears the circle's face at its head and the circle's hue on the
/// ring shown, so it reads as the circle's at a glance and not as the app's own pill with other icons (Dial-Up's
/// taskbar stays as it is).
library;

import '../../art/app_icon.dart';
import '../../art/lucide.g.dart';
import '../../circles/circles.dart';
import '../nav_bar.dart';

/// Lucide's house (lucide-static 1.70.0, ISC licence), which Ghost.md's set has not: Home on the circle's dock.
const houseIcon = LucideIcon.phosphor('house', 'M216,120v96H152V152H104v64H40V120a8,8,0,0,1,2.34-5.66l80-80a8,8,0,0,1,11.32,0l80,80A8,8,0,0,1,216,120Z', 'M219.31,108.68l-80-80a16,16,0,0,0-22.62,0l-80,80A15.87,15.87,0,0,0,32,120v96a8,8,0,0,0,8,8h64a8,8,0,0,0,8-8V160h32v56a8,8,0,0,0,8,8h64a8,8,0,0,0,8-8V120A15.87,15.87,0,0,0,219.31,108.68ZM208,208H160V152a8,8,0,0,0-8-8H104a8,8,0,0,0-8,8v56H48V120l80-80,80,80Z');

/// The rings' ids, which the frame answers.
abstract final class CircleDock {
  static const home = 'home';
  static const spaces = 'circle-spaces';
  static const members = 'circle-members';
  static const newSpace = 'circle-new';
  static const settings = 'circle-settings';
  static const invite = 'circle-invite';

  /// The rings for [c]: Home, its spaces, its members (the drawer), a new space where this device may add one, and the
  /// app's Settings. Read by the name the circle's own menu gives them.
  static List<NavItem> items(Circle c, {required bool canEdit}) => [
        const NavItem(id: home, icon: houseIcon, label: 'Home'),
        const NavItem(id: spaces, icon: Lucide.layoutList, label: 'Spaces'),
        const NavItem(id: members, icon: Lucide.users, label: 'Members'),
        // No Invite of its own: adding people is in the Members drawer (Matt, 2026-11-18: "remove the add user from the header
        // ... and in the dock and simply leave it under the users drawer").
        // "New" on Dial-Up's taskbar, where "New space" was drawn smaller than the other words to fit.
        if (canEdit) const NavItem(id: newSpace, icon: Lucide.plus, label: 'New space', short: 'New'),
        // The app's Settings (Matt, 2026-11-18); the circle's own are in its menu, under its name.
        const NavItem(id: settings, icon: Lucide.settings, label: 'Settings'),
      ];
}
