/// A call's soundboard (Matt, 2026-11-20: "build a soundboards plugin for circles"): pads that play a short sound on
/// every device in the call. The plugin (lib/plugins/soundboard.dart) puts it in a call's menu and a space's header;
/// the pads are lib/ui/soundboard_screen.dart.
///
/// - No sound is sent. Whoever presses a pad says which sound in the call ('sb' in its room, sealed as everything said
///   there is), and each device plays its own copy: one of the app's own ([builtInSounds], assets/soundboard, made by
///   tool/soundboard_sounds.py), or one of the circle's.
/// - A circle's own sounds are clips its owner or admins added. Each is sealed and kept where the circle's banner is
///   (Circle.bannerChannel), and named with its key in the circle's signed manifest, among the plugin's choices for the
///   circle (`pl.soundboard.snd`). So only what whoever may change the circle put there can be played at anyone: a
///   device plays a sound it finds in its own list and nothing else, and never a file someone names in the call.
/// - Each device rules what it hears: a loudness of the soundboard's own, and a switch to hear none of it (the pads
///   still work, and it still shows who played what). Deafened, it plays nothing. Nobody is played more than
///   [boardBurst] sounds from one person in [boardWindow], and a sound stops at [boardPlayMost].
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../app_state.dart';
import '../circles/circles.dart';
import '../files/files_store.dart';
import '../plugins/soundboard.dart' show SoundboardPlugin;
import '../ui/video_engine.dart';
import 'channels.dart';
import 'hangout.dart' show OutgoingFile;
import 'voice.dart';

/// The largest clip a circle keeps, the longest a sound plays, and how many sounds of its own a circle has: each is
/// named in the circle's manifest, which has to fit a packet.
const boardClipMost = 1024 * 1024;
const boardPlayMost = Duration(seconds: 10);
const boardCircleMost = 16;

/// How many sounds one person may play in how long; more are not said (this device's) or not played (another's).
const boardBurst = 6;
const boardWindow = Duration(seconds: 10);

/// One pad.
@immutable
class BoardSound {
  const BoardSound({required this.id, required this.name, required this.emoji, this.file});

  /// What is said in the call: the name of one of the app's own ("airhorn"), or a circle's clip's id on the relay.
  final String id;
  final String name;
  final String emoji;

  /// A circle's clip, as a Files space's entry names a file (with its key); null for one of the app's own.
  final SpaceFile? file;

  bool get builtIn => file == null;

  /// Where one of the app's own is, among the app's assets.
  String get asset => 'assets/soundboard/$id.wav';

  /// The longest a circle's sound's name is kept; a longer one is cut.
  static const nameMost = 32;

  /// A circle's sound as its manifest keeps it (never one of the app's own, which has no file).
  Map<String, Object?> toJson() => {'n': name, 'e': emoji, 'f': file!.withoutThumb().toJson()};

  /// A circle's sound from its manifest; null where it is not one.
  static BoardSound? fromJson(Object? j, {String by = ''}) {
    if (j is! Map) return null;
    final f = SpaceFile.fromJson(j['f'], by: by);
    final n = j['n'], e = j['e'];
    if (f == null || n is! String || n.trim().isEmpty || f.size > boardClipMost) return null;
    final name = n.trim();
    return BoardSound(id: f.id, name: name.length > nameMost ? name.substring(0, nameMost) : name, emoji: e is String && e.isNotEmpty && e.length <= 16 ? e : '🔊', file: f);
  }

  @override
  bool operator ==(Object other) => other is BoardSound && other.id == id && other.name == name && other.emoji == emoji;

  @override
  int get hashCode => Object.hash(id, name, emoji);
}

/// The app's own sounds, in the order of their pads.
const builtInSounds = [
  BoardSound(id: 'airhorn', name: 'Air horn', emoji: '📢'),
  BoardSound(id: 'applause', name: 'Applause', emoji: '👏'),
  BoardSound(id: 'tada', name: 'Ta-da', emoji: '🎉'),
  BoardSound(id: 'rimshot', name: 'Rimshot', emoji: '🥁'),
  BoardSound(id: 'drumroll', name: 'Drum roll', emoji: '🪘'),
  BoardSound(id: 'trombone', name: 'Sad trombone', emoji: '😢'),
  BoardSound(id: 'crickets', name: 'Crickets', emoji: '🦗'),
  BoardSound(id: 'ding', name: 'Ding', emoji: '🔔'),
  BoardSound(id: 'buzzer', name: 'Buzzer', emoji: '❌'),
  BoardSound(id: 'boing', name: 'Boing', emoji: '🤪'),
  BoardSound(id: 'pew', name: 'Pew pew', emoji: '✨'),
  BoardSound(id: 'whoosh', name: 'Whoosh', emoji: '💨'),
];

