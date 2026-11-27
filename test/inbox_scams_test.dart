import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/inbox/inbox.dart';
import 'package:ghost_messaging/inbox/scams.dart';

/// Scams in chats on Telegram and the rest (lib/inbox/scams.dart; Matt, 2026-11-15: "i also want spam filters on them
/// to work and cut out fake romance scams and other telegram scams").
void main() {
  final now = DateTime(2026, 11, 15);
  InboxChat chat(String text, {bool stranger = true, bool cold = true, bool group = false, String? flag, bool mine = false}) =>
      InboxChat(network: 'telegram', id: '1', title: 'Someone', date: now, snippet: text, stranger: stranger, cold: stranger && cold, group: group, flag: flag, lastFromMe: mine);

  test('the scams strangers send are caught', () {
    for (final text in [
      'Hello dear, how are you today?',
      'Sorry, wrong number. But you seem nice, can we be friends?',
      'Hi handsome 😊 my friend gave me your contact',
      'I made 40% daily profit with this USDT trading platform, let me show you',
      'Telegram Support: your account will be banned unless you verify your account',
      'Congratulations, you have won a Premium giveaway! Claim your prize here',
      'Can you buy me a Steam card? I will pay you back',
      'Remote job offer: earn \$300 a day, no experience needed',
    ]) {
      expect(scamOf(chat(text)), isNotNull, reason: text);
    }
    expect(scamOf(chat('Hello dear, I am looking for a serious relationship')), contains('a romance opener'));
  });

  // The three that got past Telegram's own filter (Matt, 2026-11-15: "These are the kind of spam messages that make it
  // through telegram usually chats with only one message romantic or sexual in nature with emojis included").
  test('the come-ons that get past Telegram, and accounts calling themselves Telegram', () {
    expect(scamOf(chat('I want to see your face. Are you free? I have a surprise.')), contains('a come-on from a stranger'));
    expect(scamOf(chat('Hiya! ✨ What a pleasant 😍 surprise!')), allOf(contains('a come-on'), contains('a flirty emoji')));
    expect(scamOf(chat('Want to meet someone close to you?🫕')), isNotNull);
    expect(scamOf(InboxChat(network: 'telegram', id: '2', title: 'Telegram', date: now, snippet: 'hello', stranger: false)), 'Pretends to be Telegram');
    expect(scamOf(InboxChat(network: 'telegram', id: '777000', title: 'Telegram', date: now, snippet: 'Login code: 12345', service: true)), isNull, reason: 'Telegram\'s own account');
    expect(scamOf(chat('see you at 7 😍', stranger: false)), isNull, reason: 'a contact\'s');
    // From anyone not a contact these are scams too, answered or not (Matt, 2026-11-15: "Those two messages you tested
    // against were not friends but instead also scammer").
    expect(scamOf(chat('haha so cute 😍', cold: false)), isNotNull);
    expect(scamOf(chat('Free tonight for the game? 🏀')), isNotNull);
    expect(scamOf(chat('daily profit with USDT', cold: false)), isNotNull, reason: 'an investment pitch counts from any stranger');
  });

  test('ordinary chats are left alone, and so is anything from a contact or a group', () {
    for (final text in ['are you coming tonight?', 'Hi! It\'s Maya from the climbing gym', 'thanks for the invoice, paid', 'the meeting moved to 3', 'is the bike still for sale?']) {
      expect(scamOf(chat(text)), isNull, reason: text);
    }
    expect(scamOf(chat('Hello dear, how are you?', stranger: false)), isNull, reason: 'a contact');
    expect(scamOf(chat('daily profit with USDT', group: true)), isNull, reason: 'a group');
    expect(scamOf(chat('hello dear', mine: true)), isNull, reason: 'your own words');
  });

  test('an account Telegram marks a scam or a fake is caught whatever it says', () {
    expect(scamOf(chat('hi', stranger: false, flag: 'Telegram marks this account as a scam')), 'Telegram marks this account as a scam');
  });

  // Matt, 2026-11-17: "add to the filtering for scammers when the telegram user has excessive emoji's especially hearts
  // and romance based stuff some are still getting through", of "Jeong❤️💋🌹", whose newest message was a photo.
  test('a stranger whose name is dressed in hearts, kisses and roses, or in emoji, whatever they last sent', () {
    InboxChat named(String title, {String snippet = 'Photo', bool stranger = true}) =>
        InboxChat(network: 'telegram', id: '3', title: title, date: now, snippet: snippet, stranger: stranger, cold: stranger);
    expect(scamOf(named('Jeong❤️💋🌹')), contains('hearts and roses in the name'));
    expect(scamOf(named('Anna 💕')), isNotNull);
    expect(scamOf(named('Lily🌸✨🦋', snippet: 'Sticker')), contains('a name full of emoji'));
    expect(scamOf(named('Jeong❤️💋🌹', stranger: false)), isNull, reason: 'a contact may name themselves so');
    expect(scamOf(named('Mike 🏀')), isNull, reason: 'one emoji, no heart');
    expect(scamOf(chat('Your profile looks great and caught my attention. Is that your real photo? Nice to meet you 😊')), contains('a romance opener'));
  });
}
