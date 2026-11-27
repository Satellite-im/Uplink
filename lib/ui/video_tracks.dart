import 'package:flutter/foundation.dart';

import '../app_state.dart';

/// Choosing a video's sound and its subtitles, where the file carries more than one (Matt, 2026-11-18: "on the video
/// player add support for switching audio and subtitles for files that support dual languages"). What a video offers
/// is said here the same way whichever engine plays it (lib/ui/video_engine.dart); the player's own panel
/// (lib/ui/video_screen.dart) lists it, and [TrackMemory] keeps the languages last chosen for the next file.
enum TrackKind { audio, subtitle }

/// One of a video's sound or subtitle streams, or a subtitle file beside it.
@immutable
class MediaTrack {
  const MediaTrack({required this.id, required this.kind, this.language, this.title, this.external = false});

  /// The engine's own name for it, given back to choose it.
  final String id;
  final TrackKind kind;

  /// As the file says it: 'en', 'eng', 'en-US', 'und', or nothing.
  final String? language;

  /// The file's own name for it ("Commentary", "SDH"), or the subtitle file's name.
  final String? title;

  /// A subtitle file beside the video rather than inside it.
  final bool external;

  @override
  bool operator ==(Object other) => other is MediaTrack && other.id == id && other.kind == kind && other.language == language && other.title == title && other.external == external;

  @override
  int get hashCode => Object.hash(id, kind, language, title, external);

  @override
  String toString() => 'MediaTrack(${kind.name} $id ${language ?? '-'} ${title ?? ''})';
}

/// The sound and subtitles a video offers, and which are on.
@immutable
class VideoTracks {
  const VideoTracks({this.audio = const [], this.subtitles = const [], this.audioOn, this.subtitleOn, this.innerSubtitles = true});

  final List<MediaTrack> audio;
  final List<MediaTrack> subtitles;

  /// The sound playing, by its id; null where the engine hasn't said.
  final String? audioOn;

  /// The subtitles shown, by id; null when they are off.
  final String? subtitleOn;

  /// Whether the engine can show subtitles carried inside the file. The phone's (video_player) can't: it shows only a
  /// subtitle file beside the video, and the panel says so.
  final bool innerSubtitles;

  /// Worth a button: more than one sound to choose from, or any subtitles at all.
  bool get choosable => audio.length > 1 || subtitles.isNotEmpty;

  /// The sound to mark as playing: the one the engine says, or the first while it hasn't said.
  String? get audioShown => audio.any((t) => t.id == audioOn) ? audioOn : (audio.isEmpty ? null : audio.first.id);

  /// The subtitles to mark as shown: null (Off) for one the engine names that isn't in the list ('auto').
  String? get subtitleShown => subtitles.any((t) => t.id == subtitleOn) ? subtitleOn : null;

  VideoTracks copyWith({List<MediaTrack>? audio, List<MediaTrack>? subtitles, String? audioOn, String? Function()? subtitleOn, bool? innerSubtitles}) => VideoTracks(
        audio: audio ?? this.audio,
        subtitles: subtitles ?? this.subtitles,
        audioOn: audioOn ?? this.audioOn,
        subtitleOn: subtitleOn != null ? subtitleOn() : this.subtitleOn,
        innerSubtitles: innerSubtitles ?? this.innerSubtitles,
      );

  @override
  bool operator ==(Object other) =>
      other is VideoTracks && listEquals(other.audio, audio) && listEquals(other.subtitles, subtitles) && other.audioOn == audioOn && other.subtitleOn == subtitleOn && other.innerSubtitles == innerSubtitles;

  @override
  int get hashCode => Object.hash(Object.hashAll(audio), Object.hashAll(subtitles), audioOn, subtitleOn, innerSubtitles);
}

