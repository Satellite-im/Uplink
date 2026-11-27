/// SMS spaces: a circle's texting space that people without the app are in by text (Matt, 2026-11-19: "a special space
/// in the circle called a "SMS Space" to text members").
///
/// **Whose phone.** One member's Android phone, the phone's texting app being this one, carries the space to the
/// people who are in it by text: its "texter", named in the space's own entry of the circle's manifest
/// (`CircleSpace.extra['sms'] = {'by': <their id>}`), so every member sees that it is an SMS space and whose phone texts
/// for it. An older build keeps the field unread and shows a texting space.
///
/// **Who is texted** is kept on the texter's phone alone (`sms_space_<seed>`: each person's number and name, and the
/// newest of their texts already brought in): their numbers are never put in the manifest or said to the circle.
///
/// **What goes.** Every message written in the space is texted from the texter's phone to each person by text, as
/// "Name: words" (a file or sticker as words saying so); what each of them texts back comes into the space as
/// "📱 Name: words", written by the texter's app. A text of only STOP takes the person out, and they are told so. The
/// texts are on the texter's plan, as any texts they send.
///
/// The texter's app must be running for texts to go and come (it is kept connected to its circles' spaces).
///
/// **Members with a number are in it by themselves** (Matt, 2026-11-19: "all users invited to a circle with phone
/// numbers linked should get texts via the SMS channel in a circle and they should come back to that chat as well it
/// shouldn't be a manual opt in"). The texter's phone asks each member's device that comes into the space (`sms?`,
/// with a key made for this run); a device whose number is linked (Settings › Me › Number) answers with it, sealed to
/// that key alone (`sms#`), so no other member, and not the relay, ever reads it. A device answers only the phone the
/// circle names as the space's texter. Each is then texted as anyone added by hand is, and never their own messages.
/// STOP takes them out and keeps them out; taken out by the texter, they stay out too, until added again by hand.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../app_state.dart';
import '../me/me.dart';
import '../net/crypto.dart';
import '../sms.dart';
import '../voice/channels.dart';
import '../voice/hangout.dart';
import '../voice/voice.dart';
import 'circles.dart';

/// Someone in an SMS space by text.
@immutable
class TextedPerson {
  const TextedPerson({required this.number, required this.name, this.seen = 0, this.member});
  final String number;
  final String name;

  /// The member they are, where their own device said their number: their messages in the space are not texted to them.
  final String? member;

  /// When their newest text already brought into the space was sent (ms since 1970): nothing older comes in twice.
  final int seen;

  /// The same person, with their newest text brought in dated [at].
  TextedPerson withSeen(int at) => TextedPerson(number: number, name: name, seen: at, member: member);

  Map<String, Object> toJson() => {'n': number, 'm': name, 's': seen, 'i': ?member};

  static TextedPerson? fromJson(Object? j) {
    if (j is! Map || j['n'] is! String || j['m'] is! String) return null;
    return TextedPerson(number: j['n'] as String, name: j['m'] as String, seen: (j['s'] as num?)?.toInt() ?? 0, member: j['i'] is String ? j['i'] as String : null);
  }
}

/// The mark a message brought in from a text starts with: never texted back out.
const textedMark = '📱 ';

/// Whether [space] is an SMS space, and whose phone texts for it.
String? smsTexterOf(CircleSpace space) {
  final s = space.extra['sms'];
  return s is Map && s['by'] is String ? s['by'] as String : null;
}

/// What a message in the space is texted as: "Name: words", a file or sticker said in words.
String textFor(HangoutMessage m) {
  final parts = <String>[
    if (m.text.trim().isNotEmpty) m.text.trim(),
    if (m.sticker != null) '(a sticker)',
    if (m.files.isNotEmpty) m.voice ? '(a voice message)' : (m.files.length == 1 ? '(a file: ${m.files.first.name})' : '(${m.files.length} files)'),
  ];
  final who = m.name.trim().isEmpty ? 'Someone' : m.name.trim();
  return '$who: ${parts.join(' ')}';
}

/// Whether [m] is one to text out: words or files from anyone, but not one that came in from a text.
bool textsOut(HangoutMessage m) => !m.text.startsWith(textedMark) && (m.text.trim().isNotEmpty || m.files.isNotEmpty || m.sticker != null);

/// What came in by text, as the space shows it.
String broughtIn(String name, String body) => '$textedMark$name: ${body.trim()}';

