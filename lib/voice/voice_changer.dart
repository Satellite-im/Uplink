/// A voice message sent in another voice (Matt, 2026-11-20: "How can we get a realistic voice changer with AI ... can
/// this be done real time ish with 11 labs?"; "I want it to have the same vocal queues as the speaker not just
/// transcribe and re speak what they say"; "build it as a plugin"). The plugin is lib/plugins/voice_changer.dart; its
/// pages are lib/ui/voice_changer_ui.dart.
///
/// Since 2026-11-21 a call's voice is changed too, and its choices are kept here: on this device as it is said
/// ([VoiceEffect], native/voicefx) or by ElevenLabs a phrase behind ([CallVoiceWay]; lib/voice/live_changer.dart does
/// the work). The rest of this is the voice messages.
///
/// ElevenLabs' Voice Changer (POST /v1/voice-changer/{voice}, as its reference gives it on 2026-11-21) is speech to speech: it keeps how the recording was said
/// (its timing, rise and fall, feeling, a laugh or a whisper) and gives it back in the voice chosen. It wants the whole
/// recording before it starts, so this is for voice messages, which are whole before they are sent; a live call would
/// run a sentence behind.
///
/// - The person's own ElevenLabs key, and the voice chosen from their own account's list (GET /v2/voices: ElevenLabs'
///   own voices and any they made). Nothing of Uplink's is in between and no key ships in the app: the recording goes
///   from this device to ElevenLabs and comes back.
/// - The key, the voice and the list are kept in one file only this account reads (0600), never among the app's other
///   choices, which a paired computer is shown.
/// - A recording that could not be changed is NOT sent as it was: whoever turned this on does not want their own voice
///   going out because a server was slow. The send fails, says why, and the recording is let go.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../platform_info.dart';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../desktop/store.dart' show DeskStore;
import '../plugins/voice_changer.dart' show VoiceChangerPlugin;

/// One voice of the account's.
@immutable
class ChangerVoice {
  const ChangerVoice({required this.id, required this.name, this.about = '', this.preview});
  final String id;
  final String name;

  /// A few words of it, from ElevenLabs' labels: "female · young · american".
  final String about;

  /// A short sample of it, to hear before choosing.
  final String? preview;

  /// What a voice's id may be. It goes into the request's path, so anything else is not taken for a voice.
  static final _idShape = RegExp(r'^[A-Za-z0-9_-]{8,64}$');

  Map<String, Object?> toJson() => {'id': id, 'n': name, 'a': about, 'p': ?preview};

  static ChangerVoice? fromJson(Object? j) {
    if (j is! Map || j['id'] is! String || j['n'] is! String || !_idShape.hasMatch(j['id'] as String)) return null;
    final p = j['p'];
    return ChangerVoice(id: j['id'] as String, name: j['n'] as String, about: j['a'] is String ? j['a'] as String : '', preview: p is String && p.startsWith('https://') ? p : null);
  }

  /// From ElevenLabs' list.
  static ChangerVoice? fromApi(Object? j) {
    if (j is! Map || j['voice_id'] is! String || !_idShape.hasMatch(j['voice_id'] as String)) return null;
    final labels = j['labels'] is Map ? j['labels'] as Map : const {};
    final words = [for (final k in const ['gender', 'age', 'accent', 'descriptive']) if (labels[k] is String && (labels[k] as String).isNotEmpty) (labels[k] as String).replaceAll('_', ' ')];
    final name = j['name'] is String && (j['name'] as String).trim().isNotEmpty ? (j['name'] as String).trim() : 'Voice';
    final p = j['preview_url'];
    return ChangerVoice(id: j['voice_id'] as String, name: name.length > 60 ? name.substring(0, 60) : name, about: words.join(' · '), preview: p is String && p.startsWith('https://') ? p : null);
  }

  @override
  bool operator ==(Object other) => other is ChangerVoice && other.id == id && other.name == name;

  @override
  int get hashCode => Object.hash(id, name);
}

/// A voice made on this device as it is said, for calls (native/voicefx voicefx_effect; Matt, 2026-11-21: "Add support
/// (by default) for the voice changer to use on the fly voice changing the elevenlabs is very slow and not real time"):
/// about a twentieth of a second behind, free, and nothing leaves the device.
///
/// Each moves the voice's pitch and its formants (how big the throat and mouth sound) apart, as a real voice of that
/// kind differs (Matt, 2026-11-21: "work on making them sound more realistic and do feminine masculine and things like
/// that"); the names are native/voicefx's (voicefx_effect_id).
enum VoiceEffect {
  feminine('Feminine', 'A woman\'s pitch and voice'),
  masculine('Masculine', 'A man\'s pitch and voice'),
  deeper('Deeper', 'Your voice, a little lower and fuller'),
  higher('Higher', 'Your voice, a little higher and lighter'),
  child('Child', 'High, with a small voice'),
  older('Older', 'A little lower, with a waver'),
  monster('Monster', 'Huge, very low and rough'),
  chipmunk('Chipmunk', 'The cartoon: squeaky and fast-sounding'),
  robot('Robot', 'One flat, mechanical pitch'),
  radio('Radio', 'Thin, like a walkie-talkie');