/// The circle [c]'s own sounds, as its manifest has them.
List<BoardSound> circleSounds(Circle c) {
  final list = c.manifest.plugins[SoundboardPlugin.pluginId]?['snd'];
  if (list is! List) return const [];
  final out = <BoardSound>[];
  for (final j in list) {
    final s = BoardSound.fromJson(j, by: c.manifest.by ?? '');
    if (s != null && out.length < boardCircleMost && !out.any((o) => o.id == s.id)) out.add(s);
  }
  return out;
}

/// Who played what, for the line a call shows of it.
typedef BoardPlayed = ({String by, BoardSound sound, DateTime at});

/// The soundboard on this device: follows the call there is, says and plays the pads pressed, plays what others
/// press, and keeps a circle's own sounds. Listeners are told when a sound is played or a choice changes.
class Soundboard extends ChangeNotifier {
  Soundboard._();
  static final Soundboard instance = Soundboard._();

  @visibleForTesting
  Soundboard.forTest({required this.isOn, required this.player, required this.locate, this.app, Future<SpaceFile> Function(Circle c, File file, String name)? upload}) {
    if (upload != null) this.upload = upload;
  }

  VoiceSession? _session;

  /// Whether the plugin is on in the call there is (in a circle's space, as the circle says).
  bool Function() isOn = SoundboardPlugin.onInCall;

  /// Plays the file at a path at a loudness from 0 to 1, and is done when it has played.
  Future<void> Function(String path, double volume) player = playClip;

  /// A sound's file on this device, brought down first where it is a circle's and not here yet.
  Future<String> Function(BoardSound sound, VoiceChannel? space) locate = fileOf;

  /// Where the choices are kept; the app's own where none is given.
  @visibleForTesting
  AppState? app;
  AppState? get _app => app ?? Voice.instance.app;

  /// The newest sound played in the call, shown over it for a moment ([shownFor]); null for none.
  BoardPlayed? last;
  static const shownFor = Duration(seconds: 4);
  Timer? _gone;

  /// When each person last played sounds, for [_allowed] ('me' is this device).
  final Map<String, List<DateTime>> _recent = {};

  /// How many sounds are playing here now, and the most that may at once: one more is not played.
  int _playing = 0;
  static const _atOnce = 4;

  // --- this device's choices -----------------------------------------------------------------------------------------

  static const volumeKey = 'soundboard_volume', quietKey = 'soundboard_quiet';

  /// How loud the soundboard is here, 0 to 100.
  int get volume => (int.tryParse(_app?.choice(volumeKey, '70') ?? '70') ?? 70).clamp(0, 100);

  /// This device hears none of it.
  bool get quiet => _app?.choice(quietKey, '') == 'on';

  // Kept without telling the whole app (AppState.keep): only the soundboard's own pages show them.
  void setVolume(int to) {
    _app?.keep(volumeKey, '${to.clamp(0, 100)}');
    notifyListeners();
  }

  void setQuiet(bool on) {
    _app?.keep(quietKey, on ? 'on' : '');
    notifyListeners();
  }

  // --- the call ------------------------------------------------------------------------------------------------------

  /// Whether this device is in a call.
  bool get inCall => _session != null;

  /// Follows the call [Voice] is in.
  void follow() => followSession(Voice.instance.session);

  /// Follows [s] (null: no call): hears the sounds said in it, and lets go of the call before.
  void followSession(VoiceSession? s) {
    if (identical(s, _session)) return;
    _session?.onSound = null;
    _session = s;
    _recent.clear();
    _show(null);
    s?.onSound = _heard;
    if (s != null) _warm(s.channel);
  }

