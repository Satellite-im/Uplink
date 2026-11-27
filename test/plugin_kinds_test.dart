import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/sms.dart';
import 'package:ghost_messaging/plugins/kinds.dart';
import 'package:ghost_messaging/plugins/plugin.dart';
import 'package:ghost_messaging/plugins/registry.dart';

/// Kinds of text (lib/plugins/kinds.dart): what a text from a number that is not a contact is about. Matt,
/// 2026-11-14: "tabs for messages with a intelligent spam filter, debt collectors, political messages, payment
/// reminders, tracking information, etc", and "also add in blocking of door to door sales and other sales messages
/// like tree trimming, gutter cleaning, buying the house, etc".
String? kindOf(String text, {bool contact = false, bool? outgoing}) {
  const plugin = KindsPlugin();
  final tags = plugin.tuned.first(MessageFacts(thread: 1, senders: const ['+15559870001'], text: text, contact: contact, outgoing: outgoing), PluginPrefs.none);
  return tags.isEmpty ? null : tags.single.detail;
}

void main() {
  test('each kind is found by what the text says', () {
    expect(kindOf('This is an attempt to collect a debt. Call 800-555-0100.'), 'debt');
    expect(kindOf('Your account has been placed in collections. Settle your balance today.'), 'debt');
    expect(kindOf('Election day is Tuesday. Find your polling location at vote.example'), 'political');
    expect(kindOf('Chip in \$5 to keep us in this race! Paid for by Friends of Pat Rivera'), 'political');
    expect(kindOf('The GOP wants your input: take our 2-minute survey'), 'political');
    expect(kindOf('Your electric bill of \$84.12 is due on Nov 20.'), 'reminders');
    expect(kindOf('Payment reminder: your rent is due tomorrow.'), 'reminders');
    expect(kindOf('Your package is out for delivery. Tracking number 1Z999AA10123456784'), 'deliveries');
    expect(kindOf('Good news! Your order has shipped and is arriving Thursday.'), 'deliveries');
    expect(kindOf('Appointment reminder: Dr. Lee tomorrow at 9:30. Reply C to confirm.'), 'appointments');
    expect(kindOf('Your reservation is confirmed for 7pm Friday, party of 4.'), 'appointments');
  });

  test('door-to-door and other sales: tree trimming, gutters, buying the house, and the like', () {
    for (final pitch in [
      'Hi neighbor! Our crew is in your neighborhood this week doing tree trimming.',
      'Gutter cleaning special this fall, call for a free estimate!',
      'Hello, I would like to buy your house. Cash offer, close in 7 days.',
      'Have you thought about selling your home? We buy houses in any condition.',
      'We are working in your area tomorrow. Driveway sealing, 20% off.',
      'Free roof inspection after the storm, book now.',
      'Save on your power bill with solar panels: free consultation.',
      'Pressure washing and window cleaning, ask about our discount.',
      'FLASH SALE: 40% off everything, shop now. Reply STOP to opt out',
    ]) {
      expect(kindOf(pitch), 'sales', reason: pitch);
    }
  });

  test('the kinds that are hidden as the app ships, and the ones that are shown', () {
    final hidden = {for (final k in textKinds) if (k.hidden) k.id};
    expect(hidden, {'debt', 'political', 'sales', 'scams'});
    for (final s in const KindsPlugin().sections) {
      expect(s.filter, isTrue, reason: '${s.id} is the filter\'s, not a tab');
    }
    expect(shippedPlugins.whereType<KindsPlugin>(), hasLength(1));
  });

  test('a contact is never sorted, nor your own words, and an everyday text is left alone', () {
    expect(kindOf('Paid for by Friends of Pat Rivera', contact: true), isNull);
    expect(kindOf('Your package is out for delivery', outgoing: true), isNull);
    for (final everyday in [
      'Can you vote on where we eat tonight?',
      'Running late, be there in 10',
      'Did you get the package I sent?',
      'Happy birthday!! 🎉',
      'Can you pay me back for the tickets?',
      'See you at the game on Saturday',
    ]) {
      expect(kindOf(everyday), isNull, reason: everyday);
    }
  });

  test('food delivery texts are their own kind, ahead of parcels', () {
    expect(kindOf('DoorDash: Your Dasher is on the way with your order from Thai Basil.'), 'food');
    expect(kindOf('Uber Eats: your food is arriving in 5 minutes.'), 'food');
    expect(kindOf('Your Instacart shopper has picked up your groceries.'), 'food');
    expect(kindOf('Your driver is outside with your order. Leave a tip in the app.'), 'food');
    expect(kindOf('Grubhub: the restaurant is preparing your order.'), 'food');
    expect(kindOf('Your package is out for delivery. Tracking number 1Z999AA10123456784'), 'deliveries');
    expect(kindOf('Want to grab food later?'), isNull);
  });

  test('a scam dressed as a delivery or a bill is not shown as one: the Spam filter has it', () {
    expect(kindOf('USPS: your package could not be delivered, pay the redelivery fee now at bit.ly/3xYz'), isNull);
    expect(kindOf('URGENT: your bill payment failed, your account is suspended. Verify at http://pay.example'), isNull);
  });

  // What sampling real texts showed (2026-11-14; reworded, nothing of anyone's own).
  test('what a sample of real texts showed: kinds it missed, and things it took for a kind wrongly', () {
    expect(kindOf('Your order was dropped off. See the photo your Dasher took.'), 'food');
    expect(kindOf('Store: items in order W123 were delivered. Enjoy!'), 'deliveries');
    expect(kindOf('Hi, this is Mike with a local arborist. Discounts on tree trimmings & removals nearby. Interested?'), 'sales');
    expect(kindOf('Do you want a health insurance quote? New plans with no deductible.'), 'sales');
    expect(kindOf('Our roofing team is offering no-cost roof inspections this month.'), 'sales');
    expect(kindOf('Can you share your thoughts on a quick local issues survey? Stop=End'), 'political');
    expect(kindOf('We\'re gauging views on the news and think yours would be valuable.'), 'political');
    expect(kindOf('We had issues collecting payment for your internet service.'), 'reminders');
    expect(kindOf('Your service is scheduled for interruption within 3 days. Pay \$84.24 now'), 'reminders');
    expect(kindOf('Your appt with the electrician is scheduled for Friday at 10.'), 'appointments');
    // A carrier's name alone is not a delivery: its sign-in codes and alerts are not. A sign-in alert is a
    // notification.
    expect(kindOf('FedEx: here is your one-time passcode 318874.'), isNull);
    expect(kindOf('Amazon: sign-in from NC. Tap link to respond.'), 'notices');
    // "Reply STOP to opt out" is one sign, not two: an alert that says it is not sales. It is a notification.
    expect(kindOf('Thanks! You will now get patient alerts. Reply STOP to opt out.'), 'notices');
    expect(kindOf('Someone sent you a new photo. Tap to view. Reply STOP to opt-out'), 'notices');
  });

  // The second sample (2026-11-14; reworded): Matt, "there is still a lot of messages that are unsorted that are spam
  // or confirmation based things that land in personal messages".
  test('confirmations, receipts and alerts are notifications; scams and pitches are hidden', () {
    for (final notice in [
      'You have successfully been unsubscribed. Reply START to resubscribe.',
      'Thanks for parking with us. View your receipt here: https://example.com/r',
      'Your two factor authentication settings have changed.',
      'Your feedback is important to us. Please take a survey about your visit.',
      'A deposit of \$120.00 is scheduled to be transferred in 2-3 business days.',
      'Your state return was accepted.',
      'Welcome to Example Club! You will receive up to 4 msg/week. Text STOP to quit.',
      'Sam invited you to a party - can you go? RSVP here: https://example.com/e',
      'Your recycle service at 12 Main St is delayed by six hours.',
    ]) {
      expect(kindOf(notice), 'notices', reason: notice);
    }
    for (final scam in [
      "I'm 36 years old and still single. How about you?",
      'Hey long time no see, how are you doing lately?',
      "Hi, I'm a recruiter at Example Co. We'd love to offer you a part-time role.",
      'Your resume for Benefit Specialist was reviewed. May we schedule an online interview?',
    ]) {
      expect(kindOf(scam), 'scams', reason: scam);
    }
    for (final pitch in [
      'Hi, I have some new health plans with lower deductibles. Can I get you a price estimate?',
      'There is still time to access up to 45k fast at new low rates. Reply STOP to opt out',
      'I tried reaching out about getting you featured in a national paper.',
      'Your shop could use a fresh new website. I can build it live for FREE.',
    ]) {
      expect(kindOf(pitch), 'sales', reason: pitch);
    }
    expect(kindOf("Hi, this is the debt team. Let's talk about debt relief options."), 'debt');
    expect(kindOf("Good afternoon, I'm in route for your mosquito treatment."), 'appointments');
    expect(kindOf('Your table is ready, reply 1 to confirm.'), 'appointments');
    for (final person in ['Hey boss do you have the vin?', 'Be there soon', 'Do you have any of those eye drops left?', 'Book club']) {
      expect(kindOf(person), isNull, reason: person);
    }
  });

  // Matt, 2026-11-14: "Health insurance sales people are not getting caught by the sales filter", with a screenshot
  // of a pitch he had answered: the list sorted the conversation by its newest message, his reply.
  test('a conversation is sorted by what they last sent, not by your reply to it', () {
    final c = Conversation.from({
      'id': 9,
      'date': 0,
      'people': [
        {'address': '+17345550100'},
      ],
      'snippet': 'No thanks, also I live in NC',
      'heard': 'Hi Matthew, want a free attic insulation, window, or gutter service quote before winter while we\'re in your area this week?',
    });
    final facts = MessageFacts.conversation(c);
    expect(facts.text, startsWith('Hi Matthew'));
    final tags = const KindsPlugin().tuned.first(facts, PluginPrefs.none);
    expect(tags.single.detail, 'sales');
    expect(kindOf('Do you want a quick price estimate on new health plans in IL? Reply STOP to opt out'), 'sales');
    expect(kindOf('Want a free gutter service quote?'), 'sales');
  });

  // Matt, 2026-11-17: "This message made it through spam" (an advocacy text from a toll-free number).
  test('a cause asking you to tell Congress is political, and "StopToEnd" is an opt-out', () {
    expect(kindOf("The FDA has made progress, but the work isn't finished. Tell Congress where you stand on smoke-free nicotine options: info26.net/b/juf1P7\n\nStopToEnd"), 'political');
    expect(kindOf('Urge your senators to vote yes on the bill: act.example/x'), 'political');
    expect(kindOf('Where do you stand on pineapple pizza?'), isNull, reason: 'a friend\'s question is not a campaign');
    expect(kindOf('I told my congressman about the pothole lol'), isNull);
    expect(kindOf('Let me know where you stand on dinner'), isNull, reason: 'one lesser sign alone');
  });
}
