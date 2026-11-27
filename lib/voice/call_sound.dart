/// What the others in a call say, played on this device (lib/voice/rtc.dart). On a phone and a computer WebRTC plays
/// every sound a connection receives by itself, so there is nothing to do (call_sound_none.dart). A browser plays a
/// received sound only through a media element of the page's: without one a call in a browser is silent while every
/// number says the sound is arriving (call_sound_web.dart).
library;

export 'call_sound_none.dart' if (dart.library.js_interop) 'call_sound_web.dart';

/// What a call in a browser leaves out, as Settings › Voice and video and the call itself say it: what needs the native
/// halves (lib/voice/voice_fx.dart, recorder.dart, rtc.dart's screen) a page hasn't got.
const callsInBrowser = 'In a browser a call has no recording, no voice changer, no noise removal beyond the browser\'s own, no '
    'boost past 100% and no screen sharing. Those are in Uplink on a phone or a computer.';
