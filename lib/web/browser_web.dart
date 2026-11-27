import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'browser.dart';

/// The browser this page is in (browser.dart): the one file of the app in a web page that speaks to JavaScript for
/// what it keeps and for being the only tab. Nothing here is fetched from anywhere: it is all the browser's own.
Browser browser() => _PageBrowser();

/// [Browser] by the page's own window: its address, its storage, the lock between tabs and the channel they speak on.
class _PageBrowser implements Browser {
  @override
  Uri get address => Uri.parse(web.window.location.href);

  @override
  String get name => browserNameOf(web.window.navigator.userAgent);

  @override
  String? get unfit {
    // Sealing what is kept (crypto.subtle) and the one-tab lock are given only to a page from a secure address:
    // https, or this computer itself.
    if (!web.window.isSecureContext) return 'Uplink needs a secure address to run in a browser: one that starts with https.';
    // Without the browser's lock between tabs nothing makes sure the app is open in one tab at a time: two would both
    // be this device to the relay, each taking the other's place, and both would write the one store, each over the
    // other's conversations. Every browser of the last few years has it (Chrome and Edge 69, Firefox 96, Safari 15.4).
    if (!(web.window.navigator as JSObject).has('locks') || !(web.window as JSObject).has('BroadcastChannel')) {
      return 'This browser is too old for Uplink. It can\'t make sure the app is open in only one tab, which keeps each message from arriving twice and one tab from writing over another\'s conversations. A recent Chrome, Edge, Firefox or Safari can.';
    }
    return null;
  }

  @override
  Future<BrowserStore> openStore() => _PageStore.open();

  @override
  Future<bool> keep() async {
    try {
      if (!(web.window.navigator as JSObject).has('storage')) return false;
      final storage = web.window.navigator.storage;
      if (!(storage as JSObject).has('persist')) return false;
      return (await storage.persist().toDart).toDart;
    } catch (_) {
      return false;
    }
  }

  // --- one tab at a time ---------------------------------------------------------------------------------------------

  /// What the tabs of one browser are all asking for, and where they speak to each other.
  static const _name = 'ghost-messaging-tab';

  /// The channel the tabs speak on, opened when first used.
  web.BroadcastChannel? _channel;
  web.BroadcastChannel get _talk => _channel ??= web.BroadcastChannel(_name);

  /// This tab is the app's.
  bool _mine = false;

  /// Completing it lets the lock go.
  Completer<JSAny?>? _held;

  /// What the app gave to be run when another tab asks to be the app's, and when one has taken it.
  Future<void> Function()? _onAsked;
  void Function()? _onTaken;

  /// Hears the other tabs from now on: one asking for the tab is told at once that this one is letting go, and is
  /// given it once [_onAsked] is done (the routes shut down, everything written): the lock is let go, then this page
  /// starts again as the tab that isn't it.
  void _hear() {
    final channel = _talk;
    var going = false;
    channel.onmessage = ((web.MessageEvent e) {
      if (!_mine || going || e.data.dartify() != 'yield') return;
      going = true;
      channel.postMessage('yielding'.toJS);
      final asked = _onAsked;
      // However long writing takes, the other tab waits (takeTab); ten seconds is far past any write, and a page that
      // can't finish by then lets go all the same rather than hold the app away from the other for ever.
      (asked == null ? Future<void>.value() : asked()).timeout(const Duration(seconds: 10), onTimeout: () {}).catchError((Object _) {}).whenComplete(() {
        _mine = false;
        _held?.complete(null);
        channel.postMessage('yielded'.toJS);
        reload();
      });
    }).toJS;
  }

  /// Waits [wait] for another tab to say one of [words], having said [after].
  Future<bool> _heard(Set<String> words, Duration wait, {required String after}) {
    final channel = _talk;
    final heard = Completer<bool>();
    void listener(web.Event e) {
      if (words.contains((e as web.MessageEvent).data.dartify()) && !heard.isCompleted) heard.complete(true);
    }

    final js = listener.toJS;
    channel.addEventListener('message', js);
    channel.postMessage(after.toJS);
    return heard.future.timeout(wait, onTimeout: () => false).whenComplete(() => channel.removeEventListener('message', js));
  }

