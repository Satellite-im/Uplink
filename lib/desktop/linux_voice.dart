/// A voice message recorded on Linux (GMFB-32: "Hold-to-record voice messages on Mac, Windows and Linux"). The Mac and
/// Windows have a recorder of their own in the app (DeskSound.swift, desk_sound.cpp); Linux's is a program the desktop
/// already has, run for as long as the recording lasts, as the file chooser there is zenity or kdialog
/// (linux_dialogs.dart): PipeWire's `pw-record`, PulseAudio's `parecord`, ALSA's `arecord` or `ffmpeg`, the first
/// that is installed and starts. None installed: [LinuxVoice.available] is false and no microphone is offered
/// ([Sms.canRecordVoice]).
///
/// Each records plain sound to a WAV file (16 kHz, one channel, 16 bits). How loud it is comes from the end of that
/// file as it grows. Stopped, the sound is made what the other platforms send, AAC in an `.m4a`, where `ffmpeg` is
/// there to make it; where it isn't, the WAV itself goes, which every phone and computer plays, and since that is
/// eight times the size a recording is shorter ([LinuxVoice.plainSeconds]).
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../platform_info.dart';

/// What is recorded: samples a second, and the bytes those are (one channel, two bytes a sample).
const linuxVoiceRate = 16000;
const linuxVoiceBytesPerSecond = linuxVoiceRate * 2;

/// The programs that can record, in the order they are tried: the desktop's own sound server's first (what nearly
/// every desktop since 2022 runs, then the one before it), then the sound card itself, then ffmpeg.
const linuxRecorders = ['pw-record', 'parecord', 'arecord', 'ffmpeg'];

/// What [tool] (one of [linuxRecorders], at [program]) is run with to record the microphone into the WAV at [out]
/// until it is told to stop.
List<String> linuxRecordCommand(String tool, String program, String out) => switch (tool) {
      'pw-record' => [program, '--rate', '$linuxVoiceRate', '--channels', '1', '--format', 's16', out],
      'parecord' => [program, '--rate=$linuxVoiceRate', '--channels=1', '--format=s16le', '--file-format=wav', out],
      'arecord' => [program, '-q', '-t', 'wav', '-f', 'S16_LE', '-r', '$linuxVoiceRate', '-c', '1', out],
      // Written as it comes (-flush_packets), so the file's end says how loud it is now.
      'ffmpeg' => [program, '-nostdin', '-loglevel', 'error', '-y', '-f', 'alsa', '-i', 'default', '-ac', '1', '-ar', '$linuxVoiceRate', '-c:a', 'pcm_s16le', '-flush_packets', '1', out],
      _ => throw ArgumentError.value(tool, 'tool', 'not a recorder'),
    };

/// What ffmpeg (at [program]) is run with to make the WAV at [wav] the `.m4a` at [out]: AAC at 24 kbit/s, as the
/// Mac records (DeskSound.swift), so a text's size limit means the same length here.
List<String> linuxEncodeCommand(String program, String wav, String out) => [program, '-nostdin', '-loglevel', 'error', '-y', '-i', wav, '-vn', '-c:a', 'aac', '-b:a', '24k', out];

/// Where the program called [name] is, looked for along [env]'s PATH; null where it isn't installed.
String? findProgram(String name, {required Map<String, String> env, bool Function(String path)? exists}) {
  final there = exists ?? (p) => File(p).existsSync();
  for (final dir in (env['PATH'] ?? '').split(':')) {
    if (dir.isEmpty) continue;
    final at = dir.endsWith('/') ? '$dir$name' : '$dir/$name';
    if (there(at)) return at;
  }
  return null;
}

/// Whether [bytes] are a WAV file, by the letters every one starts with.
bool isWav(Uint8List bytes) => bytes.length >= 12 && String.fromCharCodes(bytes, 0, 4) == 'RIFF' && String.fromCharCodes(bytes, 8, 12) == 'WAVE';

/// Where a WAV's sound starts and how many bytes of it there are, and the bytes a second its header says; null where
/// [bytes] are no WAV. A recorder stopped in the middle leaves a length of nothing, or of everything, in its header:
/// then the sound is all that follows.
({int start, int length, int bytesPerSecond})? _wavSound(Uint8List bytes) {
  if (!isWav(bytes)) return null;
  final data = ByteData.sublistView(bytes);
  var rate = linuxVoiceBytesPerSecond;
  var at = 12;
  while (at + 8 <= bytes.length) {
    final name = String.fromCharCodes(bytes, at, at + 4);
    final said = data.getUint32(at + 4, Endian.little);
    final left = bytes.length - at - 8;
    if (name == 'data') return (start: at + 8, length: said > 0 && said <= left ? said : left, bytesPerSecond: rate);
    if (name == 'fmt ' && at + 20 <= bytes.length) rate = data.getUint32(at + 16, Endian.little);
    if (said > left) break;
    // A piece of odd length is followed by a byte of nothing.
    at += 8 + said + (said & 1);
  }
  return null;
}

