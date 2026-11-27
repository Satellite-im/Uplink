/// Who a sign-in code is from (Matt, 2026-11-14: "have the codes section try to parse the company that's sending
/// the code and show their company logo as the code profile picture like coinbase discover etc").
///
/// A code comes from a short number that says nothing ("28849"); the company is in its words. Two ways of finding
/// it, both on the phone and both from the text alone:
///
/// - [companyIn]: one of the companies this file knows ([companies]), by its name or another it goes by ("BofA",
///   "Amex"), written as a name is written (with a capital), or by its web address in the text ("@coinbase.com
///   #482913"). A known company has a colour of its own and a web address, which is what a logo is found by.
/// - [senderNameIn]: for any other, the name the text gives itself in the ways such texts are written ("Acme: your
///   code is…", "Your Acme verification code is…", "482913 is your Acme code"). A name only: nothing is known of
///   it, and nothing is ever looked up for a name read out of a text, which anyone can send.
library;

/// The app's own address: the company whose face is the app's ghost (Matt, 2026-11-14: "it's not using the ghost
/// logo for the icon in codes").
const ghostDomain = 'gogho.st';

/// One company that sends sign-in codes: what a code's row is named and drawn by.
class Company {
  const Company(this.name, this.domain, this.color, [this.also = const []]);

  /// What it is called.
  final String name;

  /// Its web address, without "www.": what its logo is found by, and how a link in a text is known for its.
  final String domain;

  /// Its own colour, as 0xRRGGBB.
  final int color;

  /// Other names it goes by in a text. One that begins `=` is matched letter for letter ("=X", "=UPS"): a short
  /// name that is also a word, or part of one.
  final List<String> also;
}

