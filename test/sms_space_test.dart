import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/circles/circle.dart';
import 'package:ghost_messaging/circles/sms_space.dart';
import 'package:ghost_messaging/net/crypto.dart';
import 'package:ghost_messaging/voice/hangout.dart';
import 'package:ghost_messaging/voice/voice.dart';

/// SMS spaces (lib/circles/sms_space.dart; Matt, 2026-11-19: "a special space in the circle called a "SMS Space" to
/// text members"): what goes out by text, what comes in, and how a space says it is one.
void main() {
  HangoutMessage m(String text, {String name = 'Maya', String? sticker}) => HangoutMessage(id: 'x', from: 'maya-id', name: name, text: text, at: 0, sticker: sticker);

  test('a space\'s message goes out by text as "Name: words", and a sticker as words', () {
    expect(textFor(m('See you at 7')), 'Maya: See you at 7');
    expect(textFor(m('', sticker: 'ghost/03')), 'Maya: (a sticker)');
    expect(textFor(m('  ', name: '')), 'Someone: ');
  });

  test('what came in by text is never texted back out, nor an empty message', () {
    final inFromText = m(broughtIn('Dad', ' On my way '));
    expect(inFromText.text, '📱 Dad: On my way');
    expect(textsOut(inFromText), isFalse);
    expect(textsOut(m('hello')), isTrue);
    expect(textsOut(m('   ')), isFalse);
  });

  test('STOP and its usual words take someone out; a sentence with "stop" in it does not', () {
    for (final w in ['STOP', 'stop', ' Stop ', 'unsubscribe', 'QUIT']) {
      expect(isStop(w), isTrue, reason: w);
    }
    expect(isStop('stop by the shop'), isFalse);
  });

  test('a space says it is an SMS space, and whose phone texts for it, in its own entry; an older build passes it on', () {
    final s = CircleSpace.make('Texts', kind: SpaceKind.text, extra: {'sms': {'by': 'maya-id'}});
    expect(smsTexterOf(s), 'maya-id');
    final again = CircleSpace.fromJson(s.toJson())!;
    expect(smsTexterOf(again), 'maya-id');
    expect(smsTexterOf(again.copyWith(name: 'Family texts')), 'maya-id', reason: 'renamed by someone, it stays one');
    expect(smsTexterOf(CircleSpace.make('Chat', kind: SpaceKind.text)), isNull);
  });

  test('who is texted is kept with when their newest text came in', () {
    const p = TextedPerson(number: '+15551230001', name: 'Dad', seen: 10);
    final again = TextedPerson.fromJson(p.withSeen(20).toJson())!;
    expect(again.number, '+15551230001');
    expect(again.name, 'Dad');
    expect(again.seen, 20);
    expect(again.member, isNull, reason: 'added by hand');
    const member = TextedPerson(number: '+15551230002', name: 'Jamie', member: 'jamie-id');
    expect(TextedPerson.fromJson(member.withSeen(5).toJson())!.member, 'jamie-id', reason: 'a member come in by their number stays one');
  });

  // Matt, 2026-11-19: "all users invited to a circle with phone numbers linked should get texts via the SMS channel in a
  // circle and they should come back to that chat as well it shouldn't be a manual opt in".
  test('a member\'s number goes to the texting phone sealed to its ask alone: no other key opens it', () {
    final texter = NetKeys.generate();
    final answer = numberAnswer(NetCrypto.hex(texter.public), '+15551230002', 'Jamie')!;
    expect(answer['t'], 'sms#');
    expect('$answer', isNot(contains('5551230002')), reason: 'the number is not in the clear');
    final got = openNumberAnswer(texter, answer.cast<String, dynamic>())!;
    expect(got.number, '+15551230002');
    expect(got.name, 'Jamie');
    // Another member, or the relay, holding a key of its own, reads nothing.
    expect(openNumberAnswer(NetKeys.generate(), answer.cast<String, dynamic>()), isNull);
    // Changed on the way, it is no answer.
    final s = answer['s'] as String;
    expect(openNumberAnswer(texter, {...answer, 's': '${s.substring(0, s.length - 4)}AAAA'}.cast<String, dynamic>()), isNull);
    expect(numberAnswer('not a key', '+15551230002', 'Jamie'), isNull);
  });

  // The review's follow-up (2026-11-23): any member's answer was taken, as many as they sent, each with a number of their
  // choosing, and each number was texted everything written in the space on the texter's plan.
  test('a member\'s number is taken once a run and only where they were asked, in place of any they said before, and only so many by their own word', () {
    final spaces = SmsSpaces.instance..reset();
    addTearDown(spaces.reset);
    const seed = 'space';
    expect(spaces.takesAnswer(seed, 'jamie-id'), isFalse, reason: 'not asked');
    spaces.askedIn(seed).add('jamie-id');
    expect(spaces.takesAnswer(seed, 'jamie-id'), isTrue);
    expect(spaces.takesAnswer(seed, 'jamie-id'), isFalse, reason: 'once a run');
    // In place of the number they said before; a number in already, or one STOP took out, is not taken.
    const dad = TextedPerson(number: '+15551230001', name: 'Dad');
    const jamie = TextedPerson(number: '+15551230002', name: 'Jamie', member: 'jamie-id');
    expect(SmsSpaces.makeRoomFor([dad, jamie], {}, 'jamie-id', '+15551230003')!.map((p) => p.number), ['+15551230001']);
    expect(SmsSpaces.makeRoomFor([dad, jamie], {}, 'sam-id', '+15551230001'), isNull);
    expect(SmsSpaces.makeRoomFor([dad], {'+15551230009'}, 'sam-id', '+15551230009'), isNull);
    // So many by their own word and no more, though one of them may still change theirs; those added by hand don't count.
    final full = [for (var i = 0; i < SmsSpaces.mostByThemselves; i++) TextedPerson(number: '+1555000${1000 + i}', name: 'M$i', member: 'm$i')];
    expect(SmsSpaces.makeRoomFor(full, {}, 'newcomer', '+15559990000'), isNull);
    expect(SmsSpaces.makeRoomFor(full, {}, 'm3', '+15559990000'), hasLength(SmsSpaces.mostByThemselves - 1));
    expect(SmsSpaces.makeRoomFor([...full.take(3), dad], {}, 'newcomer', '+15559990000'), hasLength(4));
  });
}
