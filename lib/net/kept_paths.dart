/// Where a device keeps what is out of any backup (kept_files.dart), worked out from what it is: apart from the files
/// themselves, so a test can ask it of any platform.
library;

/// The folder [name] is kept in on a device of [os] (`android`, `ios`, `macos`, `windows`, `linux`), and the build's own
/// (the second review, N5: a release, a `flutter run` and any other build of the app never share one):
///
/// - Android: under [base], the folder Android gives the installed app for files no backup takes
///   (Context.getNoBackupFilesDir).
/// - An iPhone: under [base], the app's Caches folder in its own container, which iOS never backs up.
/// - A Mac: under [base], the person's Caches folder under this build's bundle id (the app is outside the sandbox, so
///   nothing else makes the folder its own).
/// - Windows, Linux: under the person's local (unroamed) app data, or their cache folder, under the app's name ([env]).
///
/// On a computer a build other than a release ([mode] `debug` or `profile`: a `flutter run`) keeps its own beside the
/// release's (`ledger-debug`), as it may run while the release does. A phone runs one build of the app at a time. Null
/// where none can be named.
String? keptPathFor(String name, {required String os, String? base, Map<String, String> env = const {}, String mode = 'release'}) {
  final own = mode == 'release' || os == 'android' || os == 'ios' ? name : '$name-$mode';
  String? join(String? from, List<String> parts) => from == null || from.isEmpty ? null : [from, ...parts].join(os == 'windows' ? r'\' : '/');
  return switch (os) {
    'android' || 'ios' || 'macos' => join(base, [own]),
    // The folder's name on disk stays what every install already has (the app was Ghost Messaging until 2026-11-27):
    // renamed, a Windows PC would lose what it keeps.
    'windows' => join(env['LOCALAPPDATA'], ['Ghost Messaging', own]),
    'linux' => join(env['XDG_CACHE_HOME'] ?? (env['HOME'] == null ? null : '${env['HOME']}/.cache'), ['ghost-messaging', own]),
    _ => null,
  };
}
