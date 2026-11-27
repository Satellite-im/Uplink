/// What the app in a web page asks of the browser it is in (lib/web/main.dart; Matt: "the full web client"):
/// somewhere to keep things, being the only tab of itself, a link opened beside it, and starting again. The browser's
/// own answers are in browser_web.dart, the one file here that speaks to JavaScript; anywhere else there is no
/// browser to ask (browser_none.dart), and a test stands [MemoryBrowser] in.
library;

import 'dart:async';

import 'browser_none.dart' if (dart.library.js_interop) 'browser_web.dart' as platform;

/// What a page is called in the account's list of devices, from the browser's own description of itself
/// ([userAgent]): "Browser", then which one and on what where it says ("Browser · Safari · Mac"). A page is none of the
/// five platforms and can't learn the computer's name, so two browsers are told apart by this. Only a few well-known
/// names are looked for; anything else is "Browser" alone.
String browserNameOf(String userAgent) {
  final ua = userAgent;
  // Each of these says it is the ones after it too, so the order is the test.
  final which = ua.contains('Firefox/') || ua.contains('FxiOS/')
      ? 'Firefox'
      : ua.contains('Edg/') || ua.contains('EdgA/') || ua.contains('EdgiOS/')
          ? 'Edge'
          : ua.contains('OPR/')
              ? 'Opera'
              : ua.contains('Chrome/') || ua.contains('CriOS/')
                  ? 'Chrome'
                  : ua.contains('Safari/')
                      ? 'Safari'
                      : null;
  final on = ua.contains('Android')
      ? 'Android'
      : ua.contains('iPhone') || ua.contains('iPad')
          ? 'iOS'
          : ua.contains('Windows')
              ? 'Windows'
              : ua.contains('CrOS')
                  ? 'ChromeOS'
                  : ua.contains('Mac OS X') || ua.contains('Macintosh')
                      ? 'Mac'
                      : ua.contains('Linux')
                          ? 'Linux'
                          : null;
  return ['Browser', ?which, ?on].join(' · ');
}

/// The words a page may be loaded again with ([Browser.reload]), said once on the welcome as it opens
/// (lib/standalone/welcome.dart): why the account is no longer in this browser.
const pageNotes = {'signed-out', 'removed', 'lost'};

/// What the app in a web page asks of its browser: the page's address, somewhere to keep things, being the only tab,
/// loading the page again. The page's own is lib/web/browser_web.dart; a test's is [MemoryBrowser].
abstract class Browser {
  /// The browser this page is in. A test puts its own here.
  static Browser instance = platform.browser();

  /// The page's address.
  Uri get address;

  /// What this browser is called in the account's list of devices ([browserNameOf]): "Browser · Chrome · Mac".
  String get name;

  /// Why the app can't run in this browser at all, in words for the person; null where it can. (No secure address: a
  /// browser gives a page neither the sealing nor the one-tab lock without one. No lock between tabs: two tabs would
  /// both be the device, and both write the one store.)
  String? get unfit;

  /// The page's own store. Throws where the browser will keep nothing for this page.
  Future<BrowserStore> openStore();

  /// Asks the browser to keep what the page keeps when it runs short of space (`navigator.storage.persist()`): true
  /// where it will. A browser that says no may still clear it, as it would any site's.
  Future<bool> keep();

  /// Asks to be the one tab of the app in this browser. [onAsked]: another tab wants to be it instead; shut down,
  /// finish what is being written, and the lock is let go and this page starts again as the tab that isn't it.
  /// [onTaken]: it was taken from this tab without waiting (this one said nothing in time): write nothing more, the
  /// page is starting again. Null where another tab is it already.
  Future<TabHold?> holdTab({required Future<void> Function() onAsked, void Function()? onTaken});

  /// Becomes the one tab, asking whichever tab is it to let go and waiting while it does; taken from it only where it
  /// says nothing at all (closed, or put to sleep by the browser).
  Future<TabHold> takeTab({required Future<void> Function() onAsked, void Function()? onTaken});

  /// The page, loaded again from the start; with [note] (one of [pageNotes]) said on the welcome as it opens.
  void reload({String? note});

  /// The note the page was loaded again with ([reload]), taken off the address so it is said once; null where none.
  String? takeNote();

  /// [url] opened in a tab beside this one, with no way back to this page from it; whether the browser did.
  bool openTab(String url);

  /// [then] each time the page is looked at again (its tab brought back to the front, the window shown again).
  void onVisible(void Function() then);
}

/// Being the one tab of the app. Held until the page goes.
abstract class TabHold {}

/// What is kept for this page is there and can't be opened: a sealed record under another key (two tabs once made one
/// each), or changed. The store is lost: it is wiped, and the person signs in again (lib/web/app.dart).
class BrowserStoreLost implements Exception {
  BrowserStoreLost(this.name);
  final String name;
  @override
  String toString() => 'what this browser keeps as $name can\'t be opened';
}

/// Named records that outlast the page, every one sealed: opened only with a key the browser holds for this page.
abstract class BrowserStore {
  /// A record kept plain by a build from before every record was sealed (lib/web/store.dart moves it); null where
  /// there is none, or it is sealed.
  Future<String?> readPlain(String name);

  Future<void> delete(String name);

  /// What [writeSealed] kept as [name], opened with the store's key; null where nothing is kept. Throws
  /// [BrowserStoreLost] where something is kept there and won't open.
  Future<String?> readSealed(String name);