  const VoiceEffect(this.label, this.about);
  final String label;
  final String about;

  static VoiceEffect? named(String? n) => values.where((e) => e.name == n).firstOrNull;
}

/// How a call's voice is changed: here, as it is said ([VoiceEffect]), or by ElevenLabs, a phrase behind.
enum CallVoiceWay { device, elevenlabs }

/// Why ElevenLabs could not change a recording or give its list of voices, in [words] the person is shown.
class VoiceChangerProblem implements Exception {
  const VoiceChangerProblem(this.words);
  final String words;
  @override
  String toString() => words;
}

/// The voice changer's choices on this device (the ElevenLabs key, the voice, a call's way and effect), kept in its
/// one file, and the asking of ElevenLabs. Listeners are told when a choice changes or it starts or stops asking.
class VoiceChanger extends ChangeNotifier {
  VoiceChanger._();
  static final VoiceChanger instance = VoiceChanger._();

  @visibleForTesting
  VoiceChanger.forTest({required this.folder, required this.base, bool Function()? isOn}) {
    if (isOn != null) this.isOn = isOn;
  }

  /// ElevenLabs.
  Uri base = Uri.parse('https://api.elevenlabs.io');

  /// Where its one file is kept; this device's own place where none is given.
  String? folder;

  /// Whether the plugin is added on this device.
  bool Function() isOn = VoiceChangerPlugin.isOn;

  /// The model: speech to speech in any language the recording is in.
  static const model = 'eleven_multilingual_sts_v2';

  /// What comes back: MP3, which every app a message may be read in plays (ElevenLabs gives no AAC, which is what a
  /// recording here is; an iPhone does not play Ogg).
  static const format = 'mp3_44100_64';

  /// The largest recording sent to be changed, and how long ElevenLabs is waited for.
  static const most = 20 * 1024 * 1024;
  static const patience = Duration(seconds: 90);

  String _key = '';
  ChangerVoice? _voice;
  List<ChangerVoice> _voices = const [];
  bool _clean = true;
  bool _paused = false;
  bool _live = false;
  CallVoiceWay _way = CallVoiceWay.device;
  VoiceEffect _effect = VoiceEffect.deeper;
  bool _loaded = false;

  /// Asking ElevenLabs now (its list, or a recording).
  bool busy = false;

  String get _dir => folder ?? (PlatformInfo.isAndroid ? '${Directory.systemTemp.parent.path}/files/voicechanger' : '${DeskStore.defaultDir().path}/voicechanger');
  File get _file => File('$_dir/elevenlabs.json');

  /// Reads the file, once: every getter calls it first, so nothing is read until something is asked for.
  void _load() {
    if (_loaded) return;
    _loaded = true;
    try {
      final j = jsonDecode(_file.readAsStringSync());
      if (j is! Map) return;
      _key = j['key'] is String ? j['key'] as String : '';
      _voice = ChangerVoice.fromJson(j['voice']);
      _voices = [for (final v in (j['voices'] is List ? j['voices'] as List : const [])) ?ChangerVoice.fromJson(v)];
      _clean = j['clean'] != false;
      _paused = j['paused'] == true;
      _live = j['live'] == true;
      // On this device unless ElevenLabs was chosen: the default since 2026-11-21.
      _way = j['way'] == 'elevenlabs' ? CallVoiceWay.elevenlabs : CallVoiceWay.device;
      _effect = VoiceEffect.named(j['effect'] as String?) ?? VoiceEffect.deeper;
    } catch (_) {
      // Nothing kept yet.
    }
  }

  /// Writes the file, made readable by this account alone before the key goes into it.
  void _save() {
    try {
      final dir = Directory(_dir)..createSync(recursive: true);
      final f = _file;
      if (!f.existsSync()) f.createSync();
      if (!PlatformInfo.isWindows) {
        Process.runSync('chmod', ['700', dir.path]);
        Process.runSync('chmod', ['600', f.path]);
      }
      f.writeAsStringSync(jsonEncode({'key': _key, 'voice': _voice?.toJson(), 'voices': [for (final v in _voices) v.toJson()], 'clean': _clean, 'paused': _paused, 'live': _live, 'way': _way.name, 'effect': _effect.name}), flush: true);
    } catch (_) {
      // Kept for this run alone.
    }
  }

