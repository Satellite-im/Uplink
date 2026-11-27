import 'sms.dart';

/// Reactions sent as plain texts, the way phones send them to a phone that can't take them natively:
///
/// - Google Messages: `❤️ to "message text"`, `Reacted 😂 to "…"`, `Removed ❤️ from "…"`
/// - iPhone: `Loved "…"`, `Liked "…"`, `Disliked "…"`, `Laughed at "…"`, `Emphasized "…"`, `Questioned "…"`,
///   `Reacted 🎉 to "…"`, `Removed a heart from "…"`, and `Loved an image` for a picture
///
/// The quote can be curly or straight, and a long one is cut short with "…". A reaction found here, with the
/// message it names, is drawn as a chip on that message and not as a bubble of its own ([foldReactions]).
class ParsedReaction {
  const ParsedReaction({required this.emoji, this.quote, this.media = false, this.removed = false});

  final String emoji;

  /// The text of the message reacted to, as quoted (maybe cut short). Null when it was a picture ([media]).
  final String? quote;
  final bool media;

  /// "Removed ❤️ from …": takes the sender's reaction off.
  final bool removed;
}

/// The iPhone's words for a reaction, in lower case, and the emoji each stands for.
const _verbs = {
  'loved': '❤️',
  'liked': '👍',
  'disliked': '👎',
  'laughed at': '😂',
  'emphasized': '‼️',
  'emphasised': '‼️',
  'questioned': '❓',
};

/// What an iPhone says was taken off in "Removed a heart from …", and the emoji each stands for.
const _removedNouns = {
  'a heart': '❤️',
  'a like': '👍',
  'a dislike': '👎',
  'a laugh': '😂',
  'an exclamation': '‼️',
  'an exclamation mark': '‼️',
  'an emphasis': '‼️',
  'a question mark': '❓',
};

/// The marks a quote may open with, and those it may close with: straight or curly, double or single.
const _open = '"“”„‟\'‘’';
const _close = '"“”‟\'‘’';

/// "an image", "a photo", "a video" and the like: a reaction to a picture or other attachment.
final _mediaNoun = RegExp(r'^(an? )(image|photo|picture|video|gif|attachment|movie|sticker|audio message|voice message)$', caseSensitive: false);

/// A text's quoted part: what is between the first opening quote and the last closing one, if those are its ends.
String? _quoted(String rest) {
  final s = rest.trim();
  if (s.length < 2 || !_open.contains(s[0]) || !_close.contains(s[s.length - 1])) return null;
  return s.substring(1, s.length - 1);
}

/// A run of emoji (with its joiners and variation selectors), and nothing else.
bool isEmojiRun(String s, {int max = 12}) {
  if (s.isEmpty || s.runes.length > max) return false;
  for (final r in s.runes) {
    final emojiLike = r >= 0x1F000 ||
        (r >= 0x2190 && r <= 0x2BFF) ||
        (r >= 0x2300 && r <= 0x23FF) ||
        r == 0x200D ||
        r == 0xFE0F ||
        r == 0x20E3 ||
        (r >= 0x1F1E6 && r <= 0x1F1FF) ||
        (r >= 0xE0020 && r <= 0xE007F) ||
        r == 0x00A9 ||
        r == 0x00AE ||
        r == 0x203C ||
        r == 0x2049;
    if (!emojiLike) return false;
  }
  return true;
}

