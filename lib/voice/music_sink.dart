/// A player of this device's own for a circle's music sent without loss (lib/voice/spotify_lossless.dart): what is
/// given to it is played as it is, 48 kHz stereo 16-bit, beside the call's own sound and not through WebRTC, which is the
/// point of it and also its price: where WebRTC takes the echo of what it plays out of the microphone by itself, it knows
/// nothing of what this plays ([MusicWay]).
///
/// - **Mac and iPhone**: AVAudioEngine (macos/Runner/MusicSink.swift, ios/Runner/MusicSink.swift).
/// - **Android**: AudioTrack, as media (MusicSink.kt).
/// - **Windows**: WASAPI, shared (windows/runner/music_sink.cpp).
/// - **Linux and a browser**: none; the Opus plays there.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../platform_info.dart';

/// Where the sound goes: what decides whether music played beside WebRTC would come back through the microphone.
enum MusicTo {
  /// Headphones, as far as the system says.
  headphones,

  /// A speaker, as the system says.
  speakers,

  /// Something the system does not say is either (a USB box, a Bluetooth device, a PC's jack): its person is asked.
  unknown,

  /// A Bluetooth headset in a call, whose sound is a call's and not music's while its microphone is in use.
  callHeadset,

  /// No device there is.
  none,
}

class MusicWay {
  const MusicWay(this.to, this.rate, [this.device = '']);
  final MusicTo to;

  /// Which device it is, as the system names it: what its person says of it ("I'm wearing headphones") is of it alone.
  final String device;

  /// What the device runs at, frames a second; 0 where the system does not say.
  final int rate;

  @override
  bool operator ==(Object other) => other is MusicWay && other.to == to && other.rate == rate && other.device == device;
  @override
  int get hashCode => Object.hash(to, rate, device);
}

/// How a player stands: the frames it has not played, and how many times it has run out since it was opened.
class SinkNow {
  const SinkNow(this.waiting, this.dry);
  final int waiting, dry;
}

abstract class MusicSink {
  /// Opens it on the speaker [to] ('' for the system's own). False where it can't be.
  Future<bool> open(String to);

  /// Takes interleaved 16-bit samples, low byte first; plays from the first it is given until it runs out.
  Future<SinkNow?> write(Uint8List pcm);

  /// Forgets what waits.
  Future<void> clear();

  /// How loud, and whether it is heard at all. Changed over a few hundredths of a second, so it never clicks.
  Future<void> set({required double volume, required bool silent});

  /// Another speaker, as the call's is changed.
  Future<void> output(String to);

  /// Where the sound goes with the speaker [to] chosen. Asked without opening anything.
  Future<MusicWay> way(String to);

  Future<void> close();

  /// This device's; null where it has none.
  static MusicSink? here() => kIsWeb || !(PlatformInfo.isMacOS || PlatformInfo.isIOS || PlatformInfo.isAndroid || PlatformInfo.isWindows) ? null : ChannelSink();
}

/// The native one, by the `ghost/music` channel. One at a time: there is one music in one call.
class ChannelSink implements MusicSink {
  static const channel = MethodChannel('ghost/music');

  Future<T?> _ask<T>(String method, [Object? args]) async {
    try {
      return await channel.invokeMethod<T>(method, args);
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  @override
  Future<bool> open(String to) async => await _ask<bool>('open', {'device': to}) ?? false;

  @override
  Future<SinkNow?> write(Uint8List pcm) async {
    final m = await _ask<List<Object?>>('write', pcm);
    return m != null && m.length == 2 && m[0] is int && m[1] is int ? SinkNow(m[0] as int, m[1] as int) : null;
  }

  @override
  Future<void> clear() => _ask<void>('clear');
  @override
  Future<void> set({required double volume, required bool silent}) => _ask<void>('set', {'volume': volume, 'silent': silent});
  @override
  Future<void> output(String to) => _ask<void>('output', {'device': to});

  @override
  Future<MusicWay> way(String to) async {
    final m = await _ask<Map<Object?, Object?>>('way', {'device': to});
    final rate = m?['rate'];
    return MusicWay(
      switch (m?['to']) {
        'headphones' => MusicTo.headphones,
        'call' => MusicTo.callHeadset,
        'none' || null => MusicTo.none,
        'unknown' => MusicTo.unknown,
        _ => MusicTo.speakers,
      },
      rate is num ? rate.toInt() : 0,
      '${m?['id'] ?? ''}',
    );
  }

  @override
  Future<void> close() => _ask<void>('close');
}
