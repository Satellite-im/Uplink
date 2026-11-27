/// Spotify played to a circle's call (Matt, 2026-11-25: "Please add a spotify plugin for circles that allows a user to
/// add songs to a queue and play them from spotify in the server this may require my spotify account to be running on
/// the server or something", then "I want it to join a voice chat and stream the music over the voice chat i'm in", and
/// "also make sure this works on windows").
///
/// - **The DJ** is whoever in the call pressed Start on a Mac or a PC with the Spotify app open and signed in. Their own
///   Spotify plays; the app presses its buttons and sends its sound, and nothing else's, to each listener
///   (lib/voice/spotify_app.dart). No key, no account of ours, and nothing on the relay. One DJ a call: the first stays
///   until they stop or leave.
/// - **The queue** (spotify_queue.dart) is held by the DJ's device alone, which says all of it as it changes, every
///   [beatEvery] while it plays, and to whoever comes in ('mu' in the call's room, sealed as everything said there is; a
///   build from before it ignores it). Everyone else asks the DJ: add, take away, move, skip, pause, play. The DJ does
///   as it is asked by anyone whose role may speak in the space.
/// - **The music** goes from the DJ's device to each listener's over a connection of its own (spotify_link.dart), asked
///   for by the listener and made by the DJ: stereo Opus, beside the call's and no part of it, so the microphone, mute,
///   recordings, captions and Scribe know nothing of it. Deafened, it is silent; it has a loudness of its own here.
/// - **Without loss** it goes too, on the same connection, to whoever can take it (spotify_lossless.dart): never through
///   the relay, to as many as the DJ's connection can send it to, and only where what this device plays by itself won't
///   come back through its microphone.
///
/// Only where the plugin is on in the circle, looked at on both sides for everything said and everything done.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../app_seen.dart';
import '../app_state.dart';
import '../circles/circles.dart';
import '../net/crypto.dart';
import '../plugins/spotify.dart' show SpotifyPlugin;
import 'channels.dart';
import 'music_sink.dart';
import 'rtc.dart';
import 'spotify_app.dart';
import 'spotify_deck.dart';
import 'spotify_link.dart';
import 'spotify_lookup.dart';
import 'spotify_lossless.dart';
import 'spotify_queue.dart';
import 'voice.dart';

class SpotifyMusic extends ChangeNotifier {
  SpotifyMusic._();
  static final SpotifyMusic instance = SpotifyMusic._();

  @visibleForTesting
  SpotifyMusic.forTest({required this.isOn, required this.maySpeak, required this.app, required this.source, required this.makeEar, required this.clock, this.lookUp = _noLookup, this.ways = _noWays, this.store, this.player = _noPlayer, this.speaker = _noSpeaker});
  static MusicSink? _noPlayer() => null;
  static ValueListenable<String>? _noSpeaker() => null;
  static Future<Song> _noLookup(String track) async => Song(track: track);
  static ({List<Map<String, Object>> servers, bool relay}) _noWays() => (servers: const [], relay: false);

  /// Whether the plugin is on in the call there is (in a circle's space, as the circle says).
  bool Function() isOn = SpotifyPlugin.onInCall;

  /// Whether [id] may speak in the call's space, as its roles and mutes say: only they choose songs.
  bool Function(String id) maySpeak = _roomSays;

  /// This computer's Spotify and its sound; null where it can't be the DJ.
  SpotifyApp? Function() app = SpotifyApp.here;
  MusicSource? Function() source = _sourceHere;
  MakeEar makeEar = RtcMusicEar.make;
  DateTime Function() clock = DateTime.now;
  Future<Song> Function(String track) lookUp = SpotifyLookup.of;

  /// Where a connection looks for a way through: the call's own servers, and whether the relay is among them.
  ({List<Map<String, Object>> servers, bool relay}) Function() ways = _callWays;

  /// This device's own player, for music without loss; null where it has none. And the speaker the call has.
  MusicSink? Function() player = MusicSink.here;
  ValueListenable<String>? Function() speaker = _callSpeaker;
  static ValueListenable<String>? _callSpeaker() => Voice.instance.media?.speaker;

  /// Where the loudness is kept; the app's own choices where none is given.
  @visibleForTesting
  AppState? store;
  AppState? get _store => store ?? Voice.instance.app;

  static bool _roomSays(String id) {
    final s = Voice.instance.session;
    final room = s == null ? null : Voice.instance.heldHangout(s.channel);
    return room == null || room.heard(id == s!.route.me ? room.me : id);
  }

  static MusicSource? _sourceHere() => MusicSource.here(Voice.instance.settings);

  static ({List<Map<String, Object>> servers, bool relay}) _callWays() {
    final m = Voice.instance.media;
    return m == null ? (servers: RtcMedia.defaultIce, relay: false) : (servers: m.iceServers, relay: m.hasRelay);
  }

  // --- how loud it is --------------------------------------------------------------------------------------------------

  /// How loud the music is, under [levelId], for its rings as a voice's (Matt, 2026-11-25: "also show the voice activity
  /// for the spotify user with the ripples"). Read while it plays and the app is on the screen, and only while something
  /// shows it.
  static const levelId = 'music', levelEvery = Duration(milliseconds: 200);
  late final ValueNotifier<Map<String, double>> levels = _Watched(_tuneLevels);
  Timer? _levelTimer;
  bool _readingLevel = false;