  /// Whether a key is kept. The key itself is never shown again: only its last four characters ([keyEnd]).
  bool get hasKey {
    _load();
    return _key.isNotEmpty;
  }

  String get keyEnd => hasKey && _key.length > 8 ? _key.substring(_key.length - 4) : '';

  /// The voice chosen, and the account's voices as they were last read from ElevenLabs.
  ChangerVoice? get voice {
    _load();
    return _voice;
  }

  List<ChangerVoice> get voices {
    _load();
    return _voices;
  }

  /// Background noise taken out of the recording before it is changed.
  bool get clean {
    _load();
    return _clean;
  }

  /// Set up, but the next messages go in the person's own voice.
  bool get paused {
    _load();
    return _paused;
  }

  /// In space calls too, live (lib/voice/live_changer.dart; Matt, 2026-11-20: "I'd like the voice changer to work in
  /// spaces calls in real time"): off until turned on, since others then hear each phrase a moment after it is said.
  bool get live {
    _load();
    return _live;
  }

  void setLive(bool on) {
    _load();
    _live = on;
    _save();
    notifyListeners();
  }

  /// How a call's voice is changed: on this device unless ElevenLabs was chosen.
  CallVoiceWay get way {
    _load();
    return _way;
  }

  void setWay(CallVoiceWay w) {
    _load();
    _way = w;
    _save();
    notifyListeners();
  }

  /// The effect a call's voice has, made on this device.
  VoiceEffect get effect {
    _load();
    return _effect;
  }

  void setEffect(VoiceEffect e) {
    _load();
    _effect = e;
    _save();
    notifyListeners();
  }

  /// Everything a call's voice needs to be changed: nothing more for an effect made here; a key and a voice for
  /// ElevenLabs.
  bool get callReady => way == CallVoiceWay.device || ready;

  /// A call's voice is changed live now.
  bool get liveActive => isOn() && callReady && live && !(way == CallVoiceWay.elevenlabs && paused);

  /// Everything it needs is there.
  bool get ready => hasKey && voice != null;

  /// The next voice message is changed.
  bool get active => isOn() && ready && !paused;

  /// The line under a recording while it is being made: null where the message goes as it is.
  String? get note => active ? 'Sent in ${_voice!.name}\'s voice, changed by ElevenLabs.' : null;

  void setClean(bool on) {
    _load();
    _clean = on;
    _save();
    notifyListeners();
  }

  void setPaused(bool on) {
    _load();
    _paused = on;
    _save();
    notifyListeners();
  }

  void choose(ChangerVoice v) {
    _load();
    _voice = v;
    _save();
    notifyListeners();
  }

  /// Takes [key] where ElevenLabs answers it with the account's voices. Why not, where it did not; null once it is kept.
  Future<String?> setKey(String key) async {
    final k = key.trim();
    if (k.isEmpty) return 'Paste your ElevenLabs API key.';
    if (k.length > 200 || k.contains(RegExp(r'\s'))) return 'That doesn\'t look like an API key.';
    _load();
    try {
      final list = await _list(k);
      _key = k;
      _voices = list;
      if (_voice == null || !list.any((v) => v.id == _voice!.id)) _voice = null;
      _save();
      notifyListeners();
      return null;
    } on VoiceChangerProblem catch (e) {
      return e.words;
    }
  }

  /// Reads the account's voices again. Why not, where it could not.
  Future<String?> refresh() async {
    if (!hasKey) return 'Add your ElevenLabs key first.';
    try {
      _voices = await _list(_key);
      _save();
      notifyListeners();
      return null;
    } on VoiceChangerProblem catch (e) {
      return e.words;
    }
  }

  /// Forgets the key, the voice and the list.
  void forget() {
    _load();
    _key = '';
    _voice = null;
    _voices = const [];
    _paused = false;
    try {
      if (_file.existsSync()) _file.deleteSync();
    } catch (_) {}
    notifyListeners();
  }

  // --- ElevenLabs ----------------------------------------------------------------------------------------------------

  HttpClient _client() => HttpClient()..connectionTimeout = const Duration(seconds: 15);