/// A member's answer to the texter's ask ([SmsSpaces.signal]): [number] and [name] sealed to the ask's key [theirs]
/// (hex) under a key made for this answer alone; null where [theirs] is no key.
Map<String, Object>? numberAnswer(String theirs, String number, String name) {
  final mine = NetKeys.generate();
  final key = _numberKey(mine, theirs);
  if (key == null) return null;
  final sealed = NetCrypto.seal(key, utf8.encode(jsonEncode({'n': number, 'm': name})));
  return {'t': 'sms#', 'k': NetCrypto.hex(mine.public), 's': base64.encode(sealed)};
}

/// What a member's answer [said] holds, opened with the ask's own [keys]: their number and name; null for anything
/// else (another key's, changed on the way, not an answer).
({String number, String name})? openNumberAnswer(NetKeys keys, Map<String, dynamic> said) {
  if (said['k'] is! String || said['s'] is! String) return null;
  final key = _numberKey(keys, said['k'] as String);
  if (key == null) return null;
  try {
    final clear = NetCrypto.open(key, base64.decode(said['s'] as String));
    if (clear == null) return null;
    final got = (jsonDecode(utf8.decode(clear)) as Map).cast<String, dynamic>();
    final n = got['n'], m = got['m'];
    return n is String ? (number: n, name: m is String ? m : '') : null;
  } catch (_) {
    return null;
  }
}

/// The key a number is sealed under between an ask's key and an answer's.
Uint8List? _numberKey(NetKeys mine, String theirs) {
  // Whatever another device sent: a key is 33 bytes in hex, and anything else is none.
  if (!RegExp(r'^[0-9a-f]{66}$').hasMatch(theirs)) return null;
  final pair = NetCrypto.conversationKey(mine, NetCrypto.unhex(theirs));
  return pair == null ? null : NetCrypto.derive(pair, 'sms space number');
}

/// Whether a text says to be taken out.
bool isStop(String body) => const {'stop', 'stop all', 'unsubscribe', 'quit', 'end', 'cancel'}.contains(body.trim().toLowerCase());

class SmsSpaces extends ChangeNotifier {
  SmsSpaces._();
  static final SmsSpaces instance = SmsSpaces._();

  AppState? _app;
  StreamSubscription<int>? _sub;
  final Set<String> _held = {};

  /// The texter's own id: this install's.
  String? get me => Circles.instance.signer?.id;

  /// Starts carrying this phone's SMS spaces: only on a phone that is the texting app.
  void start(AppState app) {
    if (_app != null) return;
    _app = app;
    _sub = Sms.instance.changes.stream.listen((t) => unawaited(_changed(t)));
    Circles.instance.addListener(_hold);
    _hold();
  }

  @visibleForTesting
  void reset() {
    _sub?.cancel();
    Circles.instance.removeListener(_hold);
    _app = null;
    _held.clear();
    _threads.clear();
    _asked.clear();
    _answered.clear();
    _runKeys = null;
  }

  /// Every SMS space this phone texts for, with its circle's channel for it.
  List<VoiceChannel> get mine {
    final id = me;
    if (id == null) return const [];
    return [
      for (final c in Circles.instance.all)
        for (final s in c.spaces)
          if (smsTexterOf(s) == id) c.channelOf(s),
    ];
  }

  /// Keeps this phone in the chat room of each space it texts for, so their messages come here as they are written.
  void _hold() {
    for (final c in mine) {
      if (_held.add(c.seed)) unawaited(Voice.instance.hold(c));
    }
  }

  // --- who is texted ------------------------------------------------------------------------------------------------

  /// The choice the people texted for the space with [seed] are kept under.
  static String _key(String seed) => 'sms_space_$seed';

  /// Who is in the space with [seed] by text, as kept on this phone; none where nothing readable is kept.
  List<TextedPerson> people(String seed) {
    try {
      return [for (final j in jsonDecode(_app?.choice(_key(seed), '[]') ?? '[]') as List) ?TextedPerson.fromJson(j)];
    } catch (_) {
      return const [];
    }
  }

  /// Keeps [list] as the people texted for [seed]'s space, and tells listeners.
  void _keep(String seed, List<TextedPerson> list) {
    _app?.set(_key(seed), jsonEncode([for (final p in list) p.toJson()]));
    notifyListeners();
  }