/// The companies known by name. Not every company: the ones a phone in the United States is most often sent a code
/// by. Anything else is named by [senderNameIn] where its text names it.
const List<Company> companies = [
  // Ourselves: the code that verifies a number in Settings › Me ("Your Uplink verification code is: …",
  // sent by the relay's texting service). Its face is the app's own ghost (BrandFace), not a pack's mark.
  // Under its earlier name too, Ghost Messaging, which a relay not yet brought up to date still writes in the text.
  Company('Uplink', ghostDomain, 0x000000, ['Ghost Messaging', 'Ghost.md']),
  // Money.
  Company('Coinbase', 'coinbase.com', 0x0052FF),
  Company('Discover', 'discover.com', 0xFF6000, ['Discover Card', 'Discover Bank']),
  Company('Chase', 'chase.com', 0x117ACA, ['JPMorgan Chase']),
  Company('Bank of America', 'bankofamerica.com', 0xE31837, ['BofA', '=BOA']),
  Company('Wells Fargo', 'wellsfargo.com', 0xD71E28),
  Company('Capital One', 'capitalone.com', 0x004879, ['CapitalOne']),
  Company('American Express', 'americanexpress.com', 0x006FCF, ['Amex', '=AMEX']),
  Company('Citi', 'citi.com', 0x003B70, ['Citibank', 'Citi Cards']),
  Company('U.S. Bank', 'usbank.com', 0x0C2074, ['US Bank', 'USBank']),
  Company('PNC', 'pnc.com', 0xF58025, ['=PNC', 'PNC Bank']),
  Company('TD Bank', 'td.com', 0x008A00),
  Company('Truist', 'truist.com', 0x2E1A47),
  Company('Navy Federal', 'navyfederal.org', 0x003366, ['=NFCU', 'Navy Federal Credit Union']),
  Company('USAA', 'usaa.com', 0x003A63, ['=USAA']),
  Company('Ally', 'ally.com', 0x650360, ['Ally Bank']),
  Company('Chime', 'chime.com', 0x1EC677),
  Company('SoFi', 'sofi.com', 0x00A2C7),
  Company('Charles Schwab', 'schwab.com', 0x00A0DF, ['Schwab']),
  Company('Fidelity', 'fidelity.com', 0x368727, ['Fidelity Investments']),
  Company('Vanguard', 'vanguard.com', 0x96151D),
  Company('Robinhood', 'robinhood.com', 0x00C805),
  Company('E*TRADE', 'etrade.com', 0x6633CC, ['ETRADE', 'E-Trade', 'Etrade']),
  Company('Venmo', 'venmo.com', 0x008CFF),
  Company('PayPal', 'paypal.com', 0x003087),
  Company('Cash App', 'cash.app', 0x00D632, ['CashApp']),
  Company('Zelle', 'zellepay.com', 0x6D1ED4),
  Company('Stripe', 'stripe.com', 0x635BFF),
  Company('Square', 'squareup.com', 0x3E4348),
  Company('Wise', 'wise.com', 0x9FE870),
  Company('Revolut', 'revolut.com', 0x0075EB),
  Company('Affirm', 'affirm.com', 0x4A4AF4),
  Company('Klarna', 'klarna.com', 0xFFB3C7),
  Company('Afterpay', 'afterpay.com', 0xB2FCE4),
  Company('Binance', 'binance.com', 0xF0B90B, ['Binance.US']),
  Company('Kraken', 'kraken.com', 0x5741D9),
  Company('Gemini', 'gemini.com', 0x00DCFA),
  Company('Crypto.com', 'crypto.com', 0x002D74),
  Company('Plaid', 'plaid.com', 0x111111),
  Company('Intuit', 'intuit.com', 0x236CFF, ['TurboTax', 'QuickBooks', 'Mint']),
  Company('Credit Karma', 'creditkarma.com', 0x008600),
  Company('Experian', 'experian.com', 0x1D4F91),
  // The big ones.
  Company('Google', 'google.com', 0x4285F4, ['Gmail', 'Google Voice', 'Google Pay']),
  Company('YouTube', 'youtube.com', 0xFF0000),
  Company('Apple', 'apple.com', 0x000000, ['Apple ID', 'Apple Account', 'iCloud', 'Apple Pay']),
  Company('Microsoft', 'microsoft.com', 0x0078D4, ['Outlook', 'Xbox', 'Microsoft account']),
  Company('Amazon', 'amazon.com', 0xFF9900, ['=AWS', 'Amazon Web Services', 'Prime Video']),
  Company('Meta', 'meta.com', 0x0866FF),
  Company('Facebook', 'facebook.com', 0x1877F2, ['=FB']),
  Company('Instagram', 'instagram.com', 0xE4405F),
  Company('WhatsApp', 'whatsapp.com', 0x25D366),
  Company('Messenger', 'messenger.com', 0x0084FF),
  Company('X', 'x.com', 0x000000, ['=X', 'Twitter']),
  Company('TikTok', 'tiktok.com', 0x000000),
  Company('Snapchat', 'snapchat.com', 0xFFFC00, ['Snap']),
  Company('Discord', 'discord.com', 0x5865F2),
  Company('Telegram', 'telegram.org', 0x26A5E4),
  Company('Signal', 'signal.org', 0x3A76F0),
  Company('Reddit', 'reddit.com', 0xFF4500),
  Company('LinkedIn', 'linkedin.com', 0x0A66C2),
  Company('Pinterest', 'pinterest.com', 0xBD081C),
  Company('Yahoo', 'yahoo.com', 0x6001D2),
  Company('Samsung', 'samsung.com', 0x1428A0, ['Samsung account']),
  // Play.
  Company('Twitch', 'twitch.tv', 0x9146FF),
  Company('Steam', 'steampowered.com', 0x171A21),
  Company('Epic Games', 'epicgames.com', 0x313131),
  Company('PlayStation', 'playstation.com', 0x003791, ['=PSN', 'PlayStation Network']),
  Company('Nintendo', 'nintendo.com', 0xE60012),
  Company('Roblox', 'roblox.com', 0x111111),
  Company('Netflix', 'netflix.com', 0xE50914),
  Company('Spotify', 'spotify.com', 0x1DB954),
  Company('Hulu', 'hulu.com', 0x1CE783),
  Company('Disney+', 'disneyplus.com', 0x113CCF, ['Disney', 'DisneyPlus']),
  Company('Ticketmaster', 'ticketmaster.com', 0x026CDF),
  Company('Tinder', 'tinder.com', 0xFF4458),
  Company('Bumble', 'bumble.com', 0xFFC629),
  Company('Hinge', 'hinge.co', 0x111111),
  Company('Duolingo', 'duolingo.com', 0x58CC02),
  // Getting about and getting things.
  Company('Uber', 'uber.com', 0x000000, ['Uber Eats']),
  Company('Lyft', 'lyft.com', 0xFF00BF),
  Company('DoorDash', 'doordash.com', 0xFF3008),
  Company('Grubhub', 'grubhub.com', 0xF63440),
  Company('Instacart', 'instacart.com', 0x43B02A),
  Company('Airbnb', 'airbnb.com', 0xFF5A5F),
  Company('Booking.com', 'booking.com', 0x003580),
  Company('Walmart', 'walmart.com', 0x0071CE),
  Company('Target', 'target.com', 0xCC0000),
  Company('Costco', 'costco.com', 0xE31837),
  Company('eBay', 'ebay.com', 0xE53238),
  Company('Etsy', 'etsy.com', 0xF1641E),
  Company('Shopify', 'shopify.com', 0x7AB55C, ['Shop Pay']),
  Company('Best Buy', 'bestbuy.com', 0x0046BE),
  Company('Home Depot', 'homedepot.com', 0xF96302, ['The Home Depot']),
  Company('UPS', 'ups.com', 0x351C15, ['=UPS']),
  Company('FedEx', 'fedex.com', 0x4D148C),
  Company('USPS', 'usps.com', 0x333366, ['=USPS']),
  Company('CVS', 'cvs.com', 0xCC0000, ['=CVS', 'CVS Pharmacy']),
  Company('Walgreens', 'walgreens.com', 0xE31837),
  // The phone itself.
  Company('Verizon', 'verizon.com', 0xCD040B),
  Company('AT&T', 'att.com', 0x00A8E0, ['=ATT']),
  Company('T-Mobile', 't-mobile.com', 0xE20074, ['TMobile']),
  Company('Xfinity', 'xfinity.com', 0x6138F5, ['Comcast']),
  // Work.
  Company('GitHub', 'github.com', 0x181717),
  Company('GitLab', 'gitlab.com', 0xFC6D26),
  Company('Slack', 'slack.com', 0x4A154B),
  Company('Zoom', 'zoom.us', 0x0B5CFF),
  Company('Dropbox', 'dropbox.com', 0x0061FF),
  Company('Notion', 'notion.so', 0x111111),
  Company('Atlassian', 'atlassian.com', 0x0052CC, ['Jira', 'Trello']),
  Company('Adobe', 'adobe.com', 0xFA0F00),
  Company('Salesforce', 'salesforce.com', 0x00A1E0),
  Company('OpenAI', 'openai.com', 0x111111, ['ChatGPT']),
  Company('Anthropic', 'anthropic.com', 0xD97757, ['Claude']),
  Company('Twilio', 'twilio.com', 0xF22F46, ['Authy']),
  Company('Okta', 'okta.com', 0x007DC1),
  Company('Duo', 'duo.com', 0x6BBF4E, ['Duo Security']),
  Company('DocuSign', 'docusign.com', 0x4C00FF, ['Docusign']),
  Company('Gusto', 'gusto.com', 0xF45D48),
  Company('ADP', 'adp.com', 0xD0271D, ['=ADP']),
  Company('Workday', 'workday.com', 0x0875E1),
  Company('Proton', 'proton.me', 0x6D4AFF, ['Proton Mail', 'ProtonMail']),
  Company('ID.me', 'id.me', 0x2E8540),
  Company('Login.gov', 'login.gov', 0x112E51),
];

