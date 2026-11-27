import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/sms.dart';
import 'package:ghost_messaging/ui/voice.dart';

/// Voice messages: what counts as one, and how its length and place are said.
void main() {
  test('a part that is sound is a voice message, a picture is not', () {
    expect(const Attachment(id: 1, type: 'audio/mp4', name: 'voice-20261113-194502.m4a').isAudio, isTrue);
    expect(const Attachment(id: 2, type: 'audio/amr').isAudio, isTrue);
    expect(const Attachment(id: 3, type: 'application/ogg').isAudio, isTrue);
    expect(const Attachment(id: 4, type: 'image/jpeg').isAudio, isFalse);
    expect(const Attachment(id: 5, type: 'video/mp4').isAudio, isFalse);
  });

  test('a length is said in minutes and seconds', () {
    expect(voiceClock(Duration.zero), '0:00');
    expect(voiceClock(const Duration(milliseconds: 7400)), '0:07');
    expect(voiceClock(const Duration(seconds: 67)), '1:07');
    expect(voiceClock(const Duration(minutes: 10)), '10:00');
  });

  test('what the phone says of the one playing is read', () {
    final v = VoicePlayback.from({'type': 'voice', 'part': 911, 'position': 3100, 'duration': 7400, 'playing': true});
    expect(v.part, 911);
    expect(v.position, const Duration(milliseconds: 3100));
    expect(v.length, const Duration(milliseconds: 7400));
    expect(v.playing, isTrue);
    // Ended: back at its start, and not playing.
    final ended = VoicePlayback.from({'type': 'voice', 'part': 911, 'position': 0, 'duration': 7400, 'playing': false});
    expect(ended.playing, isFalse);
    expect(ended.position, Duration.zero);
    expect(VoicePlayback.from(const {}).part, -1);
  });
}
