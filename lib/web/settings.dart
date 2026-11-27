import 'package:flutter/widgets.dart';

import '../art/app_icon.dart';
import '../art/lucide.g.dart';
import '../art/lucide_more.dart';
import '../kit/settings_kit.dart';
import '../sms.dart';
import '../ui/common.dart' show openDocs;
import '../ui/settings.dart';
import '../ui/settings_panes.dart' show aboutLicences, appVersion;
import '../ui/whats_new.dart';
import '../l10n/words.dart';

/// What is not in a browser yet, as About says it: each is absent from the page's screens, not broken in them. Calls
/// are there where the build has them (Sms.browserCalls), without what needs the app's native halves.
String get notInBrowserYet => Sms.callsHere
    ? 'Voice messages and sounds, ${Sms.filesHere ? 'files in a space\'s chat' : 'Files spaces'}, plugins and the Marketplace, chats on other networks, and texts through a phone; and in a call, recording, the voice changer, noise removal beyond the browser\'s own and sharing your screen. They are in Uplink on a phone or a computer.'
    : 'Calls, voice messages and sounds, ${Sms.filesHere ? 'files in a space\'s chat' : 'Files spaces'}, plugins and the Marketplace, chats on other networks, and texts through a phone. They are in Uplink on a phone or a computer.';

/// What the browser keeps, as About says it (lib/web/store.dart says it at length): all of it sealed, and the words and
/// the password's key not at all.
const browserKeeps = 'Who you are here, your friends, circles and conversations, in this browser\'s own store for this address, every part of it sealed with a key the browser made for this page and won\'t give out. Your recovery words and your password\'s key are not kept here: your password opens them when you want to see the words or change your account. Two things are kept that matter: a copy of your backup sealed with your password, which someone who got it could try passwords against, so make your password long; and the key your devices seal copies of your messages to each other with, which opens those copies as they pass. Signing out deletes all of it from this browser.';

/// What sealing doesn't keep out, as About says it: whatever runs in the page, a copy of the browser's files, the
/// bytes a browser keeps of what was deleted, and the server the page comes from.
const browserLimits = 'Anything that runs in this page can open what it keeps, as the app does: a script slipped into it, or a browser extension allowed to read and change this site. In Chrome, Edge and Firefox the key is among the browser\'s own files, so a copy of them opens everything; Safari keeps it locked with your Mac\'s or iPhone\'s keychain. After you sign out the browser may keep what was deleted among its files for a while; on a computer others use, use a private window, or clear the browser\'s data for this site. And the page comes from the server each time you open it, so a server broken into could hand out one that takes your password. On a computer of your own, the app keeps your keys safer.';

/// Settings › About, in a browser: the phone's About is the phone app's own and a computer's is its own
/// (lib/desktop/ui/desk_settings.dart), so the page has this one. It says what this is, what the browser keeps of
/// it, and what isn't here yet. Added to Settings by lib/web/app.dart, there alone.
List<SettingsSection> browserSettings() => [
      SettingsSection(
        id: 'browser-about',
        where: SettingsWhere.computer,
        label: 'About',
        icon: const AppIcon(Lucide.info, size: 18),
        hue: 'graphite',
        group: 'app',
        summary: (m) => 'Uplink in a browser $appVersion',
        page: (context, m) => [
          PaneSection(title: 'Uplink in a browser', children: [
            const SettingRow(icon: AppIcon(Lucide.ghost, size: 18), label: 'Version', value: Text(appVersion)),
            // The release notes again (lib/ui/whats_new.dart).
            SettingRow(icon: const AppIcon(Lucide.sparkles, size: 18), label: 'What\'s new', hint: const Tr('What the last update brought.'), onPress: () => showWhatsNew(context)),
            // gogho.st/docs, in a tab beside this one.
            const SettingRow(icon: AppIcon(Lucide.bookOpen, size: 18), label: 'Help and docs', hint: Tr('How everything works, step by step, at gogho.st/docs.'), onPress: openDocs),
            // What lib/web/store.dart says, in fewer words: what is sealed, against what, and what isn't kept at all.
            const SettingRow(
              icon: AppIcon(Lucide.lock, size: 18),
              label: 'What this browser keeps',
              hint: Text(browserKeeps),
            ),
            const SettingRow(
              icon: AppIcon(Lucide.triangleAlert, size: 18),
              label: 'What that doesn\'t keep out',
              hint: Text(browserLimits),
            ),
            const SettingRow(
              icon: AppIcon(LucideMore.appWindow, size: 18),
              label: 'One tab at a time',
              hint: Tr('A second tab offers to take over from the first, so each message arrives once.'),
            ),
            SettingRow(icon: const AppIcon(Lucide.info, size: 18), label: 'Not in the browser yet', hint: Text(notInBrowserYet)),
          ]),
          aboutLicences(),
        ],
      ),
    ];