  /// The pads of [space]: the app's own, then its circle's.
  List<BoardSound> soundsOf(VoiceChannel? space) {
    final c = space == null ? null : Circles.instance.circleOf(space);
    return [...builtInSounds, if (c != null) ...circleSounds(c)];
  }

  /// A pad pressed: said to the call there is, and played here. Why not, where it was not: too many at once.
  String? press(BoardSound s) {
    final sess = _session;
    if (sess == null) {
      preview(s);
      return null;
    }
    if (!_allowed('me')) return 'Give it a moment.';
    sess.saySound(s.id);
    _show((by: 'me', sound: s, at: DateTime.now()));
    if (!sess.deafened) unawaited(_play(s, sess.channel));
    return null;
  }

  /// [s] played on this device alone: a pad tried outside a call, or among a circle's sounds as they are arranged.
  void preview(BoardSound s, {VoiceChannel? space}) => unawaited(_play(s, space ?? _session?.channel));

  /// Someone in the call pressed a pad: shown, and played where it is one of this space's own pads, they haven't
  /// played too many, and this device hears the soundboard.
  void _heard(String from, String id) {
    final sess = _session;
    if (sess == null || !isOn() || !_allowed(from)) return;
    final s = soundsOf(sess.channel).where((x) => x.id == id).firstOrNull;
    if (s == null) return;
    _show((by: from, sound: s, at: DateTime.now()));
    if (quiet || sess.deafened) return;
    unawaited(_play(s, sess.channel));
  }

  /// Whether [who] may play another now: no more than [boardBurst] in [boardWindow].
  bool _allowed(String who) {
    final now = DateTime.now();
    final had = _recent.putIfAbsent(who, () => [])..removeWhere((t) => now.difference(t) > boardWindow);
    if (had.length >= boardBurst) return false;
    had.add(now);
    return true;
  }

  /// Sets [last], taken away again after [shownFor].
  void _show(BoardPlayed? p) {
    _gone?.cancel();
    last = p;
    if (p != null) {
      _gone = Timer(shownFor, () {
        last = null;
        notifyListeners();
      });
    }
    notifyListeners();
  }

  /// Plays [s] here at the soundboard's own loudness; not at all where that is nothing or [_atOnce] are playing.
  Future<void> _play(BoardSound s, VoiceChannel? space) async {
    final loud = volume / 100;
    if (loud <= 0 || _playing >= _atOnce) return;
    _playing++;
    try {
      // A clip that is not here in a moment is not played late, out of nowhere; it goes on coming down for next time.
      final path = await locate(s, space).timeout(const Duration(seconds: 4));
      await player(path, loud);
    } catch (_) {
      // Not here, or no player on this device: the call goes on without it.
    } finally {
      _playing--;
    }
  }

  /// Brings the circle's sounds down as the call is joined, so the first press of each plays on time.
  void _warm(VoiceChannel space) {
    for (final s in soundsOf(space)) {
      if (!s.builtIn) unawaited(locate(s, space).then((_) {}, onError: (_) {}));
    }
  }

  // --- a circle's own sounds -----------------------------------------------------------------------------------------

  /// Adds the clip at [path] to [c]'s sounds as [name] with [emoji]. Why not, where it could not be: null once it is
  /// there. Only whoever may change the circle (Circles.setPlugin).
  Future<String?> add(Circle c, {required String path, required String name, required String emoji}) async {
    final file = File(path);
    final have = circleSounds(c);
    if (!Circles.instance.can(c, CirclePerm.circle)) return 'Only whoever may change ${c.name} adds its sounds.';
    if (have.length >= boardCircleMost) return 'A circle has at most $boardCircleMost sounds of its own. Take one away first.';
    if (!file.existsSync()) return 'That file isn\'t there any more.';
    final size = file.lengthSync();
    if (size == 0) return 'That file is empty.';
    if (size > boardClipMost) return 'That clip is too big: a sound is at most 1 MB. A few seconds is plenty.';
    final ending = path.contains('.') ? path.substring(path.lastIndexOf('.')).toLowerCase() : '';
    if (!clipEndings.contains(ending)) return 'A sound is an audio file: ${clipEndings.map((e) => e.substring(1)).join(', ')}.';
    final SpaceFile up;
    try {
      up = await upload(c, file, 'sound$ending');
    } catch (e) {
      return 'Couldn\'t upload it: $e';
    }
    final s = BoardSound(id: up.id, name: name.trim().isEmpty ? 'Sound' : name.trim(), emoji: emoji, file: up);
    return await _keep(c, [...circleSounds(Circles.instance.bySeed(c.seed) ?? c), s]) ? null : 'Couldn\'t add it: the circle has no room left for another.';
  }