  /// Asks the browser for the lock: only where it is free ([free]), waiting up to [within] for the tab that has it to
  /// let go, or ([steal]) from whichever tab has it. True where this tab has it now; it is kept until [_held] is
  /// completed or the page goes.
  Future<bool> _lock({bool free = false, bool steal = false, Duration within = Duration.zero}) {
    final got = Completer<bool>();
    final held = Completer<JSAny?>();
    Timer? giveUp;
    final web.LockOptions options;
    if (free) {
      options = web.LockOptions(ifAvailable: true);
    } else if (steal) {
      options = web.LockOptions(steal: true);
    } else {
      final abort = web.AbortController();
      giveUp = Timer(within, () => abort.abort());
      options = web.LockOptions(signal: abort.signal);
    }
    final asked = web.window.navigator.locks.request(
      _name,
      options,
      ((web.Lock? lock) {
        giveUp?.cancel();
        if (lock == null) {
          if (!got.isCompleted) got.complete(false);
          return null;
        }
        if (!got.isCompleted) got.complete(true);
        _held = held;
        // Held for as long as this is not done.
        return held.future.toJS;
      }).toJS,
    );
    asked.toDart.then((_) {}, onError: (Object _) {
      giveUp?.cancel();
      if (!got.isCompleted) {
        // The wait ran out.
        got.complete(false);
      } else if (_mine) {
        // Taken from this tab by another that heard nothing from it in time: nothing more is written here, and this page
        // starts again, as the one that isn't it.
        _mine = false;
        _onTaken?.call();
        reload();
      }
    });
    return got.future;
  }

  @override
  Future<TabHold?> holdTab({required Future<void> Function() onAsked, void Function()? onTaken}) async {
    _onAsked = onAsked;
    _onTaken = onTaken;
    if (!await _lock(free: true)) return null;
    _mine = true;
    _hear();
    return _Held();
  }

  @override
  Future<TabHold> takeTab({required Future<void> Function() onAsked, void Function()? onTaken}) async {
    _onAsked = onAsked;
    _onTaken = onTaken;
    // Gone since this page said so: taken without asking anyone.
    var got = await _lock(free: true);
    if (!got) {
      // Asked first: the tab that is it says so at once, shuts its routes down, writes what it has, and lets go, and
      // this one waits for that, however long the writing takes. Taken from it only where it says nothing at all (it
      // was closed, or the browser has put it to sleep and it isn't writing anything).
      final answered = await _heard(const {'yielding', 'yielded'}, const Duration(milliseconds: 1500), after: 'yield');
      if (answered) got = await _lock(within: const Duration(seconds: 15));
      if (!got) got = await _lock(steal: true);
    }
    _mine = true;
    _hear();
    return _Held();
  }

  @override
  void reload({String? note}) {
    final here = web.window.location;
    if (note != null && pageNotes.contains(note)) web.window.history.replaceState(null, '', '${here.pathname}${here.search}#$note');
    here.reload();
  }

  @override
  String? takeNote() {
    final here = web.window.location;
    final hash = here.hash.startsWith('#') ? here.hash.substring(1) : here.hash;
    if (!pageNotes.contains(hash)) return null;
    web.window.history.replaceState(null, '', '${here.pathname}${here.search}');
    return hash;
  }

  @override
  void onVisible(void Function() then) {
    web.document.addEventListener(
      'visibilitychange',
      ((web.Event _) {
        if (web.document.visibilityState == 'visible') then();
      }).toJS,
    );
  }

  @override
  bool openTab(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || url != url.trim() || (uri.scheme != 'http' && uri.scheme != 'https') || uri.host.isEmpty) return false;
    // No way back to this page from the one opened, and it is not told where it was opened from.
    web.window.open(uri.toString(), '_blank', 'noopener,noreferrer');
    return true;
  }
}

/// This page's being the one tab: it holds nothing itself, the lock is the browser's and goes with the page.
class _Held implements TabHold {}

/// The page's own IndexedDB: one database, one store of named records, every one sealed: twelve random bytes and then
/// AES-256-GCM's output under the key kept as [_keyName], the record's name bound in. The key is made by the browser
/// as not extractable, so the page's code can't read it out; what that is worth is said in lib/web/store.dart.
class _PageStore implements BrowserStore {
  _PageStore(this._db, this._key) {
    // Another page deleting the database (the app wiping it from the tab that is it): this connection goes, so the
    // deletion isn't held up by it.
    _db.onversionchange = ((web.Event _) {
      _closed = true;
      _db.close();
    }).toJS;
  }

