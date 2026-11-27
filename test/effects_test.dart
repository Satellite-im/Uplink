import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/effects.dart';
import 'package:ghost_messaging/reactions.dart';
import 'package:ghost_messaging/sms.dart';

Message _m(String body, {bool picture = false}) => Message(
      id: 1,
      kind: picture ? 'mms' : 'sms',
      address: '+15550001111',
      body: body,
      date: DateTime(2026, 11, 13),
      outgoing: false,
      state: 'received',
      attachments: picture ? const [Attachment(id: 1, type: 'image/jpeg')] : const [],
    );

void main() {
  test('a reaction is a screen effect only when its emoji is one of the effects\' own', () {
    // Every effect has one, each its own, and none is a reaction offered on a long press.
    expect(effectReactionEmoji.keys.toSet(), ScreenEffect.values.toSet());
    expect(effectReactionEmoji.values.toSet().length, ScreenEffect.values.length);
    for (final emoji in effectReactionEmoji.values) {
      expect(reactionChoices.contains(emoji), isFalse, reason: '$emoji is a plain reaction too');
    }
    expect(effectForReaction('🎈'), ScreenEffect.balloons);
    expect(effectForReaction('❄️'), ScreenEffect.snow);
    expect(effectForReaction('❄'), ScreenEffect.snow, reason: 'with or without its colour mark');
    for (final plain in reactionChoices) {
      expect(effectForReaction(plain), isNull, reason: '$plain stays a plain reaction');
    }
    // It goes as any reaction does, and is read back as one, on the message it names.
    final text = reactionText('🎈', _m('See you at 7'));
    expect(text, 'Reacted 🎈 to “See you at 7”');
    final read = parseReaction(text)!;
    expect(read.emoji, '🎈');
    expect(effectForReaction(read.emoji), ScreenEffect.balloons);
  });

  test('effectFor: phrases anywhere, key emoji only alone', () {
    expect(effectFor('Happy birthday Maya!!'), ScreenEffect.balloons);
    expect(effectFor('omg CONGRATS'), ScreenEffect.confetti);
    expect(effectFor('Happy New Year 🥂'), ScreenEffect.fireworks);
    expect(effectFor('I love you'), ScreenEffect.hearts);
    expect(effectFor('It’s snowing!'), ScreenEffect.snow);
    expect(effectFor('pew pew'), ScreenEffect.lasers);
    expect(effectFor('BOO!'), ScreenEffect.ghosts);
    expect(effectFor('👻'), ScreenEffect.ghosts);
    expect(effectFor('the book is here'), isNull);
    expect(effectFor('Happy Lunar New Year!'), ScreenEffect.celebration);
    expect(effectFor('wow'), ScreenEffect.wow);
    expect(effectFor('xoxo'), ScreenEffect.kisses);
    expect(effectFor('Thank you so much'), ScreenEffect.thanks);
    expect(effectFor('good night!'), ScreenEffect.goodNight);
    expect(effectFor('Good morning'), ScreenEffect.goodMorning);
    expect(effectFor('get well soon'), ScreenEffect.getWell);
    expect(effectFor('bye bye'), ScreenEffect.bye);
    expect(effectFor('I’m hungry'), ScreenEffect.hungry);
    expect(effectFor('so sorry'), ScreenEffect.sorry);
    expect(effectFor('party time'), ScreenEffect.party);
    expect(effectFor('thanks'), isNull);
    expect(effectFor('🎉'), ScreenEffect.confetti);
    expect(effectFor('❤️❤️'), ScreenEffect.hearts);
    expect(effectFor('🎂 🎈'), ScreenEffect.balloons);
    // Not on their own: nothing.
    expect(effectFor('see you at the party 🎉 tonight'), isNull);
    expect(effectFor('glove you bought'), isNull);
    expect(effectFor('ok'), isNull);
  });

  test('emojiOnly counts emoji when there is nothing else', () {
    expect(emojiOnly('👻'), 1);
    expect(emojiOnly('🎉 🍿'), 2);
    expect(emojiOnly('👍🏽'), 1);
    expect(emojiOnly('👨‍👩‍👧'), 1);
    expect(emojiOnly('ok 👍'), 0);
    expect(emojiOnly('123'), 0);
  });

  test('reactionText is read back as the same reaction on the same message', () {
    for (final emoji in reactionChoices) {
      for (final body in ['See you at 7', 'Two lines\nof text', 'x' * 300]) {
        final target = _m(body);
        for (final removed in [false, true]) {
          final r = parseReaction(reactionText(emoji, target, removed: removed));
          expect(r, isNotNull, reason: '$emoji $removed ${body.length}');
          expect(r!.emoji, emoji);
          expect(r.removed, removed);
          expect(quoteMatches(r.quote!, body), isTrue);
        }
      }
    }
    expect(reactionText('❤️', _m('See you at 7')), 'Loved “See you at 7”');
    expect(reactionText('🔥', _m('See you at 7')), 'Reacted 🔥 to “See you at 7”');
    expect(reactionText('❤️', _m('See you at 7'), removed: true), 'Removed a heart from “See you at 7”');
    expect(parseReaction(reactionText('👍', _m('', picture: true)))!.media, isTrue);
  });

  test('an iPhone\'s "(sent with …)" names the effect and is taken off the words', () {
    final lasers = sentWith('Take that (sent with Lasers)');
    expect(lasers.text, 'Take that');
    expect(lasers.screen, ScreenEffect.lasers);
    expect(effectFor('Take that (sent with Lasers)'), ScreenEffect.lasers);
    expect(sentWith('hi (Sent with Echo)').screen, ScreenEffect.echo);
    expect(sentWith('look (sent with Spotlight)').screen, ScreenEffect.spotlight);
    expect(sentWith('❤️ (sent with Love)').screen, ScreenEffect.hearts);
    final slam = sentWith('NO (sent with Slam effect)');
    expect(slam.text, 'NO');
    expect(slam.bubble, BubbleEffect.slam);
    expect(sentWith('psst (sent with Invisible Ink)').bubble, BubbleEffect.invisibleInk);
    expect(sentWith('quiet (sent with Gentle Effect)').bubble, BubbleEffect.gentle);
    // Not an effect: left alone.
    expect(sentWith('lunch (sent with love from mom)').text, 'lunch (sent with love from mom)');
    expect(sentWith('plain').screen, isNull);
  });

  test('every effect has a length, and something to draw', () {
    for (final e in ScreenEffect.values) {
      expect(effectDuration(e).inMilliseconds, greaterThan(1000), reason: e.name);
    }
  });
}
