import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/links.dart';

/// What is a link in a message's words, and what it opens (lib/links.dart).
void main() {
  List<String> shown(String text) => [for (final l in MessageLink.find(text)) text.substring(l.start, l.end)];
  List<String> opens(String text) => [for (final l in MessageLink.find(text)) l.address];

  test('a web address is a link, and one written from www opens with https', () {
    expect(shown('Here\'s the link https://example.com/tickets'), ['https://example.com/tickets']);
    expect(opens('see www.example.com/a?b=1 and http://x.org'), ['https://www.example.com/a?b=1', 'http://x.org']);
    expect(shown('HTTPS://Example.com'), ['HTTPS://Example.com']);
  });

  test('what ends the sentence is not part of the link', () {
    expect(shown('Look at https://example.com/a.'), ['https://example.com/a']);
    expect(shown('(https://example.com/a), then'), ['https://example.com/a']);
    expect(shown('Is it https://example.com/a?!'), ['https://example.com/a']);
    expect(shown('"https://example.com/a"'), ['https://example.com/a']);
    // A bracket that the link itself opens stays.
    expect(shown('https://en.wikipedia.org/wiki/Ghost_(disambiguation)'), ['https://en.wikipedia.org/wiki/Ghost_(disambiguation)']);
    expect(shown('https://en.wikipedia.org/wiki/Ghost_(disambiguation).'), ['https://en.wikipedia.org/wiki/Ghost_(disambiguation)']);
  });

  test('only web addresses are opened', () {
    expect(MessageLink.openable('https://example.com'), 'https://example.com');
    expect(MessageLink.openable('www.example.com'), 'https://www.example.com');
    for (final no in ['javascript:alert(1)', 'tel:+15551230001', 'file:///etc/passwd', 'intent://x#Intent;end', 'https://', 'http://localhost', 'www.', 'ghostmsg://pair/abc']) {
      expect(MessageLink.openable(no), isNull, reason: no);
    }
    expect(shown('call tel:5551234 or mail a@b.co'), isEmpty);
    expect(shown('no links here'), isEmpty);
  });
}