/// ISO 639-2 codes (both the bibliographic and the terminology forms) to the two-letter ones files also use.
const _threeToTwo = {
  'eng': 'en', 'spa': 'es', 'fre': 'fr', 'fra': 'fr', 'ger': 'de', 'deu': 'de', 'ita': 'it', 'por': 'pt', 'jpn': 'ja',
  'kor': 'ko', 'chi': 'zh', 'zho': 'zh', 'rus': 'ru', 'ara': 'ar', 'hin': 'hi', 'dut': 'nl', 'nld': 'nl', 'swe': 'sv',
  'nor': 'no', 'nob': 'no', 'nno': 'no', 'dan': 'da', 'fin': 'fi', 'pol': 'pl', 'tur': 'tr', 'gre': 'el', 'ell': 'el',
  'heb': 'he', 'tha': 'th', 'vie': 'vi', 'ind': 'id', 'ukr': 'uk', 'cze': 'cs', 'ces': 'cs', 'hun': 'hu', 'rum': 'ro',
  'ron': 'ro', 'per': 'fa', 'fas': 'fa', 'may': 'ms', 'msa': 'ms', 'fil': 'tl', 'tgl': 'tl', 'cat': 'ca', 'hrv': 'hr',
  'srp': 'sr', 'bul': 'bg', 'slo': 'sk', 'slk': 'sk', 'slv': 'sl', 'est': 'et', 'lav': 'lv', 'lit': 'lt', 'ice': 'is',
  'isl': 'is', 'ben': 'bn', 'tam': 'ta', 'tel': 'te', 'urd': 'ur', 'baq': 'eu', 'eus': 'eu', 'glg': 'gl', 'wel': 'cy',
  'cym': 'cy', 'gle': 'ga',
};

const _names = {
  'en': 'English', 'es': 'Spanish', 'fr': 'French', 'de': 'German', 'it': 'Italian', 'pt': 'Portuguese', 'ja': 'Japanese',
  'ko': 'Korean', 'zh': 'Chinese', 'ru': 'Russian', 'ar': 'Arabic', 'hi': 'Hindi', 'nl': 'Dutch', 'sv': 'Swedish',
  'no': 'Norwegian', 'da': 'Danish', 'fi': 'Finnish', 'pl': 'Polish', 'tr': 'Turkish', 'el': 'Greek', 'he': 'Hebrew',
  'th': 'Thai', 'vi': 'Vietnamese', 'id': 'Indonesian', 'uk': 'Ukrainian', 'cs': 'Czech', 'hu': 'Hungarian',
  'ro': 'Romanian', 'fa': 'Persian', 'ms': 'Malay', 'tl': 'Filipino', 'ca': 'Catalan', 'hr': 'Croatian', 'sr': 'Serbian',
  'bg': 'Bulgarian', 'sk': 'Slovak', 'sl': 'Slovenian', 'et': 'Estonian', 'lv': 'Latvian', 'lt': 'Lithuanian',
  'is': 'Icelandic', 'bn': 'Bengali', 'ta': 'Tamil', 'te': 'Telugu', 'ur': 'Urdu', 'eu': 'Basque', 'gl': 'Galician',
  'cy': 'Welsh', 'ga': 'Irish',
};

/// A language as one code, so 'eng', 'en' and 'en-US' are the same; null for none, or for "undetermined" ('und').
String? normalLanguage(String? code) {
  if (code == null) return null;
  final c = code.trim().toLowerCase().split(RegExp('[-_]')).first;
  if (c.isEmpty || const {'und', 'unk', 'mis', 'mul', 'zxx', 'qaa', 'auto'}.contains(c)) return null;
  return _threeToTwo[c] ?? c;
}

/// Whether [code] is a language this file names (so "forced" or "sdh" in a file's name is not taken for one).
bool knownLanguage(String? code) => _names.containsKey(normalLanguage(code));

/// A language's name in English ("Japanese"); the code itself, capitalised, for one not known here.
String? languageName(String? code) {
  final c = normalLanguage(code);
  if (c == null) return null;
  return _names[c] ?? c.toUpperCase();
}

