import 'dart:io';
import '../platform_info.dart';
import 'dart:typed_data';

import '../sms.dart';
import 'linux_voice.dart';
import 'platform.dart';

/// A voice message recorded with this computer's own microphone (GMFB-32, from the Uplink gap review: "voice messages
/// from the desktop"): the Mac's and the iPhone's DeskSound.swift, Windows' windows/runner/desk_sound.cpp, all asked
/// alike through [MacPlatform]. What they record is what the phone records (android/.../Voice.kt): AAC in an `.m4a`,
/// so a phone plays a computer's clip and a computer a phone's.
///
/// Both kinds of conversation use it, through whatever answers the screens' calls (lib/desktop/remote.dart for a
/// computer paired with a phone, lib/standalone/standalone.dart for one of its own):
/// - **A text** (`voiceStart` with no `file`): the phone's carrier says how long one may be (`voiceLimit`), and the
///   recording goes to the phone as bytes to send ([stopBytes], remote.dart `voiceSend`).
/// - **A file** (`voiceStart` with `file: true`: a network's chat, a space, a friend): no carrier holds it, so
///   [fileSeconds]; the recording is a file in the temporary folder ([finish], `voiceFinish`), sent as any file there
///   is, marked a voice message.
class DeskVoice {
  DeskVoice._();

  /// How long a voice message that goes as a file may run.
  static const fileSeconds = 300;

  /// What the Mac's recorder writes in a second (AAC at 24 kbit/s, DeskSound.swift): turns [fileSeconds] into the size
  /// it stops itself at. Windows records at 96 kbit/s and says its own seconds back.
  static const macBytesPerSecond = 3000;

  /// The size a file's recording stops at: [fileSeconds] at the Mac's rate, with room for the file's header.
  static int get fileBytes => fileSeconds * macBytesPerSecond + 64 * 1024;

  /// Starts recording: `{ok: true, seconds}` with how long it may run, `{ok: false, denied: true}` where the computer
  /// said no to the microphone. [carrier] is the phone's `voiceLimit` (`{seconds, bytes}`) for a text; null for a file.
  /// Throws, in words, where the microphone couldn't be started.
  static Future<Map<String, Object?>> start({Map? carrier}) async {
    // A text's voice message is an .m4a small enough for the carrier, which Linux makes with ffmpeg alone
    // (lib/desktop/linux_voice.dart): without it only a file's can be recorded there.
    if (carrier != null && PlatformInfo.isLinux && !LinuxVoice.instance.encodes) throw const VoiceProblem('A voice message in a text needs ffmpeg on this computer. Install it and try again.');
    final seconds = carrier == null ? fileSeconds : (carrier['seconds'] as num).toInt();
    final bytes = carrier == null ? fileBytes : (carrier['bytes'] as num).toInt();
    final began = await MacPlatform.voiceStart(bytes);
    if (began['ok'] == true) {
      // Windows says how long fits in [bytes] at its own rate (desk_sound.cpp); the Mac stops itself at the size.
      final own = (began['seconds'] as num?)?.toInt();
      return {'ok': true, 'seconds': own != null && own > 0 && own < seconds ? own : seconds};
    }
    if (began['denied'] == true) return {'ok': false, 'denied': true};
    throw VoiceProblem('${began['error'] ?? 'The microphone could not be started'}');
  }

  /// How loud it is now, 0 to 1; told to the recorder ([Sms.voiceFull]) once it is as long as it may be.
  static Future<double> level() async {
    final heard = await MacPlatform.voiceLevel();
    if (heard['full'] == true) Sms.instance.voiceFull.add(null);
    return ((heard['level'] as num?)?.toDouble() ?? 0.0).clamp(0.0, 1.0);
  }

  /// Stops recording and lets what was recorded go.
  static Future<void> cancel() => MacPlatform.voiceCancel();

  /// Ends it: the `.m4a`'s bytes. Throws where it was too short to keep (under a second).
  static Future<Uint8List> stopBytes() async {
    final sound = await MacPlatform.voiceStop();
    if (sound == null || sound.isEmpty) throw const VoiceProblem('That was too short to send');
    return sound;
  }

