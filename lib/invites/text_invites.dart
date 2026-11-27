/// Inviting someone not on Uplink by a text from your own phone, and leaving a sealed copy of the invite on
/// the relay for the day they set the app up (Matt, 2026-11-17: "if they're not on ghost yet it should send them a
/// text saying they've been invited to join a space in ghost with a link that eventually follows through after they
/// setup their account").
library;

import 'dart:async';
import 'dart:typed_data';

import '../me/me.dart';
import '../net/hub_carrier.dart' show NetSigner;
import '../net/net.dart';
import '../sms.dart';
import 'invite_relay.dart';
import 'invite_seal.dart';

/// Someone to text: a name to say who, and the number the text goes to.
class TextInvitee {
  const TextInvitee(this.name, this.number, {this.onGhost = false});
  final String name;
  final String number;

  /// A friend by number, on the app already: texted, but no copy is left for them to find on setting up.
  final bool onGhost;
}

/// Sends the texts and leaves the copies. The arguments are for a test; the app's own otherwise: [sendText] texts from
/// the phone, or through it on a paired computer; [ask] leaves the copies over the app's connection to the relay;
/// [signer] signs each copy with this install's key; [ownNumber] is the inviter's own number, which says what country
/// a contact saved without one is in; [viaPhone] has the phone leave the copies, on a paired computer.
class TextInvites {
  TextInvites({
    Future<int> Function(List<String> to, String words)? sendText,
    InviteAsk? ask,
    NetSigner? Function()? signer,
    Future<String?> Function()? ownNumber,
    Future<int> Function(List<String> numbers, WaitingInvite invite)? viaPhone,
  })  : _sendText = sendText ?? ((to, words) => Sms.instance.send(to, words)),
        _ask = ask ?? askAnyHub,
        _signer = signer ?? (() => Net.instance.hub?.signer),
        _ownNumber = ownNumber ?? _appOwnNumber,
        _viaPhone = viaPhone ?? (ask == null ? _phoneLeaves : null);

  final Future<int> Function(List<String> to, String words) _sendText;
  final InviteAsk _ask;
  final NetSigner? Function() _signer;
  final Future<String?> Function() _ownNumber;
  final Future<int> Function(List<String> numbers, WaitingInvite invite)? _viaPhone;

  /// The number this phone verified in Settings › Me, else the one its SIM says.
  static Future<String?> _appOwnNumber() async {
    final verified = Me.instance.links['phone'];
    if (verified != null) return verified;
    try {
      return await Sms.instance.ownNumber();
    } catch (_) {
      return null;
    }
  }

  /// On a paired computer the phone leaves them, signed with its key and over its connection (Me.forComputer's
  /// `invite-leave`): the computer has no connection of its own the relay would take them from.
  static Future<int> _phoneLeaves(List<String> numbers, WaitingInvite invite) async {
    final got = await Sms.instance.me({'dir': 'invite-leave', 'who': numbers, 'invite': invite.toJson()});
    return (got['left'] as num?)?.toInt() ?? 0;
  }

  /// How many go to the relay in one message (its `Invites.maxAtOnce`).
  static const _atOnce = 25;

  /// Texts [invite]'s words to each of [who], one text each (never a group text: they don't know each other), and
  /// gives back those it could not text. The copies for the relay are left after, for those reached, without
  /// waiting: the text has the link whether or not they are kept ([left] says how that went, for a test).
  Future<List<TextInvitee>> send(List<TextInvitee> who, WaitingInvite invite, String words) async {
    final failed = <TextInvitee>[];
    final reached = <TextInvitee>[];
    for (final w in who) {
      try {
        await _sendText([w.number], words);
        reached.add(w);
      } catch (_) {
        failed.add(w);
      }
    }
    left = leave(reached, invite);
    unawaited(left!.catchError((Object e) {
      // Nothing to tell the person: their text went, with the link in it.
      Sms.instance.devLog('invites', 'not left on the relay: $e');
      return 0;
    }));
    return failed;
  }

  /// The last copies being left ([send]): how many the relay kept.
  Future<int>? left;

  /// Leaves a sealed copy of [invite] for each of [who] whose number's country is known ([copyNumber]), each signed
  /// by this install; gives back how many the relay kept.
  Future<int> leave(List<TextInvitee> who, WaitingInvite invite) async {
    final wanted = [for (final w in who) if (!w.onGhost) w.number];
    if (wanted.isEmpty) return 0;
    final phone = _viaPhone;
    if (phone != null && Sms.paired) return phone(wanted, invite);
    final own = await _ownNumber();
    final signer = _signer();
    final to = <({String e164, Uint8List? key, Uint8List? sig})>[];
    final seen = <String>{};
    for (final number in wanted) {
      final n = copyNumber(number, own: own);
      if (n == null || !seen.add(n)) continue;
      Uint8List? sig;
      if (signer != null) {
        try {
          sig = await signer.sign(inviteSigned(n, invite));
        } catch (_) {
          // Unsigned, it still opens; it is only never shown as a friend's.
        }
      }
      to.add((e164: n, key: sig == null ? null : signer!.publicKey, sig: sig));
    }
    if (to.isEmpty) return 0;
    final blobs = await sealInvites(to, invite);
    final list = [
      for (var i = 0; i < to.length; i++) {'h': numberHash(to[i].e164), 'b': blobs[i], 't': inviteTag(to[i].e164, invite.link)},
    ];
    var kept = 0;
    for (var i = 0; i < list.length; i += _atOnce) {
      final got = await _ask({'dir': 'invite', 'list': list.sublist(i, i + _atOnce > list.length ? list.length : i + _atOnce)});
      kept += (got['left'] as num?)?.toInt() ?? 0;
    }
    return kept;
  }
}