  static const _dbName = 'ghost-messaging', _records = 'kept', _keyName = 'seal-key';

  final web.IDBDatabase _db;

  /// Made by the browser as not extractable: `encrypt` and `decrypt` take it, and nothing gives its bytes.
  final web.CryptoKey _key;

  /// Nothing more is written ([close]); and the database is gone ([wipe]).
  bool _closed = false, _gone = false;

  @override
  void Function(String name)? onLost;

  /// Opens the database, made with its one store of records where it is new, and finds or makes the key.
  static Future<_PageStore> open() async {
    final opening = web.window.indexedDB.open(_dbName, 1);
    opening.onupgradeneeded = ((web.Event _) {
      final db = opening.result as web.IDBDatabase;
      if (!db.objectStoreNames.contains(_records)) db.createObjectStore(_records);
    }).toJS;
    final db = (await _asked(opening)) as web.IDBDatabase;
    return _PageStore(db, await _keyOf(db));
  }

  /// The store's key: the one kept, or, where there is none, one made now and kept, in one transaction, so two pages
  /// opening the store at once end with the one key (one each was the way one page's records came to be sealed under
  /// a key the next had replaced). The browser makes a key asynchronously, and a transaction ends once nothing is
  /// asked of it, so a key is made first, and kept only where none is.
  static Future<web.CryptoKey> _keyOf(web.IDBDatabase db) async {
    final made = (await web.window.crypto.subtle
        .generateKey(_object({'name': 'AES-GCM'.toJS, 'length': 256.toJS}), false, ['encrypt'.toJS, 'decrypt'.toJS].toJS)
        .toDart) as web.CryptoKey;
    final done = Completer<web.CryptoKey>();
    final tx = db.transaction(_records.toJS, 'readwrite');
    final store = tx.objectStore(_records);
    web.CryptoKey? chosen;
    final asked = store.get(_keyName.toJS);
    asked.onsuccess = ((web.Event _) {
      final had = asked.result;
      if (had != null && had.isA<web.CryptoKey>()) {
        chosen = had as web.CryptoKey;
      } else {
        chosen = made;
        store.put(made, _keyName.toJS);
      }
    }).toJS;
    tx.oncomplete = ((web.Event _) {
      if (!done.isCompleted) done.complete(chosen!);
    }).toJS;
    void failed(web.Event _) {
      if (!done.isCompleted) done.completeError(StateError('the browser\'s store: ${tx.error?.message ?? 'the key was not kept'}'));
    }

    tx.onerror = failed.toJS;
    tx.onabort = failed.toJS;
    return done.future;
  }

  /// What [request] comes to: its result, or a [StateError] with the browser's reason.
  static Future<JSAny?> _asked(web.IDBRequest request) {
    final done = Completer<JSAny?>();
    request.onsuccess = ((web.Event _) => done.complete(request.result)).toJS;
    request.onerror = ((web.Event _) => done.completeError(StateError('the browser\'s store: ${request.error?.message ?? 'refused'}'))).toJS;
    return done.future;
  }

  /// The record kept under [name], as the database holds it (sealed); null where there is none.
  static Future<JSAny?> _get(web.IDBDatabase db, String name) => _asked(db.transaction(_records.toJS).objectStore(_records).get(name.toJS));

  /// Done when the browser says the write is kept, not when it was asked for. Nothing once the store is closed.
  Future<void> _write(void Function(web.IDBObjectStore store) change) {
    if (_closed) return Future.value();
    final done = Completer<void>();
    final tx = _db.transaction(_records.toJS, 'readwrite');
    tx.oncomplete = ((web.Event _) => done.complete()).toJS;
    void failed(web.Event _) {
      if (!done.isCompleted) done.completeError(StateError('the browser\'s store: ${tx.error?.message ?? 'the write was not kept'}'));
    }

    tx.onerror = failed.toJS;
    tx.onabort = failed.toJS;
    change(tx.objectStore(_records));
    return done.future;
  }

  @override
  Future<String?> readPlain(String name) async {
    if (_gone) return null;
    final got = await _get(_db, name);
    return got != null && got.isA<JSString>() ? (got as JSString).toDart : null;
  }

