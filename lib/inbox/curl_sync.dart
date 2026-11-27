import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter/foundation.dart' show visibleForTesting;

import '../account/account.dart';
import '../app_state.dart';
import '../me/me.dart';
import '../sms.dart';
import 'account_helper.dart';
import 'inbox.dart';

/// The third-party sign-in cookies ("cURL entries") a Chrome extension captures on one device, synced to the rest
/// through the Uplink account so a service signed in once is signed in everywhere (Matt, 2026-11-21: "make a chrome
/// plugin that works with ghost messaging to handle getting all the curl keys ... sync the cURL entries across all
/// devices so we don't need to login to things like instagram on every device if we're already logged into a ghost
/// account").
///
/// The extension (messaging/extension) logs into the account, captures the cookies of a signed-in browser for each
/// cookie-login service (Messenger, Instagram, LinkedIn, and any added later), seals them with a key only the
/// account's devices have (the backup's kept_key, Me.curlKeep), and keeps them on the relay. Every device reads them
/// back as it reaches the relay ([pull]) and, for each service it is not already signed in to, switches that plugin
/// on and signs it in with the cookies — the same path a pasted sign-in takes (AccountHelper.signIn).
///
/// The relay holds only the sealed blob; it cannot read the cookies. One blob per account (keyed by the shared Uplink
/// identity), last writer wins, so the extension reads-modifies-writes it, and so does [share] (a sign-in made in the
/// app, for the account's other devices).
class CurlSync {
  CurlSync._() {
    AccountHelper.onShare = (id, cookies) => unawaited(share(id, cookies));
  }
  static final CurlSync instance = CurlSync._();

  /// One of its own, with its own networks and Me (a test).
  @visibleForTesting
  CurlSync.forTest({required Iterable<InboxNetwork> Function() networks, required Me Function() me})
      : _networks = networks,
        _me = me;

  Iterable<InboxNetwork> Function() _networks = _allNetworks;
  Me Function() _me = _theMe;
  static Iterable<InboxNetwork> _allNetworks() => Inbox.instance.networks;
  static Me _theMe() => Me.instance;

  /// The app's choices, set as the app starts: nothing is read or shared before then.
  AppState? _app;
  AppState? get app => _app;
  set app(AppState? a) {
    _app = a;
    // Read again every few minutes while the app runs, not only as the relay says hello or the app comes to the front:
    // a computer's window stays open for days (Matt, 2026-11-21: "Plugins should sync across devices also").
    _every?.cancel();
    if (a != null) _every = Timer.periodic(const Duration(minutes: 2), (_) => unawaited(pull()));
  }

  Timer? _every;

  /// A [pull] is running: another asked for meanwhile is passed over.
  bool _busy = false;

  /// What the account keeps: `{v:1, entries:{<serviceId>:{cookies:{name:value}, at:ms, from:'<label>'}}}`.
  static const _version = 1;

  /// Brings this device and the account's others into step, as the app starts (the relay's hello) and every few
  /// minutes after (Matt, 2026-11-27: "have a startup task and a task that runs every once in a while where if a
  /// connection is setup on one device but not another on the same account it gets sent over"):
  ///
  /// - every service kept for the account that this device isn't signed in to is signed in here ([_apply]);
  /// - every service this device is signed in to that the account doesn't keep yet is kept for it ([_push]): a sign-in
  ///   made before sign-ins were shared, made while the relay was away, or whose sharing failed, goes out now, where
  ///   before it was shared only at the moment it was made and never again;
  /// - a paired computer without the account's words (it took the phone's identity but never signed in to the account
  ///   itself, so it cannot open what the account keeps) asks its phone across the link instead ([forComputer]).
  ///
  /// Safe to call on every reconnect: one runs at a time.
  Future<void> pull() async {
    final app = this.app;
    if (app == null || _busy) return;
    _busy = true;
    try {
      Map<String, Object?>? kept;
      try {
        kept = await _me().curlKept();
      } catch (_) {
        // The relay away, or a blob this build can't open: nothing to apply from it this time.
      }
      final entries = kept != null && kept['v'] == _version ? (kept['entries'] as Map? ?? const {}).cast<String, Object?>() : const <String, Object?>{};
      final found = <String, ({Map<String, String> cookies, int at})>{
        for (final e in entries.entries)
          if (_entry(e.value) case final entry?) e.key: entry,
      };
      // The phone's, on a paired computer: what it holds and what it can read of the account's, newer winning.
      if (Sms.remote) {
        for (final e in (await _ofPhone()).entries) {
          final had = found[e.key];
          if (had == null || e.value.at > had.at) found[e.key] = e.value;
        }
      }
      for (final e in found.entries) {
        await _apply(app, e.key, e.value.cookies, e.value.at);
      }
      // Nothing kept yet reads as null, as no account key does: the strict reading before writing tells them apart.
      if (kept == null || kept['v'] == _version) await _push(app, kept ?? const {'v': _version});
    } catch (_) {
      // Whatever went wrong is tried again at the next pull.
    } finally {
      _busy = false;
    }
  }