  /// The DJ's loudest reading since the last look at Spotify ([_poll]'s, for silence): asking takes it from the platform.
  double _loudest = 0;

  @override
  void notifyListeners() {
    super.notifyListeners();
    _tuneLevels();
  }

  void _tuneLevels() {
    final watched = (levels as _Watched).watched;
    // Told as the app is put away and brought back, while anything shows the music's rings.
    AppSeen.now.removeListener(_tuneLevels);
    if (watched) AppSeen.now.addListener(_tuneLevels);
    final want = watched && AppSeen.now.value && state?.playing == true && (mine || _ear != null);
    if (want) {
      _levelTimer ??= Timer.periodic(levelEvery, (_) => unawaited(_readLevel()));
      return;
    }
    _levelTimer?.cancel();
    _levelTimer = null;
    if (levels.value.isNotEmpty) levels.value = const {};
  }

  Future<void> _readLevel() async {
    if (_readingLevel) return;
    if (!AppSeen.now.value) return _tuneLevels();
    _readingLevel = true;
    try {
      final from = _source;
      final l = mine ? (from == null ? 0.0 : await from.level().catchError((_) => 0.0)) : await (_ear?.level() ?? Future.value(0.0));
      if (mine) _loudest = math.max(_loudest, l);
      // Music is loud all the way through: brought down so the rings move with it and not stand at their widest.
      if (_levelTimer != null) levels.value = {levelId: l < 0.01 ? 0 : math.min(1, l * 0.5)};
    } finally {
      _readingLevel = false;
    }
  }

  // --- how often things are said and done --------------------------------------------------------------------------------

  static const beatEvery = Duration(seconds: 5), pollEvery = Duration(seconds: 1);

  /// Two who pressed Start at once settle it by their ids, within this long of starting.
  static const settlesWithin = Duration(seconds: 10);

  /// The DJ's: how often one person may ask for a connection, how many things of the queue's they may ask in
  /// [askWindow], and the most listeners there may be.
  static const linkEvery = Duration(seconds: 2), askWindow = Duration(seconds: 10);
  static const asksMost = 12, listenersMost = 60;

  /// Silence from Spotify for this many looks while it says it plays: nothing is being heard of it.
  static const silentAfter = 10;

  /// The longest description and way to connect taken from the room.
  static const sdpMost = 24000, candidateMost = 800;

  // --- the call ----------------------------------------------------------------------------------------------------------

  VoiceSession? _session;

  /// Who is playing the music: their id, this device's own where it is; null for nobody.
  String? get dj => _dj;
  String? _dj;
  DateTime? _djAt;

  /// This device is the DJ.
  bool get mine => _deck != null;

  /// What they last said, or what this device says; null while nobody plays.
  MusicState? state;

  bool get inCall => _session != null;
  String? get me => _session?.route.me;

  /// Whether this device's person may choose songs: in the call, and their role may speak.
  bool get mayChoose => _session != null && maySpeak(me!);

  /// Whether this computer could be the DJ, Spotify there or not.
  bool get canDj => app() != null;

  /// What to say is wrong, at the DJ's own device or at someone else's; null for nothing.
  String? get troubleWords {
    final w = state?.trouble ?? '';
    if (w.isEmpty) return null;
    return mine ? MusicTrouble.mine(w, mac: app()?.mac ?? true) : MusicTrouble.words[w];
  }

  /// Follows the call [Voice] is in.
  void follow() => followSession(Voice.instance.session);

  void followSession(VoiceSession? s) {
    if (identical(s, _session)) return;
    final was = _session;
    was?.onMusic = null;
    was?.removeListener(_callChanged);
    if (mine) unawaited(_stopDj());
    _forgetDj();
    _session = s;
    _asked.clear();
    _linkAt.clear();
    _known = const {};
    if (s != null) {
      s.onMusic = _heard;
      s.addListener(_callChanged);
      if (_circles == null) {
        _circles = _callChanged;
        Circles.instance.addListener(_circles!);
      }
      // Whoever is playing says so to this device.
      if (isOn()) s.sayMusic({'k': 'hi'});
    } else if (_circles != null) {
      Circles.instance.removeListener(_circles!);
      _circles = null;
    }
    notifyListeners();
  }

  VoidCallback? _circles;

  /// Who was in the call as last looked: whoever is new is told what plays.
  Set<String> _known = const {};

  /// Anything in the call changed: who is in it, what they may do, this device deafened.
  void _callChanged() {
    final s = _session;
    if (s == null) return;
    if (!isOn()) {
      if (mine) unawaited(stop());
      if (_dj != null) {
        _forgetDj();
        notifyListeners();
      }
      return;
    }
    final here = s.members.keys.toSet();
    if (mine) {
      // Muted for everyone, or a role that may not speak: not heard, so neither is their music.
      if (!maySpeak(s.route.me)) {
        unawaited(stop());
        return;
      }
      for (final id in here.difference(_known)) {
        _sayState(to: id);
      }
      for (final id in _links.keys.toList()) {
        if (!here.contains(id)) unawaited(_dropLink(id));
      }
    } else if (_dj != null && (!here.contains(_dj) || !maySpeak(_dj!))) {
      _forgetDj();
      notifyListeners();
    }
    _known = here;
    _tuneEar();
  }

