import '../standalone/store.dart';
import 'browser.dart';

/// [StandaloneStore] for the app in a web page: the browser's own store for this page (IndexedDB, browser_web.dart).
///
/// What is kept here, and what that is worth (said the same way in Settings › About in a browser, lib/web/settings.dart,
/// web/index.html and docs/OPEN_NETWORK.md, part 6):
///
/// - **Every record is sealed**: the JSON (`state`: the conversations, the choices, friends, the circles' and spaces'
///   keys, the password-sealed copy of the account's backup), the key that is who this device is, and every secret
///   (forward secrecy's prekeys, circles' keys, the key the account's devices seal copies to each other with). Sealed
///   with AES-256-GCM under a key the browser made for this page as not extractable: the page's own code can't read
///   the key's bytes out.
/// - **What that does not do.** Anything that runs in this page can ask the browser to open every record with that key,
///   just as the app does: a script slipped into the page, or a browser extension allowed to read and change pages on
///   this address. And the key itself is kept among the browser profile's files: in Chrome, Edge and Firefox as it is,
///   so a copy of the profile opens everything; Safari wraps it with a key kept in the Keychain.
/// - **What is not kept here at all**: the recovery words and the key the password makes. They are opened from the
///   backup with the password each time they are wanted (lib/account/account.dart: showing the words, a new password,
///   the backup brought up to date, the devices listed or one removed) and forgotten again. The password-sealed copy
///   of the backup is kept, so whoever reads it could try passwords against it, as fast as they like: a long password
///   is what stands in the way. So is the key the account's devices seal copies to each other with (Me.mineSecret),
///   which opens every copy of what is said with friends by username, both ways, and never changes.
/// - **Signing out, or being removed from the account, deletes the whole database**, the key with it ([wipe]), and
///   asks the server for `Clear-Site-Data: "storage"`. Deleted, the database is gone to the page and to anyone using
///   the browser after; but the browser may keep its bytes among the profile's files for a while (Chrome did, the key
///   among them, until the clearing above took them away). On a shared computer, a private window, or clearing the
///   browser's data for the app, is safer.
class WebStandaloneStore implements StandaloneStore {
  WebStandaloneStore(this.store);
  final BrowserStore store;

  /// The records' names in the browser's store: the JSON, the identity's key, and each secret by its name.
  static const stateName = 'state', identityName = 'identity';
  static String secretName(String name) => 'secret:$name';

  /// The JSON was there as the page started: a store in use, which has an identity too.
  bool _hadState = false;

  @override
  Future<void> open() async {}

  /// [name], opened; what won't open means the whole store is lost.
  Future<String?> _sealed(String name) async {
    try {
      return await store.readSealed(name);
    } on BrowserStoreLost {
      throw StoreLost(name);
    }
  }

  @override
  Future<String?> readState() async {
    // Kept plain by a build from before every record was sealed: sealed now, in the same place.
    final plain = await store.readPlain(stateName);
    if (plain != null) {
      await store.writeSealed(stateName, plain);
      _hadState = true;
      return plain;
    }
    final text = await _sealed(stateName);
    _hadState = text != null;
    return text;
  }

  @override
  Future<void> writeState(String text) => store.writeSealed(stateName, text);

  /// Opened and makes no sense: what else this store holds can't be trusted either.
  @override
  Future<void> unreadableState() async => throw StoreLost(stateName);

  @override
  Future<String?> readIdentity() async {
    final hex = await _sealed(identityName);
    // The identity is written as the page first starts, before anything else is: a store with the rest and not that
    // has lost it, and must not quietly become someone new while its choices still say whose account it is.
    if (hex == null && _hadState) throw StoreLost(identityName);
    return hex;
  }

  @override
  Future<void> writeIdentity(String hex, {bool imported = false}) => store.writeSealed(identityName, hex);

  @override
  Future<String?> readSecret(String name) => _sealed(secretName(name));

  @override
  Future<void> writeSecret(String name, String value) => store.writeSealed(secretName(name), value);

  @override
  Future<void> deleteSecret(String name) => store.delete(secretName(name));

  @override
  Future<void> wipe() => store.wipe();

  @override
  void close() => store.close();
}