  /// A kept entry's cookies and when it was kept; null for one that is not.
  static ({Map<String, String> cookies, int at})? _entry(Object? entry) {
    if (entry is! Map) return null;
    final cookies = (entry['cookies'] as Map?)?.cast<String, Object?>();
    if (cookies == null || cookies.isEmpty) return null;
    return (cookies: {for (final c in cookies.entries) c.key: '${c.value}'}, at: (entry['at'] as num?)?.toInt() ?? 0);
  }

  /// The sign-ins this device holds now, by service, with when each was made here where this device knows
  /// (`curl_mine_<service>`, set as it shares one; 0 for one made before that was kept).
  Future<Map<String, ({Map<String, String> cookies, int at})>> _held(AppState app) async {
    final out = <String, ({Map<String, String> cookies, int at})>{};
    for (final n in _networks()) {
      if (n is! AccountHelper) continue;
      final cookies = await n.heldSignIn();
      if (cookies == null) continue;
      // A sign-in made here before sign-ins were shared has no time: it is given the moment it is first met, still
      // working. Kept as it is from then on, so two devices settle rather than take turns writing over each other.
      final key = 'curl_mine_${n.service.id}', seen = 'curl_seen_${n.service.id}';
      var at = int.tryParse(app.choice(key, '0')) ?? 0;
      final hash = _hash(cookies);
      if (at == 0 || app.choice(seen, '') != hash) {
        if (at == 0) at = DateTime.now().millisecondsSinceEpoch;
        app.set(key, '$at');
        app.set(seen, hash);
      }
      out[n.service.id] = (cookies: cookies, at: at);
    }
    return out;
  }

  /// Keeps for the account every sign-in this device holds that the account doesn't, and replaces one it keeps where
  /// this device's was made later; written once, and only where something changed ([kept] as just read).
  Future<void> _push(AppState app, Map<String, Object?> kept) async {
    final held = await _held(app);
    if (held.isEmpty) return;
    final entries = Map<String, Object?>.from((kept['entries'] as Map?)?.cast<String, Object?>() ?? const {});
    final from = Account.instance.profiles.deviceName;
    final changed = <String>[];
    for (final e in held.entries) {
      final there = _entry(entries[e.key]);
      final same = there != null && _same(there.cookies, e.value.cookies);
      if (same) continue;
      // Kept already from another device, and this one's is not known to be newer: theirs stands (this device is
      // signed in anyway, and a sign-in made earlier may be the one the service has since turned away).
      if (there != null && e.value.at <= there.at) continue;
      entries[e.key] = {'cookies': e.value.cookies, 'at': e.value.at, 'from': from};
      changed.add(e.key);
    }
    if (changed.isEmpty) return;
    // Read again just before writing, as [share] does: what another device kept meanwhile is kept with it.
    final fresh = await _me().curlKept(strict: true) ?? kept;
    if (fresh['v'] != _version) return;
    final merged = Map<String, Object?>.from((fresh['entries'] as Map?)?.cast<String, Object?>() ?? const {});
    for (final id in changed) {
      final there = _entry(merged[id]), was = _entry((kept['entries'] as Map?)?[id]);
      // Another device kept this service between the two readings: theirs is the newer.
      if (there != null && (was == null || there.at > was.at)) continue;
      merged[id] = entries[id];
    }
    await _me().curlKeep({...fresh, 'entries': merged});
  }

  /// A short fingerprint of a sign-in's cookies, to know them again without keeping them: SHA-256's first 16 hex digits.
  static String _hash(Map<String, String> cookies) {
    final keys = cookies.keys.toList()..sort();
    return sha256.convert(utf8.encode(jsonEncode([for (final k in keys) [k, cookies[k]]]))).toString().substring(0, 16);
  }

  static bool _same(Map<String, String> a, Map<String, String> b) => a.length == b.length && a.entries.every((e) => b[e.key] == e.value);

  /// On the phone, for a paired computer that asks ('signins' across the link): the sign-ins this phone holds, and
  /// those the account keeps where this phone can read them, by service, newer winning. Only a computer paired with
  /// this phone can ask, and the link is sealed end to end (docs/desktop.md).
  Future<Map<String, Object?>> forComputer(Map<String, Object?> args) async {
    final app = this.app;
    if (app == null) return const {'entries': <String, Object?>{}};
    final found = <String, ({Map<String, String> cookies, int at})>{};
    final held = await _held(app);
    try {
      // Bounded well inside the link's own wait: a slow relay costs the account's entries, never this phone's own.
      final kept = await _me().curlKept().timeout(const Duration(seconds: 6));
      if (kept != null && kept['v'] == _version) {
        for (final e in ((kept['entries'] as Map?) ?? const {}).entries) {
          if (_entry(e.value) case final entry?) found['${e.key}'] = entry;
        }
      }
    } catch (_) {}
    // What this phone is signed in with now, where the account keeps nothing for it or keeps something older: it works.
    for (final e in held.entries) {
      final had = found[e.key];
      if (had == null || (!_same(had.cookies, e.value.cookies) && e.value.at >= had.at)) found[e.key] = e.value;
    }
    // X's cookies are no use without its passcode, which the computer asks for itself: not sent.
    found.removeWhere((id, _) => _networks().any((n) => n is AccountHelper && n.service.id == id && n.service.passcode));
    return {
      'entries': {for (final e in found.entries) e.key: {'cookies': e.value.cookies, 'at': e.value.at}},
    };
  }

