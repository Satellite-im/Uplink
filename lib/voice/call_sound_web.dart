import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter_webrtc/flutter_webrtc.dart' show MediaStreamTrack;
import 'package:web/web.dart' as web;

/// A browser's (lib/voice/call_sound.dart): each person's sound in an audio element of the page's own, kept out of
/// sight in one box, at their volume, silenced as RtcMedia says, through the speaker chosen where the browser lets a
/// page choose one.
class CallSound {
  static const bool playsItself = true;

  /// Chromium and Firefox let a page send an element's sound to a speaker of its choice (setSinkId); Safari doesn't,
  /// and plays through whatever the computer uses.
  static bool get canChooseOutput => web.HTMLAudioElement().has('setSinkId');

  /// An element plays no louder than the sound it is given.
  static const double most = 1.0;

  final Map<String, web.HTMLAudioElement> _playing = {};
  String _sink = '';

  static const _boxId = 'ghost-call-sound';

  web.Element _box() {
    final had = web.document.getElementById(_boxId);
    if (had != null) return had;
    final box = web.HTMLDivElement()
      ..id = _boxId
      ..style.display = 'none';
    web.document.body?.append(box);
    return box;
  }

  /// Plays [track] as [id]'s voice, in place of any sound of theirs before it (a connection made again).
  void play(String id, MediaStreamTrack track) {
    // The page's own track inside flutter_webrtc's (dart_webrtc's MediaStreamTrackWeb.jsTrack, a package the app
    // doesn't name: asked for by name, as the analyser reads this file as a phone's).
    final web.MediaStreamTrack js;
    try {
      js = (track as dynamic).jsTrack as web.MediaStreamTrack;
    } catch (_) {
      return;
    }
    final el = _playing[id] ??= (web.HTMLAudioElement()
      ..autoplay = true
      ..setAttribute('data-person', id));
    if (el.parentElement == null) _box().append(el);
    el.srcObject = web.MediaStream([js].toJS);
    if (_sink.isNotEmpty) _sinkTo(el, _sink);
    // Started as the call is joined, by the press that joined it; a browser that still says no leaves it waiting.
    el.play().toDart.ignore();
  }

  void set(String id, {required double volume, required bool silent}) {
    final el = _playing[id];
    if (el == null) return;
    el.volume = volume.clamp(0.0, most);
    el.muted = silent;
  }

  /// Every sound through the speaker [deviceId] ('' the computer's own): false where the browser can't choose.
  Future<bool> output(String deviceId) async {
    _sink = deviceId;
    if (!canChooseOutput) return false;
    var all = true;
    for (final el in _playing.values) {
      all = await _sinkTo(el, deviceId) && all;
    }
    return all;
  }

  static Future<bool> _sinkTo(web.HTMLAudioElement el, String deviceId) async {
    if (!el.has('setSinkId')) return false;
    try {
      await el.setSinkId(deviceId).toDart;
      return true;
    } catch (_) {
      return false;
    }
  }

  void stop(String id) {
    final el = _playing.remove(id);
    if (el == null) return;
    el.pause();
    el.srcObject = null;
    el.remove();
  }

  void stopAll() {
    for (final id in _playing.keys.toList()) {
      stop(id);
    }
  }
}
