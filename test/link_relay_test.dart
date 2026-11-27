import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/circles/circle.dart';
import 'package:ghost_messaging/circles/circles.dart';
import 'package:ghost_messaging/invites/invite_seal.dart';
import 'package:ghost_messaging/invites/link_relay.dart';
import 'package:ghost_messaging/ui/circles/circle_invite_card.dart' show circleLinkElsewhere;
import 'package:ghost_messaging/voice/voice.dart';

/// Which relay an invite link's circle or space is on (lib/invites/link_relay.dart; GMFB-25: "The app works fully
/// against a self-hosted hub"). A circle and a space are rooms on one relay and their links named none, so someone on
/// another relay joined the same rooms there, alone, and was told nothing. A link made on a relay other than Uplink's
/// now ends with its host; one made on ours is as it always was.

void main() {
  final seed = 'ab' * 32, owner = '02${'cd' * 32}';
  final name = base64Url.encode(utf8.encode('Book club')).replaceAll('=', '');
  final circleLink = 'https://gogho.st/join/#c.$seed.$name.$owner';
  final spaceLink = 'https://gogho.st/join/#$seed.$name.$owner.text';

  tearDown(() => LinkRelay.here = null);

  test('a link is split from the relay it names, and only what could be a relay\'s host is taken for one', () {
    expect(LinkRelay.split('$circleLink@relay.example.com'), (link: circleLink, relay: 'relay.example.com'));
    expect(LinkRelay.split('$circleLink@Relay.Example.com:8443'), (link: circleLink, relay: 'relay.example.com:8443'));
    expect(LinkRelay.split(circleLink), (link: circleLink, relay: null));
    for (final junk in ['@localhost', '@', '@relay.example.com/x', '@-bad.example.com', '@a b.example.com']) {
      expect(LinkRelay.split('$circleLink$junk'), (link: '$circleLink$junk', relay: null), reason: junk);
    }
    // An address with a name and a password in it is not a link that names a relay: only what follows the #.
    expect(LinkRelay.split('https://user@gogho.st/join/#c.$seed').relay, isNull);
  });

  test('made on Uplink\'s relay, or with nothing said of the relay, a link is exactly as it always was', () {
    final c = Circle.fromLink(circleLink)!, s = VoiceChannel.fromLink(spaceLink)!;
    expect([c.link, s.link], [circleLink, spaceLink]);
    LinkRelay.here = () => null;
    expect([c.link, s.link], [circleLink, spaceLink]);
  });

  test('made on a relay of one\'s own, a circle\'s link and a space\'s end with its host, and are read back as the same circle and space', () {
    final c = Circle.fromLink(circleLink)!, s = VoiceChannel.fromLink(spaceLink)!;
    LinkRelay.here = () => 'relay.example.com';
    expect(c.link, '$circleLink@relay.example.com');
    expect(s.link, '$spaceLink@relay.example.com');
    final c2 = Circle.fromLink(c.link)!, s2 = VoiceChannel.fromLink(s.link)!;
    expect([c2.seed, c2.name, c2.owner], [seed, 'Book club', owner]);
    expect([s2.seed, s2.name, s2.owner, s2.kind], [s.seed, 'Book club', owner, s.kind]);
    // Something that could not be a host is never written into a link.
    LinkRelay.here = () => 'not a host';
    expect(c.link, circleLink);
  });

  test('a circle\'s link is found among other words with the relay it names, and not with the full stop after it', () {
    expect(Circles.linkIn('Join my circle Book club on Uplink: $circleLink@relay.example.com'), '$circleLink@relay.example.com');
    expect(Circles.linkIn('It is $circleLink@relay.example.com. See you there'), '$circleLink@relay.example.com');
    expect(Circles.linkIn('It is $circleLink@relay.example.com:8443, see you'), '$circleLink@relay.example.com:8443');
    expect(Circles.linkIn('It is $circleLink. See you there'), circleLink);
    expect(Circles.linkIn('mail me at $circleLink@'), circleLink);
  });

  test('an invite kept for someone who is not here yet carries the relay too', () {
    final w = WaitingInvite.fromJson({'v': 1, 'k': 'circle', 'l': '$circleLink@relay.example.com', 'n': 'Book club', 'by': 'Maya'})!;
    expect(Circle.fromLink(w.link)!.seed, seed);
    expect(LinkRelay.split(w.link).relay, 'relay.example.com');
  });

  test('where a link names another relay than this app\'s, that is said in place of joining; one that names none, or this one, is joined as ever', () {
    bool here(String h) => h == 'www.relay.example.com';
    expect(LinkRelay.elsewhere(circleLink, mine: null), isNull);
    expect(LinkRelay.elsewhere(circleLink, mine: 'relay.example.com'), isNull, reason: 'a link from before named none: taken to be here');
    expect(LinkRelay.elsewhere('$circleLink@relay.example.com', mine: null), 'relay.example.com');
    expect(LinkRelay.elsewhere('$circleLink@relay.example.com', mine: 'relay.example.com'), isNull);
    expect(LinkRelay.elsewhere('$circleLink@www.relay.example.com', mine: 'relay.example.com', isHere: here), isNull, reason: 'the same relay under another of its names');
    expect(LinkRelay.elsewhere('$circleLink@other.example.org', mine: 'relay.example.com', isHere: here), 'other.example.org');
    expect(LinkRelay.elsewhereWords('relay.example.com', mine: 'Uplink\'s relay (gogho.st)'),
        'This circle is on the relay relay.example.com, and you use Uplink\'s relay (gogho.st). A circle and its spaces are on the relay they were made on: to join, use that relay first (Settings › Routes › Relay server).');
    expect(LinkRelay.elsewhereWords('relay.example.com', mine: 'x', space: true), startsWith('This space is on the relay relay.example.com'));
    // As the app asks, on Uplink's relay (no routes are set up under this test: the relay is ours).
    expect(circleLinkElsewhere(circleLink), isNull);
    expect(circleLinkElsewhere('$circleLink@relay.example.com'), contains('is on the relay relay.example.com, and you use Uplink\'s relay (gogho.st)'));
  });
}
