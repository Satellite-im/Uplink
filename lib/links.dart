/// The links in a message's words: where each is, and the address it opens (Matt, 2026-11-14: "I can't click to open
/// links in the desktop app"). Until then a link was underlined and nothing more, on the phone as on a computer.
///
/// A link is `http://…`, `https://…` or `www.…` up to the next space. What usually follows a link in a sentence and
/// is not part of it is left off its end: a full stop, a comma, a closing bracket with no opening one inside, a
/// formatting marker (GMFB-35). Only web addresses are opened: nothing in a text can start another app or run anything.
class MessageLink {
  const MessageLink(this.start, this.end, this.address);

  /// Where the link's own characters are in the words.
  final int start;
  final int end;

  /// What it opens: the words as written, with `https://` put before one written from `www.`.
  final String address;

  /// What may be a link: a run with no space in it from `http://`, `https://` or `www.`. [_trailing] are the marks
  /// that end a sentence, not an address, where they are its last characters.
  static final _pattern = RegExp(r'(https?://[^\s]+|www\.[^\s]+)', caseSensitive: false);
  // And the formatting markers a link may be written inside (lib/message_format.dart): "**https://x.com**".
  static const _trailing = '.,;:!?\'"*_~|`';

  /// Every link in [text], in order, each without the punctuation that follows it.
  static List<MessageLink> find(String text) {
    final found = <MessageLink>[];
    for (final m in _pattern.allMatches(text)) {
      var end = m.end;
      while (end > m.start) {
        final last = text[end - 1];
        final inside = text.substring(m.start, end - 1);
        // A closing bracket belongs to the link only where its opening one is in it (a Wikipedia address).
        final stray = (last == ')' && !inside.contains('(')) || (last == ']' && !inside.contains('[')) || (last == '}' && !inside.contains('{'));
        if (!_trailing.contains(last) && !stray) break;
        end--;
      }
      final written = text.substring(m.start, end);
      final address = openable(written);
      if (address != null) found.add(MessageLink(m.start, end, address));
    }
    return found;
  }

  /// The web address [written] opens, or null where it is not one: only http and https, with a name after them.
  static String? openable(String written) {
    final whole = written.toLowerCase().startsWith('www.') ? 'https://$written' : written;
    final uri = Uri.tryParse(whole);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) return null;
    // A name of two parts or more, none of them empty: "www." and "localhost" are not addresses to open.
    final parts = uri.host.split('.');
    if (parts.length < 2 || parts.any((p) => p.isEmpty)) return null;
    return whole;
  }
}