/// Reads [text] as a reaction, or null when it is an ordinary message.
ParsedReaction? parseReaction(String text) {
  final t = text.trim();
  if (t.isEmpty || t.length > 2000) return null;
  final lower = t.toLowerCase();

  // What a reaction is to: a quoted message, or a picture by its noun. Anything else makes [t] an ordinary message.
  ParsedReaction? target(String emoji, String rest, {bool removed = false}) {
    final q = _quoted(rest);
    if (q != null && q.trim().isNotEmpty) return ParsedReaction(emoji: emoji, quote: q, removed: removed);
    if (_mediaNoun.hasMatch(rest.trim())) return ParsedReaction(emoji: emoji, media: true, removed: removed);
    return null;
  }

  // iPhone's words: Loved "…", Laughed at an image.
  for (final e in _verbs.entries) {
    if (lower.startsWith('${e.key} ')) {
      final r = target(e.value, t.substring(e.key.length + 1));
      if (r != null) return r;
    }
  }

  // Reacted 🎉 to "…" (both phones).
  final reacted = RegExp(r'^Reacted (.+?) to (.+)$', caseSensitive: false, dotAll: true).firstMatch(t);
  if (reacted != null && isEmojiRun(reacted.group(1)!)) {
    final r = target(reacted.group(1)!, reacted.group(2)!);
    if (r != null) return r;
  }

  // Removed a heart from "…" / Removed ❤️ from "…".
  final removed = RegExp(r'^Removed (.+?) from (.+)$', caseSensitive: false, dotAll: true).firstMatch(t);
  if (removed != null) {
    final what = removed.group(1)!;
    final emoji = _removedNouns[what.toLowerCase()] ?? (isEmojiRun(what) ? what : null);
    if (emoji != null) {
      final r = target(emoji, removed.group(2)!, removed: true);
      if (r != null) return r;
    }
  }

  // Google Messages: ❤️ to "…".
  final to = RegExp(r'^(\S+) to (.+)$', dotAll: true).firstMatch(t);
  if (to != null && isEmojiRun(to.group(1)!)) {
    final r = target(to.group(1)!, to.group(2)!);
    if (r != null) return r;
  }
  return null;
}

/// [s] as quotes are compared: curly quotes made straight, runs of space made one, trimmed, in lower case.
String _norm(String s) => s
    .replaceAll(RegExp('[“”„‟]'), '"')
    .replaceAll(RegExp('[‘’]'), "'")
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim()
    .toLowerCase();

/// [s] without its emoji: Google Messages quotes a message without them (Matt, 2026-11-15, of `😂 to "Lmao i knew we
/// had two!"` left as a bubble under "Lmao i knew we had two! 😂": "Reactions are not being properly parsed on the RCS
/// version").
String _bare(String s) => String.fromCharCodes(s.runes.where((r) => !isEmojiRun(String.fromCharCode(r))));

/// Whether [body] is the message [quote] names: the same text, or its start when the quote was cut short; and the
/// same again with the emoji left out of both, where any words are left.
bool quoteMatches(String quote, String body) {
  bool same(String q, String b) {
    if (q.isEmpty || b.isEmpty) return false;
    if (q == b) return true;
    for (final cut in const ['…', '...']) {
      if (q.endsWith(cut)) {
        final head = q.substring(0, q.length - cut.length).trim();
        if (head.length >= 3 && b.startsWith(head)) return true;
      }
    }
    return false;
  }

  if (same(_norm(quote), _norm(body))) return true;
  final q = _norm(_bare(quote)), b = _norm(_bare(body));
  return q.length >= 2 && same(q, b);
}

/// One person's reaction on a message. [by] is their number, or '' for you.
class Reaction {
  const Reaction({required this.emoji, required this.by, required this.date});
  final String emoji;
  final String by;
  final DateTime date;
}

/// What [foldReactions] makes of a conversation.
class Folded {
  const Folded({required this.messages, required this.reactions});

  /// The messages to draw, newest first, without the reaction texts that found their message.
  final List<Message> messages;

  /// The reactions on each message, by [Message.key], oldest first.
  final Map<String, List<Reaction>> reactions;
}

