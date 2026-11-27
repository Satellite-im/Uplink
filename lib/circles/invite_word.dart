/// A circle's invite word (Matt, 2026-11-19: "add the custom invite code word as a default feature"): gogho.st/c/bookclub
/// in place of the circle's long link, as a Discord server's vanity invite is, for every circle and for nothing.
///
/// The relay keeps it (relay/lib/invite_words.dart) by [inviteWordHash], never the word, with the circle's link sealed
/// by [inviteWordKey], a key made from the word by PBKDF2. The site's /c/ page (site/c/index.html) does the same in the
/// browser, so the derivation and the sealing here and there must stay the same. A word is meant to be shared: anyone
/// who knows it can join, as anyone with the link can.
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart' show HMac, PBKDF2KeyDerivator, Pbkdf2Parameters, SHA256Digest;

import '../invites/invite_relay.dart';
import '../net/fast_gcm.dart';
import 'circles.dart';

const _label = 'ghost-invite-word/v1';

/// PBKDF2's rounds: the site's page does as many.
const inviteWordRounds = 60000;

/// Words nobody may take: the site's own places, and the app's name.
const reservedInviteWords = {
  'admin', 'alpha', 'api', 'app', 'apps', 'beta', 'c', 'docs', 'download', 'feedback', 'files', 'ghost', 'ghostmessaging', 'gogho',
  'gogh', 'help', 'hub', 'join', 'link', 'mac', 'official', 'pair', 'privacy', 'relay', 'root', 'security', 'staff', 'support',
  'team', 'terms', 'uplink', 'windows', 'word', 'www',
};

/// [raw] as a word ("Book Club!" is "book-club"; "gogho.st/c/bookclub" is "bookclub"), or null where it can't be one:
/// 3 to 32 letters, digits and single hyphens, not at its ends.
String? tidyInviteWord(String raw) {
  var w = raw.trim().toLowerCase();
  w = w.replaceFirst(RegExp(r'^(https?://)?(www\.)?gogho\.st/c/'), '');
  w = w.replaceAll(RegExp(r'[\s_]+'), '-').replaceAll(RegExp(r'[^a-z0-9-]'), '').replaceAll(RegExp(r'-{2,}'), '-');
  w = w.replaceAll(RegExp(r'^-+|-+$'), '');
  if (w.length < 3 || w.length > 32) return null;
  return w;
}

/// Why [word] can't be had, or null where it can be asked for.
String? inviteWordProblem(String raw) {
  final w = tidyInviteWord(raw);
  if (w == null) return 'A word is 3 to 32 letters, numbers or hyphens.';
  if (reservedInviteWords.contains(w)) return '"$w" is kept for Uplink itself. Try another.';
  return null;
}

/// gogho.st/c/[word].
String inviteWordLink(String word) => 'https://gogho.st/c/$word';

/// The word in [text] where it is a word's link (gogho.st/c/…), else null.
String? inviteWordIn(String? text) {
  if (text == null) return null;
  final m = RegExp(r'gogho\.st/c/([A-Za-z0-9-]{3,32})').firstMatch(text);
  return m == null ? null : tidyInviteWord(m.group(1)!);
}

/// Bytes as lower-case hex.
String _hex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

/// What the relay keeps [word] by: a SHA-256 of it, as hex.
String inviteWordHash(String word) {
  final d = SHA256Digest();
  return _hex(d.process(Uint8List.fromList(utf8.encode('$_label:$word'))));
}

/// The key [word]'s link is sealed with.
Uint8List inviteWordKey(String word) {
  final k = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64))..init(Pbkdf2Parameters(Uint8List.fromList(utf8.encode(_label)), inviteWordRounds, 32));
  return k.process(Uint8List.fromList(utf8.encode(word)));
}

final _aad = Uint8List.fromList(utf8.encode(_label));

/// [link] sealed under [word]: the nonce, then AES-GCM's words and tag, as base64.
String sealInviteWord(String word, String link, {Random? random}) {
  final r = random ?? Random.secure();
  final nonce = Uint8List.fromList(List.generate(12, (_) => r.nextInt(256)));
  final sealed = FastGcm(inviteWordKey(word)).seal(nonce, _aad, Uint8List.fromList(utf8.encode(link)));
  return base64Encode([...nonce, ...sealed]);
}

/// The circle's link sealed under [word], where it opens and is a circle's; else null.
String? openInviteWord(String word, String blob) {
  try {
    final bytes = base64Decode(blob);
    if (bytes.length < 12 + 16) return null;
    final clear = FastGcm(inviteWordKey(word)).open(Uint8List.fromList(bytes.sublist(0, 12)), _aad, Uint8List.fromList(bytes.sublist(12)));
    if (clear == null) return null;
    return Circles.linkIn(utf8.decode(clear));
  } catch (_) {
    return null;
  }
}

/// Asking the relay: claiming a word for a circle's link, letting one go, and finding the link a word is.
class InviteWords {
  InviteWords({InviteAsk? ask}) : _ask = ask ?? askAnyHub;
  final InviteAsk _ask;

  /// Holds [word] for [link]. Throws an [InviteRelayError] saying why where it is taken or refused.
  Future<void> claim(String word, String link) async {
    await _ask({'dir': 'word-set', 'h': inviteWordHash(word), 'b': sealInviteWord(word, link)});
  }

  /// Lets [word] go, where this install holds it.
  Future<void> drop(String word) async {
    await _ask({'dir': 'word-drop', 'h': inviteWordHash(word)});
  }

  /// The circle's link [word] is, or null where no circle has it.
  Future<String?> resolve(String word) async {
    final got = await _ask({'dir': 'word', 'h': inviteWordHash(word)});
    final b = got['b'];
    return b is String ? openInviteWord(word, b) : null;
  }
}
