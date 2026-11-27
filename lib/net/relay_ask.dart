import 'dart:async';
import 'dart:convert';

import 'crypto.dart';
import 'hub_carrier.dart';
import 'hub_link.dart';

/// Why another relay could not be asked ([whoisAt]), in words to show.
class RelayAskError implements Exception {
  RelayAskError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// What another relay said of a username there ([whoisAt]): who holds it, their record where that relay gave it, and
/// whether that relay passes messages to other relays at all (its hub's hello says so).
typedef FoundThere = ({String id, String key, Object? home, bool talks});

/// Asks the relay at [url] itself who has the username [name] there (docs/OPEN_NETWORK.md, section 4: "where its own
/// relay doesn't link, the app asks the other relay itself"). A short hub connection under a key made for this one
/// question and thrown away after it ([stranger], for a test; found in the review of relays that talk, 2026-11-23):
/// signed in with this account's own key, the relay asked could pass the number of this account's own relay along and
/// sign in there as this account with the answer. So nothing of this account goes there: not its key, not its device's
/// name, and nothing that relay hands over is taken. Then `whois`, whose answer carries their home record where that
/// relay keeps one. Null where nobody has the name; a [RelayAskError] where the relay could not be asked.
///
/// Nothing here waits on a clock but [timeout] for the whole of it.
Future<FoundThere?> whoisAt(String url, String name, {HubDial? dial, Duration timeout = const Duration(seconds: 10), NetSigner? stranger}) async {
  final HubLink link;
  try {
    link = await (dial ?? dialHub)(url).timeout(timeout);
  } catch (_) {
    throw RelayAskError('That relay couldn\'t be reached.');
  }
  // A key of no account's: all the relay asked can do with its signature is sign in as nobody.
  final signer = stranger ?? KeysSigner(NetKeys.generate());
  final done = Completer<FoundThere?>();
  void fail(String why) {
    if (!done.isCompleted) done.completeError(RelayAskError(why));
  }

  var signedIn = false;
  var talks = false;
  final sub = link.said.listen(
    (data) async {
      // Whatever that relay hands over is not this account's, and is not taken.
      if (done.isCompleted || data is! String) return;
      final Map m;
      try {
        m = jsonDecode(data) as Map;
      } catch (_) {
        return;
      }
      if (m['hello'] is String && !signedIn) {
        final card = m['relay'];
        talks = card is Map && card['fed'] == true;
        // Signed v1 even where that relay offers v2: a key used once and thrown away has nothing to bind, and a v2
        // sign-in would have the relay keep it among those it holds to for ever (found in the second review,
        // 2026-11-23).
        final List<int> sig;
        try {
          sig = await signer.sign([...utf8.encode(HubCarrier.greeting), ...NetCrypto.unhex(m['hello'] as String)]);
        } catch (_) {
          return fail('This device couldn\'t sign in there.');
        }
        if (done.isCompleted) return;
        link.say(jsonEncode({'id': signer.id, 'key': base64Encode(signer.publicKey), 'sig': base64Encode(sig), 'mode': 'invisible'}));
      } else if (m.containsKey('ok') && !signedIn) {
        if (m['ok'] != true) return fail('That relay refused this app.');
        signedIn = true;
        link.say(jsonEncode({'dir': 'whois', 'name': name}));
      } else if (m['dir'] == 'whois' && m['at'] == null) {
        if (m['none'] == true || m['id'] is! String || m['key'] is! String) return done.complete(null);
        done.complete((id: m['id'] as String, key: m['key'] as String, home: m['home'], talks: talks));
      } else if (m['dir'] == 'err' && m['about'] == 'whois') {
        // A relay with no usernames says so; one that has had too many questions says that.
        fail('${m['err'] ?? 'That relay couldn\'t say.'}');
      }
    },
    onDone: () => fail('That relay closed the connection.'),
    onError: (_) => fail('That relay closed the connection.'),
    cancelOnError: true,
  );
  try {
    return await done.future.timeout(timeout, onTimeout: () => throw RelayAskError('That relay didn\'t answer.'));
  } finally {
    await sub.cancel().catchError((_) {});
    await link.close().timeout(const Duration(seconds: 2)).catchError((_) {});
  }
}