/// What the panel calls each track: its language and its own title ("English", "Japanese · Commentary"), "Track 2"
/// where it says neither, and a number after any name two of them share.
List<String> trackLabels(List<MediaTrack> tracks) {
  final names = <String>[];
  for (var i = 0; i < tracks.length; i++) {
    final t = tracks[i];
    final lang = languageName(t.language);
    final title = t.title?.trim();
    final hasTitle = title != null && title.isNotEmpty && title.toLowerCase() != lang?.toLowerCase();
    names.add(lang != null && hasTitle ? '$lang · $title' : (lang ?? (hasTitle ? title : 'Track ${i + 1}')));
  }
  final seen = <String, int>{};
  final counts = <String, int>{};
  for (final n in names) {
    counts[n] = (counts[n] ?? 0) + 1;
  }
  return [
    for (final n in names)
      if (counts[n]! > 1) '$n ${seen[n] = (seen[n] ?? 0) + 1}' else n,
  ];
}

/// The first of [tracks] in [language], or null where none is.
MediaTrack? trackIn(List<MediaTrack> tracks, String? language) {
  final want = normalLanguage(language);
  if (want == null) return null;
  for (final t in tracks) {
    if (normalLanguage(t.language) == want) return t;
  }
  return null;
}

/// What a newly opened video should switch to, to match what was last chosen: a sound by id, subtitles by id, or
/// subtitles off. Nothing where it already matches, or where nothing matches (the file's own choice stays).
@immutable
class TrackPlan {
  const TrackPlan({this.audio, this.subtitle, this.subtitlesOff = false});
  final String? audio;
  final String? subtitle;
  final bool subtitlesOff;
  bool get isEmpty => audio == null && subtitle == null && !subtitlesOff;

  @override
  bool operator ==(Object other) => other is TrackPlan && other.audio == audio && other.subtitle == subtitle && other.subtitlesOff == subtitlesOff;
  @override
  int get hashCode => Object.hash(audio, subtitle, subtitlesOff);
  @override
  String toString() => 'TrackPlan(audio: $audio, subtitle: $subtitle, off: $subtitlesOff)';
}

/// The languages last chosen in the player, kept with the app's other choices (lib/app_state.dart), so the next video
/// picks a matching sound and subtitles by itself.
class TrackMemory {
  TrackMemory({required this.read, required this.write});

  /// The app's own store; a test gives a map.
  factory TrackMemory.of(AppState state) => TrackMemory(read: (k) => state.choice(k, ''), write: state.set);

  static const audioKey = 'video_audio_language';
  static const subtitleKey = 'video_subtitle_language';

  /// Kept for subtitles turned off: the next video starts with them off.
  static const off = 'off';

  final String Function(String key) read;
  final void Function(String key, String value) write;

  /// What to change on a video carrying [tracks] so it plays in the languages kept: only what differs from what is
  /// already on, and a sound only where there is more than one to choose from.
  TrackPlan plan(VideoTracks tracks) {
    String? audio;
    final heard = read(audioKey);
    if (heard.isNotEmpty && tracks.audio.length > 1) {
      final match = trackIn(tracks.audio, heard);
      if (match != null && match.id != tracks.audioShown) audio = match.id;
    }
    String? subtitle;
    var subtitlesOff = false;
    final chosen = read(subtitleKey);
    if (chosen == off) {
      subtitlesOff = tracks.subtitleOn != null;
    } else if (chosen.isNotEmpty) {
      final match = trackIn(tracks.subtitles, chosen);
      if (match != null && match.id != tracks.subtitleOn) subtitle = match.id;
    }
    return TrackPlan(audio: audio, subtitle: subtitle, subtitlesOff: subtitlesOff);
  }

  /// A sound chosen: its language kept (one that says none changes nothing).
  void choseAudio(MediaTrack track) {
    final lang = normalLanguage(track.language);
    if (lang != null) write(audioKey, lang);
  }

  /// Subtitles chosen, or turned off (null).
  void choseSubtitle(MediaTrack? track) {
    if (track == null) {
      write(subtitleKey, off);
      return;
    }
    final lang = normalLanguage(track.language);
    if (lang != null) write(subtitleKey, lang);
  }
}