/// One way a company is written in a text, as a pattern: its name or one of its other names, letter for letter where
/// it was written with `=`, in either case otherwise.
class _Way {
  _Way(this.company, String written)
      : exact = written.startsWith('='),
        words = written.startsWith('=') ? written.substring(1) : written {
    // A whole name: not the middle of a longer word or number.
    pattern = RegExp('(?<![A-Za-z0-9])${RegExp.escape(words)}(?![A-Za-z0-9])', caseSensitive: exact);
  }
  final Company company;
  final bool exact;
  final String words;
  late final RegExp pattern;
}

/// Every way each company is written, the longest first: "Capital One" before "One" could be anything's.
final List<_Way> _ways = [
  for (final c in companies) ...[_Way(c, c.name), for (final a in c.also) _Way(c, a)],
]..sort((a, b) => b.words.length.compareTo(a.words.length));

// A web address in a text, its host captured: after http(s)://, after an @, or bare ("chase.com").
final RegExp _address = RegExp(r'(?:https?://|@|(?<![A-Za-z0-9.@-]))((?:[a-z0-9-]+\.)+[a-z]{2,})(?![A-Za-z0-9-])', caseSensitive: false);

/// The known company [text] is from, or null: the one named first in it, by name or by web address.
Company? companyIn(String text) {
  Company? found;
  var at = text.length + 1;
  var long = 0;
  // The earliest in the text wins; of two at the same place, the longer.
  void take(Company c, int start, int length) {
    if (start < at || (start == at && length > long)) {
      found = c;
      at = start;
      long = length;
    }
  }

  for (final way in _ways) {
    for (final m in way.pattern.allMatches(text)) {
      // Written as a name is: with a capital (or a figure) first, or just as the company writes it ("eBay").
      // "discover more" is not Discover.
      final first = text[m.start];
      if (!way.exact && first == first.toLowerCase() && first != first.toUpperCase() && m.group(0) != way.words) continue;
      take(way.company, m.start, m.end - m.start);
      break;
    }
  }
  for (final m in _address.allMatches(text)) {
    final host = m.group(1)!.toLowerCase();
    for (final c in companies) {
      if (host == c.domain || host.endsWith('.${c.domain}')) {
        take(c, m.start, m.end - m.start);
        break;
      }
    }
  }
  return found;
}

