import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/voice/rtc.dart';

/// The level meter's silent partner (lib/voice/rtc.dart RtcMedia._openMeter) receives this device's microphone under
/// ids of its own. Under the microphone's own id, switching the partner's copy off switched the microphone off (the
/// others couldn't hear you) and the copy was played (you heard yourself). Matt, 2026-11-16: "I can hear myself also
/// if I mute and unmute in a space"; "I cant hear the other person that joined the space".
void main() {
  const offer = 'v=0\r\n'
      'a=group:BUNDLE 0\r\n'
      'a=msid-semantic: WMS stream-abc\r\n'
      'm=audio 9 UDP/TLS/RTP/SAVPF 111\r\n'
      'a=mid:0\r\n'
      'a=sendonly\r\n'
      'a=msid:stream-abc track-123\r\n'
      'a=ssrc:42 cname:x\r\n'
      'a=ssrc:42 msid:stream-abc track-123\r\n';

  test('the partner\'s copy carries the meter\'s ids, never the microphone\'s', () {
    final apart = RtcMedia.meterApart(offer, trackId: 'track-123', streamId: 'stream-abc');
    expect(apart, contains('a=msid:ghost-meter-stream-abc ghost-meter-track-123'));
    expect(apart, contains('a=ssrc:42 msid:ghost-meter-stream-abc ghost-meter-track-123'));
    expect(RegExp(r'(?<!ghost-meter-)track-123').hasMatch(apart), isFalse, reason: 'no line still names the microphone');
    expect(RegExp(r'(?<!ghost-meter-)stream-abc').hasMatch(apart), isFalse);
    // Everything else as it was.
    expect(apart.replaceAll('ghost-meter-', ''), offer);
  });

  test('only tracks with the meter\'s prefix are ever switched off', () {
    expect('ghost-meter-track-123'.startsWith(RtcMedia.meterPrefix), isTrue);
    expect('track-123'.startsWith(RtcMedia.meterPrefix), isFalse);
  });
}