  /// Ends it and keeps it as a file to send: `{path, millis}`, as the phone's `voiceFinish` answers.
  static Future<Map<String, Object?>> finish({Directory? into}) async {
    final sound = await stopBytes();
    final dir = into ?? Directory('${Directory.systemTemp.path}${PlatformInfo.pathSeparator}ghost-voice');
    dir.createSync(recursive: true);
    // An .m4a everywhere but a Linux computer with no ffmpeg, whose recording is a WAV (lib/desktop/linux_voice.dart).
    final wav = isWav(sound);
    final file = File('${dir.path}${PlatformInfo.pathSeparator}voice-${DateTime.now().millisecondsSinceEpoch}.${wav ? 'wav' : 'm4a'}');
    await file.writeAsBytes(sound, flush: true);
    return {'path': file.path, 'millis': wav ? wavMillis(sound) : m4aMillis(sound)};
  }
}

/// Why a voice message couldn't be recorded, in words for the person.
class VoiceProblem implements Exception {
  const VoiceProblem(this.message);
  final String message;

  @override
  String toString() => message;
}

/// How long the sound in an MP4 or `.m4a` runs, in milliseconds, from its `mvhd` box (the movie's timescale and
/// duration); 0 where it has none (an AMR from another phone, a file cut short). For a computer with no native player
/// to ask (Windows, Linux: [MacPlatform.voiceLength]).
int m4aMillis(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  // 'mvhd' sits inside 'moov', which may come at the end: looked for wherever it is.
  for (var i = 4; i + 4 <= bytes.length; i++) {
    if (bytes[i] != 0x6d || bytes[i + 1] != 0x76 || bytes[i + 2] != 0x68 || bytes[i + 3] != 0x64) continue;
    final body = i + 4;
    if (body + 4 > bytes.length) return 0;
    final version = bytes[body];
    int scale, length;
    if (version == 1) {
      if (body + 32 > bytes.length) return 0;
      scale = data.getUint32(body + 20);
      length = data.getUint32(body + 24) * 0x100000000 + data.getUint32(body + 28);
    } else {
      if (body + 20 > bytes.length) return 0;
      scale = data.getUint32(body + 12);
      length = data.getUint32(body + 16);
    }
    if (scale == 0) return 0;
    return length * 1000 ~/ scale;
  }
  return 0;
}

/// Whether [bytes] are an Ogg file (.ogg, .oga, .opus), by the four letters every one starts with.
bool isOgg(Uint8List bytes) => bytes.length >= 4 && bytes[0] == 0x4f && bytes[1] == 0x67 && bytes[2] == 0x67 && bytes[3] == 0x53;

/// How long the sound in an Ogg file runs, in milliseconds; 0 where it can't be told (not Ogg, neither Vorbis nor
/// Opus, cut short). Its last page says how many samples there are in all, and its first what a second holds: Opus
/// counts 48000 to the second whatever it was recorded at, less the samples it says to skip at the start; Vorbis says
/// its own rate (GMFB-60: an .ogg in a conversation said no length until it was played).
int oggMillis(Uint8List bytes) {
  if (!isOgg(bytes) || bytes.length < 58) return 0;
  final data = ByteData.sublistView(bytes);
  // The first page: 27 bytes, then as many lengths as byte 26 says, then the codec's first packet.
  final first = 27 + bytes[26];
  if (first + 30 > bytes.length) return 0;
  bool named(String word) {
    for (var i = 0; i < word.length; i++) {
      if (bytes[first + i] != word.codeUnitAt(i)) return false;
    }
    return true;
  }

  int rate, skip = 0;
  if (named('OpusHead')) {
    rate = 48000;
    skip = data.getUint16(first + 10, Endian.little);
  } else if (named('\x01vorbis')) {
    rate = data.getUint32(first + 12, Endian.little);
  } else {
    return 0;
  }
  if (rate == 0) return 0;
  // The last page's count of samples: looked for from the end, a page being 65307 bytes at most.
  for (var i = bytes.length - 27; i >= 0 && i >= bytes.length - 65307 - 27; i--) {
    if (bytes[i] != 0x4f || bytes[i + 1] != 0x67 || bytes[i + 2] != 0x67 || bytes[i + 3] != 0x53) continue;
    final low = data.getUint32(i + 6, Endian.little), high = data.getUint32(i + 10, Endian.little);
    // All ones is a page that ends no packet, with no count: the one before it has it.
    if (low == 0xffffffff && high == 0xffffffff) continue;
    final samples = high * 0x100000000 + low - skip;
    return samples <= 0 ? 0 : samples * 1000 ~/ rate;
  }
  return 0;
}