  /// Something said of the music by [from].
  void _heard(String from, Map<String, dynamic> m) {
    final s = _session;
    if (s == null || !isOn() || !s.members.containsKey(from)) return;
    switch (m['k']) {
      case 'state':
        _heardState(from, m);
      case 'stop':
        if (from == _dj && !mine) {
          _forgetDj();
          notifyListeners();
        }
      case 'hi':
        if (mine && _may(from)) _sayState(to: from);
      case 'do':
        if (mine && m['to'] == s.route.me && maySpeak(from) && _may(from)) _doAsked(from, m);
      case 'ask':
        if (mine && m['to'] == s.route.me) unawaited(_offerTo(from, m['n'], m['ll']));
      case 'ans':
        if (mine && m['to'] == s.route.me) unawaited(_answered(from, m));
      case 'offer':
        if (!mine && from == _dj && m['to'] == s.route.me) unawaited(_offered(m));
      case 'ice':
        if (m['to'] == s.route.me) unawaited(_heardIce(from, m));
      case 'll':
        if (m['to'] == s.route.me) _heardLossless(from, m);
    }
  }

  /// Whether [from] may ask one more thing of this device now.
  bool _may(String from) {
    final now = clock();
    final list = _asked.putIfAbsent(from, () => []);
    list.removeWhere((t) => now.difference(t) >= askWindow);
    if (list.length >= asksMost) return false;
    list.add(now);
    return true;
  }

  final Map<String, List<DateTime>> _asked = {};

  void _heardState(String from, Map<String, dynamic> m) {
    final s = _session!;
    if (!maySpeak(from)) {
      // Who may no longer speak is no longer heard, and neither is their music.
      if (from == _dj && !mine) {
        _forgetDj();
        notifyListeners();
      }
      return;
    }
    final now = clock();
    if (mine) {
      // Someone else started too: within a moment of each other the lower id stays; later, the one who was first.
      if (now.difference(_djAt!) < settlesWithin && from.compareTo(s.route.me) < 0) unawaited(stop());
      return;
    }
    final had = _dj;
    if (had != null && had != from) {
      if (now.difference(_djAt!) >= settlesWithin || from.compareTo(had) > 0) return;
      _forgetDj();
    }
    final fresh = MusicState.fromWire(m, at: now);
    if (fresh == null) return;
    if (_dj == null) {
      _dj = from;
      _djAt = now;
    }
    state = fresh;
    _tuneEar();
    notifyListeners();
  }

  /// Nobody plays, as far as this device knows.
  void _forgetDj() {
    _dj = null;
    _djAt = null;
    state = null;
    _tries = 0;
    _askTimer?.cancel();
    _askTimer = null;
    unawaited(_dropEar());
  }

  // --- what this device's person asks ------------------------------------------------------------------------------------

  /// Adds the song [pasted] names. Why not, where it can't be.
  Future<String?> add(String pasted) async {
    final s = _session;
    if (s == null || !isOn() || _dj == null) return 'Nobody is playing music here yet.';
    if (!maySpeak(s.route.me)) return 'Your role in this space can\'t speak, so it can\'t choose songs.';
    final p = songIn(pasted);
    if (p.id == null) return p.why;
    final q = state?.next ?? const <QueuedSong>[];
    if (q.length >= songsMost) return 'The queue is full: $songsMost songs.';
    if (q.where((x) => x.by == s.route.me).length >= songsEachMost) return 'That is $songsEachMost songs from you in the queue. One more when one of them has played.';
    final song = await lookUp(p.id!);
    // The call was left, or the music stopped, while Spotify was asked what the song is.
    if (!identical(s, _session) || _dj == null) return 'The music stopped.';
    if (mine) return _add(song, s.route.me);
    s.sayMusic({'k': 'do', 'to': _dj, 'w': 'add', 'x': song.toWire()});
    return null;
  }

  void remove(int id) => mine ? _remove(id, me!) : _ask({'w': 'rm', 'e': id});
  void move(int id, int place) => mine ? _move(id, place) : _ask({'w': 'mv', 'e': id, 'i': place});
  void skip() => mine ? unawaited(_press((d) => d.skip(clock()))) : _ask({'w': 'skip'});
  void pause() => mine ? unawaited(_press((d) => d.pause())) : _ask({'w': 'pause'});
  void play() => mine ? unawaited(_press((d) => d.resume(clock()))) : _ask({'w': 'play'});
  void toggle() => (state?.playing ?? false) ? pause() : play();

  void _ask(Map<String, Object?> what) {
    final s = _session;
    if (s == null || _dj == null || !isOn() || !maySpeak(s.route.me)) return;
    s.sayMusic({'k': 'do', 'to': _dj, ...what});
  }

  /// Whether this device's person may take [song] away: their own, or any as the DJ.
  bool mayRemove(QueuedSong song) => mine || (mayChoose && song.by == me);

  // --- the DJ --------------------------------------------------------------------------------------------------------------

  SpotifyDeck? _deck;
  MusicSource? _source;
  SpotifyApp? _spotify;
  Timer? _poll, _beat;

  /// Between Start being pressed and the music being the call's.
  bool starting = false;

