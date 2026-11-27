/// An invite to a space or circle, kept on the relay for someone not on Uplink yet, sealed so the relay holds
/// what it can't read (Matt, 2026-11-17: "if they're not on ghost yet it should send them a text saying they've been
/// invited to join a space in ghost with a link that eventually follows through after they setup their account").
///
/// The text the inviter's phone sends has the link in it; this is the copy that waits on the relay
/// (relay/lib/invites.dart) for the day the person verifies their number in the app (Settings › Me), so the space or
/// circle is offered to them whether or not the text's link was ever tapped.
///
/// - Kept by [numberHash]: the hash a verified number is linked by on the relay (lib/me/me.dart's handleKey, the relay's
///   `Handles.keyOf`), so the relay can hand it only to the install that proved the number. It has to be that hash,
///   which also means the relay, or anyone with its file, can tell which numbers have invites waiting: there are few
///   enough numbers to hash them all.
/// - Sealed with [sealKey], made from the number by a slow, salted derivation (scrypt), a fresh salt for each invite.
///   A guess at a number is then a fraction of a second's work for each blob, rather than nothing, so reading the
///   whole file would take years, not seconds; the person it is for opens their few at once.
/// - Signed by the inviter's install key and checked as it is opened ([WaitingInvite.signer]): anyone who knows a
///   number can leave an invite for it, so the name written in it is only shown as a friend's where the key that
///   signed it is that friend's (lib/invites/pending_invites.dart).
library;

import 'dart:async';
import 'dart:convert';
import '../aside.dart';
import 'dart:typed_data';

import 'package:pointycastle/export.dart' show Scrypt, ScryptParameters;

import '../me/me.dart' show handleKey, numberFits, tidyNumber;
import '../net/crypto.dart';

/// What is sealed: which kind of place, its link, its name as the inviter saw it, and who invited.
class WaitingInvite {
  const WaitingInvite({required this.kind, required this.link, required this.name, required this.by, this.at, this.signer});

  /// 'space' or 'circle'.
  final String kind;

  /// The gogho.st/join link, as the text had it.
  final String link;
  final String name;

  /// The inviter's name as they wrote it; empty where they have none. Nobody checks it: show it as a friend's only
  /// where [signer] is that friend.
  final String by;

  /// When the relay kept it, as it says; null before.
  final DateTime? at;

  /// The install that signed it (NetCrypto.idOf its key), where the signature checks out for the number it was
  /// opened with; null where it was not signed, or the signature does not fit.
  final String? signer;

  bool get circle => kind == 'circle';

  /// The same, as the relay dated it.
  WaitingInvite keptAt(DateTime? when) => WaitingInvite(kind: kind, link: link, name: name, by: by, at: when, signer: signer);

  /// What is sealed: the kind, the link, the place's name and the inviter's. Its date and its signer are not in it.
  Map<String, Object> toJson() => {'v': 1, 'k': kind, 'l': link, 'n': name, 'by': by};

  static WaitingInvite? fromJson(Object? j, {DateTime? at, String? signer}) {
    if (j is! Map || j['v'] != 1) return null;
    final kind = j['k'], link = j['l'], name = j['n'], by = j['by'];
    if ((kind != 'space' && kind != 'circle') || link is! String || name is! String || by is! String) return null;
    // Only the app's own links: what a sealed invite opens is a place in the app, never somewhere else.
    if (!link.startsWith('https://gogho.st/join/#')) return null;
    return WaitingInvite(kind: kind as String, link: link, name: name, by: by, at: at, signer: signer);
  }
}

/// [number] as the relay keeps numbers (E.164), or null where it is not a whole number with its country's code.
String? inviteNumber(String number) {
  final n = tidyNumber(number);
  return numberFits(n) ? n : null;
}

/// [raw], a number as a contact has it or as it was typed, as the number a copy is left for; null where its country
/// can't be known. A number saved with "+" says its country. One saved without is taken as North American only where
/// the inviter's own number ([own]) is: a ten-digit number saved in India, or an eleven-digit one starting with 1 in
/// China, read as American, would leave the place's join link waiting for a stranger who verifies that number in the
/// United States.
String? copyNumber(String raw, {String? own}) {
  if (raw.trim().startsWith('+')) return inviteNumber(raw);
  final mine = own == null ? null : inviteNumber(own);
  if (mine == null || !mine.startsWith('+1')) return null;
  return inviteNumber(raw);
}

/// The hash a number's invites are kept by: the one its verification is linked by.
String numberHash(String e164) => handleKey('phone', e164);

/// scrypt's cost: about a tenth of a second on a phone for each invite sealed or opened.
const _cost = 1 << 14;
const _saltLength = 16;