  /// Takes [s] from [c]'s sounds. Its sealed file stays on the relay until the relay clears it, as a replaced banner's does.
  Future<bool> remove(Circle c, BoardSound s) => _keep(c, [for (final x in circleSounds(c)) if (x.id != s.id) x]);

  /// Names [s] again in [c].
  Future<bool> rename(Circle c, BoardSound s, {String? name, String? emoji}) => _keep(c, [
        for (final x in circleSounds(c))
          if (x.id == s.id) BoardSound(id: x.id, name: (name ?? x.name).trim().isEmpty ? x.name : (name ?? x.name).trim(), emoji: emoji ?? x.emoji, file: x.file) else x,
      ]);

  /// Writes [sounds] as the circle's own, in its manifest's choices for the plugin; false where the circle refused.
  Future<bool> _keep(Circle c, List<BoardSound> sounds) async {
    final now = Circles.instance.bySeed(c.seed) ?? c;
    final ok = await Circles.instance.setPlugin(now, SoundboardPlugin.pluginId, on: now.manifest.pluginOn(SoundboardPlugin.pluginId) ?? false, choices: {'snd': [for (final s in sounds) s.toJson()]});
    if (ok) notifyListeners();
    return ok;
  }

  /// Seals a clip and puts it where the circle keeps its own files: what names it afterwards.
  Future<SpaceFile> Function(Circle c, File file, String name) upload = uploadClip;

  static Future<SpaceFile> uploadClip(Circle c, File file, String name) =>
      FilesStore.instance.uploadForChat(c.bannerChannel, OutgoingFile(path: file.path, name: name, size: file.lengthSync(), mime: FileKind.mimeOf(name), owned: false), byName: c.name, thumbMost: 0, moved: () {});

  /// What a clip may be: what every device's player reads.
  static const clipEndings = ['.mp3', '.wav', '.ogg', '.m4a', '.aac', '.opus', '.flac'];

  /// Where a sound's file is on this device: one of the app's own written out of the app once, a circle's brought down
  /// from where the circle keeps it.
  static Future<String> fileOf(BoardSound s, VoiceChannel? space) async {
    final f = s.file;
    if (f == null) {
      final out = File('${Directory.systemTemp.path}/ghost-soundboard/${s.id}.wav');
      if (!out.existsSync() || out.lengthSync() == 0) {
        final bytes = await rootBundle.load(s.asset);
        out.parent.createSync(recursive: true);
        await out.writeAsBytes(bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes), flush: true);
      }
      return out.path;
    }
    final c = space == null ? null : Circles.instance.circleOf(space);
    if (c == null) throw StateError('no circle');
    return FilesStore.instance.fetch(c.bannerChannel, f);
  }

  /// The player for this device (lib/ui/video_engine.dart: libmpv on the computers and Android, AVFoundation on an
  /// iPhone), opened for one clip and let go when it has played, or at [boardPlayMost].
  static Future<void> playClip(String path, double volume) async {
    final e = VideoEngine.make();
    try {
      await e.open(path).timeout(const Duration(seconds: 5));
      if (!e.value.ready) return;
      await e.setVolume(volume.clamp(0, 1).toDouble());
      final done = Completer<void>();
      var started = false;
      // Done when the player says it ended or failed, or stops after having started.
      void tick() {
        final v = e.value;
        if (v.playing) started = true;
        if ((v.error != null || v.ended || (started && !v.playing)) && !done.isCompleted) done.complete();
      }

      e.addListener(tick);
      await e.play();
      await done.future.timeout(boardPlayMost, onTimeout: () {});
      e.removeListener(tick);
    } catch (_) {
      // Unreadable here: nothing is played.
    } finally {
      try {
        await e.pause();
        await e.release();
      } catch (_) {}
      e.dispose();
    }
  }
}
