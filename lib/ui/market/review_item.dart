/// One submission as the reviewer reads it (Matt, 2026-11-20: "I'd like to be able to verify them for the store through
/// a review process"): its package checked on this device (its SHA-256 worked out here, whether it was sent canonical,
/// every problem and warning), what it can do and what this version can do that the listed one can't, the rules that
/// act on texts set apart so none hides among the phrases, Try it, the file itself and what changed since the version
/// listed and since the reviewer last asked, its listing (screenshots drawn in Dart, never by the platform's codecs),
/// who sent it, and the decision.
///
/// An approval is signed here, by this device's hub key, over the id and version the package itself says and the
/// SHA-256 worked out here: never over anything the relay said, so a relay can't have a different package approved.
library;

import 'dart:async';
import 'dart:convert';
import '../../aside.dart';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../../app_state.dart';
import '../../art/app_icon.dart';
import '../../art/lucide.g.dart';
import '../../kit/semantic_colors.dart';
import '../../kit/settings_kit.dart';
import '../../kit/settings_type.dart';
import '../../market/market_api.dart';
import '../../market/market_models.dart';
import '../../market/market_state.dart';
import '../../market/png_view.dart';
import '../../net/hub_carrier.dart' show NetSigner;
import '../../plugins/pack/pack.dart';
import '../../plugins/registry.dart' show AppStore;
import '../admin_page.dart' show AdminSignIn;
import '../circles/new_circle.dart' show askCircleWords;
import '../common.dart';
import '../skeleton.dart';
import '../dialup/bevel.dart' show isBevelChrome;
import '../plugins_page/plugin_art.dart';
import '../settings_panes.dart' show appVersion;
import 'market_flows.dart' show packGrew;
import 'market_forms.dart';
import 'try_pack.dart';
import '../../l10n/words.dart';

// --- the file, written out for reading ------------------------------------------------------------------------------

/// [json] (a pack's decoded file) as the reviewer reads it: two spaces, keys sorted, the icon as `<icon: N bytes>`, and
/// inside a phrase every character outside U+0020 to U+007E as `\u{…}`, so a look-alike letter or an invisible one
/// shows for what it is.
String prettyPack(Object? json) {
  final out = StringBuffer();
  void write(Object? v, String indent, {bool phrase = false, String key = '', bool top = false}) {
    if (v is Map) {
      if (v.isEmpty) return out.write('{}');
      final keys = [for (final k in v.keys) '$k']..sort();
      out.writeln('{');
      for (final (i, k) in keys.indexed) {
        out.write('$indent  ${jsonEncode(k)}: ');
        if (top && k == 'icon' && v[k] is String) {
          out.write('<icon: ${_iconBytes(v[k] as String)} bytes>');
        } else {
          write(v[k], '$indent  ', key: k, phrase: phrase);
        }
        out.writeln(i == keys.length - 1 ? '' : ',');
      }
      out.write('$indent}');
    } else if (v is List) {
      if (v.isEmpty) return out.write('[]');
      // A tag rule's any, all and none are its phrases.
      final phrases = phrase || key == 'any' || key == 'all' || key == 'none';
      out.writeln('[');
      for (final (i, x) in v.indexed) {
        out.write('$indent  ');
        write(x, '$indent  ', phrase: phrases);
        out.writeln(i == v.length - 1 ? '' : ',');
      }
      out.write('$indent]');
    } else if (v is String) {
      final quoted = jsonEncode(v);
      if (!phrase) return out.write(quoted);
      for (final r in quoted.runes) {
        r >= 0x20 && r <= 0x7E ? out.writeCharCode(r) : out.write('\\u{${r.toRadixString(16).toUpperCase().padLeft(4, '0')}}');
      }
    } else {
      out.write(jsonEncode(v));
    }
  }

  write(json, '', top: true);
  return out.toString();
}

int _iconBytes(String b64) {
  try {
    return base64Decode(b64).length;
  } catch (_) {
    return b64.length;
  }
}

/// The line diff of [a] to [b] by Myers' O((N+M)·D) algorithm: each line of the result is "  ", "- " or "+ " and the
/// line; null where more than [most] lines differ ("Too different to compare here"), so a pack rewritten whole costs
/// a bounded time and memory. Run in an isolate (Isolate.run): a pack is up to a few thousand lines.
List<String>? lineDiff(List<String> a, List<String> b, {int most = 2000}) {
  // Shared ends first: the diff is of what lies between.
  var start = 0;
  while (start < a.length && start < b.length && a[start] == b[start]) {
    start++;
  }
  var endA = a.length, endB = b.length;
  while (endA > start && endB > start && a[endA - 1] == b[endB - 1]) {
    endA--;
    endB--;
  }
  final x0 = a.sublist(start, endA), y0 = b.sublist(start, endB);
  final n = x0.length, m = y0.length;
  final middle = <String>[];
  if (n > 0 || m > 0) {
    // V by diagonal k, offset so k = -(d+1) .. d+1 fit; each step's V kept for the way back.
    final width = 2 * (most + 2) + 1;
    final off = most + 2;
    final v = Int32List(width);
    final trace = <Int32List>[];
    var found = -1;
    for (var d = 0; d <= most; d++) {
      trace.add(Int32List.fromList(v.sublist(off - d - 1, off + d + 2)));
      for (var k = -d; k <= d; k += 2) {
        int x;
        if (k == -d || (k != d && v[off + k - 1] < v[off + k + 1])) {
          x = v[off + k + 1];
        } else {
          x = v[off + k - 1] + 1;
        }
        var y = x - k;
        while (x < n && y < m && x0[x] == y0[y]) {
          x++;
          y++;
        }
        v[off + k] = x;
        if (x >= n && y >= m) {
          found = d;
          break;
        }
      }
      if (found >= 0) break;
    }
    if (found < 0) return null;
    // The way back, from the end to the start, each step's snake then its one edit.
    var x = n, y = m;
    final back = <String>[];
    for (var d = found; d >= 0; d--) {
      final row = trace[d];
      int at(int k) => row[k + d + 1];
      final k = x - y;
      final prevK = (k == -d || (k != d && at(k - 1) < at(k + 1))) ? k + 1 : k - 1;
      final prevX = d == 0 ? 0 : at(prevK);
      final prevY = prevX - prevK;
      while (x > prevX && y > prevY) {
        back.add('  ${x0[x - 1]}');
        x--;
        y--;
      }
      if (d > 0) {
        if (x == prevX) {
          back.add('+ ${y0[y - 1]}');
        } else {
          back.add('- ${x0[x - 1]}');
        }
      }
      x = prevX;
      y = prevY;
    }
    middle.addAll(back.reversed);
  }
  return [for (final l in a.sublist(0, start)) '  $l', ...middle, for (final l in a.sublist(endA)) '  $l'];
}

