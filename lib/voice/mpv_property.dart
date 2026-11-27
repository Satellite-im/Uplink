/// One of libmpv's own settings on a media_kit player (lib/voice/recording_playback.dart). media_kit's player in a
/// browser is the page's own, with no such settings and no way to name the one that has them, so there this does
/// nothing (mpv_property_web.dart).
library;

export 'mpv_property_io.dart' if (dart.library.js_interop) 'mpv_property_web.dart';
