/// What the walkthrough says on each page (lib/onboarding/onboarding.dart): shown as the page's words, and spoken
/// aloud in a friendly voice where the app can play it. The voice is ElevenLabs', made once at build time by
/// tool/onboarding_voice.py from these very lines (one a line, in single quotes, as the tool reads them), and kept as
/// `assets/onboarding/<page>.mp3`. Change a line, run the tool, and that page alone is spoken again.
library;

// Uplink's voice (Matt, 2026-11-15: "Rework the onboarding to be a bit shorter and have it focus on the fact that ghost
// is an all in one messenger look at branding from things like discord telegram etc and find our own voice amoung
// those"): where Discord is a loud hangout, Telegram fast and powerful, Signal principled and WhatsApp plain, Uplink is
// calm and sure of itself, in short sentences with a little wit. All your people, one quiet app.
const Map<String, String> narration = {
  'welcome': 'Hi, I\'m Ghost. Your texts, your friends, your groups and your calls, all in one quiet app. No more juggling five messengers to reach the people you care about.',
  'texts': 'Ghost starts with every text you already have. Make it your texting app, or keep Google Messages and Ghost works right beside it. Nothing is lost either way.',
  'together': 'Friends who have Ghost get more: chats over the internet, locked so only your phones can read them, with reactions, stickers and groups. Everyone else still gets a text, in the same conversation.',
  'calls': 'Every group has a space that\'s always open. Drop in when you\'re free, slip out when you\'re not. Share a link, and anyone can join from a browser.',
  'everywhere': 'Ghost is on your Mac and your Windows computer, too. Scan a code once, and your conversations follow you, sent from your own number.',
  'start': 'That\'s Ghost. Pick a look, then go say hi to someone.',
};

/// Where a page's voice is kept.
String narrationAsset(String page) => 'assets/onboarding/$page.mp3';