  /// The voices of the account [key] opens, as ElevenLabs lists them. Throws a [VoiceChangerProblem] where it could
  /// not be read, or the account has none.
  Future<List<ChangerVoice>> _list(String key) async {
    _busy(true);
    final client = _client();
    try {
      final out = <ChangerVoice>[];
      String? next;
      // A few pages at most: an account with hundreds of voices shows its first three hundred.
      for (var page = 0; page < 3; page++) {
        final req = await client.getUrl(base.replace(path: '/v2/voices', queryParameters: {'page_size': '100', 'next_page_token': ?next}));
        req.headers.set('xi-api-key', key);
        final res = await req.close().timeout(const Duration(seconds: 30));
        final body = await utf8.decodeStream(res).timeout(const Duration(seconds: 30));
        if (res.statusCode != 200) throw VoiceChangerProblem(_why(res.statusCode, body));
        final j = jsonDecode(body);
        if (j is! Map || j['voices'] is! List) throw const VoiceChangerProblem('ElevenLabs answered with something that isn\'t a list of voices.');
        out.addAll([for (final v in j['voices'] as List) ?ChangerVoice.fromApi(v)]);
        next = j['has_more'] == true && j['next_page_token'] is String ? j['next_page_token'] as String : null;
        if (next == null) break;
      }
      if (out.isEmpty) throw const VoiceChangerProblem('That account has no voices to choose from.');
      return out;
    } on VoiceChangerProblem {
      rethrow;
    } on TimeoutException {
      throw const VoiceChangerProblem('ElevenLabs didn\'t answer in time.');
    } catch (_) {
      throw const VoiceChangerProblem('Couldn\'t reach ElevenLabs. Check the connection and try again.');
    } finally {
      client.close(force: true);
      _busy(false);
    }
  }

  /// The recording at [path] in the voice chosen: a new file beside it. Throws a [VoiceChangerProblem] where it could
  /// not be done; nothing is written then.
  Future<String> convert(String path) async {
    _load();
    final v = _voice;
    if (_key.isEmpty || v == null) throw const VoiceChangerProblem('Choose a voice first, in Settings › Voice changer.');
    final file = File(path);
    if (!file.existsSync()) throw const VoiceChangerProblem('The recording isn\'t there any more.');
    final bytes = await file.readAsBytes();
    if (bytes.isEmpty) throw const VoiceChangerProblem('The recording is empty.');
    if (bytes.length > most) throw const VoiceChangerProblem('That recording is too long to change.');
    _busy(true);
    final client = _client();
    try {
      // A multipart form written by hand: the model, the noise choice, then the recording as the `audio` file.
      final boundary = 'ghost-${DateTime.now().microsecondsSinceEpoch.toRadixString(16)}';
      final name = path.split(PlatformInfo.pathSeparator).last.split('/').last.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
      List<int> field(String n, String value) => utf8.encode('--$boundary\r\nContent-Disposition: form-data; name="$n"\r\n\r\n$value\r\n');
      final body = BytesBuilder(copy: false)
        ..add(field('model_id', model))
        ..add(field('remove_background_noise', _clean ? 'true' : 'false'))
        ..add(utf8.encode('--$boundary\r\nContent-Disposition: form-data; name="audio"; filename="$name"\r\nContent-Type: application/octet-stream\r\n\r\n'))
        ..add(bytes)
        ..add(utf8.encode('\r\n--$boundary--\r\n'));
      final req = await client.postUrl(base.replace(path: '/v1/voice-changer/${v.id}', queryParameters: {'output_format': format}));
      req.headers
        ..set('xi-api-key', _key)
        ..set(HttpHeaders.contentTypeHeader, 'multipart/form-data; boundary=$boundary');
      final sent = body.takeBytes();
      req.contentLength = sent.length;
      req.add(sent);
      final res = await req.close().timeout(patience);
      final got = BytesBuilder(copy: false);
      await for (final chunk in res.timeout(patience)) {
        got.add(chunk);
        if (got.length > most) throw const VoiceChangerProblem('ElevenLabs sent back more than a voice message.');
      }
      final back = got.takeBytes();
      if (res.statusCode != 200) throw VoiceChangerProblem(_why(res.statusCode, utf8.decode(back, allowMalformed: true)));
      if (back.length < 200) throw const VoiceChangerProblem('ElevenLabs sent back nothing to play.');
      final dot = path.lastIndexOf('.');
      final out = File('${dot > path.lastIndexOf(PlatformInfo.pathSeparator) ? path.substring(0, dot) : path}-changed.mp3');
      await out.writeAsBytes(back, flush: true);
      return out.path;
    } on VoiceChangerProblem {
      rethrow;
    } on TimeoutException {
      throw const VoiceChangerProblem('ElevenLabs didn\'t answer in time.');
    } catch (_) {
      throw const VoiceChangerProblem('Couldn\'t reach ElevenLabs. Check the connection and try again.');
    } finally {
      client.close(force: true);
      _busy(false);
    }
  }