/// Takes the reaction texts out of [newestFirst] and hangs each on the message it names: the newest message before
/// it whose text matches the quote (or the newest picture, for "an image"). A reaction that names no message here
/// stays an ordinary bubble, so nothing is ever hidden that can't be shown somewhere.
///
/// One person keeps one reaction of each kind on a message; "Removed …" takes theirs off. You can react with several
/// kinds, as both phones allow.
Folded foldReactions(List<Message> newestFirst) {
  final hidden = <String>{};
  final reactions = <String, List<Reaction>>{};
  final oldestFirst = newestFirst.reversed.toList();
  for (var i = 0; i < oldestFirst.length; i++) {
    final m = oldestFirst[i];
    if (m.attachments.isNotEmpty) continue;
    final r = parseReaction(m.body);
    if (r == null) continue;
    Message? found;
    // Looked for among the 400 messages before it, the nearest first; a reaction text is never itself reacted to.
    for (var j = i - 1; j >= 0 && j >= i - 400; j--) {
      final c = oldestFirst[j];
      if (hidden.contains(c.key)) continue;
      if (r.media ? c.attachments.isNotEmpty : quoteMatches(r.quote!, c.body)) {
        found = c;
        break;
      }
    }
    if (found == null) continue;
    hidden.add(m.key);
    final by = m.outgoing ? '' : m.address;
    final list = reactions.putIfAbsent(found.key, () => []);
    list.removeWhere((x) => _samePerson(x.by, by) && x.emoji == r.emoji);
    if (!r.removed) list.add(Reaction(emoji: r.emoji, by: by, date: m.date));
    if (list.isEmpty) reactions.remove(found.key);
  }
  // Reactions the network keeps on a message (Google Messages' connection): each emoji once, beside those its reaction
  // texts gave; who reacted is not said, so it is no one in particular.
  for (final m in newestFirst) {
    if (m.reactions.isEmpty || hidden.contains(m.key)) continue;
    final list = reactions.putIfAbsent(m.key, () => []);
    for (final emoji in m.reactions) {
      if (!list.any((x) => x.emoji == emoji)) list.add(Reaction(emoji: emoji, by: '?', date: m.date));
    }
  }
  return Folded(messages: [for (final m in newestFirst) if (!hidden.contains(m.key)) m], reactions: reactions);
}

/// Whether two addresses are one person's: numbers by their last ten digits, so +1 before one does not part them;
/// anything without digits as written. You ('') are only yourself.
bool _samePerson(String a, String b) {
  String d(String s) {
    final x = s.replaceAll(RegExp(r'[^0-9]'), '');
    return x.length > 10 ? x.substring(x.length - 10) : x;
  }
  if (a.isEmpty || b.isEmpty) return a == b;
  final da = d(a), db = d(b);
  return da.isNotEmpty ? da == db : a == b;
}

/// What a reaction text says in a conversation's one-line preview: "❤️ to “See you at 7”".
String? reactionSnippet(String text) {
  final r = parseReaction(text);
  if (r == null) return null;
  final what = r.media ? 'a picture' : '“${r.quote}”';
  return r.removed ? 'Removed ${r.emoji} from $what' : 'Reacted ${r.emoji} to $what';
}

/// The emoji offered on a long press, the six every phone knows first.
const reactionChoices = ['❤️', '👍', '👎', '😂', '‼️', '❓', '😮', '😢', '🙏', '🎉', '🔥'];

/// The iPhone's wording for the six it has words for: the verb that sends each, and the noun that takes it off.
const _verbFor = {'❤️': 'Loved', '👍': 'Liked', '👎': 'Disliked', '😂': 'Laughed at', '‼️': 'Emphasized', '❓': 'Questioned'};
const _nounFor = {'❤️': 'a heart', '👍': 'a like', '👎': 'a dislike', '😂': 'a laugh', '‼️': 'an exclamation', '❓': 'a question mark'};

/// The text that sends [emoji] as a reaction to [target] (or takes it off, [removed]): the iPhone's wording, which
/// Google Messages and Samsung Messages turn back into a reaction on the other person's phone, and which this app
/// folds too ([parseReaction]). A phone that knows neither shows the sentence, which still reads.
String reactionText(String emoji, Message target, {bool removed = false}) {
  final String what;
  if (target.body.trim().isEmpty) {
    what = target.attachments.any((a) => a.type.startsWith('video/')) ? 'a video' : 'an image';
  } else {
    final body = target.body.trim();
    // Over 120 characters, the first 100 and "…": [quoteMatches] finds the message by that start.
    what = '“${body.length > 120 ? '${body.substring(0, 100).trimRight()}…' : body}”';
  }
  if (removed) return 'Removed ${_nounFor[emoji] ?? emoji} from $what';
  final verb = _verbFor[emoji];
  return verb != null ? '$verb $what' : 'Reacted $emoji to $what';
}