  /// Adds [name] at [number] to [space] by text, and texts them to say so. [member]: the member whose own device said
  /// the number (they came in by themselves); by hand otherwise, which also undoes an earlier STOP.
  Future<bool> add(VoiceChannel space, String name, String number, {String? member}) async {
    final n = number.trim();
    if (n.isEmpty) return false;
    final list = people(space.seed);
    if (list.any((p) => p.number == n)) return false;
    if (member == null) {
      _setStopped(space.seed, n, false);
    } else if (stopped(space.seed).contains(n)) {
      return false;
    }
    _keep(space.seed, [...list, TextedPerson(number: n, name: name.trim().isEmpty ? n : name.trim(), seen: DateTime.now().millisecondsSinceEpoch, member: member)]);
    final circle = Circles.instance.circleOf(space)?.name;
    await _send([n], member != null
        ? 'You\'re in ${space.name}${circle == null ? '' : ' in $circle'} by text, as a member whose number is on Uplink: what people write there comes to you here, and what you text back goes to all of them. Text STOP to leave.'
        : 'You\'re in ${space.name}${circle == null ? '' : ' in $circle'} by text: what people write there comes to you here, and what you text back goes to all of them. Text STOP to leave.');
    Voice.instance.hangoutFor(space)?.send('$textedMark${name.trim().isEmpty ? n : name.trim()} is in this space by text now.');
    return true;
  }

  /// Takes [number] out of [space]; [tell]: text them that they are out.
  Future<void> remove(VoiceChannel space, String number, {bool tell = true}) async {
    final list = people(space.seed);
    final p = list.where((x) => x.number == number).firstOrNull;
    if (p == null) return;
    _keep(space.seed, [for (final x in list) if (x.number != number) x]);
    // Out is out: a member's device saying their number again does not put them back (by hand does).
    _setStopped(space.seed, number, true);
    if (tell) await _send([number], 'You\'ve left ${space.name}. You won\'t get its messages by text any more.');
    Voice.instance.hangoutFor(space)?.send('$textedMark${p.name} left this space.');
  }

  // --- members with a number, in by themselves ----------------------------------------------------------------------

  static String _stopKey(String seed) => 'sms_space_stopped_$seed';

  /// The numbers taken out of [seed]'s space (STOP, or by the texter): not put back by their own device.
  Set<String> stopped(String seed) {
    try {
      return {for (final n in jsonDecode(_app?.choice(_stopKey(seed), '[]') ?? '[]') as List) '$n'};
    } catch (_) {
      return {};
    }
  }

  /// Notes [number] as taken out of [seed]'s space ([out]), or no longer so.
  void _setStopped(String seed, String number, bool out) {
    final s = stopped(seed);
    if (!(out ? s.add(number) : s.remove(number))) return;
    _app?.set(_stopKey(seed), jsonEncode(s.toList()));
  }

  /// A key made for this run, whose public half goes with each ask: a member's number is sealed to it alone.
  NetKeys? _runKeys;
  NetKeys get _keys => _runKeys ??= NetKeys.generate();

  /// Who has been asked in each space this run: once each, as they come in.
  final Map<String, Set<String>> _asked = {};

  /// Who has answered in each space this run: one answer to the one ask ([takesAnswer]).
  final Map<String, Set<String>> _answered = {};

  /// The most people in one space by their own device's word (members whose number is linked): each of them is texted
  /// everything written there, on this phone's plan.
  static const mostByThemselves = 20;

  /// Who has been asked in [seed]'s space this run ([roomChanged] adds to it as members come in).
  @visibleForTesting
  Set<String> askedIn(String seed) => _asked.putIfAbsent(seed, () => {});

  /// Whether an answer from [member] in [seed]'s space is taken: one from a member this phone asked this run, and only
  /// their first (found in review, 2026-11-23: any member's answer was taken, as many as they sent, each with a number of
  /// their choosing, and each number was texted everything written in the space on this phone's plan). Taking it counts
  /// as their answer; they are asked again the next time the app runs.
  @visibleForTesting
  bool takesAnswer(String seed, String member) {
    if (!(_asked[seed]?.contains(member) ?? false)) return false;
    return _answered.putIfAbsent(seed, () => {}).add(member);
  }

  /// The people of a space once [member]'s own device has said their number is [number]: whatever number they said
  /// before taken out, for this one to be put in its place ([add]). Null where it isn't taken: STOP took that number out
  /// ([stopped]), it is in already, or [mostByThemselves] are in by their own word and [member] is not one of them.
  @visibleForTesting
  static List<TextedPerson>? makeRoomFor(List<TextedPerson> list, Set<String> stopped, String member, String number) {
    if (stopped.contains(number) || list.any((p) => p.number == number)) return null;
    final rest = [for (final p in list) if (p.member != member) p];
    if (rest.length == list.length && list.where((p) => p.member != null).length >= mostByThemselves) return null;
    return rest;
  }

  /// Told when [room] changes: on the texter's phone, each member come in who has not been asked yet is asked.
  void roomChanged(HangoutRoom room) {
    if (_app == null) return;
    final seed = room.channel.seed;
    if (!mine.any((c) => c.seed == seed)) return;
    final asked = _asked.putIfAbsent(seed, () => {});
    for (final id in room.present.keys) {
      if (id == room.me || !asked.add(id)) continue;
      room.signal({'t': 'sms?', 'to': id, 'k': NetCrypto.hex(_keys.public)});
    }
  }