  /// Why the last Start here did not start, in a word of [MusicTrouble]'s; null where it did.
  String? startTrouble;
  String? get startWords => startTrouble == null ? null : MusicTrouble.mine(startTrouble!, mac: app()?.mac ?? true);

  /// What is wrong with it now, as the DJ's device knows it.
  String _trouble = '';
  int _silent = 0;

  /// Each button pressed counts one: what Spotify had said before it is not believed after.
  int _presses = 0;
  bool _polling = false;

  /// Becomes the DJ: only ever by this device's person pressing Start here. True where it did; else [startTrouble].
  Future<bool> start() async {
    final s = _session;
    if (s == null || !isOn() || mine || starting || _dj != null || !maySpeak(s.route.me)) return false;
    final spotify = app(), source = this.source();
    if (spotify == null || source == null) return false;
    starting = true;
    startTrouble = null;
    notifyListeners();
    String? why;
    try {
      final able = await spotify.able();
      if (!able.system) throw const SpotifyRefused(MusicTrouble.system);
      if (!able.installed && !able.running) throw const SpotifyRefused(MusicTrouble.absent);
      if (!able.running) throw const SpotifyRefused(MusicTrouble.closed);
      // Asked what it is doing first: this is where the system asks the person whether the app may.
      final now = await spotify.now();
      await source.begin();
      // Left, or someone else started, or the plugin was turned off, while the system asked.
      if (!identical(s, _session) || !isOn() || _dj != null) {
        await source.end();
        why = '';
      } else {
        _begin(s, spotify, source, now);
      }
    } on SpotifyRefused catch (e) {
      why = e.word;
      await source.end();
    } catch (e) {
      debugPrint('spotify: not started: $e');
      why = MusicTrouble.failed;
      await source.end();
    }
    starting = false;
    startTrouble = why == null || why.isEmpty ? null : why;
    notifyListeners();
    return why == null;
  }

  void _begin(VoiceSession s, SpotifyApp spotify, MusicSource source, SpotifyNow now) {
    final deck = _deck = SpotifyDeck(me: s.route.me, opens: spotify.opens);
    _spotify = spotify;
    _source = source;
    _dj = s.route.me;
    _djAt = clock();
    _trouble = '';
    _silent = 0;
    _known = s.members.keys.toSet();
    source.onCandidate = (id, c) {
      final l = _links[id];
      if (l != null) _session?.sayMusic({'k': 'ice', 'to': id, 'l': l, 'c': c});
    };
    source.onState = (id, state) {
      if (state == 'failed' || state == 'closed') unawaited(_dropLink(id));
    };
    spotify.onQuit = () {
      if (!identical(_deck, deck)) return;
      deck.playing = false;
      _setTrouble(MusicTrouble.closed);
    };
    // What Spotify was playing already is what the call hears first.
    final d = deck.heard(now, clock());
    _poll = Timer.periodic(pollEvery, (_) => unawaited(look()));
    _beat = Timer.periodic(beatEvery, (_) {
      if (deck.playing) _sayState();
    });
    _said(force: true);
    if (d != null) unawaited(_do(d));
  }

  /// Stops the music for everyone, and lets go of Spotify's sound. A song of the queue's is paused in Spotify; one the DJ
  /// chose there is left playing, as theirs.
  Future<void> stop() async {
    if (!mine) return;
    await _stopDj();
    notifyListeners();
  }

  Future<void> _stopDj() async {
    final deck = _deck, source = _source, spotify = _spotify;
    _deck = null;
    _source = null;
    _spotify = null;
    _poll?.cancel();
    _beat?.cancel();
    _poll = _beat = null;
    _links.clear();
    _desk.clear();
    _captured = 0;
    _trouble = '';
    spotify?.onQuit = null;
    source?.onCandidate = null;
    source?.onState = null;
    _dj = null;
    _djAt = null;
    state = null;
    _session?.sayMusic({'k': 'stop'});
    notifyListeners();
    if (deck != null && deck.oursPlaying) {
      try {
        await spotify?.pause();
      } catch (_) {}
    }
    await source?.end();
  }

  /// Looks at what Spotify is doing, and does what follows from it. Once a second while this device is the DJ.
  @visibleForTesting
  Future<void> look() async {
    final deck = _deck, spotify = _spotify, source = _source;
    if (deck == null || spotify == null || source == null || _polling) return;
    // The role changed while this device's microphone was off already, or the circle turned the plugin off.
    if (!isOn() || !maySpeak(me!)) return stop();
    _polling = true;
    try {
      final presses = _presses;
      final SpotifyNow now;
      try {
        now = await spotify.now();
      } on SpotifyRefused catch (e) {
        if (identical(deck, _deck)) _setTrouble(e.word, stopped: true);
        return;
      }
      if (!identical(deck, _deck)) return;
      // A button was pressed while it was asked: what it said was from before it.
      if (presses != _presses) return;
      if (_trouble == MusicTrouble.closed || _trouble == MusicTrouble.denied || _trouble == MusicTrouble.failed) _trouble = '';
      final d = deck.heard(now, clock());
      // The loudest since the last look: the rings' own readings take it too (_readLevel), so theirs are counted.
      final level = math.max(_loudest, await source.level().catchError((_) => 1.0));
      _loudest = 0;
      if (!identical(deck, _deck)) return;
      // Nothing at all from it for a while, though it says it plays.
      _silent = deck.playing && now.playing && level < 0.0005 ? _silent + 1 : 0;
      if (_silent >= silentAfter) {
        _trouble = MusicTrouble.silent;
      } else if (_trouble == MusicTrouble.silent && _silent == 0) {
        _trouble = '';
      }
      if (d != null) await _do(d);
      _said();
      // Never waited for: WebRTC slow to say how its connections stand is nothing to the queue.
      unawaited(_lookLossless(source, deck));
    } finally {
      _polling = false;
    }
  }

