// The docs' sections and pages, in reading order (tool/build-docs.mjs). Each page is docs-src/pages/<slug>.html.
// `soon` marks a page about something not out yet (Matt, 2026-11-19: "Mark them Coming soon").
export const sections = [
  {
    title: 'Getting started',
    pages: [
      { slug: 'index', icon: 'rocket', title: 'Welcome', summary: 'What Uplink is, and where to start.' },
      { slug: 'alpha', icon: 'flask-conical', title: 'Join the alpha', summary: 'Try Uplink before it launches: what to install, and how to join the testers\' circle.' },
      { slug: 'install', icon: 'download', title: 'Install the app', summary: 'Get Uplink on an Android phone, a Mac, a Windows PC or a Linux computer.' },
      { slug: 'first-run', icon: 'rocket', title: 'The first time you open it', summary: 'A username and a password, your recovery words, and on Android your texts.' },
      { slug: 'account', icon: 'key-round', title: 'Your account', summary: 'Create an account, keep your recovery words safe, and sign in on another device.' },
      { slug: 'how-accounts-work', icon: 'badge-check', title: 'How your account works', summary: 'Recovery words, your password, the account address, and being the same you on every device.' },
      { slug: 'profile', icon: 'circle-user', title: 'Your profile and number', summary: 'Your name, picture, status and username, and verifying your phone number.' },
    ],
  },
  {
    title: 'Circles, spaces and calls',
    pages: [
      { slug: 'circles', icon: 'users', title: 'Make a circle and invite people', summary: 'A circle is a group of people with a sidebar of spaces. Make one, invite people, and join one.' },
      { slug: 'spaces', icon: 'message-circle', title: 'Spaces', summary: 'The five kinds of space, polls, mentions, and spaces of your own.' },
      { slug: 'roles', icon: 'shield-check', title: 'Roles and permissions', summary: 'Who can do what in a circle, and changing it space by space.' },
      { slug: 'open-spaces', icon: 'compass', title: 'Open spaces', summary: 'A call you walk around in: hear who is near you, and gather in groups.' },
      { slug: 'sms-spaces', icon: 'smartphone', title: 'SMS spaces', summary: 'A space that people without the app are in by text.' },
      { slug: 'calls', icon: 'headphones', title: 'Calls', summary: 'Joining voice, the call\'s controls, each person\'s volume, and guests from a browser.' },
      { slug: 'files', icon: 'folder', title: 'Files spaces', summary: 'Share files with a circle, sealed end to end, and play videos in the app.' },
    ],
  },
  {
    title: 'Plugins',
    pages: [
      // The slug stays `plugins`: the app's docsButton('plugins') and other pages link it.
      { slug: 'plugins', icon: 'store', title: 'The Marketplace', summary: 'Add plugins for yourself, built in or from other developers, and built-in ones for a whole circle.' },
      { slug: 'record-call', icon: 'circle-dot', title: 'Record call', summary: 'Record a call to one file with a named track for each voice.' },
      { slug: 'scribe', icon: 'file-text', title: 'Scribe', summary: 'Turn a recorded call into words, on your device.' },
      { slug: 'live-captions', icon: 'type', title: 'Live captions', summary: 'See what everyone in a call says, as they say it.' },
      { slug: 'watch-together', icon: 'film', title: 'Watch together', summary: 'Play a video or song for everyone in a call, in step.' },
      { slug: 'soundboard', icon: 'megaphone', title: 'Soundboard', summary: 'Pads in a call that play a sound for everyone in it.' },
      { slug: 'notion', icon: 'file-text', title: 'Notion', summary: 'Notion pages and boards opened out in a circle\'s chats.' },
      { slug: 'spotify', icon: 'audio-lines', title: 'Spotify', summary: 'A queue of songs for a circle\'s call, played from one person\'s Spotify.' },
      { slug: 'auto-leveler', icon: 'audio-lines', title: 'Auto leveler', summary: 'Everyone in a call at about the same loudness.' },
      { slug: 'voice-changer', icon: 'audio-lines', title: 'Voice changer', summary: 'Send voice messages in another voice, said the way you said them.' },
      { slug: 'performance', icon: 'gauge', title: 'Performance', summary: 'See what the app is using, in a row at the top, and copy a log of it.' },
      { slug: 'translate', icon: 'languages', title: 'Translate', summary: 'Read texts in other languages, translated on your phone.' },
      { slug: 'codes', icon: 'key-round', title: 'Codes', summary: 'Sign-in codes in a tab of their own, a tap to copy.' },
      { slug: 'spam', icon: 'ban', title: 'Spam filter', summary: 'Texts that look like spam, kept out of your way.' },
      { slug: 'kinds', icon: 'list-filter', title: 'Kinds of text', summary: 'Texts from strangers sorted by what they are about.' },
      { slug: 'unknown-numbers', icon: 'user-round-search', title: 'Unknown numbers', summary: 'What a number you don\'t know likely is, with Save and Block.' },
      { slug: 'quiet-hours', icon: 'clock', title: 'Quiet hours', summary: 'Silence for strangers at night, and never a sound for spam.' },
      { slug: 'link-previews', icon: 'link', title: 'Link previews', summary: 'Links shown as cards with their picture and title.' },
      { slug: 'quick-actions', icon: 'calendar-plus', title: 'Quick actions', summary: 'Dates, addresses, tracking numbers and phone numbers become buttons.' },
      { slug: 'replies', icon: 'reply', title: 'Replies', summary: 'Suggested replies, and reminders to follow up.' },
      { slug: 'cleaner', icon: 'brush-cleaning', title: 'Cleaner', summary: 'Delete conversations in bulk by kind.' },
      { slug: 'discord', icon: 'bot', title: 'Discord servers', summary: 'Link a Discord server, see who is in its voice channels, and talk in them from Uplink.' },
    ],
  },
  // Plugins from other developers (Matt, 2026-11-20: "Please include documents on how users can develop plugins"). The
  // app links build-a-plugin (Marketplace › How to build a plugin), plugin-testing (Settings › Developer),
  // plugin-guidelines (the submission form) and plugins: those slugs are part of its contract. Each page is Coming soon
  // until the release that carries the Marketplace, which takes `soon` away.
  {
    title: 'Build a plugin',
    pages: [
      { slug: 'build-a-plugin', icon: 'code', title: 'Build a plugin', summary: 'What a plugin of your own can do, what it is made of, and how it reaches the Marketplace.' },
      { slug: 'plugin-quick-start', icon: 'rocket', title: 'Your first plugin', summary: 'Load the Bills plugin in Developer mode, try it on a text, then change it.' },
      { slug: 'plugin-format', icon: 'file-code', title: 'The plugin file', summary: 'Every field of a ghost-plugin/1 file, with its limits.' },
      { slug: 'plugin-rules', icon: 'list-filter', title: 'Tags, tabs and buttons', summary: 'Tags, tabs and kinds with their rows, buttons and menu lines, and what happens as texts arrive.' },
      { slug: 'plugin-phrases', icon: 'text-search', title: 'Phrases and tokens', summary: 'How a plugin finds words in a text: phrases, tokens like {digits:6}, and what a match gives it.' },
      { slug: 'plugin-permissions', icon: 'shield-check', title: 'What a plugin may do', summary: 'Permissions, what each one lets a plugin do, and what people are told before they add it.' },
      { slug: 'plugin-testing', icon: 'flask-conical', title: 'Try it in Developer mode', summary: 'Load your plugin from a file, a link or the clipboard, try it on a text, reload it, and read what went wrong.' },
      { slug: 'plugin-submit', icon: 'send', title: 'Submit it to the Marketplace', summary: 'The submission form, what review looks at, listing it, and sending a new version.' },
      { slug: 'plugin-guidelines', icon: 'list-checks', title: 'Marketplace guidelines', summary: 'What gets a plugin listed, what keeps one out, and how reports and withdrawals work.' },
    ],
  },
  {
    title: 'Messaging',
    pages: [
      { slug: 'texts', icon: 'message-square', title: 'Texts and conversations', summary: 'Sending, reactions, edits, ticks, stickers, effects and conversation settings.' },
      { slug: 'google-messages', icon: 'message-circle', title: 'Beside Google Messages', summary: 'Keep Google Messages for RCS and use Uplink for everything else.' },
      { slug: 'friends', icon: 'user-plus', title: 'Friends', summary: 'Add friends by username, and friends by number.' },
      { slug: 'networks', icon: 'send', title: 'Telegram, Signal and more', summary: 'Your other chats in one inbox: linking Telegram, Signal, WhatsApp and Matrix.' },
      { slug: 'encryption', icon: 'lock', title: 'Encrypted texts', summary: 'Seal texts with one person end to end, and check it is really them.' },
    ],
  },
  {
    title: 'Computers',
    pages: [
      { slug: 'computers', icon: 'laptop', title: 'Mac, Windows and Linux apps', summary: 'Uplink on a computer, with or without your phone.' },
      { slug: 'pairing', icon: 'qr-code', title: 'Pair a computer with your phone', summary: 'Your texts on your computer: scan, match the six digits, and keep it connected.' },
      { slug: 'browser-extension', icon: 'puzzle', title: 'The browser extension', summary: 'Sign in to your chat networks once, in your browser, and every device of yours is signed in too.' },
    ],
  },
  {
    title: 'Privacy and settings',
    pages: [
      { slug: 'privacy', icon: 'eye', title: 'Privacy and safety', summary: 'What is sealed, what the server sees, blocking, reporting, and signing out.' },
      { slug: 'settings', icon: 'settings', title: 'Settings, at a glance', summary: 'Every section of Settings, and what it holds.' },
      { slug: 'appearance', icon: 'palette', title: 'Looks, colours and fonts', summary: 'The app\'s looks, making and sharing your own, and the Readable font.' },
      { slug: 'keyboard-shortcuts', icon: 'keyboard', title: 'Keyboard shortcuts', summary: 'Jump to a conversation, format what you write, mute a call, and change any shortcut\'s keys.' },
      { slug: 'routes', icon: 'globe', title: 'Routes', summary: 'How messages travel between Uplink apps: the relay, your own relay, texts, and testing them.' },
      // For whoever runs the server (GMFB-25, "Self-hosting the relay, documented"): docs/SELF_HOSTING.md as a page of the site.
      { slug: 'self-hosting', icon: 'hard-drive', title: 'Run your own relay', summary: 'Run the relay on a server of your own: what you give up, Docker or a single program, TLS, TURN for calls, and its settings.' },
      { slug: 'coming-soon', icon: 'clock', title: 'Coming soon', summary: 'What is built but not out yet.', soon: true },
    ],
  },
];