/// Only the changed lines of a [diff], with [context] lines round each, the rest as "…".
List<String> diffShown(List<String> diff, {int context = 2}) {
  final keep = List<bool>.filled(diff.length, false);
  for (var i = 0; i < diff.length; i++) {
    if (diff[i].startsWith('  ')) continue;
    for (var j = math.max(0, i - context); j <= math.min(diff.length - 1, i + context); j++) {
      keep[j] = true;
    }
  }
  final out = <String>[];
  var skipped = false;
  for (var i = 0; i < diff.length; i++) {
    if (keep[i]) {
      if (skipped && out.isNotEmpty) out.add('…');
      out.add(diff[i]);
      skipped = false;
    } else {
      skipped = true;
    }
  }
  return out;
}

// --- what to look at closely ------------------------------------------------------------------------------------------

/// The parts of [pack] that act on texts or reach outside it, a line each with its path: every `from` a condition holds
/// for, every incoming rule and the toggle it waits for, every text a button writes or copies, its link, and every
/// phrase with no anchor. One rule that acts can't hide among two hundred phrases.
List<String> lookClosely(PluginPack pack) {
  final out = <String>[];
  final rules = pack.rules;
  String label(String key) => rules.sections.where((s) => s.key == key).firstOrNull?.label ?? key;
  void from(PackWhen? w, String path) {
    if (w == null || w.from.isEmpty) return;
    // An entry with nothing to compare (no digit, no letter) holds for no one, and says so rather than showing blank.
    out.add('$path.from: only from ${[for (final f in w.from) f.isEmpty ? '(an entry that matches no one)' : f].join(', ')}');
  }

  for (final (i, r) in rules.tags.indexed) {
    from(r.when, 'rules.tags[$i].when');
    for (final (key, phrases) in [('any', r.any), ('all', r.all), ('none', r.none)]) {
      for (final (j, p) in phrases.indexed) {
        if (p.anchorless) out.add('rules.tags[$i].$key[$j]: no anchor: "${p.source}"');
      }
    }
  }
  for (final (i, s) in rules.sections.indexed) {
    from(s.takes, 'rules.sections[$i].takes');
  }
  for (final (i, a) in rules.actions.indexed) {
    from(a.when, 'rules.actions[$i].when');
    if (a.verb == 'write' || a.verb == 'copy') out.add('rules.actions[$i] (${a.verb}, "${a.label}"): "${a.text ?? ''}"');
    if (a.verb == 'link') out.add('rules.actions[$i] (link, "${a.label}"): opens ${a.url ?? pack.links.firstOrNull ?? ''}');
  }
  for (final (i, r) in rules.incoming.indexed) {
    from(r.when, 'rules.incoming[$i].when');
    out.add('rules.incoming[$i]: ${r.verbs.map((v) => v == 'markread' ? 'marks read' : 'silences').join(' and ')} ${label(r.section)} texts as they come, once "${r.setting}" is on');
  }
  for (final (i, l) in pack.links.indexed) {
    out.add('links[$i]: $l');
  }
  return out;
}

// --- the screen ---------------------------------------------------------------------------------------------------------

/// The review page for the submission [sid].
class ReviewItemScreen extends StatefulWidget {
  const ReviewItemScreen(this.sid, {super.key, this.api, this.ask});
  final String sid;

  /// The Marketplace: MarketState.instance.api where null, which is Uplink's own (MarketApi.live) in the app.
  final MarketApi? api;

  /// For a test: the relay's answers to the admin sign-in, in place of Me.admin.
  final Future<Map<String, dynamic>> Function(Map<String, Object?> what)? ask;

  @override
  State<ReviewItemScreen> createState() => _ReviewItemScreenState();
}

class _ReviewItemScreenState extends State<ReviewItemScreen> {
  late final MarketApi _api = widget.api ?? MarketState.instance.api;
  ReviewItem? _item;
  MarketError? _error;

  /// The package as sent and what this device makes of it.
  Uint8List _bytes = Uint8List(0);
  String _sha = '';
  bool _canonical = false;
  PackParse? _parse;
  PluginPack? _previous;
  String? _pretty;
  List<String>? _diff, _diffAsked;
  bool _diffTooBig = false, _diffAskedTooBig = false, _diffing = false;

  /// The screenshots the package names, by their place in its `shots`, decoded in Dart: an image, or null where it
  /// can't be shown here; why one isn't the picture the package names (its bytes are another picture's); and those
  /// that couldn't be fetched at all (a dropped connection, a timeout, a busy relay), which Refresh asks for again. An
  /// approval covers the package's own list, which every user's page draws, so these are its pictures, never the ones
  /// the relay's row names (review, 2026-11-20).
  final Map<int, ui.Image?> _shots = {};
  final Set<int> _shotsAsked = {};
  final Map<int, String> _shotsWrong = {};
  final Set<int> _shotsFailed = {};

  /// Its icon, decoded in Dart as its screenshots are, and the bytes it was decoded from: its head draws its symbol
  /// until then, or where it can't be decoded here.
  ui.Image? _icon;
  Uint8List? _iconFrom;

  /// The SHA-256 of the version before, worked out here from the package the relay sent with it, where that is the
  /// hash the relay says and the package is this plugin's: the only hash "Withdraw it too" signs. Null where they
  /// don't agree, and then it can't be withdrawn from this page.
  String? _previousSha;