  // --- without loss, the DJ's side ---------------------------------------------------------------------------------------

  late final LosslessDesk _desk = LosslessDesk(clock: () => clock());
  double _captured = 0;

  /// How many are sent the music without loss now, and what that takes of this device's upload, in bits a second.
  int get sentLossless => mine ? _desk.having : 0;
  double get losslessBits => mine && _desk.having > 0 ? _desk.bitsPerSecond : 0;

  /// Those who have the music from here at all.
  int get listeners => mine ? _links.length : 0;

  /// What Spotify's sound is taken at on this computer is less than the music is made at: a Bluetooth headset's
  /// microphone in use brings a Mac's output down to a call's, and then that is all there is to send.
  bool get capturedLow => mine && _captured > 0 && _captured < 44100;

  bool _lookingLossless = false;
  static const _answerWithin = Duration(seconds: 4);

  Future<void> _lookLossless(MusicSource source, SpotifyDeck deck) async {
    if (_lookingLossless) return;
    _lookingLossless = true;
    try {
      final hz = await source.rate().timeout(_answerWithin);
      if (!identical(deck, _deck)) return;
      final low = capturedLow;
      _captured = hz;
      if (low != capturedLow) notifyListeners();
      if (_desk.isEmpty) return;
      final had = sentLossless;
      final now = await source.losslessState().timeout(_answerWithin);
      if (!identical(deck, _deck)) return;
      for (final d in _desk.look(now)) {
        switch (d) {
          case LosslessBegin(:final id):
            await source.lossless(id, on: true);
            _tellLossless(id, null);
          case LosslessEnd(:final id, :final why):
            await source.lossless(id, on: false);
            // Not wanted, they know why.
            if (why != LosslessWhy.off) _tellLossless(id, why);
          case LosslessTell(:final id, :final why):
            _tellLossless(id, why);
        }
        if (!identical(deck, _deck)) return;
      }
      if (had != sentLossless) notifyListeners();
    } catch (e) {
      debugPrint('spotify: lossless not looked at: $e');
    } finally {
      _lookingLossless = false;
    }
  }

  void _tellLossless(String id, LosslessWhy? why) {
    final mark = _links[id];
    if (mark != null) _session?.sayMusic({'k': 'll', 'to': id, 'l': mark, 'w': why?.word ?? ''});
  }

  /// What [from] says of the music without loss: a listener that they take it or don't, the DJ why they don't get it.
  void _heardLossless(String from, Map<String, dynamic> m) {
    if (mine) {
      if (m['l'] is String && _links[from] == m['l'] && _may(from)) _desk.said(from, wants: m['w'] == 1, slow: m['s'] == 1);
    } else if (from == _dj && m['l'] == _earMark && m['l'] != null) {
      _djWhy = LosslessWhy.said(m['w']);
      if (_djWhy == null) _earWhy = null;
      notifyListeners();
    }
  }

  void _setTrouble(String word, {bool stopped = false}) {
    final deck = _deck;
    if (deck == null) return;
    if (stopped) deck.playing = false;
    _trouble = word;
    _said();
  }

  /// Presses what [of] says, for the DJ's own person or someone who asked.
  Future<void> _press(DeckDo? Function(SpotifyDeck d) of) async {
    final deck = _deck;
    if (deck == null) return;
    final d = of(deck);
    _said();
    if (d != null) await _do(d);
  }

  Future<void> _do(DeckDo d) async {
    final spotify = _spotify, deck = _deck;
    if (spotify == null) return;
    _presses++;
    try {
      switch (d) {
        case DeckPlay(:final track):
          await spotify.play(track);
        case DeckPause():
          await spotify.pause();
        case DeckResume():
          await spotify.resume();
      }
      if (identical(deck, _deck) && (_trouble == MusicTrouble.closed || _trouble == MusicTrouble.denied || _trouble == MusicTrouble.failed)) _trouble = '';
    } on SpotifyRefused catch (e) {
      if (identical(deck, _deck)) _setTrouble(e.word, stopped: true);
    } finally {
      _presses++;
    }
    if (identical(deck, _deck)) _said();
  }

  /// Does what [from] asked, where it is something that can be asked.
  void _doAsked(String from, Map<String, dynamic> m) {
    final id = m['e'], place = m['i'];
    switch (m['w']) {
      case 'add':
        final song = Song.fromWire(m['x']);
        if (song != null) _add(song, from);
      case 'rm':
        if (id is int) _remove(id, from);
      case 'mv':
        if (id is int && place is int) _move(id, place);
      case 'skip':
        unawaited(_press((d) => d.skip(clock())));
      case 'pause':
        unawaited(_press((d) => d.pause()));
      case 'play':
        unawaited(_press((d) => d.resume(clock())));
    }
  }