// The developer docs: a book of their own at /docs/developer/, with their own sidebar and search, never listed among
// the pages above (Matt, 2026-11-23: "a developer docs section ... that outlines all the major parts of the app and how
// they work together, I'd like an API docs complete with a postman file", then "please also list the developer docs at
// /docs/developer and don't mix them in with /docs"). Each page is docs-src/pages/developer/<name>.html, but the first,
// which is docs-src/pages/developer.html: the list of them. The two API references are drawn from docs-src/api
// (tool/build-docs.mjs), as the Postman collection is.
export const developer = [
  {
    title: 'The source',
    pages: [
      { slug: 'developer', icon: 'braces', title: 'Developer docs', summary: 'For people reading, building or scripting Uplink: how it is built, and both of its APIs.' },
      { slug: 'developer/architecture', icon: 'network', title: 'How the app is built', summary: 'The major parts of Uplink, where each lives in the source, and what it talks to.' },
      { slug: 'developer/flows', icon: 'workflow', title: 'How the parts work together', summary: 'Things followed from the tap to the wire: a text, a message to a friend, a call, an open space\'s floor, pairing a computer, adding a plugin, and more.' },
      { slug: 'developer/build', icon: 'terminal', title: 'Build, test and run it', summary: 'Running the app and the relay from source, the tests, the scripts, and how the code is commented.' },
    ],
  },
  {
    title: 'APIs',
    pages: [
      { slug: 'developer/api', icon: 'book-open', title: 'API overview and Postman', summary: 'The two APIs, how each is reached and signed, and a Postman collection of both.' },
      { slug: 'developer/app-api', icon: 'code', title: 'App API', summary: 'Control the app from a script or another program: every method, what it takes and what it answers.' },
      { slug: 'developer/relay-api', icon: 'globe', title: 'Relay server API', summary: 'The relay server\'s HTTP routes: files, the Marketplace, feedback and the rest.' },
      { slug: 'developer/hub', icon: 'share-2', title: 'The hub and pairing protocols', summary: 'What an app says to the relay server over a WebSocket: signing in, packets, presence, rooms and the directory.' },
    ],
  },
];