  final _note = TextEditingController();
  bool _revokePrevious = false;
  String? _deciding;
  ReviewDecision? _held;
  bool _heldUnreachable = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_read());
  }

  @override
  void dispose() {
    _note.dispose();
    for (final i in _shots.values) {
      i?.dispose();
    }
    _icon?.dispose();
    super.dispose();
  }

  PluginPack? get _pack => _parse?.pack;
  ReviewRow? get _row => _item?.submission;

  static Uint8List _decode(String b64) {
    try {
      return base64Decode(b64);
    } catch (_) {
      return Uint8List(0);
    }
  }

  static PluginPack? _parsed(String? b64) => b64 == null ? null : parsePack(_decode(b64), appVersion: appVersion, checkMinApp: false).pack;

  /// Reads the submission and checks its package here: parsed, hashed, compared with its canonical form and with the
  /// version listed before it; then the diffs, the screenshots and the icon, each in its own time.
  Future<void> _read() async {
    final ReviewItem item;
    try {
      item = await _api.reviewItem(widget.sid);
    } on MarketError catch (e) {
      if (mounted) setState(() => _error = e);
      return;
    }
    final bytes = _decode(item.package);
    final parse = parsePack(bytes, appVersion: appVersion, submission: true);
    final previous = item.previous;
    final previousBytes = previous == null ? null : _decode(previous.package);
    final previousPack = _parsed(previous?.package);
    if (!mounted) return;
    setState(() {
      _error = null;
      _item = item;
      _bytes = bytes;
      _sha = sha256Hex(bytes);
      _parse = parse;
      _canonical = parse.canonical != null && listEquals(parse.canonical, bytes);
      _previous = previousPack;
      // Nothing of the relay's is signed as it says: the hash of the bytes it sent, where that is the hash it named and
      // the package is this plugin's. A relay broken into could otherwise have the reviewer withdraw another plugin
      // altogether with one switch (review, 2026-11-20).
      final previousSha = previousBytes == null || previousBytes.isEmpty ? null : sha256Hex(previousBytes);
      _previousSha = previousSha != null && previousSha == previous!.sha256 && previousPack != null && previousPack.id == parse.pack?.id ? previousSha : null;
      if (_previousSha == null) _revokePrevious = false;
      _pretty = _prettyOf(bytes);
    });
    unawaited(_diffs(item));
    unawaited(_pictures(item, parse.pack?.shots ?? item.submission.view.shots));
    unawaited(_iconOf(parse.pack?.icon));
  }

  /// The hashes of the screenshots shown: the package's own where it parses (what an approval covers), else the row's.
  List<String> get _shotShas => _pack?.shots ?? _row?.view.shots ?? const [];

  /// The icon [png], decoded in Dart: it is a stranger's bytes on the one device that holds the review key and the
  /// admin session, as every submission's screenshot is, so it never reaches the platform's codecs here (D.10, G.5).
  Future<void> _iconOf(Uint8List? png) async {
    if (png == null || listEquals(png, _iconFrom)) return;
    _iconFrom = png;
    ui.Image? image;
    try {
      image = await decodePngInDart(png, most: PackLimits.iconMax);
    } catch (_) {}
    if (!mounted || !identical(_iconFrom, png)) {
      image?.dispose();
      return;
    }
    final was = _icon;
    setState(() => _icon = image);
    was?.dispose();
  }

  /// The plugin's id as the package itself says, where it parses; else as its JSON says, for a package this app no
  /// longer reads but which was approved once.
  String? _idInPackage() {
    final pack = _pack;
    if (pack != null) return pack.id;
    try {
      final json = jsonDecode(utf8.decode(_bytes));
      final id = json is Map ? json['id'] : null;
      return id is String && packIdPattern.hasMatch(id) ? id : null;
    } catch (_) {
      return null;
    }
  }

  static String? _prettyOf(List<int> bytes) {
    try {
      return prettyPack(jsonDecode(utf8.decode(bytes)));
    } catch (_) {
      return null;
    }
  }

  /// The file's changes since the version listed and since the reviewer asked, worked out on an isolate.
  Future<void> _diffs(ReviewItem item) async {
    final now = _pretty;
    if (now == null) return;
    final before = item.previous == null ? null : _prettyOf(_decode(item.previous!.package));
    final asked = item.asked == null ? null : _prettyOf(_decode(item.asked!.package));
    if (before == null && asked == null) return;
    setState(() => _diffing = true);
    final lines = now.split('\n');
    final a = before?.split('\n'), b = asked?.split('\n');
    try {
      final got = await _diffBoth(a, b, lines);
      if (!mounted) return;
      setState(() {
        _diff = got.$1;
        _diffTooBig = a != null && got.$1 == null;
        _diffAsked = got.$2;
        _diffAskedTooBig = b != null && got.$2 == null;
      });
    } catch (_) {
      // Left out: the file itself is there to read.
    } finally {
      if (mounted) setState(() => _diffing = false);
    }
  }

  /// Both diffs on an isolate of their own. A static function, so the closure the isolate is sent holds the lines
  /// alone and never this screen's state.
  static Future<(List<String>?, List<String>?)> _diffBoth(List<String>? before, List<String>? asked, List<String> now) => runAside(() => (before == null ? null : lineDiff(before, now), asked == null ? null : lineDiff(asked, now)));

  /// The screenshots [shas] names (route 12, by their place), each held to its hash there and decoded in Dart: every one
  /// is a stranger's bytes, on the one device that holds the review key and the admin session, so none reaches the
  /// platform's codecs here.
  Future<void> _pictures(ReviewItem item, List<String> shas) async {
    for (final (n, sha) in shas.indexed) {
      // A submission's screenshots never change: each is decoded once, however often the page is read again; one that
      // couldn't be fetched is asked for again.
      if (!_shotsAsked.add(n)) continue;
      ui.Image? image;
      String? wrong;
      var failed = false;
      try {
        final bytes = await _api.submissionShot(item.submission.sid, n);
        if (sha256Hex(bytes) == sha) {
          image = await decodePngInDart(bytes);
        } else {
          wrong = 'Not the picture its file names';
        }
      } catch (_) {
        // Not fetched: nothing says the listing is wrong, only that this picture isn't seen yet. It was counted with
        // the mismatches, so a dropped connection read as a tampered listing, "Don't approve it" (review, 2026-11-20).
        failed = true;
      }
      if (!mounted) {
        image?.dispose();
        return;
      }
      setState(() {
        _shots[n] = image;
        if (wrong == null) {
          _shotsWrong.remove(n);
        } else {
          _shotsWrong[n] = wrong;
        }
        if (failed) {
          _shotsFailed.add(n);
        } else {
          _shotsFailed.remove(n);
        }
        if (wrong != null || failed) _shotsAsked.remove(n);
      });
    }
  }

  /// Why the store's listing of it isn't the one its package names, or null: the relay's list of screenshots or its
  /// developer isn't the package's, or a screenshot the package names came as another picture's bytes. One that
  /// couldn't be fetched at all is no sign of that, and holds Approve back on its own ([_approveWhy]). Users' pages
  /// draw the package's own (D.4), under "Reviewed by Uplink"; a relay that is wrong or broken into could show
  /// the reviewer other pictures and another "By @" (review, 2026-11-20).
  String? get _listingWrong {
    final row = _row, pack = _pack;
    if (row == null || pack == null) return null;
    if (!listEquals(row.view.shots, pack.shots) || pack.developer != row.developer || _shotsWrong.isNotEmpty) return 'The store\'s listing isn\'t the one this package names. Don\'t approve it.';
    return null;
  }

  // --- deciding ---------------------------------------------------------------------------------------------------

  /// Why Approve can't be pressed, or null where it can.
  String? get _approveWhy {
    final row = _row;
    final signer = _api.signer;
    if (signer == null) return 'This device has no Uplink identity of its own: review from your phone.';
    final here = InstalledPlugins.instance;
    if (!isReviewKey(signer.publicKey, keys: here.reviewKeys, retired: here.retiredKeys)) return 'This build doesn\'t trust this device\'s key for reviews: its approvals wouldn\'t install.';
    final pack = _pack;
    if (row == null || pack == null || (_parse?.errors.isNotEmpty ?? true) || _sha != row.view.sha256 || !_canonical || pack.id != row.plugin || pack.version != row.version) return 'The plugin has problems.';
    if (row.status != 'submitted' && row.status != 'in_review') return 'It isn\'t waiting for a decision.';
    final listing = _listingWrong;
    if (listing != null) return listing;
    // Every picture its page will show is seen here first.
    if (_shotsFailed.isNotEmpty) return 'A screenshot couldn\'t be loaded. Refresh to try again.';
    if (pack.shots.indexed.any((e) => !_shots.containsKey(e.$1))) return 'Its screenshots are still loading.';
    if (pack.shots.indexed.any((e) => _shots[e.$1] == null)) return 'A screenshot can\'t be shown on this device, so it can\'t be checked: ask for changes.';
    return null;
  }

  /// The note as the Marketplace takes it, or null where it can't be sent, said in a toast: the relay answers a slip
  /// with "Something in that isn't right." alone (review, 2026-11-20).
  String? _noteFor(int most) {
    final note = marketCut(marketWords(_note.text), most);
    final problem = note.isEmpty ? null : marketWordsProblem(note, most);
    if (problem == null) return note;
    toast(context, 'The note: $problem', tone: GlacierToastTone.danger);
    return null;
  }

  Future<void> _approve() async {
    if (_approveWhy != null) return;
    final note = _noteFor(MarketMost.decisionNote);
    if (note == null) return;
    final pack = _pack!, signer = _api.signer!, item = _item!;
    // Signed over what the package itself says and the SHA-256 worked out here, by the key the request is signed with.
    final approval = await signApproval(signer, plugin: pack.id, version: pack.version, sha256: _sha);
    final previousSha = _previousSha;
    final revokes = [
      if (_revokePrevious && item.previous != null && previousSha != null) await signRevocation(signer, plugin: pack.id, sha256: previousSha, why: 'Replaced by ${pack.version}: update it from its page.'),
    ];
    await _decide(ReviewDecision('approve', note: note, approval: approval, revokes: revokes));
  }

  Future<void> _ask(String decision) async {
    if (marketWords(_note.text).isEmpty) return toast(context, decision == 'changes' ? 'Say what to change in the note first.' : 'Say why in the note first.');
    final note = _noteFor(MarketMost.decisionNote);
    if (note == null) return;
    await _decide(ReviewDecision(decision, note: note));
  }

  /// Sends [d]. Refused for a sign-in (the relay restarted, or an approval wants one within the half hour) or
  /// unreachable, it is kept as it is, its note and its approval with it, and sent again after a sign-in or Try again.
  Future<void> _decide(ReviewDecision d) async {
    if (_deciding != null) return;
    setState(() {
      _deciding = d.decision;
      _heldUnreachable = false;
    });
    try {
      final done = await _api.decide(widget.sid, d);
      _held = null;
      if (!mounted) return;
      toast(context, switch (d.decision) {
        'start' => 'Review started',
        // As the Marketplace answered: a version sent to be listed later, or of a plugin its developer took off the
        // Marketplace, stays off it once approved, whatever its list said (review, 2026-11-20).
        'approve' => done.view.listing == 'listed' ? 'Approved and listed' : 'Approved: it stays off the Marketplace until its developer lists it',
        'changes' => 'Changes asked for',
        _ => 'Rejected',
      }, tone: GlacierToastTone.success);
      if (d.decision != 'start') _note.clear();
      unawaited(_read());
    } on MarketError catch (e) {
      if (!mounted) return;
      if (e.code == 'not_admin') {
        _held = d;
        unawaited(_signInThen(d));
      } else if (e.code == 'unreachable') {
        setState(() {
          _held = d;
          _heldUnreachable = true;
        });
      } else {
        toast(context, e.message, tone: GlacierToastTone.danger);
      }
    } finally {
      if (mounted) setState(() => _deciding = null);
    }
  }

  /// The admin sign-in on a page over this one, above the keyboard; signed in, [d] goes again as it was (a newly signed
  /// request, the same approval).
  Future<void> _signInThen(ReviewDecision d) => pushAdminSignIn(context, words: 'The Marketplace wants a fresh admin sign-in for that. Your note and decision are kept.', key: const ValueKey('market-review-signin-sheet'), ask: widget.ask, signedIn: () {
        if (mounted) unawaited(_decide(d));
      });

  /// Asks before something not lightly taken back: true only where [yes] was pressed and the page is still up.
  Future<bool> _confirm(String title, String words, String yes, {bool danger = false}) async {
    final t = context.tokens;
    var go = false;
    await showChoices(context, title: title, header: Padding(
      padding: EdgeInsets.symmetric(horizontal: t.space(4), vertical: t.space(2)),
      child: Text(words, style: pageText(t, t.fontSize('md'), height: 1.4, color: t.color('app-ink-2'))),
    ), choices: [
      Choice(yes, danger ? Lucide.ban : Lucide.check, () => go = true, danger: danger),
      Choice('Not now', Lucide.x, () {}),
    ]);
    return go && mounted;
  }

  Future<void> _setListed(bool listed) async {
    final row = _row;
    if (row == null) return;
    final name = row.name.ifEmpty(row.plugin);
    final note = _noteFor(MarketMost.listingNote);
    if (note == null) return;
    if (!await _confirm(listed ? 'List $name again?' : 'Unlist $name?', listed ? 'It goes back in the Marketplace for anyone to add.' : 'People who added it keep it. Nobody new can add it, and only review can list it again.', listed ? 'List again' : 'Unlist', danger: !listed)) return;
    await _act(() => _api.setListed(row.plugin, listed, note: note.isEmpty ? null : note), listed ? '$name is listed again' : '$name was unlisted');
  }

  /// Withdraws this version everywhere: asks why in one line, then [_revokeFor] confirms and signs it.
  void _revoke() {
    final row = _row;
    final signer = _api.signer;
    if (row == null || signer == null) return;
    final name = '${row.name.ifEmpty(row.plugin)} ${row.version}';
    askCircleWords(context, title: 'Why withdraw $name?', hint: 'One line, shown to everyone who has it: "It mutes texts it shouldn\'t".', then: (why) {
      // Asked over this page once the words' page has gone: it pops itself just after saying them.
      Timer.run(() {
        if (mounted) unawaited(_revokeFor(row, signer, name, why.trim()));
      });
    });
  }

  /// Why this version can't be withdrawn from this page, or null: what is signed is the package shown here (its hash
  /// worked out here, its id its own), never a hash or an id the relay names alone.
  String? get _revokeWhy {
    final row = _row;
    if (row == null) return 'It hasn\'t been read yet.';
    final signer = _api.signer;
    if (signer == null) return 'This device has no Uplink identity of its own: review from your phone.';
    // A withdrawal counts on a device only where that build pins its key (verifyRevocation), a retired one among them;
    // one signed by a key it doesn't pin switched nothing off, while the store took it, unlisted the plugin and
    // kept it as the one withdrawal of that version (review, 2026-11-20).
    if (!InstalledPlugins.instance.reviewKeys.contains(base64Encode(signer.publicKey))) return 'This build doesn\'t trust this device\'s key: no app would take its withdrawal.';
    if (_sha != row.view.sha256 || _idInPackage() != row.plugin) return 'This package isn\'t the one the store lists: it can\'t be withdrawn from here.';
    return null;
  }

  Future<void> _revokeFor(ReviewRow row, NetSigner signer, String name, String words) async {
    if (words.isEmpty || words.length > 200 || !packTextOk(words)) return toast(context, 'Say why in one line of up to 200 characters.', tone: GlacierToastTone.danger);
    final why = _revokeWhy;
    if (why != null) return toast(context, why, tone: GlacierToastTone.danger);
    if (!await _confirm('Withdraw $name?', 'It\'s switched off on every device that has it, with "$words" on its page. This can\'t be undone.', 'Withdraw this version', danger: true)) return;
    // The package as worked out here, in case it changed while the sheet was up.
    final plugin = _idInPackage(), sha = _sha;
    if (_revokeWhy != null || plugin == null) return;
    final r = await signRevocation(signer, plugin: plugin, sha256: sha, why: words);
    await _act(() => _api.revoke(plugin, r), '$name was withdrawn');
  }

  /// Blocks the developer from submitting (with their plugins unlisted too, where chosen), or lets them submit again.
  Future<void> _block(DeveloperView dev, {required bool blocked}) async {
    final who = dev.username == null ? 'this developer' : '@${dev.username}';
    final note = _noteFor(MarketMost.listingNote);
    if (note == null) return;
    var unlist = false;
    var go = false;
    final t = context.tokens;
    await showChoices(context, title: blocked ? 'Block $who?' : 'Let $who submit again?', header: Padding(
      padding: EdgeInsets.symmetric(horizontal: t.space(4), vertical: t.space(2)),
      child: Text(blocked ? 'They can\'t submit plugins while blocked. Their plugins stay listed unless you unlist them too.' : 'They can submit plugins again. Unlisted plugins stay unlisted.', style: pageText(t, t.fontSize('md'), height: 1.4, color: t.color('app-ink-2'))),
    ), choices: [
      if (blocked) ...[
        Choice('Block $who', Lucide.ban, () => go = true, danger: true),
        Choice('Block $who, and unlist their plugins too', Lucide.eyeOff, () {
          go = true;
          unlist = true;
        }, danger: true),
      ] else
        Choice('Let $who submit again', Lucide.check, () => go = true),
      Choice('Not now', Lucide.x, () {}),
    ]);
    if (!go || !mounted) return;
    await _act(() => _api.block(dev.id, blocked: blocked, note: note.isEmpty ? null : note, unlist: unlist), blocked ? '$who is blocked' : '$who can submit again');
  }

  /// Runs an admin [call], says [done] and reads the page afresh; where the relay wants a fresh admin sign-in, signs in
  /// here and runs it again.
  Future<void> _act(Future<Object?> Function() call, String done) async {
    setState(() => _busy = true);
    try {
      await call();
      if (!mounted) return;
      toast(context, done, tone: GlacierToastTone.success);
      unawaited(_read());
    } on MarketError catch (e) {
      if (!mounted) return;
      if (e.code == 'not_admin') {
        await pushAdminSignIn(context, words: 'The Marketplace wants a fresh admin sign-in for that.', key: const ValueKey('market-review-act-signin'), ask: widget.ask, signedIn: () {
          if (mounted) unawaited(_act(call, done));
        });
      } else {
        toast(context, e.message, tone: GlacierToastTone.danger);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // --- drawing ----------------------------------------------------------------------------------------------------

  /// Its tile: its symbol on its hue, with its icon over it once decoded in Dart ([_iconOf]). Never PluginTile's own
  /// picture, which the platform's codecs decode.
  Widget _tile(Tokens t, PluginPack? pack, ReviewRow row, double size) {
    final face = pack == null ? MarketFace.of(row.view) : MarketFace(id: pack.registryId, name: pack.name, symbol: pack.symbol, hue: pack.hue);
    final icon = _icon;
    final bevel = isBevelChrome(t);
    final picture = icon == null ? null : RawImage(key: const ValueKey('market-review-icon'), image: icon, fit: BoxFit.cover, filterQuality: FilterQuality.medium);
    return SizedBox.square(
      dimension: size,
      child: Stack(fit: StackFit.expand, children: [
        PluginTile(plugin: face, size: size),
        if (picture != null)
          bevel ? Center(child: SizedBox.square(dimension: size * 0.7, child: picture)) : ClipRRect(borderRadius: BorderRadius.circular(pluginCorner(t, size * 0.28)), child: picture),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final item = _item;
    final error = _error;
    return GhostPage(
      key: ValueKey('market-review-item-${widget.sid}'),
      title: item == null ? 'Submission' : '${item.submission.name.ifEmpty(item.submission.plugin)} ${item.submission.version}',
      actions: [IconTap(icon: Lucide.refreshCw, label: 'Refresh', onPressed: () => unawaited(_read()))],
      body: item == null
          ? ListView(padding: EdgeInsets.all(t.space(4)), children: [
              if (error?.code == 'not_admin')
                KeyedSubtree(key: const ValueKey('market-review-signin'), child: AdminSignIn(ask: widget.ask, onDone: _read))
              else if (error?.code == 'unreachable')
                MarketUnreachable(onRetry: () => unawaited(_read()))
              else if (error != null)
                MarketBlock(words: error.message)
              else
                const SkeletonPeople(label: 'Loading', most: 4, shrink: true),
            ])
          : SettingsPaneScope(finder: SettingsFinder(), child: _body(context, t, item)),
    );
  }

  Widget _body(BuildContext context, Tokens t, ReviewItem item) {
    final row = item.submission;
    final pack = _pack;
    final gap = SizedBox(height: t.space(5));
    final quiet = pageText(t, t.fontSize('sm'), height: 1.4, color: t.color('app-ink-2'));
    final body = pageText(t, t.fontSize('md'), height: 1.4, color: t.color('app-ink'));
    final mono = TextStyle(fontFamily: 'JetBrains Mono Variable', fontSize: t.fontSize('xs'), height: 1.45, color: t.color('app-ink-2'));
    final shaOk = _sha == row.view.sha256;
    final previous = _previous;
    // What it can do on a phone, where it does the most, wherever it is reviewed: a computer's words leave out the
    // silencing and the marking read as texts come that every phone runs (review, 2026-11-20).
    final grew = pack == null ? null : packGrew(pack, previous, here: 'phone');
    final listingWrong = _listingWrong;
    final shotShas = _shotShas;
    final closely = pack == null ? const <String>[] : lookClosely(pack);
    final closelyBefore = previous == null ? null : lookClosely(previous).toSet();
    final approveWhy = _approveWhy;
    final open = row.status == 'submitted' || row.status == 'in_review';
    final current = row.view.listing != null ? row.view : item.history.where((h) => h.listing != null).firstOrNull;
    final developerNote = row.view.notes.where((n) => n.by == 'developer').firstOrNull;
    final side = math.max(t.space(4), (MediaQuery.sizeOf(context).width - 760) / 2);
    Widget lines(List<String> ls, {TextStyle? style}) => SettingRowBox(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [for (final l in ls) Padding(padding: EdgeInsets.only(bottom: t.space(1)), child: Text(l, style: style ?? quiet))]));
    Widget diffBox(List<String> diff) => SettingRowBox(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              for (final l in diffShown(diff)) Text(l, style: mono.copyWith(color: l.startsWith('+ ') ? t.color('app-accent') : (l.startsWith('- ') ? t.danger : null))),
            ]),
          ),
        );
    return ListView(
      padding: EdgeInsetsDirectional.fromSTEB(side, t.space(2), side, t.space(8) + MediaQuery.paddingOf(context).bottom),
      children: [
        if (!shaOk)
          PaneSection(children: [SettingRow(key: const ValueKey('market-review-mismatch'), icon: AppIcon(Lucide.triangleAlert, size: 18, color: t.danger), label: 'This package isn\'t the one the store lists. Don\'t approve it.', labelColor: t.danger)]),
        if (!shaOk) gap,
        if (listingWrong != null) ...[
          PaneSection(children: [SettingRow(key: const ValueKey('market-review-listing-mismatch'), icon: AppIcon(Lucide.triangleAlert, size: 18, color: t.danger), label: listingWrong, labelColor: t.danger)]),
          gap,
        ],
        if (item.asked != null) ...[
          PaneSection(children: [
            SettingRow(key: const ValueKey('market-review-asked'), icon: const AppIcon(Lucide.messageSquare, size: 18), label: 'You asked: ${item.asked!.note}', hint: Text('Of ${item.asked!.version}, ${item.asked!.status == 'rejected' ? 'not accepted' : 'changes asked for'}.')),
          ]),
          gap,
        ],
        // The head: what it is, by whom, and where it stands.
        PaneSection(children: [
          SettingRow(
            key: const ValueKey('market-review-head'),
            icon: _tile(t, pack, row, t.lenOf('2.4rem')),
            label: '${pack?.name ?? row.name.ifEmpty(row.plugin)} ${pack?.version ?? row.version}',
            // By whom its file says: the "By @" every user's page draws.
            hint: Text([pack?.tagline ?? row.view.tagline, '@${pack?.developer ?? row.developer ?? '?'}', submissionStatusWords(row.view)].where((s) => s.isNotEmpty).join(' · ')),
          ),
          if (row.status == 'submitted')
            SettingRow(key: const ValueKey('market-review-start'), icon: const AppIcon(Lucide.play, size: 18), label: _deciding == 'start' ? 'Starting…' : 'Start review', hint: const Tr('Its developer sees it\'s being reviewed.'), disabled: _deciding != null, onPress: () => unawaited(_decide(const ReviewDecision.start()))),
        ]),
        gap,
        PaneSection(key: const ValueKey('market-review-what'), title: 'What it can do', description: packHere() == 'phone' ? null : const Tr('As on a phone, where it does the most.'), children: [
          if (pack == null)
            SettingRowBox(child: Tr('It doesn\'t load here, so what it can do can\'t be said: see Checks.', style: quiet))
          else ...[
            for (final r in packReaches(pack, here: 'phone')) SettingRow(icon: AppIcon(r.icon, size: 18), label: r.label, hint: r.hint == null ? null : Text(r.hint!)),
            for (final a in packAdds(pack, here: 'phone')) SettingRow(icon: const AppIcon(Lucide.plus, size: 18), label: a),
            if (previous != null && grew != null && (grew.reaches.isNotEmpty || grew.adds.isNotEmpty)) ...[
              SettingRowBox(key: const ValueKey('market-review-new'), child: Text('New in this version:', style: pageText(t, t.fontSize('md'), weight: 'semibold', color: t.color('app-ink')))),
              for (final r in grew.reaches) SettingRow(icon: AppIcon(r.icon, size: 18), label: r.label, hint: r.hint == null ? null : Text(r.hint!)),
              for (final a in grew.adds) SettingRow(icon: const AppIcon(Lucide.plus, size: 18), label: a),
            ],
          ],
        ]),
        gap,
        PaneSection(
          key: const ValueKey('market-review-risky'),
          title: 'Look closely',
          description: const Tr('What acts on texts or reaches outside it, set apart from its phrases.'),
          children: [
            if (closely.isEmpty) SettingRowBox(child: Tr('Nothing: it only tags and sorts.', style: quiet)) else lines(closely, style: mono),
            if (closelyBefore != null) ...[
              SettingRowBox(child: Text('Since ${item.previous!.version}:', style: pageText(t, t.fontSize('sm'), weight: 'semibold', color: t.color('app-ink-2')))),
              lines([
                for (final l in closely) if (!closelyBefore.contains(l)) '+ $l',
                for (final l in closelyBefore) if (!closely.contains(l)) '- $l',
              ].ifNone('No change among these.'), style: mono),
            ],
          ],
        ),
        gap,
        PaneSection(key: const ValueKey('market-review-checks'), title: 'Checks', children: [
          SettingRow(icon: AppIcon(shaOk ? Lucide.circleCheck : Lucide.circleX, size: 18), label: shaOk ? 'SHA-256 matches' : 'SHA-256 doesn\'t match', hint: Text(shaOk ? _sha : 'Worked out here: $_sha. The store says: ${row.view.sha256}.')),
          SettingRow(icon: AppIcon(_canonical ? Lucide.circleCheck : Lucide.circleX, size: 18), label: _canonical ? 'Sent canonical' : 'Not sent canonical'),
          if (pack != null && (pack.id != row.plugin || pack.version != row.version))
            SettingRow(icon: const AppIcon(Lucide.circleX, size: 18), label: 'Its file says ${pack.id} ${pack.version}, the submission ${row.plugin} ${row.version}'),
          if ((_parse?.issues ?? const []).isEmpty)
            SettingRow(icon: const AppIcon(Lucide.circleCheck, size: 18), label: 'No problems found')
          else
            lines(issueLines(_parse!.issues, (i) => '${i.isError ? 'error' : 'warning'} ${i.code}${i.path.isEmpty ? '' : ' at ${i.path}'}: ${i.message}'), style: mono),
        ]),
        if (pack != null) ...[
          gap,
          TryPackSection(pack, key: ValueKey('market-review-try-${widget.sid}'), keyPrefix: 'market-review-', store: AppStore(AppState.of(context))),
        ],
        gap,
        PaneSection(key: const ValueKey('market-review-manifest'), title: 'The file', children: [
          SettingRowBox(
            child: SizedBox(
              height: t.lenOf('22rem'),
              child: SingleChildScrollView(
                child: SingleChildScrollView(scrollDirection: Axis.horizontal, child: Text(_pretty ?? utf8.decode(_bytes, allowMalformed: true), style: mono)),
              ),
            ),
          ),
        ]),
        if (item.previous != null) ...[
          gap,
          PaneSection(key: const ValueKey('market-review-diff'), title: 'Changes since ${item.previous!.version}', children: [
            if (_diff != null) diffBox(_diff!) else SettingRowBox(child: Text(_diffTooBig ? 'Too different to compare here' : (_diffing ? 'Comparing…' : 'Couldn\'t compare them.'), style: quiet)),
          ]),
        ],
        if (item.asked != null) ...[
          gap,
          PaneSection(key: const ValueKey('market-review-diff-asked'), title: 'Changes since you asked', children: [
            if (_diffAsked != null) diffBox(_diffAsked!) else SettingRowBox(child: Text(_diffAskedTooBig ? 'Too different to compare here' : (_diffing ? 'Comparing…' : 'Couldn\'t compare them.'), style: quiet)),
          ]),
        ],
        gap,
        PaneSection(
          key: const ValueKey('market-review-listing'),
          title: 'Its listing',
          footer: const Tr('Check the screenshots show no real person\'s texts or number.'),
          children: [
            if (shotShas.isNotEmpty)
              SettingRowBox(
                child: SizedBox(
                  height: t.lenOf('14rem'),
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: shotShas.length,
                    separatorBuilder: (context, _) => SizedBox(width: t.space(2)),
                    itemBuilder: (context, n) {
                      final height = t.lenOf('14rem');
                      final image = _shots[n];
                      if (!_shots.containsKey(n)) return SizedBox(width: height * 0.5, height: height, child: Center(child: Text('…', style: quiet)));
                      if (image == null) {
                        return Container(key: ValueKey('market-review-shot-$n'), width: height * 0.6, height: height, alignment: Alignment.center, color: t.color('app-paper-3'), padding: EdgeInsets.all(t.space(2)), child: Text(_shotsFailed.contains(n) ? 'Couldn\'t load this picture. Refresh to try again.' : _shotsWrong[n] ?? 'Can\'t show this picture here', textAlign: TextAlign.center, style: quiet));
                      }
                      final width = height * image.width / math.max(1, image.height);
                      return SizedBox(key: ValueKey('market-review-shot-$n'), width: width, height: height, child: RawImage(image: image, fit: BoxFit.contain, filterQuality: FilterQuality.medium));
                    },
                  ),
                ),
              )
            else
              SettingRowBox(child: Tr('No screenshots.', style: quiet)),
            if ((pack?.whatsNew ?? '').isNotEmpty) SettingRow(icon: const AppIcon(Lucide.sparkles, size: 18), label: 'What\'s new', hint: Text(pack!.whatsNew!)),
            SettingRow(icon: const AppIcon(Lucide.mail, size: 18), label: 'Help link or email', hint: Text(pack?.support ?? row.view.support ?? 'None')),
            if (developerNote != null) SettingRow(icon: const AppIcon(Lucide.messageSquare, size: 18), label: 'The developer\'s notes', hint: Text(developerNote.text)),
          ],
        ),
        gap,
        PaneSection(title: 'The developer', children: [
          SettingRow(
            key: const ValueKey('market-review-developer'),
            icon: AppIcon(row.verified ? Lucide.userCheck : Lucide.userX, size: 18),
            label: ['@${item.developer.username ?? row.developer ?? '?'}', '${item.developer.plugins} ${item.developer.plugins == 1 ? 'plugin' : 'plugins'}', '${item.developer.submissions} ${item.developer.submissions == 1 ? 'submission' : 'submissions'}', if (item.developer.firstAt > 0) 'first ${marketDate(item.developer.firstAt)}'].join(' · '),
            hint: Text([row.verified ? 'Number verified' : 'Number not verified', if (item.developer.blocked) 'blocked'].join(' · ')),
          ),
          SettingRow(key: const ValueKey('market-review-block'), icon: AppIcon(item.developer.blocked ? Lucide.circleCheck : Lucide.ban, size: 18), label: item.developer.blocked ? 'Let them submit again' : 'Block this developer', labelColor: item.developer.blocked ? null : t.danger, disabled: _busy, onPress: () => unawaited(_block(item.developer, blocked: !item.developer.blocked))),
          for (final h in item.history.take(8)) SettingRow(icon: const AppIcon(Lucide.history, size: 18), label: '${h.version} · ${submissionStatusWords(h)}', hint: Text(marketDate(h.submittedAt))),
        ]),
        gap,
        PaneSection(
          title: 'The decision',
          footer: approveWhy == null || !open ? null : Text(approveWhy, key: const ValueKey('market-review-approve-why'), style: TextStyle(color: t.danger)),
          children: [
            if (_held != null && _heldUnreachable) ...[
              SettingRow(icon: const AppIcon(Lucide.globe, size: 18), label: marketUnreachableWords),
              SettingRow(key: const ValueKey('market-review-again'), icon: const AppIcon(Lucide.refreshCw, size: 18), label: 'Try again', disabled: _deciding != null, onPress: () => unawaited(_decide(_held!))),
            ],
            SettingRowBox(child: MarketTextArea(key: const ValueKey('market-review-note'), controller: _note, label: 'Note', placeholder: 'A note for the developer: what to change, or why not. Needed to ask for changes or to reject.'.t, most: 2000, minLines: 3, maxLines: 10)),
            if (item.previous != null && open && _previousSha != null)
              SettingRow(
                icon: const AppIcon(Lucide.undo2, size: 18),
                label: 'Withdraw ${item.previous!.version} too',
                hint: const Tr('Off: devices that haven\'t updated keep it. On: it\'s switched off on each of them.'),
                control: GlacierSwitch(key: const ValueKey('market-review-revoke-previous'), checked: _revokePrevious, onCheckedChange: (on) => setState(() => _revokePrevious = on), ariaLabel: 'Withdraw ${item.previous!.version} too'),
              )
            else if (item.previous != null && open)
              SettingRow(
                key: const ValueKey('market-review-revoke-previous-off'),
                icon: const AppIcon(Lucide.undo2, size: 18),
                label: 'Withdraw ${item.previous!.version} too',
                hint: const Tr('Can\'t from here: the copy of it the Marketplace sent doesn\'t check out on this device.'),
                disabled: true,
              ),
            SettingRow(
              key: const ValueKey('market-review-approve'),
              icon: const AppIcon(Lucide.circleCheck, size: 18),
              label: _deciding == 'approve' ? 'Approving…' : 'Approve and list',
              // A plugin whose current version is off the Marketplace stays off it where its developer took it off: the
              // relay keeps their choice, whatever this version's list says (C.6), and only review's own unlisting lists
              // again with an approval.
              hint: Text(row.view.list == 'later'
                  ? 'Its developer asked to list it themselves once it\'s approved.'
                  : current?.listing == 'unlisted'
                      ? 'Signed here with this device\'s key, and listed, unless its developer took it off the Marketplace.'
                      : 'Signed here with this device\'s key, and listed.'),
              disabled: approveWhy != null || _deciding != null,
              onPress: approveWhy != null ? null : () => unawaited(_approve()),
            ),
            SettingRow(key: const ValueKey('market-review-changes'), icon: const AppIcon(Lucide.pencil, size: 18), label: _deciding == 'changes' ? 'Asking…' : 'Ask for changes', disabled: !open || _deciding != null, onPress: !open ? null : () => unawaited(_ask('changes'))),
            SettingRow(key: const ValueKey('market-review-reject'), icon: AppIcon(Lucide.circleX, size: 18, color: t.danger), label: _deciding == 'reject' ? 'Rejecting…' : 'Reject', labelColor: t.danger, disabled: !(open || row.status == 'changes_requested') || _deciding != null, onPress: !(open || row.status == 'changes_requested') ? null : () => unawaited(_ask('reject'))),
          ],
        ),
        if (current != null) ...[
          gap,
          PaneSection(title: 'Its listing now', children: [
            if (current.listing == 'listed')
              SettingRow(key: const ValueKey('market-review-unlist'), icon: const AppIcon(Lucide.eyeOff, size: 18), label: 'Unlist', hint: Text('${current.version} is listed.'), disabled: _busy, onPress: () => unawaited(_setListed(false)))
            else
              SettingRow(key: const ValueKey('market-review-relist'), icon: const AppIcon(Lucide.store, size: 18), label: 'List again', hint: Text('${current.version} isn\'t listed.'), disabled: _busy, onPress: () => unawaited(_setListed(true))),
            if (row.status == 'approved' && row.view.revokedAt == null)
              SettingRow(
                key: const ValueKey('market-review-revoke'),
                icon: AppIcon(Lucide.ban, size: 18, color: t.danger),
                label: 'Withdraw this version',
                labelColor: t.danger,
                hint: Text(_revokeWhy ?? 'Switched off on every device that has it, with your reason.'),
                disabled: _busy || _revokeWhy != null,
                onPress: _revokeWhy != null ? null : _revoke,
              ),
          ]),
        ],
        if (row.view.revokedAt != null) ...[
          gap,
          PaneSection(children: [SettingRow(icon: AppIcon(Lucide.ban, size: 18, color: t.danger), label: 'Withdrawn by review: ${row.view.revokedWhy ?? ''}')]),
        ],
        SizedBox(height: t.space(2)),
        Text('Sent ${marketDate(row.view.submittedAt)}${row.view.list == 'later' ? ' · its developer lists it themselves' : ''}', style: body.copyWith(color: t.color('app-ink-3'), fontSize: t.fontSize('sm'))),
      ],
    );
  }
}

extension on List<String> {
  List<String> ifNone(String words) => isEmpty ? [words] : this;
}