  String? _add(Song song, String by) {
    final deck = _deck;
    if (deck == null) return 'Nobody is playing music here yet.';
    final why = deck.queue.add(song, by);
    if (why != null) return why;
    final id = deck.queue.songs.last.id;
    unawaited(_press((d) => d.added(clock())));
    // Added from a browser, or where its name could not be read: read here, for everyone.
    if (song.title.isEmpty) {
      unawaited(lookUp(song.track).then((found) {
        if (!identical(deck, _deck) || found.title.isEmpty) return;
        final n = deck.now;
        if (n != null && n.id == id && n.song.title.isEmpty) deck.now = n.withSong(found.copyWith(length: n.song.length));
        deck.queue.say(id, found);
        _said();
      }).catchError((_) {}));
    }
    return null;
  }

  void _remove(int id, String by) {
    final deck = _deck;
    if (deck != null && deck.queue.remove(id, by: by, dj: by == me)) _said();
  }

  void _move(int id, int place) {
    final deck = _deck;
    if (deck != null && deck.queue.move(id, place)) _said();
  }

  /// What was last said of it, to say it again only when it is something else.
  String _last = '';
  DateTime? _lastAt;
  Duration _lastPos = Duration.zero;

  /// The state is as the deck has it now: kept, shown here, and said to the call where it is not what was last said
  /// (its place alone is said with the beat, or where it was moved).
  void _said({bool force = false}) {
    final deck = _deck;
    if (deck == null) return;
    final now = clock();
    final fresh = deck.state(now, trouble: _trouble);
    state = fresh;
    final mark = '${fresh.now?.id}|${fresh.now?.song.hashCode}|${fresh.playing}|${fresh.trouble}|${[for (final q in fresh.next) '${q.id}:${q.song.hashCode}'].join(',')}';
    final due = _lastAt == null ? Duration.zero : _lastPos + (fresh.playing ? now.difference(_lastAt!) : Duration.zero);
    if (force || mark != _last || (fresh.position - due).abs() > const Duration(seconds: 3)) _sayState();
    _last = mark;
    notifyListeners();
  }

  /// Says the whole state, to everyone or to [to].
  void _sayState({String? to}) {
    final deck = _deck, s = _session;
    if (deck == null || s == null) return;
    final now = clock();
    final fresh = deck.state(now, trouble: _trouble);
    if (to == null) {
      _lastAt = now;
      _lastPos = fresh.position;
    }
    s.sayMusic({'k': 'state', 'to': ?to, ...fresh.toWire()});
  }

  // --- the connections, the DJ's side ----------------------------------------------------------------------------------------

  /// Each listener's connection, by its mark: what is said of another is not for it.
  final Map<String, String> _links = {};
  final Map<String, DateTime> _linkAt = {};

  Future<void> _offerTo(String id, Object? tries, [Object? lossless]) async {
    final s = _session, source = _source;
    if (s == null || source == null) return;
    final now = clock();
    final last = _linkAt[id];
    if (last != null && now.difference(last) < linkEvery) return;
    if (!_links.containsKey(id) && _links.length >= listenersMost) return;
    _linkAt[id] = now;
    final mark = _links[id] = NetCrypto.hex(NetCrypto.randomBytes(8));
    final w = ways();
    // Through the relay alone first where there is one, as the call's own connections are; every path the next time. The
    // other way about for who is to have it without loss, which the relay is never sent: every path first (the relay's
    // among them), the relay alone next.
    final relay = w.relay && (tries is! int || (lossless == 1 ? tries.isOdd : tries.isEven));
    // 1: they want it; 0: they might later. A build from before says neither.
    final can = lossless == 0 || lossless == 1;
    final channel = can && !relay;
    if (can) {
      _desk.asked(id, wants: lossless == 1);
      _desk.offered(id, channel: false);
    } else {
      _desk.gone(id);
    }
    final sdp = await source.offer(id, servers: w.servers, relayOnly: relay, lossless: channel).catchError((_) => null);
    if (_links[id] != mark || !identical(source, _source)) return;
    if (sdp == null) {
      _links.remove(id);
      _desk.gone(id);
      return;
    }
    if (can) _desk.offered(id, channel: channel);
    s.sayMusic({'k': 'offer', 'to': id, 'l': mark, 'sdp': sdp, if (relay) 'r': 1});
    if (can && relay) _tellLossless(id, LosslessWhy.relay);
  }

  Future<void> _answered(String from, Map<String, dynamic> m) async {
    final mark = _links[from], sdp = m['sdp'];
    if (mark == null || m['l'] != mark || sdp is! String || sdp.length > sdpMost) return;
    final ok = await _source?.answer(from, sdp).catchError((_) => false) ?? false;
    if (!ok && _links[from] == mark) await _dropLink(from);
  }

  Future<void> _dropLink(String id) async {
    if (_links.remove(id) == null) return;
    _desk.gone(id);
    await _source?.close(id).catchError((_) {});
  }

  Future<void> _heardIce(String from, Map<String, dynamic> m) async {
    final c = m['c'];
    if (c is! Map || m['l'] is! String) return;
    final line = c['candidate'], mid = c['sdpMid'], at = c['sdpMLineIndex'];
    if (line is! String || line.length > candidateMost) return;
    final way = <String, dynamic>{'candidate': line, 'sdpMid': mid is String && mid.length < 40 ? mid : '', 'sdpMLineIndex': at is int && at >= 0 && at < 8 ? at : 0};
    if (mine) {
      if (_links[from] == m['l']) await _source?.candidate(from, way).catchError((_) {});
    } else if (from == _dj && m['l'] == _earMark) {
      try {
        await _ear?.candidate(way);
      } catch (_) {}
    }
  }