/// The sound in a WAV file, without its header; empty where there is none.
Uint8List wavSamples(Uint8List bytes) {
  final sound = _wavSound(bytes);
  if (sound == null) return Uint8List(0);
  // Whole samples only.
  return Uint8List.sublistView(bytes, sound.start, sound.start + (sound.length & ~1));
}

/// How long the sound in a WAV runs, in milliseconds; 0 where it can't be told.
int wavMillis(Uint8List bytes) {
  final sound = _wavSound(bytes);
  if (sound == null || sound.bytesPerSecond <= 0) return 0;
  return sound.length * 1000 ~/ sound.bytesPerSecond;
}

/// [samples] (16 bits, one channel, [linuxVoiceRate] a second) as a WAV file with a header that says how long it is.
Uint8List wavFile(Uint8List samples) {
  final out = Uint8List(44 + samples.length);
  final data = ByteData.sublistView(out);
  void word(int at, String s) => out.setRange(at, at + 4, s.codeUnits);
  word(0, 'RIFF');
  data.setUint32(4, 36 + samples.length, Endian.little);
  word(8, 'WAVE');
  word(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, linuxVoiceRate, Endian.little);
  data.setUint32(28, linuxVoiceBytesPerSecond, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  word(36, 'data');
  data.setUint32(40, samples.length, Endian.little);
  out.setRange(44, out.length, samples);
  return out;
}

/// How loud [samples] are, 0 to 1: the loudest of them.
double pcmLevel(Uint8List samples) {
  final data = ByteData.sublistView(samples);
  var peak = 0;
  for (var i = 0; i + 1 < samples.length; i += 2) {
    final v = data.getInt16(i, Endian.little).abs();
    if (v > peak) peak = v;
  }
  return (peak / 32768).clamp(0.0, 1.0);
}

/// The recorder: answers what the Mac's and Windows' answer over their channel ([MacPlatform.voiceStart] and the
/// three beside it), so everything above it is the same on all three.
class LinuxVoice {
  LinuxVoice({Map<String, String>? env, bool Function(String path)? exists, Future<Process> Function(String program, List<String> args)? spawn, Future<ProcessResult> Function(String program, List<String> args)? run, Directory? dir, this.settle = const Duration(milliseconds: 250)})
      : _env = env ?? PlatformInfo.environment,
        _exists = exists,
        _spawn = spawn ?? Process.start,
        _run = run ?? Process.run,
        _dir = dir;

  /// This computer's; a test puts its own here.
  static LinuxVoice instance = LinuxVoice();

  /// How long a recording may run where there is no ffmpeg to make it small: the WAV that goes is 32 KB a second,
  /// so two minutes is under 4 MB.
  static const plainSeconds = 120;

  final Map<String, String> _env;
  final bool Function(String path)? _exists;
  final Future<Process> Function(String program, List<String> args) _spawn;
  final Future<ProcessResult> Function(String program, List<String> args) _run;
  final Directory? _dir;

  /// How long a recorder is given to show it has started: one whose sound server isn't running ends at once, and the
  /// next is tried.
  final Duration settle;

  /// The recorders installed here, in the order they are tried, each with where it is. Looked for once.
  late final List<(String tool, String program)> recorders = [
    for (final tool in linuxRecorders)
      if (findProgram(tool, env: _env, exists: _exists) case final program?) (tool, program),
  ];

  /// ffmpeg, which makes the recording an `.m4a`; null where it isn't installed.
  late final String? encoder = findProgram('ffmpeg', env: _env, exists: _exists);

  /// Whether a voice message can be recorded on this computer at all.
  bool get available => recorders.isNotEmpty;

  /// Whether what is recorded goes as the `.m4a` the other platforms send. A text's voice message must: a carrier
  /// takes no WAV, and none that would fit.
  bool get encodes => encoder != null;

  Directory get _folder => _dir ?? Directory('${Directory.systemTemp.path}/ghost-voice-rec');

  Process? _process;
  File? _file;
  int _limit = 0;

  /// The recorder running now, by name; null while nothing is recorded.
  String? get recording => _process == null ? null : _tool;
  String? _tool;

  /// Starts recording, to stop at about [bytes] of `.m4a`: `{ok: true, seconds}` with how long that is, or
  /// `{ok: false, error}` in words.
  Future<Map> start(int bytes) async {
    await cancel();
    if (recorders.isEmpty) return const {'ok': false, 'error': 'This computer has nothing to record with. Install pipewire, pulseaudio-utils, alsa-utils or ffmpeg.'};
    final seconds = encodes ? ((bytes - 64 * 1024) ~/ 3000).clamp(1, 3600) : plainSeconds;
    _folder.createSync(recursive: true);
    for (final (tool, program) in recorders) {
      final file = File('${_folder.path}/recording-${DateTime.now().microsecondsSinceEpoch}.wav');
      final command = linuxRecordCommand(tool, program, file.path);
      final Process process;
      try {
        process = await _spawn(command.first, command.sublist(1));
      } on ProcessException {
        continue;
      }
      // What it says is not read; left unread it would stop a talkative one.
      unawaited(process.stdout.drain<void>().catchError((_) {}));
      unawaited(process.stderr.drain<void>().catchError((_) {}));
      var ended = false;
      unawaited(process.exitCode.then((_) => ended = true));
      await Future<void>.delayed(settle);
      if (ended) {
        _remove(file);
        continue;
      }
      _process = process;
      _file = file;
      _tool = tool;
      _limit = seconds * linuxVoiceBytesPerSecond;
      return {'ok': true, 'seconds': seconds};
    }
    return const {'ok': false, 'error': 'The microphone could not be started'};
  }

  /// How loud it is now (`level`, 0 to 1: the last tenth of a second in the file) and whether the recording is as
  /// long as it may be (`full`).
  Future<Map> level() async {
    final file = _file;
    if (_process == null || file == null) return const {};
    try {
      final length = file.lengthSync();
      // A WAV's header is 44 bytes as each of these writes it; a few more would only be heard as a click of level.
      final sound = length - 44;
      if (sound <= 0) return const {'level': 0.0, 'full': false};
      final take = sound < 3200 ? sound & ~1 : 3200;
      final from = 44 + ((sound - take) & ~1);
      final raf = file.openSync();
      try {
        raf.setPositionSync(from);
        return {'level': pcmLevel(raf.readSync(take)), 'full': sound >= _limit};
      } finally {
        raf.closeSync();
      }
    } catch (_) {
      return const {};
    }
  }

  /// Throws the recording under way away.
  Future<void> cancel() async {
    final file = await _end();
    if (file != null) _remove(file);
  }

  /// Ends the recording: an `.m4a`'s bytes where ffmpeg made one, else the WAV's; null where there is under a second.
  Future<Uint8List?> stop() async {
    final limit = _limit;
    final file = await _end();
    if (file == null) return null;
    Uint8List samples;
    try {
      samples = wavSamples(await file.readAsBytes());
    } catch (_) {
      samples = Uint8List(0);
    }
    _remove(file);
    if (samples.length > limit) samples = Uint8List.sublistView(samples, 0, limit);
    if (samples.length < linuxVoiceBytesPerSecond) return null;
    final wav = wavFile(samples);
    final ffmpeg = encoder;
    if (ffmpeg == null) return wav;
    // Made an .m4a. Should ffmpeg fail, the WAV goes as it would with none.
    final from = File('${file.path}.in.wav'), to = File('${file.path}.m4a');
    try {
      await from.writeAsBytes(wav, flush: true);
      final command = linuxEncodeCommand(ffmpeg, from.path, to.path);
      final done = await _run(command.first, command.sublist(1));
      if (done.exitCode == 0 && to.existsSync() && to.lengthSync() > 0) return await to.readAsBytes();
      return wav;
    } catch (_) {
      return wav;
    } finally {
      _remove(from);
      _remove(to);
    }
  }

  /// Stops the recorder as Ctrl-C would, which is when each writes its file's end; one that will not go is ended.
  Future<File?> _end() async {
    final process = _process, file = _file;
    _process = null;
    _file = null;
    _tool = null;
    if (process == null) return null;
    process.kill(ProcessSignal.sigint);
    await process.exitCode.timeout(const Duration(seconds: 2), onTimeout: () {
      process.kill(ProcessSignal.sigkill);
      return -1;
    });
    return file;
  }

  void _remove(File file) {
    try {
      if (file.existsSync()) file.deleteSync();
    } catch (_) {}
  }
}
