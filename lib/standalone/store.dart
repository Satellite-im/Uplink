/// Where a device of its own keeps what it keeps (lib/standalone/standalone.dart, [StandaloneCalls]): one text of
/// JSON (the choices, the friends by username, the conversations), the key that is who this device is, and the
/// secrets kept by name beside it (the account's words, forward secrecy's prekeys, circles' keys).
///
/// On a computer and an iPhone it is a folder and the Keychain (store_files.dart, exactly as before there was this).
/// A browser has neither: there it is the page's own IndexedDB, every record sealed with a key the page can use and
/// not read out (lib/web/store.dart; Matt: "the full web client").
abstract class StandaloneStore {
  /// Made ready, before anything is read.
  Future<void> open();

  /// The JSON as it was last kept, or null where there is none yet. Throws [StoreLost] where it is there and can't be
  /// opened, and whatever else stopped it being read just now: the app does not start on that, so it never writes
  /// over what it couldn't read (StandaloneCalls.load).
  Future<String?> readState();

  /// What [readState] gave makes no sense (damaged, or written by something else): kept aside where it can be (a
  /// computer's or an iPhone's folder keeps it beside the rest), so the app can start without writing over it. A
  /// browser's store can't be trusted after it, and throws [StoreLost].
  Future<void> unreadableState();

  /// Keeps [text] as the JSON, whole or not at all. Never two at once: whoever calls waits for one before the next.
  Future<void> writeState(String text);

  /// The key that is who this device is (64 hex digits), or null where there is none yet. Throws [StoreLost] where it
  /// is there and can't be opened, or is missing from a store that has the rest.
  Future<String?> readIdentity();

  /// Keeps [hex] as that key: one made here for a device that had none, or ([imported]) another put in its place as
  /// the device signs in to an account.
  Future<void> writeIdentity(String hex, {bool imported = false});

  /// The secret kept as [name], or null.
  Future<String?> readSecret(String name);

  /// Keeps [value] as [name].
  Future<void> writeSecret(String name, String value);

  /// Forgets what is kept as [name].
  Future<void> deleteSecret(String name);

  /// Everything kept deleted: the JSON, the key, every secret (lib/account: signed out with everything deleted, or
  /// removed from the account from another device).
  Future<void> wipe();

  /// Nothing more is written: what is asked to be written after this is let go (a page handing over to another tab,
  /// whose writes would cross this one's).
  void close();
}

/// What is kept is there and can't be opened, or is missing from what has the rest: kept no longer, and not to be
/// quietly replaced by a new identity while the choices beside it still name an account (lib/web/app.dart wipes it,
/// and the person signs in again).
class StoreLost implements Exception {
  StoreLost(this.name);
  final String name;
  @override
  String toString() => 'what is kept as $name can\'t be opened';
}