  // --- the listener ------------------------------------------------------------------------------------------------------------

  MusicEar? _ear;
  String? _earMark;
  bool _through = false;
  int _tries = 0;
  Timer? _askTimer;

  /// The music is coming to this device.
  bool get hearing => _ear != null && _through;

  static const volumeKey = 'spotify_volume';

  /// How loud the music is here, 0 to 100. At 0 it is not asked for at all.
  int get volume => (int.tryParse(_store?.choice(volumeKey, '60') ?? '60') ?? 60).clamp(0, 100);

  void setVolume(int to) {
    _store?.keep(volumeKey, '${to.clamp(0, 100)}');
    _tuneEar();
    notifyListeners();
  }

  /// Whether this device wants the music's sound: someone else plays it, and it is not turned all the way down.
  bool get _wants => _session != null && !mine && _dj != null && state?.now != null && volume > 0 && isOn();

  /// The connection as it should be: asked for, let go of, or as loud as it is to be.
  void _tuneEar() {
    if (!_wants) {
      _askTimer?.cancel();
      _askTimer = null;
      if (_ear != null && (mine || _dj == null || volume == 0 || !isOn())) unawaited(_dropEar());
    } else if (_ear == null && _askTimer == null) {
      if (_player == null || _way != null) {
        _askNow();
      } else {
        // Where the sound goes is looked at first: it is said in the asking.
        unawaited(_lookWay().then((_) {
          if (_wants && _way != null && _ear == null && _askTimer == null) _askNow();
        }));
      }
    }
    _loud();
  }

  void _loud() {
    final s = _session;
    final out = Voice.instance.media?.settings.outputVolume ?? 100;
    _ear?.set(volume: volume / 100 * out / 100, silent: s == null || s.deafened);
    _ear?.playing(state?.playing ?? false);
  }

  // --- without loss, the listener's side -----------------------------------------------------------------------------------

  static const losslessKey = 'spotify_lossless', headphonesKey = 'spotify_headphones', wayEvery = Duration(seconds: 2);

  /// Whether the music is to come without loss on this device, where it can.
  bool get lossless => _store?.choice(losslessKey, '1') != '0';

  void setLossless(bool on) {
    _store?.keep(losslessKey, on ? '1' : '0');
    unawaited(_lookWay());
    notifyListeners();
  }

  /// This device's person says what they hear it on now is headphones, where the system can't tell.
  bool get headphones {
    final w = _way;
    return w != null && w.device.isNotEmpty && _store?.choice(headphonesKey, '') == w.device;
  }

  void setHeadphones(bool on) {
    _store?.keep(headphonesKey, on ? _way?.device ?? '' : '');
    unawaited(_lookWay());
    notifyListeners();
  }

  /// Whether this device has a player for it at all.
  bool get losslessCan => _player != null;
  MusicSink? get _player => player();

  /// What stands in its way on this device ([_lookWay]); why the DJ's doesn't send it; why it was given up here.
  LosslessWhy? _bar = LosslessWhy.device, _djWhy, _earWhy;
  MusicWay? _way;

  /// The music is heard without loss.
  bool get hearingLossless => _ear != null && _heardLosslessNow;
  bool _heardLosslessNow = false;

  /// The connection there is was made with room for it; what was asked for it.
  bool _room = false;
  int? _askedLossless;
  Timer? _wayTimer;
  ValueListenable<String>? _speakerOf;

  /// Why it isn't, in plain words; null where it is, or is on its way.
  String? get losslessWords {
    if (hearingLossless) return null;
    final why = !losslessCan ? LosslessWhy.device : _bar ?? _earWhy ?? _djWhy ?? (hearing && !_room ? LosslessWhy.old : null);
    return why?.words;
  }

  /// Whether what it waits for, or has, is this person's word that these are headphones.
  bool get asksHeadphones => lossless && _way?.to == MusicTo.unknown && _way!.device.isNotEmpty;

  LosslessWhy? _barFor(MusicWay w) => !lossless
      ? LosslessWhy.off
      : switch (w.to) {
          MusicTo.none => LosslessWhy.sink,
          MusicTo.callHeadset => LosslessWhy.callHeadset,
          MusicTo.speakers => LosslessWhy.speakers,
          MusicTo.unknown when !headphones => LosslessWhy.unknown,
          // Whatever it is, at a call's rate it plays no music whole.
          _ => w.rate > 0 && w.rate < 44100 ? LosslessWhy.callHeadset : null,
        };

  bool _lookingWay = false, _lookAgain = false;

  /// Looks at where the sound goes, and whether the music may come without loss.
  Future<void> _lookWay() async {
    final p = _player;
    if (p == null) return;
    if (_lookingWay) {
      _lookAgain = true;
      return;
    }
    _lookingWay = true;
    try {
      do {
        _lookAgain = false;
        final w = await p.way(speaker()?.value ?? '').catchError((_) => const MusicWay(MusicTo.none, 0));
        _way = w;
        final bar = _barFor(w);
        if (bar != _bar) {
          _bar = bar;
          if (bar == null) _earWhy = null;
          _barChanged();
          notifyListeners();
        }
      } while (_lookAgain);
    } finally {
      _lookingWay = false;
    }
  }

