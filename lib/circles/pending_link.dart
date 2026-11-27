/// A circle's invite link held until the app is set up (Matt, 2026-11-19: "make a route to allow people to click a link
/// on their phone or desktop to join a circle, have it prompt them to download the app if it's not downloaded already
/// and then have it redirect to the circle after they sign up for their account").
///
/// Two ways one comes to be held:
/// - opened while the app is still being set up (the walkthrough on a phone, the welcome on a computer), when there is
///   no list to show it in yet;
/// - copied by the invite page (site/join) as its Get the app button is pressed: read from the clipboard once, the
///   first time the app is set up on this install, where that is a circle's link.
///
/// Once the app is set up (the list on the screen, lib/ui/shell.dart), the held link is taken: the circle joined and
/// opened, as the person asked by opening it or by getting the app for it.
library;

import 'package:flutter/services.dart';

import '../sms.dart';
import 'circles.dart';

/// The one link held, kept in the app's prefs so it outlasts the app being closed mid-setup: [hold] it, [take] it.
class PendingCircleLink {
  PendingCircleLink._();

  /// The pref the held link is under; '' once taken.
  static const _key = 'pending_circle_link';

  /// Set once the clipboard has been looked at, so it is looked at only on a new install's first setup.
  static const _clipKey = 'pending_clip_checked';

  /// For a test: the prefs in place of the app's, and the clipboard's words in place of the system's.
  static Future<Map<String, String>> Function() readPrefs = () => Sms.instance.prefs();
  static Future<void> Function(String key, String value) writePref = (k, v) => Sms.instance.setPref(k, v);
  static Future<String?> Function() readClipboard = () async => (await Clipboard.getData(Clipboard.kTextPlain))?.text;

  /// What is held in memory too, for the moment between holding it and the pref being written.
  static String? _held;

  /// Holds the circle's link in [text] for when the app is set up; false where [text] has none.
  static Future<bool> hold(String text) async {
    final link = Circles.linkIn(text);
    if (link == null) return false;
    _held = link;
    await writePref(_key, link);
    return true;
  }

  /// The link held, and forgotten: null where none is. On a new install's first setup, a circle's link on the
  /// clipboard (the invite page copies it) where none is held; the clipboard is looked at only that once, and only
  /// where this install is in no circle yet ([fresh]).
  static Future<String?> take({required bool fresh}) async {
    final prefs = await readPrefs();
    var link = _held ?? (prefs[_key]?.isNotEmpty == true ? prefs[_key] : null);
    _held = null;
    if (link != null) await writePref(_key, '');
    if (prefs[_clipKey] != '1') {
      await writePref(_clipKey, '1');
      if (link == null && fresh) {
        try {
          link = Circles.linkIn(await readClipboard());
        } catch (_) {}
      }
    }
    return link;
  }
}
