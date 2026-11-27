import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/desktop/desk_voice.dart';
import 'package:ghost_messaging/desktop/linux_voice.dart';

/// A recorder made up for a test: it writes its WAV as it is started, and ends when told to (or at once, [dead]).
class _Tool implements Process {
  _Tool({this.dead = false});
  final bool dead;
  final _done = Completer<int>();
  final signals = <ProcessSignal>[];

  @override
  Future<int> get exitCode => _done.future;
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    signals.add(signal);
    if (!_done.isCompleted) _done.complete(0);
    return true;
  }

  @override
  Stream<List<int>> get stdout => const Stream.empty();
  @override
  Stream<List<int>> get stderr => const Stream.empty();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// [seconds] of sound at [loud] (of 32767), as 16-bit samples.
Uint8List _samples(double seconds, {int loud = 8000}) {
  final n = (seconds * linuxVoiceRate).round();
  final data = ByteData(n * 2);
  for (var i = 0; i < n; i++) {
    data.setInt16(i * 2, i.isEven ? loud : -loud, Endian.little);
  }
  return data.buffer.asUint8List();
}

/// Linux's recorder (GMFB-32, lib/desktop/linux_voice.dart): which program is chosen, what it is run with, and what
/// comes of the file it leaves.
void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('ghost-linux-voice'));
  tearDown(() => dir.deleteSync(recursive: true));

  const env = {'PATH': '/usr/local/bin:/usr/bin:'};
  bool Function(String) has(Set<String> names) => (path) => names.any((n) => path == '/usr/bin/$n');

  /// A recorder on a computer with [installed], whose programs leave [sound] in the file they are given. [dead] end
  /// at once, as one whose sound server isn't running does.
  ({LinuxVoice voice, List<List<String>> ran, List<_Tool> tools}) made(Set<String> installed, {Uint8List? sound, Set<String> dead = const {}, bool encodeFails = false}) {
    final ran = <List<String>>[];
    final tools = <_Tool>[];
    final voice = LinuxVoice(
      env: env,
      exists: has(installed),
      dir: dir,
      settle: const Duration(milliseconds: 5),
      spawn: (program, args) async {
        ran.add([program, ...args]);
        final name = program.split('/').last;
        final tool = _Tool(dead: dead.contains(name));
        tools.add(tool);
        if (tool.dead) {
          tool.kill();
        } else {
          File(args.last).writeAsBytesSync(wavFile(sound ?? _samples(2)));
        }
        return tool;
      },
      run: (program, args) async {
        ran.add([program, ...args]);
        if (encodeFails) return ProcessResult(1, 1, '', 'no aac');
        File(args.last).writeAsBytesSync([0, 0, 0, 24, ...'ftypM4A '.codeUnits]);
        return ProcessResult(1, 0, '', '');
      },
    );
    return (voice: voice, ran: ran, tools: tools);
  }

  group('which program records', () {
    test('found along PATH, and not where it isn\'t installed', () {
      expect(findProgram('arecord', env: env, exists: has({'arecord'})), '/usr/bin/arecord');
      expect(findProgram('arecord', env: env, exists: has({'ffmpeg'})), isNull);
      expect(findProgram('arecord', env: const {}, exists: (_) => true), isNull);
    });

    test('PipeWire\'s first, then PulseAudio\'s, ALSA\'s, ffmpeg', () {
      expect(linuxRecorders, ['pw-record', 'parecord', 'arecord', 'ffmpeg']);
      final all = made({'ffmpeg', 'arecord', 'parecord', 'pw-record'}).voice;
      expect([for (final (tool, _) in all.recorders) tool], linuxRecorders);
      expect(all.encodes, isTrue);
      final old = made({'arecord'}).voice;
      expect(old.recorders, [('arecord', '/usr/bin/arecord')]);
      expect(old.available, isTrue);
      expect(old.encodes, isFalse);
    });

    test('none installed: no microphone is offered, and a start says what to install', () async {
      final none = made({}).voice;
      expect(none.available, isFalse);
      final began = await none.start(DeskVoice.fileBytes);
      expect(began['ok'], isFalse);
      expect('${began['error']}', contains('Install'));
    });

    test('one that ends at once is passed over for the next', () async {
      final m = made({'pw-record', 'parecord', 'arecord'}, dead: {'pw-record', 'parecord'});
      expect((await m.voice.start(DeskVoice.fileBytes))['ok'], isTrue);
      expect(m.voice.recording, 'arecord');
      expect([for (final r in m.ran) r.first], ['/usr/bin/pw-record', '/usr/bin/parecord', '/usr/bin/arecord']);
      await m.voice.cancel();
      // And where every one does, it is said.
      final gone = made({'pw-record'}, dead: {'pw-record'}).voice;
      expect(await gone.start(DeskVoice.fileBytes), {'ok': false, 'error': 'The microphone could not be started'});
    });
  });

  test('what each is run with: 16 kHz, one channel, 16 bits, a WAV', () {
    expect(linuxRecordCommand('pw-record', '/usr/bin/pw-record', '/tmp/a.wav'), ['/usr/bin/pw-record', '--rate', '16000', '--channels', '1', '--format', 's16', '/tmp/a.wav']);
    expect(linuxRecordCommand('parecord', '/usr/bin/parecord', '/tmp/a.wav'), ['/usr/bin/parecord', '--rate=16000', '--channels=1', '--format=s16le', '--file-format=wav', '/tmp/a.wav']);
    expect(linuxRecordCommand('arecord', '/usr/bin/arecord', '/tmp/a.wav'), ['/usr/bin/arecord', '-q', '-t', 'wav', '-f', 'S16_LE', '-r', '16000', '-c', '1', '/tmp/a.wav']);
    expect(linuxRecordCommand('ffmpeg', '/usr/bin/ffmpeg', '/tmp/a.wav'), ['/usr/bin/ffmpeg', '-nostdin', '-loglevel', 'error', '-y', '-f', 'alsa', '-i', 'default', '-ac', '1', '-ar', '16000', '-c:a', 'pcm_s16le', '-flush_packets', '1', '/tmp/a.wav']);
    expect(() => linuxRecordCommand('sox', '/usr/bin/sox', '/tmp/a.wav'), throwsArgumentError);
    expect(linuxEncodeCommand('/usr/bin/ffmpeg', '/tmp/a.wav', '/tmp/a.m4a'), ['/usr/bin/ffmpeg', '-nostdin', '-loglevel', 'error', '-y', '-i', '/tmp/a.wav', '-vn', '-c:a', 'aac', '-b:a', '24k', '/tmp/a.m4a']);
  });

  group('a WAV', () {
    test('written and read back: its sound and how long it runs', () {
      final wav = wavFile(_samples(1.5));
      expect(isWav(wav), isTrue);
      expect(wavMillis(wav), 1500);
      expect(wavSamples(wav), _samples(1.5));
      expect(isWav(Uint8List.fromList('OggS........'.codeUnits)), isFalse);
      expect(wavMillis(Uint8List(10)), 0);
    });

    test('one whose recorder was stopped before it wrote its length is read to its end', () {
      final wav = wavFile(_samples(1));
      // No length, as ffmpeg leaves it; then every bit set, as a stream's is.
      ByteData.sublistView(wav).setUint32(40, 0, Endian.little);
      expect(wavSamples(wav).length, linuxVoiceBytesPerSecond);
      ByteData.sublistView(wav).setUint32(40, 0xffffffff, Endian.little);
      expect(wavMillis(wav), 1000);
    });

    test('how loud: the loudest sample', () {
      expect(pcmLevel(_samples(0.1, loud: 16384)), 0.5);
      expect(pcmLevel(_samples(0.1, loud: 0)), 0);
      expect(pcmLevel(Uint8List(0)), 0);
    });
  });

  group('a recording', () {
    test('with ffmpeg: as long as the size allows, how loud it is, stopped with Ctrl-C and made an .m4a', () async {
      final m = made({'pw-record', 'ffmpeg'});
      // A file's: five minutes. A text's (a carrier's 299008 bytes): what fits at the Mac's rate.
      expect(await m.voice.start(DeskVoice.fileBytes), {'ok': true, 'seconds': 300});
      expect(m.voice.recording, 'pw-record');
      final heard = await m.voice.level();
      expect(heard['level'], closeTo(8000 / 32768, 0.001));
      expect(heard['full'], isFalse);
      final sound = (await m.voice.stop())!;
      expect(m.tools.single.signals, [ProcessSignal.sigint]);
      expect(String.fromCharCodes(sound, 4, 8), 'ftyp');
      expect(m.ran.last.first, '/usr/bin/ffmpeg');
      expect(m.voice.recording, isNull);
      // Nothing is left behind.
      expect(dir.listSync(), isEmpty);
      await m.voice.cancel();
      expect((await made({'pw-record', 'ffmpeg'}).voice.start(299008))['seconds'], 77);
    });

    test('without ffmpeg: two minutes at most, and the WAV itself', () async {
      final m = made({'arecord'});
      expect(await m.voice.start(DeskVoice.fileBytes), {'ok': true, 'seconds': LinuxVoice.plainSeconds});
      final sound = (await m.voice.stop())!;
      expect(isWav(sound), isTrue);
      expect(wavMillis(sound), 2000);
      expect(m.ran.length, 1);
    });

    test('ffmpeg failing leaves the WAV to send', () async {
      final m = made({'pw-record', 'ffmpeg'}, encodeFails: true);
      await m.voice.start(DeskVoice.fileBytes);
      expect(isWav((await m.voice.stop())!), isTrue);
      expect(dir.listSync(), isEmpty);
    });

    test('under a second is nothing to send, and one thrown away leaves no file', () async {
      final short = made({'arecord'}, sound: _samples(0.4));
      await short.voice.start(DeskVoice.fileBytes);
      expect(await short.voice.stop(), isNull);
      final m = made({'arecord'});
      await m.voice.start(DeskVoice.fileBytes);
      await m.voice.cancel();
      expect(m.tools.single.signals, [ProcessSignal.sigint]);
      expect(dir.listSync(), isEmpty);
      expect(await m.voice.stop(), isNull);
      expect(await m.voice.level(), isEmpty);
    });

    test('as long as it may be: said full, and cut there', () async {
      final m = made({'arecord'}, sound: _samples(LinuxVoice.plainSeconds + 3.0));
      await m.voice.start(DeskVoice.fileBytes);
      expect((await m.voice.level())['full'], isTrue);
      expect(wavMillis((await m.voice.stop())!), LinuxVoice.plainSeconds * 1000);
    });
  });

  test('kept as a file to send, a WAV is named one and says how long it runs', () async {
    // What DeskVoice.finish names the file by: what the bytes are.
    final wav = wavFile(_samples(3));
    expect(isWav(wav), isTrue);
    expect(wavMillis(wav), 3000);
    expect(m4aMillis(wav), 0);
  });
}