  /// It may come now, or no longer may.
  void _barChanged() {
    final ear = _ear, s = _session;
    if (ear == null || s == null) return;
    final take = _bar == null;
    ear.lossless(take);
    if (!take) _heardLosslessNow = false;
    if (take && !_room && _askedLossless == 0) {
      // The connection was made without room for it, when there was no use for it: made again, with it.
      _tries = 0;
      _askTimer?.cancel();
      _askTimer = null;
      unawaited(_dropEar().then((_) {
        if (_wants && _ear == null && _askTimer == null) _askNow();
      }));
    } else if (_room) {
      s.sayMusic({'k': 'll', 'to': _dj, 'l': _earMark, 'w': take ? 1 : 0});
    }
  }

  void _speakerChanged() {
    unawaited(_ear?.output(speaker()?.value ?? '').catchError((_) {}));
    unawaited(_lookWay());
  }

  /// Asks the DJ for a connection, and again, further apart each time, until it is through.
  void _askNow() {
    final s = _session;
    if (s == null || !_wants) return;
    _askedLossless = losslessCan ? (_bar == null ? 1 : 0) : null;
    s.sayMusic({'k': 'ask', 'to': _dj, 'n': _tries, 'll': ?_askedLossless});
    if (_player != null) unawaited(_lookWay());
    final wait = Duration(seconds: [4, 8, 16, 30][_tries.clamp(0, 3)]);
    _tries++;
    _askTimer = Timer(wait, () {
      _askTimer = null;
      if (_ear == null && _wants) _askNow();
    });
  }

  /// The DJ's offer, for a connection this device asked for.
  Future<void> _offered(Map<String, dynamic> m) async {
    final s = _session, mark = m['l'], sdp = m['sdp'];
    if (s == null || !_wants || mark is! String || mark.length > 40 || sdp is! String || sdp.length > sdpMost) return;
    await _dropEar();
    if (!identical(s, _session) || !_wants) return;
    _earMark = mark;
    final from = _dj!;
    late final MusicEar ear;
    ear = _ear = makeEar(
      servers: ways().servers,
      relayOnly: m['r'] == 1,
      onCandidate: (c) {
        if (identical(_ear, ear)) _session?.sayMusic({'k': 'ice', 'to': from, 'l': mark, 'c': c});
      },
      onState: (up) {
        if (!identical(_ear, ear)) return;
        _through = up;
        if (up) {
          _tries = 0;
          _askTimer?.cancel();
          _askTimer = null;
        } else {
          // Lost, or never through: let go of, and asked for again.
          unawaited(_dropEar().then((_) {
            if (_wants && _ear == null && _askTimer == null) _askNow();
          }));
        }
        notifyListeners();
      },
      onLossless: (heard, why) {
        if (!identical(_ear, ear)) return;
        _heardLosslessNow = heard;
        if (heard) _earWhy = null;
        if (why != null) {
          _earWhy = why;
          // The DJ's device waits a while and begins again, longer each time; or not at all, where this one never could.
          _session?.sayMusic({'k': 'll', 'to': from, 'l': mark, 'w': 0, if (why == LosslessWhy.slow) 's': 1});
        }
        notifyListeners();
      },
    );
    _room = sdp.contains('m=application');
    _djWhy = _earWhy = null;
    ear.lossless(_bar == null);
    // It changed since it was asked.
    if (_askedLossless != null && (_askedLossless == 1) != (_bar == null)) scheduleMicrotask(_barChanged);
    _loud();
    final out = speaker();
    unawaited(ear.output(out?.value ?? '').catchError((_) {}));
    if (_player != null) {
      _speakerOf = out;
      _speakerOf?.addListener(_speakerChanged);
      _wayTimer = Timer.periodic(wayEvery, (_) => unawaited(_lookWay()));
    }
    try {
      final answer = await ear.takeOffer(sdp);
      if (identical(_ear, ear)) _session?.sayMusic({'k': 'ans', 'to': from, 'l': mark, 'sdp': answer});
    } catch (e) {
      debugPrint('spotify: the music\'s offer not taken: $e');
      if (identical(_ear, ear)) await _dropEar();
    }
  }

  Future<void> _dropEar() async {
    final ear = _ear;
    _ear = null;
    _earMark = null;
    _through = _heardLosslessNow = _room = false;
    _djWhy = _earWhy = null;
    _wayTimer?.cancel();
    _wayTimer = null;
    _speakerOf?.removeListener(_speakerChanged);
    _speakerOf = null;
    await ear?.close();
  }
}

/// A notifier that says when it gains its first listener or loses its last.
class _Watched extends ValueNotifier<Map<String, double>> {
  _Watched(this.changed) : super(const {});
  final VoidCallback changed;
  int _count = 0;
  bool get watched => _count > 0;

  @override
  void addListener(VoidCallback listener) {
    super.addListener(listener);
    if (++_count == 1) changed();
  }

  @override
  void removeListener(VoidCallback listener) {
    super.removeListener(listener);
    if (_count > 0 && --_count == 0) changed();
  }
}