/// The key an invite to [e164] is sealed with under [salt]: slow by design, and never [numberHash], so the hash the
/// relay keeps does not open it.
Uint8List sealKey(String e164, List<int> salt) {
  final s = Scrypt()..init(ScryptParameters(_cost, 8, 1, 32, Uint8List.fromList(salt)));
  return NetCrypto.derive(s.process(Uint8List.fromList(utf8.encode('ghost-invite v2|$e164'))), 'invite seal');
}

/// A quick key made from the number alone, for [inviteTag], which must come out the same each time; it seals nothing.
Uint8List _tagKey(String e164) => NetCrypto.derive(NetCrypto.sha256(utf8.encode('ghost-invite v1|$e164')), 'invite seal');

/// What the inviter's install signs for an invite to [e164]: the number and every word of it, so a signature can't be
/// moved to another number or another place.
Uint8List inviteSigned(String e164, WaitingInvite invite) => Uint8List.fromList(utf8.encode('ghost-invite v2|$e164|${invite.kind}|${invite.link}|${invite.name}|${invite.by}'));

/// The blob's first byte: this way of sealing.
const _version = 2;

/// [invite], sealed for [e164], as base64, with the inviter's public key and signature ([inviteSigned]) where given.
String sealInvite(String e164, WaitingInvite invite, {List<int>? publicKey, List<int>? signature}) {
  final salt = NetCrypto.randomBytes(_saltLength);
  final body = {...invite.toJson(), if (publicKey != null && signature != null) 'pk': base64Encode(publicKey), if (publicKey != null && signature != null) 'sig': base64Encode(signature)};
  return base64Encode([_version, ...salt, ...NetCrypto.seal(sealKey(e164, salt), utf8.encode(jsonEncode(body)))]);
}

/// What [blob] holds, where it was sealed for [e164]; null where it was not, or is not an invite.
WaitingInvite? openInvite(String e164, String blob, {DateTime? at}) {
  try {
    final bytes = base64Decode(blob);
    if (bytes.length < 1 + _saltLength || bytes[0] != _version) return null;
    final clear = NetCrypto.open(sealKey(e164, bytes.sublist(1, 1 + _saltLength)), bytes.sublist(1 + _saltLength));
    if (clear == null) return null;
    final j = jsonDecode(utf8.decode(clear));
    final plain = WaitingInvite.fromJson(j, at: at);
    if (plain == null) return null;
    String? signer;
    final pk = (j as Map)['pk'], sig = j['sig'];
    if (pk is String && sig is String) {
      final key = base64Decode(pk);
      if (NetCrypto.verify(key, inviteSigned(e164, plain), base64Decode(sig))) signer = NetCrypto.idOf(key);
    }
    return WaitingInvite.fromJson(j, at: at, signer: signer);
  } catch (_) {
    return null;
  }
}

/// Where the slow sealing and opening are done: another isolate, so the screen keeps moving while a list of invites
/// is sealed. A widget test, whose clock is its own, sets it to do the work in place.
Future<R> Function<R>(FutureOr<R> Function() work) inviteWorker = runAside;

/// Seals [invite] for each of [to] (a number with its public key and signature, where signed), off the screen's
/// isolate.
Future<List<String>> sealInvites(List<({String e164, Uint8List? key, Uint8List? sig})> to, WaitingInvite invite) {
  final kind = invite.kind, link = invite.link, name = invite.name, by = invite.by;
  final each = [for (final t in to) (t.e164, t.key, t.sig)];
  return inviteWorker(() {
    final w = WaitingInvite(kind: kind, link: link, name: name, by: by);
    return [for (final (n, k, s) in each) sealInvite(n, w, publicKey: k, signature: s)];
  });
}

/// Opens each of [blobs] for [e164], off the screen's isolate; null for each that does not open.
Future<List<WaitingInvite?>> openInvites(String e164, List<String> blobs) async {
  final opened = await inviteWorker(() => [
        for (final b in blobs)
          if (openInvite(e164, b) case final i?) {'j': i.toJson(), 's': i.signer} else null,
      ]);
  return [for (final o in opened) o == null ? null : WaitingInvite.fromJson(o['j'], signer: o['s'] as String?)];
}

/// The tag the relay knows the same invite again by, so a second invite to one place for one number replaces the
/// first: made from the number, so to the relay it is noise that says nothing across numbers.
String inviteTag(String e164, String link) => NetCrypto.hex(NetCrypto.derive(_tagKey(e164), 'invite tag $link'));

/// The words of the text an invite goes as (Matt, 2026-11-17: "send them a text saying they've been invited to join a
/// space in ghost with a link"). [me] is the inviter's name; without one the text says nobody's.
String inviteText({required String me, required String name, required String link}) =>
    me.trim().isEmpty ? 'You\'re invited to join $name on Uplink: $link' : '${me.trim()} invited you to join $name on Uplink: $link';