  @override
  Future<void> delete(String name) => _write((s) => s.delete(name.toJS));

  /// AES-GCM under [nonce], with the record's own name bound in: one record's bytes put under another name don't open.
  static JSObject _params(Uint8List nonce, String name) =>
      _object({'name': 'AES-GCM'.toJS, 'iv': nonce.toJS, 'additionalData': Uint8List.fromList(utf8.encode('ghost-messaging kept v1|$name')).toJS});

  /// A plain JavaScript object of [fields], as the browser's sealing takes its settings.
  static JSObject _object(Map<String, JSAny?> fields) {
    final o = JSObject();
    fields.forEach((name, value) => o[name] = value);
    return o;
  }

  @override
  Future<void> writeSealed(String name, String value) async {
    if (_closed) return;
    final filled = _random(12);
    final sealed = (await web.window.crypto.subtle.encrypt(_params(filled, name), _key, Uint8List.fromList(utf8.encode(value)).toJS).toDart) as JSArrayBuffer;
    final out = Uint8List(12 + sealed.toDart.lengthInBytes)
      ..setRange(0, 12, filled)
      ..setRange(12, 12 + sealed.toDart.lengthInBytes, sealed.toDart.asUint8List());
    await _write((s) => s.put(out.toJS, name.toJS));
  }

  /// [n] bytes from the browser's own random. Read back from what JavaScript filled: a list handed over may be a
  /// copy there.
  static Uint8List _random(int n) {
    final js = Uint8List(n).toJS;
    web.window.crypto.getRandomValues(js);
    return js.toDart;
  }

  /// The record [name] is there and can't be opened: the app is told ([onLost]), and [BrowserStoreLost] is thrown.
  Never _lost(String name) {
    onLost?.call(name);
    throw BrowserStoreLost(name);
  }

  @override
  Future<String?> readSealed(String name) async {
    if (_gone) return null;
    final got = await _get(_db, name);
    if (got == null) return null;
    if (!got.isA<JSUint8Array>()) _lost(name);
    final bytes = (got as JSUint8Array).toDart;
    if (bytes.length < 12 + 16) _lost(name);
    final JSArrayBuffer clear;
    try {
      clear = (await web.window.crypto.subtle.decrypt(_params(Uint8List.sublistView(bytes, 0, 12), name), _key, Uint8List.sublistView(bytes, 12).toJS).toDart) as JSArrayBuffer;
    } catch (_) {
      // Sealed under another key, or changed: what this page kept can't be trusted, nor anything beside it.
      _lost(name);
    }
    return utf8.decode(clear.toDart.asUint8List());
  }

  @override
  Future<void> wipe() async {
    _closed = true;
    _gone = true;
    // This page's own connection first, or the deletion would wait on it.
    _db.close();
    final asked = web.window.indexedDB.deleteDatabase(_dbName);
    final done = Completer<void>();
    asked.onsuccess = ((web.Event _) {
      if (!done.isCompleted) done.complete();
    }).toJS;
    asked.onerror = ((web.Event _) {
      if (!done.isCompleted) done.completeError(StateError('the browser\'s store: ${asked.error?.message ?? 'it was not deleted'}'));
    }).toJS;
    // Held up by a connection in another page (one that has not let go yet): that page is told (versionchange) and
    // closes its own, and the deletion goes on. Waited for, so the page doesn't start again with the database there.
    await done.future.timeout(const Duration(seconds: 15), onTimeout: () {});
    // And the browser told, by the page's own address, to clear everything it keeps for it (relay/lib/web_app.dart,
    // app.gogho.st's block: `Clear-Site-Data: "storage"`, answered only where the browser says the asking came from
    // this very page, `Sec-Fetch-Site: same-origin`, which its fetch says by itself): Chromium leaves a deleted
    // database's bytes, its key among them, in the profile's files until it next tidies them, and this takes them away.
    // A server that doesn't answer it leaves them; what the app says of that is in lib/web/store.dart.
    try {
      await web.window
          .fetch('clear-site-data'.toJS, web.RequestInit(method: 'GET', cache: 'no-store', credentials: 'same-origin'))
          .toDart
          .timeout(const Duration(seconds: 10));
    } catch (_) {}
  }

  @override
  void close() => _closed = true;
}