  /// Keeps [value] as [name], whole or not at all, sealed first with a key the browser holds for this page and hands
  /// out to no one, the page included (a script running in the page can still ask it to open what it sealed).
  Future<void> writeSealed(String name, String value);

  /// Everything kept for the page deleted, the key with it (the whole database). Nothing is written after, and
  /// nothing more is read.
  Future<void> wipe();

  /// Nothing more is written (another tab is taking over, or the page is going): a write asked for after this is let
  /// go unwritten.
  void close();

  /// Told when a record is found that won't open while the app runs: the store is lost (lib/web/app.dart wipes it).
  void Function(String name)? onLost;
}

/// A [Browser] in memory, for a test: one store per browser, and tabs that ask each other as real ones do.
class MemoryBrowser implements Browser {
  MemoryBrowser({Uri? address, this.unfit, MemoryBrowserProfile? profile, this.name = 'Browser', this.note})
      : address = address ?? Uri.parse('https://relay.example/app/'),
        profile = profile ?? MemoryBrowserProfile();

  @override
  final Uri address;
  @override
  final String? unfit;
  @override
  final String name;

  /// What tabs of one browser share: the store, and which of them is the one.
  final MemoryBrowserProfile profile;

  /// The note the page was loaded with, until taken.
  String? note;

  int reloads = 0;

  /// The note each [reload] was asked with.
  final List<String?> reloadNotes = [];
  final List<String> opened = [];

  /// Set to have [openStore] fail, as a browser that keeps nothing for a page does.
  bool noStore = false;

  /// What [keep] answers, and how many times it was asked.
  bool keeps = true;
  int keepAsked = 0;

  @override
  Future<BrowserStore> openStore() async {
    if (noStore) throw StateError('no store here');
    return profile.store;
  }

  @override
  Future<bool> keep() async {
    keepAsked++;
    return keeps;
  }

  @override
  Future<TabHold?> holdTab({required Future<void> Function() onAsked, void Function()? onTaken}) async {
    if (profile._holder != null) return null;
    return profile._holder = _MemoryHold(onAsked);
  }

  @override
  Future<TabHold> takeTab({required Future<void> Function() onAsked, void Function()? onTaken}) async {
    final had = profile._holder;
    // The tab that has it is asked, and is waited for: it lets go once it has shut down and written what it had.
    await had?.onAsked();
    profile._holder = null;
    return profile._holder = _MemoryHold(onAsked);
  }

  @override
  void reload({String? note}) {
    reloads++;
    reloadNotes.add(note);
  }

  @override
  String? takeNote() {
    final n = note;
    note = null;
    return n != null && pageNotes.contains(n) ? n : null;
  }

  @override
  bool openTab(String url) {
    opened.add(url);
    return true;
  }

  /// What [onVisible] was given, run by [becomeVisible].
  final List<void Function()> _visible = [];

  @override
  void onVisible(void Function() then) => _visible.add(then);

  /// The page is looked at again, as a tab brought back to the front is.
  void becomeVisible() {
    for (final f in [..._visible]) {
      f();
    }
  }
}

/// What a test's tabs of one browser share: the store, and which tab is the app's.
class MemoryBrowserProfile {
  MemoryBrowserStore store = MemoryBrowserStore();
  _MemoryHold? _holder;

  /// The tab that was the one has gone (closed, or loaded again).
  void tabGone() => _holder = null;
}

/// A test tab's being the one, with what it runs when another asks for it.
class _MemoryHold implements TabHold {
  _MemoryHold(this.onAsked);
  final Future<void> Function() onAsked;
}

/// A [BrowserStore] in memory, for a test: it "seals" by a marker and the value backwards, so a test can see that
/// nothing is held as it was written.
class MemoryBrowserStore implements BrowserStore {
  /// Records kept plain, as a build from before kept the state: never written by this one.
  final Map<String, String> plain = {};

  /// What was sealed, as the store holds it: never the value itself.
  final Map<String, String> sealed = {};

  /// The database was deleted ([wipe]); and how many times.
  int wipes = 0;
  bool closed = false;

  /// Writes let go unwritten after [close] or [wipe].
  int dropped = 0;

  /// Set to have every read, or every write, fail as a browser's store can (busy, or full).
  bool failReads = false, failWrites = false;

  @override
  void Function(String name)? onLost;

  static String _seal(String value) => 'sealed:${String.fromCharCodes(value.codeUnits.reversed)}';

  @override
  Future<String?> readPlain(String name) async {
    if (failReads) throw StateError('the browser\'s store: busy');
    return plain[name];
  }

  @override
  Future<void> delete(String name) async {
    if (closed) return;
    plain.remove(name);
    sealed.remove(name);
  }

  @override
  Future<String?> readSealed(String name) async {
    if (failReads) throw StateError('the browser\'s store: busy');
    final kept = sealed[name];
    if (kept == null) return null;
    if (!kept.startsWith('sealed:')) {
      onLost?.call(name);
      throw BrowserStoreLost(name);
    }
    return String.fromCharCodes(kept.substring(7).codeUnits.reversed);
  }

  @override
  Future<void> writeSealed(String name, String value) async {
    if (closed) {
      dropped++;
      return;
    }
    if (failWrites) throw StateError('the browser\'s store: full');
    plain.remove(name);
    sealed[name] = _seal(value);
  }

  @override
  Future<void> wipe() async {
    closed = true;
    wipes++;
    plain.clear();
    sealed.clear();
  }

  @override
  void close() => closed = true;
}
