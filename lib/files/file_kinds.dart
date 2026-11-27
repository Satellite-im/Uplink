import '../platform_info.dart';

/// Whether this device's own picture reader opens a HEIC or HEIF (GMFB-60: ".heic files don't render an image
/// preview"). Flutter reads JPEG, PNG, GIF, WebP and BMP itself and hands anything else to the system's reader
/// (dart:ui's note on image formats): Android's ImageDecoder, which reads HEIF on every Android the app runs on (9 and
/// later), and Apple's ImageIO on an iPhone and a Mac. Windows reads one only with an extension from its store, and
/// Linux and most browsers not at all: there it stays a file to open elsewhere. A test puts its own answer here.
bool Function() readsHeic = () => PlatformInfo.isAndroid || PlatformInfo.isIOS || PlatformInfo.isMacOS;

/// What kind of file something is, by its type or its name's ending: what a Files space draws it as (its icon and
/// colour, lib/ui/files_space/file_badge.dart), how it is previewed, and how the list is filtered and sorted by type.
enum FileKind {
  image('Picture', 'Pictures'),
  video('Video', 'Videos'),
  audio('Audio', 'Audio'),
  pdf('PDF', 'PDFs'),
  doc('Document', 'Documents'),
  sheet('Spreadsheet', 'Spreadsheets'),
  slides('Slides', 'Slides'),
  archive('Archive', 'Archives'),
  code('Code', 'Code'),
  text('Text', 'Text'),
  other('File', 'Other files');

  const FileKind(this.label, this.plural);
  /// What one file of the kind is called, and what the filter calls them all.
  final String label;
  final String plural;

  /// Shown in the app itself: a picture zoomed, a video or sound played, words read.
  bool get previews => this == image || this == video || this == audio || this == text || this == code;

  /// The kind by a name's ending ([endingOf]): asked first, since a type is often missing or says only "octet-stream".
  static const _byEnding = <String, FileKind>{
    // Pictures
    'jpg': image, 'jpeg': image, 'png': image, 'gif': image, 'webp': image, 'heic': image, 'heif': image, 'bmp': image, 'svg': image, 'tif': image, 'tiff': image, 'avif': image, 'ico': image,
    // Video
    'mp4': video, 'mov': video, 'm4v': video, 'mkv': video, 'webm': video, 'avi': video, '3gp': video, 'wmv': video,
    // Audio
    'mp3': audio, 'm4a': audio, 'aac': audio, 'wav': audio, 'flac': audio, 'ogg': audio, 'oga': audio, 'opus': audio, 'aiff': audio, 'aif': audio, 'amr': audio, 'mid': audio, 'midi': audio,
    'pdf': pdf,
    // Documents
    'doc': doc, 'docx': doc, 'odt': doc, 'rtf': doc, 'pages': doc, 'epub': doc,
    'xls': sheet, 'xlsx': sheet, 'ods': sheet, 'csv': sheet, 'tsv': sheet, 'numbers': sheet,
    'ppt': slides, 'pptx': slides, 'odp': slides, 'key': slides,
    // Archives
    'zip': archive, 'rar': archive, '7z': archive, 'tar': archive, 'gz': archive, 'tgz': archive, 'bz2': archive, 'xz': archive, 'dmg': archive, 'iso': archive, 'apk': archive, 'pkg': archive,
    // Code
    'dart': code, 'js': code, 'mjs': code, 'ts': code, 'tsx': code, 'jsx': code, 'py': code, 'rb': code, 'go': code, 'rs': code, 'java': code, 'kt': code, 'kts': code, 'swift': code,
    'c': code, 'h': code, 'cc': code, 'cpp': code, 'hpp': code, 'cs': code, 'php': code, 'sh': code, 'zsh': code, 'bash': code, 'ps1': code, 'sql': code, 'html': code, 'htm': code,
    'css': code, 'scss': code, 'json': code, 'yaml': code, 'yml': code, 'toml': code, 'xml': code, 'gradle': code, 'lua': code, 'r': code, 'scala': code, 'vue': code, 'svelte': code,
    // Text
    'txt': text, 'md': text, 'markdown': text, 'log': text, 'ini': text, 'cfg': text, 'conf': text, 'srt': text, 'vtt': text,
  };