  /// The words between the texter's phone and members' phones ([HangoutRoom.onSignal]).
  void signal(HangoutRoom room, String from, Map<String, dynamic> said) {
    if (_app == null) return;
    final space = room.channel;
    final entry = Circles.instance.circleOf(space)?.space(space.seed);
    final texter = entry == null ? null : smsTexterOf(entry);
    if (texter == null) return;
    switch (said['t']) {
      case 'sms?':
        // Only the phone the circle names as this space's texter is told, and only where the number is linked.
        if (from != texter || from == room.me || said['k'] is! String) return;
        final number = Me.instance.number;
        if (number == null || number.isEmpty) return;
        final name = Me.instance.displayName.trim().isNotEmpty ? Me.instance.displayName.trim() : (Me.instance.username ?? '');
        final answer = numberAnswer(said['k'] as String, number, name);
        if (answer != null) room.signal({...answer, 'to': from});
      case 'sms#':
        if (texter != room.me || _runKeys == null) return;
        // Only from a member asked this run, who hasn't answered yet ([takesAnswer]).
        if (!(_asked[space.seed]?.contains(from) ?? false) || (_answered[space.seed]?.contains(from) ?? false)) return;
        final got = openNumberAnswer(_runKeys!, said);
        if (got == null) return;
        final number = tidyNumber(got.number);
        if (!numberFits(number) || number == Me.instance.number || !takesAnswer(space.seed, from)) return;
        // In place of any number they said before, and not past the most there may be by their own word.
        final rest = makeRoomFor(people(space.seed), stopped(space.seed), from, number);
        if (rest == null) return;
        _keep(space.seed, rest);
        final named = got.name.trim();
        unawaited(add(space, named.isNotEmpty ? named : Voice.instance.nameOf(from), number, member: from));
    }
  }

  // --- out: the space's messages, texted ------------------------------------------------------------------------------

  /// Told of each message [room] takes in (Voice's onFresh): those in a space this phone texts for go out by text.
  void heard(HangoutRoom room, List<HangoutMessage> fresh) {
    if (_app == null) return;
    final seed = room.channel.seed;
    if (!mine.any((c) => c.seed == seed)) return;
    final everyone = people(seed);
    if (everyone.isEmpty) return;
    for (final m in fresh) {
      if (!textsOut(m)) continue;
      // Only what is new: a device coming back into the room is handed history it has seen.
      if (DateTime.now().millisecondsSinceEpoch - m.at > const Duration(minutes: 10).inMilliseconds) continue;
      // A member's own words are not texted back to them.
      final to = [for (final p in everyone) if (p.member == null || p.member != m.from) p.number];
      if (to.isNotEmpty) unawaited(_send(to, textFor(m)));
    }
  }

  /// Each person on their own, so nobody's number goes to the others and a reply comes back to this phone alone.
  Future<void> _send(List<String> numbers, String body) async {
    for (final n in numbers) {
      try {
        await Sms.instance.send([n], body);
      } catch (_) {}
    }
  }

  // --- in: what the texted people send ------------------------------------------------------------------------------

  /// The phone's conversation with each number, once asked for.
  final Map<String, int> _threads = {};

  /// The phone's conversation with [number]; null where the phone can't say.
  Future<int?> _threadOf(String number) async {
    final had = _threads[number];
    if (had != null) return had;
    try {
      return _threads[number] = await Sms.instance.threadFor([number]);
    } catch (_) {
      return null;
    }
  }

  Future<void> _changed(int thread) async {
    for (final c in mine) {
      final list = people(c.seed);
      for (final p in list) {
        final t = await _threadOf(p.number);
        if (t == null || (thread != -1 && t != thread)) continue;
        List<Message> got;
        try {
          got = await Sms.instance.messages(t, limit: 20);
        } catch (_) {
          continue;
        }
        final fresh = [for (final m in got) if (!m.outgoing && m.date.millisecondsSinceEpoch > p.seen && m.body.trim().isNotEmpty) m]..sort((a, b) => a.date.compareTo(b.date));
        if (fresh.isEmpty) continue;
        final now = people(c.seed);
        _keep(c.seed, [for (final x in now) x.number == p.number ? x.withSeen(fresh.last.date.millisecondsSinceEpoch) : x]);
        for (final m in fresh) {
          if (isStop(m.body)) {
            await remove(c, p.number);
            break;
          }
          Voice.instance.hangoutFor(c)?.send(broughtIn(p.name, m.body));
        }
      }
    }
  }
}
