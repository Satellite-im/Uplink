import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/plugins/codes.dart';
import 'package:ghost_messaging/art/svg_path.dart';
import 'package:ghost_messaging/plugins/companies.dart';
import 'package:ghost_messaging/plugins/company_marks.g.dart';
import 'package:ghost_messaging/plugins/ui.dart' show BrandFace;

// Who a sign-in code is from (lib/plugins/companies.dart; Matt, 2026-11-14: "have the codes section try to parse the
// company that's sending the code and show their company logo as the code profile picture like coinbase discover
// etc"). The texts are written as such texts are; none is a real one.

void main() {
  test('a known company is found by its name, as texts about codes write it', () {
    final texts = {
      'Your Coinbase verification code is: 551204. Don\'t share this code with anyone; our employees will never ask for the code.': 'Coinbase',
      'Discover: 884213 is your one-time passcode. We will never call to ask for it.': 'Discover',
      'Chase: DON\'T share. Use code 30481122. We\'ll NEVER call to ask for this code.': 'Chase',
      'Your Google verification code is 482913.': 'Google',
      'Your Uber code is 4821. Never share this code.': 'Uber',
      '[TikTok] 771204 is your verification code, valid for 5 minutes.': 'TikTok',
      '<#> Your WhatsApp code: 482-913\nDon\'t share this code with others\n4sgLq1p5sV6': 'WhatsApp',
      'Amazon: Your one-time password is 204817. Do not share it with anyone.': 'Amazon',
      'BofA: DO NOT share this Sign In code. We will NEVER call you or text you for it. Code 739114.': 'Bank of America',
      'Use verification code 620443 for Microsoft authentication.': 'Microsoft',
      'Your Apple Account code is: 913377. Don\'t share it with anyone.': 'Apple',
      '204481 is your Facebook confirmation code': 'Facebook',
      'Use 118204 to verify your Instagram account.': 'Instagram',
      'Your X confirmation code is 55120488.': 'X',
      'Amex SafeKey: Your one-time code is 771930.': 'American Express',
      'Cash App: 482-913 is your sign in code. No one representing Cash App will ever ask for this code.': 'Cash App',
      'Your Capital One code is 204481. For your security, don\'t share it.': 'Capital One',
      'Wells Fargo will NEVER call or text you for this code. Don\'t share it. Enter 913377 on the secure website.': 'Wells Fargo',
      'PayPal: Your security code is 620443. Your code expires in 10 minutes. Please don\'t reply.': 'PayPal',
    };
    for (final e in texts.entries) {
      expect(signInCode(e.key), isNotNull, reason: 'a code is in it: ${e.key}');
      expect(companyIn(e.key)?.name, e.value, reason: e.key);
    }
  });

  test('a name the company writes with a small first letter is found as it writes it', () {
    expect(companyIn('Your eBay security code is 482913.')?.name, 'eBay');
    expect(companyIn('Your EBAY security code is 482913.')?.name, 'eBay');
    expect(companyIn('Your iCloud code is 482913.')?.name, 'Apple');
    expect(companyIn('Your code is 482913. Sold on ebay last week.'), isNull);
  });

  test('or by its web address in the text', () {
    expect(companyIn('482913 is your verification code.\n\n@coinbase.com #482913')?.name, 'Coinbase');
    expect(companyIn('Your code is 204481. https://accounts.google.com/signin')?.name, 'Google');
    expect(companyIn('Your code is 204481 @www.paypal.com #204481')?.name, 'PayPal');
    // An address that only ends like a known one is not it.
    expect(companyIn('Your code is 204481. https://notcoinbase.com/login'), isNull);
    expect(companyIn('Your code is 204481. https://coinbase.com.example.net/login'), isNull);
  });

  test('a word that is also a company\'s name is not the company unless it is written as a name', () {
    expect(companyIn('Your code is 482913. Tap to discover more.'), isNull);
    expect(companyIn('Your verification code is 482913. It is on target for delivery.'), isNull);
    expect(companyIn('Your security code is 482913. Do not chase this message.'), isNull);
    // A short name is matched letter for letter, whole: "X" is, a letter in a word or a small x is not.
    expect(companyIn('Your code is 482913. Reply x to stop.'), isNull);
    expect(companyIn('Your Xfinity code is 482913.')?.name, 'Xfinity');
    expect(companyIn('UPS: your delivery code is 4829.')?.name, 'UPS');
    expect(companyIn('Your code is 482913. Thanks for your support. ups and downs happen.'), isNull);
    // Part of a longer name is not the shorter one.
    expect(companyIn('Your Duolingo code is 482913.')?.name, 'Duolingo');
    expect(companyIn('Your Metamask code is 482913.'), isNull);
  });

  test('the one named first is the one it is from', () {
    expect(companyIn('Venmo: your code is 482913. Never share it, even with PayPal.')?.name, 'Venmo');
    expect(companyIn('Your Google Voice verification code is 482913.')?.name, 'Google');
  });

  test('any other company is named as its text names it', () {
    final texts = {
      'Acme Corp: your verification code is 482913.': 'Acme Corp',
      'Your Brightwater verification code is 482913.': 'Brightwater',
      '482913 is your Lumen Credit Union security code.': 'Lumen Credit Union',
      '[Pelican] 482913 is your code.': 'Pelican',
      'Use 482913 as your login code for Harbor & Vine.': 'Harbor & Vine',
      'Your code is 482913. Do not share it. - Northfield Bank': 'Northfield Bank',
      'To sign in to your Tidewater account, enter 482913.': 'Tidewater',
    };
    for (final e in texts.entries) {
      expect(companyIn(e.key), isNull, reason: 'not one the app knows: ${e.key}');
      expect(senderNameIn(e.key), e.value, reason: e.key);
    }
  });

  test('a text that names nobody is left with its number', () {
    for (final text in [
      'Your verification code is 482913. Don\'t share it with anyone.',
      'Your Verification Code is 482913',
      '482913 is your one-time passcode.',
      'Your security code: 482913',
      'Use code 482913 to log in.',
      'Code: 482913. Never share this code.',
      'Your One-Time PIN is 482913',
    ]) {
      expect(companyIn(text), isNull, reason: text);
      expect(senderNameIn(text), isNull, reason: text);
    }
  });

  test('every company has a web address and a colour, and no two share a name', () {
    final names = <String>{};
    for (final c in companies) {
      expect(c.domain, matches(RegExp(r'^[a-z0-9-]+(\.[a-z0-9-]+)+$')), reason: c.name);
      expect(c.color, inInclusiveRange(0, 0xFFFFFF), reason: c.name);
      expect(names.add(c.name.toLowerCase()), isTrue, reason: '${c.name} twice');
      // And each is found by its own name.
      expect(companyIn('Your ${c.name} code is 482913.')?.name, c.name, reason: c.name);
    }
  });

  test('every mark is a known company\'s, and draws inside its square', () {
    // lib/plugins/company_marks.g.dart, made by tool/company_marks.py from an open pack of brand icons.
    final domains = {for (final c in companies) c.domain};
    expect(companyMarks, isNotEmpty);
    for (final e in companyMarks.entries) {
      expect(domains, contains(e.key), reason: 'a mark for nobody: ${e.key}');
      final box = parseSvgPath(e.value).getBounds();
      expect(box.isEmpty, isFalse, reason: e.key);
      // A path's bounds take in the handles of its curves, which stand outside what is drawn (DoorDash's reach
      // 25.8, Signal's -4.5): held to the square with that much room, which still catches a path read wrongly.
      // The picture 12-plugins-company-faces shows each as it is drawn.
      expect(box.left, greaterThanOrEqualTo(-6), reason: e.key);
      expect(box.top, greaterThanOrEqualTo(-6), reason: e.key);
      expect(box.right, lessThanOrEqualTo(30), reason: e.key);
      expect(box.bottom, lessThanOrEqualTo(30), reason: e.key);
      // And it is a mark, not a speck: it reaches across most of the square one way or the other.
      expect(box.longestSide, greaterThan(14), reason: e.key);
    }
    // The two Matt named have one.
    expect(companyMarks['coinbase.com'], isNotNull);
    expect(companyMarks['discover.com'], isNotNull);
    // The ones the pack has since taken out are here as it last had them (Matt, asked whether to keep letters for
    // them: "Use older logos").
    for (final domain in ['microsoft.com', 'amazon.com', 'linkedin.com', 'yahoo.com', 'nintendo.com', 'hulu.com', 'grubhub.com', 'walmart.com', 'slack.com', 'adobe.com', 'salesforce.com', 'openai.com', 'twilio.com', 'docusign.com']) {
      expect(companyMarks[domain], isNotNull, reason: domain);
    }
    // One the pack never had is drawn as a letter.
    expect(companyMarks['capitalone.com'], isNull);
    expect(companyMarks.length, 86);
  });

  test('a company\'s face: its letter, in ink on a light colour and white on a dark one', () {
    expect(BrandFace.letterOf('Coinbase'), 'C');
    expect(BrandFace.letterOf('eBay'), 'E');
    expect(BrandFace.letterOf('7-Eleven'), '7');
    expect(BrandFace.inkOn(0xFFFC00), isTrue, reason: 'Snapchat\'s yellow');
    expect(BrandFace.inkOn(0x9FE870), isTrue, reason: 'Wise\'s green');
    expect(BrandFace.inkOn(0x0052FF), isFalse, reason: 'Coinbase\'s blue');
    expect(BrandFace.inkOn(0x000000), isFalse);
  });
  test('our own verification code is Uplink\'s, with the app\'s ghost for a face', () {
    final c = companyIn('Your Uplink verification code is: 240021')!;
    expect(c.name, 'Uplink');
    expect(c.domain, ghostDomain);
  });
}