  /// The rate the changed voice of a live phrase comes back at ([convertPhrase]).
  static const liveRate = 24000;

  /// One phrase said in a call ([wav]: what the microphone heard, as a WAV file's bytes) in the voice chosen: raw
  /// 16-bit mono at [liveRate] to play into the call. Throws a [VoiceChangerProblem] where it could not be done.
  Future<Uint8List> convertPhrase(Uint8List wav) async {
    _load();
    final v = _voice;
    if (_key.isEmpty || v == null) throw const VoiceChangerProblem('Choose a voice first, in Settings › Voice changer.');
    final client = _client();
    try {
      final boundary = 'ghost-${DateTime.now().microsecondsSinceEpoch.toRadixString(16)}';
      List<int> field(String n, String value) => utf8.encode('--$boundary\r\nContent-Disposition: form-data; name="$n"\r\n\r\n$value\r\n');
      final body = BytesBuilder(copy: false)
        ..add(field('model_id', model))
        ..add(field('remove_background_noise', 'false'))
        ..add(utf8.encode('--$boundary\r\nContent-Disposition: form-data; name="audio"; filename="phrase.wav"\r\nContent-Type: audio/wav\r\n\r\n'))
        ..add(wav)
        ..add(utf8.encode('\r\n--$boundary--\r\n'));
      final req = await client.postUrl(base.replace(path: '/v1/voice-changer/${v.id}', queryParameters: {'output_format': 'pcm_$liveRate'}));
      req.headers
        ..set('xi-api-key', _key)
        ..set(HttpHeaders.contentTypeHeader, 'multipart/form-data; boundary=$boundary');
      final sent = body.takeBytes();
      req.contentLength = sent.length;
      req.add(sent);
      final res = await req.close().timeout(const Duration(seconds: 20));
      final got = BytesBuilder(copy: false);
      await for (final chunk in res.timeout(const Duration(seconds: 20))) {
        got.add(chunk);
        if (got.length > most) throw const VoiceChangerProblem('ElevenLabs sent back more than a phrase.');
      }
      final back = got.takeBytes();
      if (res.statusCode != 200) throw VoiceChangerProblem(_why(res.statusCode, utf8.decode(back, allowMalformed: true)));
      return back;
    } on VoiceChangerProblem {
      rethrow;
    } on TimeoutException {
      throw const VoiceChangerProblem('ElevenLabs didn\'t answer in time.');
    } catch (_) {
      throw const VoiceChangerProblem('Couldn\'t reach ElevenLabs. Check the connection and try again.');
    } finally {
      client.close(force: true);
    }
  }

  /// What a voice message's recording is sent as: itself where this is not [active]; else the changed one, with the
  /// recording let go. Where it could not be changed the recording is let go too and the problem thrown: it is never
  /// sent as it was.
  Future<String> forSending(String path) async {
    if (!active) return path;
    try {
      return await convert(path);
    } finally {
      try {
        File(path).deleteSync();
      } catch (_) {}
    }
  }

  /// Sets [busy] and tells the pages, which show it.
  void _busy(bool on) {
    busy = on;
    notifyListeners();
  }

  /// ElevenLabs' refusal in words: its own where it gave some that are short and plain.
  static String _why(int status, String body) {
    String? said, kind;
    try {
      final j = jsonDecode(body);
      final d = j is Map ? j['detail'] : null;
      if (d is Map) {
        said = d['message'] is String ? d['message'] as String : null;
        kind = d['status'] is String ? d['status'] as String : null;
      } else if (d is String) {
        said = d;
      }
    } catch (_) {}
    // By what it says first: ElevenLabs answers 401 for a plan that has run out as it does for a bad key.
    if (kind == 'quota_exceeded') return 'Your ElevenLabs plan has nothing left this month for a recording this long.';
    if (kind == 'voice_not_found') return 'That voice isn\'t in your ElevenLabs account any more. Choose another.';
    if (status == 401 || kind == 'invalid_api_key') return 'ElevenLabs didn\'t accept that key. Check it, and that it may use Voice Changer and read voices.';
    if (status == 404) return 'That voice isn\'t in your ElevenLabs account any more. Choose another.';
    if (status == 429) return 'ElevenLabs is busy or you\'ve asked too often. Try again in a moment.';
    if (said != null && said.length <= 160) return 'ElevenLabs: $said';
    return 'ElevenLabs couldn\'t do it (error $status).';
  }
}