  /// On a paired computer: what its phone answers ([forComputer]); nothing where the phone is away or too old to say.
  Future<Map<String, ({Map<String, String> cookies, int at})>> _ofPhone() async {
    try {
      final m = await Sms.instance.signInsOfPhone();
      return {
        for (final e in ((m['entries'] as Map?) ?? const {}).entries)
          if (_entry(e.value) case final entry?) '${e.key}': entry,
      };
    } catch (_) {
      return const {};
    }
  }

  /// Keeps [cookies], a sign-in to [serviceId] just made on this device, for the account's other devices: read, joined
  /// and written back whole (the plugin list and the other entries kept as they are). Marked applied here, so this
  /// device doesn't sign in with it again.
  Future<void> share(String serviceId, Map<String, String> cookies) async {
    final app = this.app;
    if (app == null || cookies.isEmpty) return;
    try {
      final kept = await _me().curlKept(strict: true) ?? {'v': _version};
      if (kept['v'] != _version) return;
      final entries = Map<String, Object?>.from((kept['entries'] as Map?)?.cast<String, Object?>() ?? const {});
      final at = DateTime.now().millisecondsSinceEpoch;
      entries[serviceId] = {'cookies': cookies, 'at': at, 'from': Account.instance.profiles.deviceName};
      app.set('curl_mine_$serviceId', '$at');
      await _me().curlKeep({...kept, 'entries': entries});
      app.set('curl_applied_$serviceId', '$at');
    } catch (_) {
      // The relay away, or the blob unreadable: not written over; the next sign-in shares it.
    }
  }

  /// The synced cookies of [serviceId] as the extension last kept them, and when; null where there are none. Google
  /// Messages' ('gmessages', GMFB-10) are read here rather than applied: pairing makes Google ask for an emoji on the
  /// phone, so it is started by the person, from Google Messages' setup (lib/gm/google_signin_flow.dart).
  Future<({Map<String, String> cookies, int at})?> entryOf(String serviceId) async {
    try {
      final kept = await _me().curlKept();
      if (kept == null || kept['v'] != _version) return null;
      final entry = (kept['entries'] as Map? ?? const {})[serviceId];
      if (entry is! Map) return null;
      final cookies = (entry['cookies'] as Map?)?.cast<String, Object?>();
      if (cookies == null || cookies.isEmpty) return null;
      return (cookies: {for (final c in cookies.entries) c.key: '${c.value}'}, at: (entry['at'] as num?)?.toInt() ?? 0);
    } catch (_) {
      return null;
    }
  }

  /// Signs this device in to [serviceId] with a synced entry's [cookies], kept at [at] (ms), unless it is signed in
  /// already or this entry was tried before (`curl_applied_<service>` holds the time of the last one applied).
  Future<void> _apply(AppState app, String serviceId, Map<String, String> cookies, int at) async {
    final n = _networks().where((n) => n.id == serviceId).firstOrNull;
    if (n is! AccountHelper) return; // only cookie-login helpers can take cURL entries
    // X also needs its passcode, which only the person can give: its sign-in screen offers the synced cookies.
    if (n.service.passcode) return;
    final appliedKey = 'curl_applied_$serviceId', triedKey = 'curl_tried_$serviceId';
    final already = int.tryParse(app.choice(appliedKey, '0')) ?? 0;
    final hash = _hash(cookies);

    // Already signed in on this device: note we've seen this entry and leave the live session alone. Signed out of it
    // later, these same cookies are not signed in again.
    if (n.state == InboxState.ready || n.state == InboxState.signingIn) {
      if (at > already) app.set(appliedKey, '$at');
      app.set(triedKey, hash);
      return;
    }
    // Switched off here by the person: left off.
    if (app.choice('inbox_on_$serviceId', '') == 'off') return;
    // These very cookies tried here before (signed in with and since signed out of, or refused): not again, whatever
    // time they carry. Only another sign-in, made somewhere since, is tried.
    if (app.choice(triedKey, '') == hash) return;
    // Nothing newer than what we last signed in with, and not currently signed in: the cookies likely expired the
    // same way here; try again only when the extension has captured fresher ones.
    if (at <= already && already > 0) return;

    // Not started yet (a plugin switched off, or never started): switch it on so its helper runs, then sign in.
    if (n.state == InboxState.unavailable) await Inbox.instance.enable(n);
    // A helper just started takes a moment to say it is up: wait for it, rather than give up on this entry until the
    // next pull (the reason a synced Discord never signed in on a phone, 2026-11-21).
    for (var i = 0; i < 40 && n.state == InboxState.unavailable; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    if (n.state != InboxState.signedOut) return; // helper not in this build

    app.set(triedKey, hash);
    final ok = await n.signIn(jsonEncode(cookies), share: false);
    if (ok) app.set(appliedKey, '$at');
  }
}