  /// The type (MIME) of the common endings, for [mimeOf]; fewer than [_byEnding] knows a kind for.
  static const _types = <String, String>{
    'jpg': 'image/jpeg', 'jpeg': 'image/jpeg', 'png': 'image/png', 'gif': 'image/gif', 'webp': 'image/webp', 'heic': 'image/heic', 'heif': 'image/heif', 'svg': 'image/svg+xml', 'bmp': 'image/bmp',
    'mp4': 'video/mp4', 'mov': 'video/quicktime', 'm4v': 'video/x-m4v', 'webm': 'video/webm', 'mkv': 'video/x-matroska',
    'mp3': 'audio/mpeg', 'm4a': 'audio/mp4', 'aac': 'audio/aac', 'wav': 'audio/wav', 'flac': 'audio/flac', 'ogg': 'audio/ogg', 'oga': 'audio/ogg', 'opus': 'audio/opus',
    'pdf': 'application/pdf', 'zip': 'application/zip', 'json': 'application/json', 'txt': 'text/plain', 'md': 'text/markdown', 'csv': 'text/csv', 'html': 'text/html',
    'doc': 'application/msword', 'docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'xls': 'application/vnd.ms-excel', 'xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    'ppt': 'application/vnd.ms-powerpoint', 'pptx': 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
  };

  /// The ending of [name], lower case, without the dot; empty where there is none.
  static String endingOf(String name) {
    final dot = name.lastIndexOf('.');
    return dot <= 0 || dot == name.length - 1 ? '' : name.substring(dot + 1).toLowerCase();
  }

  /// A file's type from its name, where it is a common one.
  static String mimeOf(String name) => _types[endingOf(name)] ?? 'application/octet-stream';

  /// Whether the app draws a file named [name] with type [mime] as a picture itself, in a chat and in its preview: a
  /// picture that is not an SVG (never drawn here), and a HEIC or HEIF only where this device reads one ([readsHeic]).
  /// Every place that draws one still falls back where the picture turns out not to open. GMFB-60.
  static bool drawsAsPicture(String name, [String mime = '']) {
    if (of(name, mime) != image) return false;
    final ending = endingOf(name), m = mime.toLowerCase();
    if (ending == 'svg' || (ending.isEmpty && m.startsWith('image/svg'))) return false;
    if (ending == 'heic' || ending == 'heif' || (ending.isEmpty && (m.startsWith('image/heic') || m.startsWith('image/heif')))) return readsHeic();
    return true;
  }

  /// The kind of a file named [name] with type [mime]: by the name's ending where it is known, else by the type, else
  /// [other].
  static FileKind of(String name, [String mime = '']) {
    final byName = _byEnding[endingOf(name)];
    if (byName != null) return byName;
    final m = mime.toLowerCase();
    if (m.startsWith('image/')) return image;
    if (m.startsWith('video/')) return video;
    if (m.startsWith('audio/')) return audio;
    if (m == 'application/pdf') return pdf;
    if (m.contains('zip') || m.contains('compressed') || m.contains('tar')) return archive;
    if (m.contains('spreadsheet') || m.contains('excel')) return sheet;
    if (m.contains('presentation') || m.contains('powerpoint')) return slides;
    if (m.contains('word') || m.contains('opendocument.text')) return doc;
    if (m.startsWith('text/')) return text;
    return other;
  }
}

/// A size in words: "820 B", "14 KB", "2.1 MB", "1.4 GB".
String fileSize(int bytes) {
  if (bytes < 1000) return '$bytes B';
  if (bytes < 1000 * 1000) return '${(bytes / 1000).round()} KB';
  if (bytes < 1000 * 1000 * 1000) {
    final mb = bytes / (1000 * 1000);
    return '${mb < 10 ? mb.toStringAsFixed(1) : mb.round()} MB';
  }
  return '${(bytes / (1000 * 1000 * 1000)).toStringAsFixed(1)} GB';
}