// A name as a text writes one: capitalised words, up to four of them.
const String _name = r"[A-Z][A-Za-z0-9&.'+-]*(?: (?:[A-Z][A-Za-z0-9&.'+-]*|&|of|and)){0,3}";
const String _code = r'(?:code|passcode|password|PIN|pin|OTP|otp|Code|CODE)';

final List<RegExp> _namings = [
  // "[Acme] 482913 is your code"
  RegExp(r'^\s*(?:<#>\s*)?\[([^\]\n]{2,30})\]'),
  // "Acme: your code is 482913", "Acme - 482913 is your code"
  RegExp('^\\s*(?:<#>\\s*)?($_name)\\s*[:|\\u2013\\u2014-]\\s'),
  // "Your Acme verification code is 482913", "482913 is your Acme code"
  RegExp('\\b[Yy]our ($_name) (?:[a-z-]+ ){0,3}$_code\\b'),
  // "your code for Acme", "verification code from Acme"
  RegExp('\\b$_code (?:for|from) (?:your )?($_name)'),
  // "to sign in to your Acme account"
  RegExp('\\byour ($_name) (?:account|login|sign-in|profile)\\b'),
  // "Your code is 482913. - Acme"
  RegExp('[\\u2013\\u2014-]\\s*($_name)\\.?\\s*\$'),
];

/// Words a text about a code begins its phrases with, which are not anybody's name.
const Set<String> _notNames = {
  'your', 'the', 'this', 'that', 'use', 'code', 'verification', 'verify', 'security', 'secure', 'login', 'log', 'sign', 'one', 'time', 'one-time', 'account', 'hi', 'hello', 'dear', 'otp', 'pin',
  'passcode', 'password', 'reminder', 'alert', 'notice', 'important', 'urgent', 'message', 'msg', 'text', 'do', 'never', 'please', 'enter', 'it', 'if', 'we', 'you', 'for', 'to', 'new', 'temporary',
  'authentication', 'confirmation', 'access', 'reply', 'stop', 'help', 'thanks', 'thank', 'welcome', 'here', 'requested', 'free', 'a', 'an', 'my', 'no', 'not', 'id', 'two-factor', '2fa', 'mobile', 'phone',
  'single-use', 'single', 'unique', 'personal', 'identification', 'number', 'expires', 'valid', 'don\'t', 'dont',
};

/// The name [text] gives for who sent it, where it gives one in a way such texts do; null where it does not. For a
/// text no known company is found in ([companyIn]).
String? senderNameIn(String text) {
  for (final naming in _namings) {
    final m = naming.firstMatch(text);
    if (m == null) continue;
    var name = m.group(1)!.trim();
    // "Acme Verification" is Acme: what follows the name is the phrase, not more of the name.
    final words = name.split(' ');
    while (words.isNotEmpty && _notNames.contains(words.last.toLowerCase())) {
      words.removeLast();
    }
    while (words.isNotEmpty && _notNames.contains(words.first.toLowerCase())) {
      words.removeAt(0);
    }
    name = words.join(' ').replaceAll(RegExp(r"[.'&+-]+$"), '');
    if (name.length < 2 || name.length > 30 || !name.contains(RegExp('[A-Za-z]'))) continue;
    return name;
  }
  return null;
}
