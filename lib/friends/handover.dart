import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../account/account.dart';
import '../desktop/own_calls.dart' show DeskOwnCalls;
import '../me/me.dart';
import '../net/crypto.dart';
import '../net/net.dart';
import '../sms.dart';
import '../standalone/overlay.dart';
import 'buddies.dart';

/// On the phone: what a paired computer is handed to have friends and circles of its own (Matt, 2026-11-18: "I want
/// desktop to be able to run standalone for internal friends and circles please fix that even if the desktop is
/// linked"; lib/desktop/own_calls.dart). Asked across the pairing's own link, which only that computer and this phone
/// can read (it was confirmed by the six digits both showed): the identity's key, the friends by username, the
/// conversations with them, and who this is (username, name, line).
///
/// `{"buddies": "<json>"}` in what is asked is the computer's own list: taken in first, so a friend made there is
/// this phone's too. `{"only": "buddies"}` hands over the list alone (asked each time the two connect).
Future<Object?> answerHandover(Map<String, Object?> what) async {
  final theirs = what['buddies'];
  final b = Buddies.instance;
  if (theirs is String && theirs.isNotEmpty) {
    final merged = DeskOwnCalls.mergeBuddies(jsonEncode([for (final x in b.all) x.toJson()]), theirs);
    await b.takeAll(merged);
  }
  final list = jsonEncode([for (final x in b.all) x.toJson()]);
  // The Uplink account this phone is signed in to, by its address and username only (never its words or password):
  // the computer asks to be signed in to the same one, and warns before another, which would make the two different
  // people (Matt, 2026-11-18: "i would like to be able to link a session to a new account").
  final account = {'a': Account.instance.address ?? '', 'u': Account.instance.address == null ? '' : (Me.instance.username ?? '')};
  final me = Me.instance;
  // Who this is, with each sync too: the computer is the same person, by the same username and name.
  final who = {'u': me.username ?? '', 'n': me.displayName, 'b': me.bio, if (Net.instance.id != null) 'id': Net.instance.id};
  if (what['only'] == 'buddies') return {'buddies': list, 'account': account, 'me': who};
  final scalar = await Sms.instance.identityExport();
  final calls = Sms.calls;
  return {
    'scalar': NetCrypto.hex(scalar),
    'buddies': list,
    if (calls is OverlayCalls) 'chats': calls.chats.toJson(),
    'me': who,
    'account': account,
  };
}

/// On a paired computer: where taking on the phone's identity stands (lib/desktop/main.dart's handover), for Settings
/// › Me to say, with a way to ask again. Until it is done the computer's friends, profile and account are the phone's,
/// asked across the link, and nothing here can be signed in (Matt, 2026-11-18: "it seems i'm not logged in on desktop,
/// there doesn't seem to be a way to login on desktop").
///
/// [phase] is `waiting` (the phone is not connected), `old` (the phone's Uplink is from before handovers),
/// `asking`, `failed` (with the phone's [problem]: most often that the app is not open on it, since the phone answers
/// in its Dart, which runs only while the app does) or `done`.
class DeskHandover {
  DeskHandover._();
  static final state = ValueNotifier<({String phase, String? problem})>((phase: 'waiting', problem: null));

  /// Asks the phone again now; null where there is no link to ask over.
  static VoidCallback? retry;
}
