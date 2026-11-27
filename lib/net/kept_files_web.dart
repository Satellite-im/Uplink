import 'forward_secrecy.dart' show FsStore;

/// In a browser (kept_files.dart): no files, and so no ledger, which a browser has no direct route to compare anyway.
FsStore? ledgerFiles() => null;

/// And nowhere to keep which route each person was last on (routes_kept.dart): a browser starts each time knowing none.
FsStore? routesFiles() => null;
