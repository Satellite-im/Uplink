/// Links opened into the computer's app (Matt, 2026-11-19: "make a route to allow people to click a link on their phone
/// or desktop to join a circle"): the invite page's Open in Uplink (site/join) opens
/// `ghostmsg://join/#c.…`, which the Mac hands over through its AppDelegate and Windows through the copy of the app
/// it starts (windows/runner/links.cpp), Linux through the copy of the app the desktop starts (linux/runner/links.cc)
/// and an iPhone through its scene (ios/Runner/SceneDelegate.swift), all on "ghost_desktop/links".
///
/// A circle's link, with the app set up: its invite raised (Join and Not now), as on a phone. Before that (the welcome,
/// pairing): held, and the circle joined and opened once the app is set up (lib/circles/pending_link.dart).
library;

import 'dart:async';

import 'package:flutter/services.dart';

import '../circles/pending_link.dart';
import '../friends/add_link.dart' show addLinkUsername;
import '../ui/add_me.dart' show askToAdd;
import '../ui/circles/circle_invite_card.dart' show openCircleLink;
import '../ui/common.dart' show toast;
import '../ui/relay_host_section.dart' show askToUseRelay;
import '../ui/shell.dart';

/// Hears the links the system hands the app, and opens the circle each names.
class DeskLinks {
  DeskLinks._();

  static const _channel = MethodChannel('ghost_desktop/links');
  static bool _started = false;

  /// The app's own scheme, as the invite page writes it.
  static const scheme = 'ghostmsg://join/';

  /// The link in [url] as the app knows a circle's: `ghostmsg://join/#c.…` is `https://gogho.st/join/#c.…`.
  static String normalise(String url) {
    final u = url.trim();
    if (u.toLowerCase().startsWith(scheme)) return 'https://gogho.st/join/${u.substring(scheme.length)}';
    if (u.toLowerCase().startsWith('ghostmsg://join')) return 'https://gogho.st/join/${u.substring('ghostmsg://join'.length)}';
    return u;
  }

  /// Whether [url] is someone's add-me link (lib/friends/add_link.dart), in the app's own scheme or the site's.
  static bool isAddLink(String url) => !url.trim().toLowerCase().startsWith('ghostmsg://join') && addLinkUsername(url) != null;

  /// An add-me link that came before the frame was up, the last one; for this run only.
  static String? _heldAdd;

  /// The add-me link held from before the frame was up, and forgotten; null where none is. The frame asks once it is
  /// on the screen (lib/ui/shell.dart), and asks to add them then.
  static String? takeHeldAdd() {
    final link = _heldAdd;
    _heldAdd = null;
    return link;
  }

  /// Listens for links, and takes any the app was started with.
  static Future<void> start() async {
    if (_started) return;
    _started = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'open' && call.arguments is String) await opened(call.arguments as String);
      return null;
    });
    try {
      final waiting = await _channel.invokeListMethod<String>('take');
      for (final url in waiting ?? const <String>[]) {
        await opened(url);
      }
    } catch (_) {
      // A build without the native half: no links come.
    }
  }

  /// [url] was opened into the app.
  static Future<void> opened(String url) async {
    // A relay's link (`ghostmsg://relay?a=…`, a relay hosted from someone's app; lib/relay_host): asked whether to use
    // it, once the app is set up; before that, there is no relay to switch from, and it is let go.
    if (url.trim().toLowerCase().startsWith('ghostmsg://relay')) {
      final shell = AppShellState.live;
      if (shell != null && shell.mounted) await askToUseRelay(shell.context, url.trim());
      return;
    }
    // Someone's add-me link (`ghostmsg://add/NAME#KEY`, from the page's Open in Uplink, site/add; GMFB-34):
    // asked first, then the friend request, as on a phone. It was taken for a circle's link here, and answered "That
    // circle link isn't complete". One that comes before the frame is up (the app started by the link, as a computer
    // or an iPhone is when it wasn't running, or still at the welcome) is held until it is ([takeHeldAdd]).
    if (isAddLink(url)) {
      final shell = AppShellState.live;
      if (shell != null && shell.mounted) {
        askToAdd(shell.context, url.trim());
      } else {
        _heldAdd = url.trim();
      }
      return;
    }
    // Any other of the app's own links (a computer's pairing link, ghostmsg://pair/…, read by an iPhone's camera) is
    // not a circle's, and is let go rather than answered "That circle link isn't complete".
    if (url.trim().toLowerCase().startsWith('ghostmsg:') && !url.trim().toLowerCase().startsWith('ghostmsg://join')) return;
    final link = normalise(url);
    final shell = AppShellState.live;
    if (shell == null || !shell.mounted) {
      // Not set up yet: once it is.
      await PendingCircleLink.hold(link);
      return;
    }
    if (!openCircleLink(shell, link) && shell.mounted) toast(shell.context, 'That circle link isn\'t complete. Ask for it again.');
  }
}
