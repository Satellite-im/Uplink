import 'dart:convert';

import 'handles.dart' show Fetch;

/// A service that texts a number a code, and says whether a code is the one it sent: what shows a phone number is
/// someone's (Matt, 2026-11-14: "I'd like to use a third party service that allows us to send the text code to a
/// number to verify so it can't be spoofed"; docs/me.md in the app).
///
/// The code is made, sent and checked by the service. This server passes a number on to be texted and a code on to
/// be checked, and keeps neither: so nothing here can say what a code was, and a number typed into the app is not
/// taken as the app's own until the service says the code that reached that number came back.
abstract class TextCodes {
  /// Texts [number] (E.164: "+", country code, digits) a code.
  Future<Texted> send(String number);

  /// Whether [code] is the one last sent to [number]. Null where the service could not be asked.
  Future<bool?> check(String number, String code);
}

/// How asking for a text went.
enum Texted {
  sent,

  /// The service will not text that number: not a mobile, a country it is not allowed to text, or one it distrusts.
  cannot,

  /// The service has texted that number too often lately.
  tooOften,

  /// The service did not answer, or would not let this server in.
  down,
}

/// Twilio Verify (twilio.com/docs/verify/api). One service there, named for the app: its name is what the text
/// says ("Your Uplink verification code is: 482913").
///
/// [sid] and [token] sign every request: the account's SID and auth token, or better an API key's SID and its
/// secret, which can be taken back alone. [service] is the Verify service's SID ("VA…").
class TwilioVerify implements TextCodes {
  TwilioVerify(this._fetch, {required this.sid, required this.token, required this.service});

  final Fetch _fetch;
  final String sid;
  final String token;
  final String service;

  // Part of an address: nothing but what a SID is made of.
  bool get _sound => RegExp(r'^[A-Za-z0-9]{8,64}$').hasMatch(service);

  // The service's address for Verifications (send a code) or VerificationCheck (check one).
  Uri _at(String what) => Uri.https('verify.twilio.com', '/v2/Services/$service/$what');

  Map<String, String> get _headers => {
        'Content-Type': 'application/x-www-form-urlencoded',
        'Authorization': 'Basic ${base64Encode(utf8.encode('$sid:$token'))}',
      };

  static String _form(Map<String, String> fields) => fields.entries.map((e) => '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}').join('&');

  // The `status` Twilio's answer carries ("pending" once a code is sent, "approved" once one checks out), or null.
  static Object? _status(String body) {
    try {
      return (jsonDecode(body) as Map)['status'];
    } catch (_) {
      return null;
    }
  }

  @override
  Future<Texted> send(String number) async {
    if (!_sound) return Texted.down;
    final r = await _fetch('POST', _at('Verifications'), headers: _headers, body: _form({'To': number, 'Channel': 'sms'}));
    if (r.status == 200 || r.status == 201) return _status(r.body) == 'pending' ? Texted.sent : Texted.down;
    if (r.status == 429) return Texted.tooOften;
    // 400: not a number it can read. 403: a landline, a country that is switched off, or a number it blocks.
    if (r.status == 400 || r.status == 403) return Texted.cannot;
    return Texted.down;
  }

  @override
  Future<bool?> check(String number, String code) async {
    if (!_sound) return null;
    final r = await _fetch('POST', _at('VerificationCheck'), headers: _headers, body: _form({'To': number, 'Code': code}));
    // 404: nothing is waiting for that number. The code ran out (ten minutes), or was tried too often there.
    if (r.status == 404) return false;
    if (r.status != 200 && r.status != 201) return null;
    final status = _status(r.body);
    return status == null ? null : status == 'approved';
  }
}
