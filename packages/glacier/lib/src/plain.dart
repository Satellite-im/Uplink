/// The app's plain build (`--dart-define=GHOST_PLAIN=true`, the app's lib/app/plain.dart): no pane of the kit's
/// glass blurs what is behind it. False in every other build, by a constant.
library;

const bool glacierPlain = bool.fromEnvironment('GHOST_PLAIN');
