/// Settings' sections and what is on each one's page (the frame is settings.dart). A page is a list of the kit's
/// cards and rows, handed over plain, so the search can read every setting's name off it.
library;

import 'whats_new.dart' show showWhatsNew;
import '../api/remote.dart';
import '../api/server.dart';
import 'admin_page.dart' show adminOffered, adminPane;
import 'setup.dart' show TextsStep;
import 'api_pane.dart';
import 'app_lock_ui.dart' show AppLockPane, appLockSummary;
import '../inbox/inbox.dart';
import 'blocking.dart';
import 'report_sheet.dart' show ReportsMadeList, reportsMadeKey;
import '../safety/abuse_report.dart' show MadeReport;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';
import '../app_state.dart';

import '../art/app_icon.dart';
import '../art/lucide.g.dart';
import '../art/lucide_more.dart';
import '../backgrounds.dart';
import '../effects.dart';
import '../emoji_sets.dart';
import '../platform_info.dart';
import '../kit/settings_kit.dart';
import '../plugins/settings.dart';
import '../onboarding/onboarding.dart';
import '../kit/settings_type.dart';
import '../custom_css.dart';
import '../custom_theme.dart';
import '../looks.dart';
import '../sms.dart';
import '../sounds.dart';
import 'background_picker.dart';
import '../desktop/platform.dart' show computerWord;
import '../voice/voice_settings.dart';
import 'common.dart';
import 'gm_guide_screen.dart';
import 'gm_web_screen.dart';
import 'look_picker.dart';
import 'resource_packs_ui.dart';
import '../packs/resource_pack.dart';
import 'market/dev_plugins.dart' show devPluginsPane;
import 'rcs_setup.dart';
import 'voice_pane.dart';
import 'voice_screen.dart' show VolumeSlider;
import 'text_scale.dart';
import 'computers.dart';
import 'conversations.dart';
import 'encryption.dart';
import 'me.dart';
import 'network.dart';
import 'settings.dart';
import 'settings_shortcuts.dart';
import 'custom_css_editor.dart';
import 'custom_theme_editor.dart';
import 'nav_style.dart';
import '../summaries.dart';
import '../keep_running.dart';
import '../net/net.dart' show Net;
import '../l10n/words.dart';

/// A row's icon at the size every settings row uses.
Widget _icon(LucideIcon icon) => AppIcon(icon, size: 18);

String _onOff(bool on) => on ? 'On' : 'Off';

/// Every section, in the order of the list. Rows with the same group share a card.
/// Read each time Settings is drawn: the app's own sections, with those that come from outside round them
/// (SettingsSources: a plugin's page, a computer's own), and those for another kind of device left out.
List<SettingsSection> get settingsSections => SettingsSources.around(_ownSections());

/// What a group of sections is called where groups are named: the Settings ring's menu (lib/ui/shell.dart). A name
/// is never one of its own sections' names, which stand right under it.
String settingsGroupLabel(String group) => switch (group) {
      'computer' => 'Phone',
      'me' => 'You',
      'look' => 'Look',
      'messages' => 'Conversations',
      'plugins' => 'Extras',
      'privacy' => 'Privacy',
      'phone' => 'This phone',
      'app' => Sms.remote ? 'This $computerWord' : 'App',
      _ => group,
    };

/// The same for one kind of device, whichever this is: what a phone's Settings has, or a computer's.
List<SettingsSection> settingsSectionsOn(SettingsWhere here) => SettingsSources.around(_ownSections(), here: here);

/// The app's own sections, in the list's order: each with its group, its state line and the function below that
/// builds its page.
List<SettingsSection> _ownSections() => [
  // Plugins (lib/plugins/settings.dart), first of all (Matt, 2026-11-17: "move plugins to the very top of settings list";
  // SettingsSources.around keeps them above a computer's own sections too): the band to the Plugins page, and each
  // plugin's own settings, once the app has one.
  ...pluginsSettings(),
  SettingsSection(
    id: 'me',
    label: 'Me',
    icon: _icon(Lucide.userRound),
    hue: 'blue',
    group: 'me',
    summary: meSummary,
    page: mePane,
  ),
  SettingsSection(
    id: 'friends-joining',
    label: 'Friends joining',
    icon: _icon(Lucide.userPlus),
    hue: 'green',
    group: 'me',
    summary: friendsSummary,
    page: friendsPane,
  ),
  SettingsSection(
    id: 'appearance',
    label: 'Appearance',
    icon: _icon(Lucide.sunMoon),
    hue: 'indigo',
    group: 'look',
    summary: (m) {
      final look = m.app.look;
      final own = CustomTheme.used(m.app);
      if (own != null) return [own.name, if (m.app.font == 'readable') 'Readable font', if (m.app.textPercent != 100) '${m.app.textPercent}% text'].join(' · ');
      // The look, then the pack it is drawn with: one of its own (Uplink's Mist), or a resource pack's name.
      final used = ResourcePacks.instance.usedBy(m.app)?.entry;
      final pictures = used == null ? null : ResourcePacks.nameOf(used);
      return [
        if (look.family != Look.ghost) look.family.label,
        if (look.isPack) look.label,
        ?pictures,
        if (look.forced == null) switch (m.app.theme) { 'light' => 'Light', 'dark' => 'Dark', _ => 'System theme' },
        '${m.app.bubble == 'theme' ? (look == Look.ghost ? 'White' : look.label) : bubbleColor(m.app.bubble).name} bubbles',
        if (m.app.font == 'readable') 'Readable font',
        if (m.app.textPercent != 100) '${m.app.textPercent}% text',
      ].join(' · ');
    },
    page: _appearance,
  ),
  // The app's language, a section of its own (Matt, 2026-11-26: "make sure there is a language section in the
  // settings"), now that there are twenty.
  SettingsSection(
    id: 'language',
    label: 'Language',
    icon: _icon(LucideMore.languages),
    hue: 'cyan',
    group: 'look',
    summary: (m) => languageWords(m.app.choice(Words.key, Words.automatic)),
    page: _language,
  ),
  SettingsSection(
    id: 'background',
    label: 'Chat background',
    icon: _icon(Lucide.image),
    hue: 'purple',
    group: 'look',
    summary: (m) => ChatBackground.everyChat(m.app).label,
    page: (context, m) => const [],
    screen: (context, m) => const BackgroundPicker(),
  ),
  SettingsSection(
    id: 'emoji',
    label: 'Emoji',
    icon: _icon(LucideMore.smile),
    hue: 'amber',
    group: 'look',
    summary: (m) => emojiSetInUse(m.app.emoji).name,
    page: _emoji,
  ),
  SettingsSection(
    id: 'effects',
    label: 'Effects',
    icon: _icon(Lucide.sparkles),
    hue: 'magenta',
    group: 'look',
    summary: (m) => m.app.effects ? 'On · ${ScreenEffect.values.length} effects' : 'Off',
    page: _effects,
  ),
  SettingsSection(
    id: 'shortcuts',
    label: 'Keyboard shortcuts',
    icon: _icon(LucideMore.keyboard),
    hue: 'slate',
    group: 'look',
    summary: shortcutsSummary,
    page: shortcutsPane,
  ),
  SettingsSection(
    id: 'sounds',
    // Played by the phone or the computer itself: a page in a browser plays none yet.
    when: (m) => !Sms.browser,
    label: 'Sounds',
    icon: _icon(Lucide.audioLines),
    hue: 'mint',
    group: 'look',
    summary: (m) => !Sounds.instance.on
        ? 'Off'
        : '${_choiceName(Sounds.messageChoices, Sounds.instance.message)} · ${_choiceName(Sounds.ringChoices, Sounds.instance.ring)} · ${Sounds.instance.quiet}%',
    page: _sounds,
  ),
  SettingsSection(
    id: 'messages',
    label: 'Messages',
    icon: _icon(Lucide.messageSquare),
    hue: 'blue',
    group: 'messages',
    summary: (m) => m.app.enterSends ? 'Enter sends' : 'Enter starts a new line',
    page: _messages,
  ),
  SettingsSection(
    id: 'receipts',
    // What the phone asks of the carrier: the phone's own.
    where: SettingsWhere.phone,
    label: 'Receipts',
    icon: _icon(Lucide.checkCheck),
    hue: 'cyan',
    group: 'messages',
    summary: (m) => 'Delivery ${_onOff(m.app.flag('delivery_reports')).toLowerCase()} · read ${_onOff(m.app.readReports).toLowerCase()}',
    page: _receipts,
  ),
  SettingsSection(
    id: 'notifications',
    // Android's notifications: the phone's own.
    where: SettingsWhere.phone,
    label: 'Notifications',
    icon: _icon(Lucide.bell),
    hue: 'coral',
    group: 'messages',
    summary: (m) => m.status == null ? '' : (m.status!.notifications ? (m.app.flag('notif_preview') ? 'Allowed · previews shown' : 'Allowed · previews hidden') : 'Off in Android'),
    page: _notifications,
  ),
  // Calls (lib/voice/voice_settings.dart; Matt, 2026-11-15: "voice settings to change all kinds of things like bitrates
  // and sound input devices etc etc"), on the phone and on a computer alike.
  SettingsSection(
    id: 'voice',
    // Nothing to set where there are no calls (a browser, for now).
    when: (m) => Sms.callsHere,
    label: 'Voice and video',
    icon: _icon(LucideMore.headphones),
    hue: 'mint',
    group: 'messages',
    summary: (m) {
      final v = VoiceSettings.of(m.app);
      return '${v.audioKbps} kb/s${v.stereo ? ' stereo' : ''} · ${v.video}p';
    },
    page: (context, m) => [const VoicePane()],
  ),
  // The app's own lock (GMFB-46; lib/app_lock, lib/ui/app_lock_ui.dart): a PIN, and the fingerprint or face where the
  // device has one. Not in a browser, which keeps nothing a lock could stand on.
  SettingsSection(
    id: 'app-lock',
    label: 'Lock the app',
    icon: _icon(Lucide.keyRound),
    hue: 'slate',
    group: 'privacy',
    when: (m) => !Sms.browser,
    summary: (m) => appLockSummary(),
    page: (context, m) => const [AppLockPane()],
  ),
  SettingsSection(
    id: 'encryption',
    label: 'Encryption',
    icon: _icon(Lucide.lock),
    hue: 'green',
    group: 'privacy',
    summary: (m) {
      final on = m.e2e.where((e) => e.on).length;
      final waiting = m.e2e.length - on;
      if (m.e2e.isEmpty) return 'Off';
      return [if (on > 0) 'On with $on ${on == 1 ? 'person' : 'people'}', if (waiting > 0) '$waiting waiting'].join(' · ');
    },
    page: _encryption,
  ),
  SettingsSection(
    id: 'blocked',
    label: 'Blocked',
    icon: _icon(Lucide.ban),
    hue: 'red',
    group: 'privacy',
    // Numbers and Telegram and Signal people together (lib/ui/blocking.dart).
    summary: (m) {
      final n = m.blocked.length + Inbox.instance.networks.fold<int>(0, (a, x) => a + (x.soon ? 0 : x.blockedPeople.length));
      return n == 0 ? 'None' : '$n ${n == 1 ? 'person' : 'people'}';
    },
    page: _blocked,
  ),
  // Reports you've made (GMFB-40): kept on this device alone (lib/ui/report_sheet.dart).
  SettingsSection(
    id: 'reports',
    label: 'Reports you\'ve made',
    icon: _icon(Lucide.flag),
    hue: 'amber',
    group: 'privacy',
    summary: (m) {
      final n = MadeReport.readAll(m.app.choice(reportsMadeKey, '[]')).length;
      return n == 0 ? 'None' : '$n';
    },
    page: (context, m) => const [ReportsMadeList()],
  ),
  SettingsSection(
    id: 'archived',
    label: 'Archived',
    icon: _icon(Lucide.archive),
    hue: 'slate',
    group: 'privacy',
    summary: (m) => m.archived == 0 ? 'Nothing archived' : '${m.archived} ${m.archived == 1 ? 'conversation' : 'conversations'}',
    page: (context, m) => const [],
    screen: (context, m) => const ConversationsScreen(archived: true),
  ),
  // No "Your number" here: the phone's own number is Me › Number's, verified there and told to Android's side
  // (Matt, 2026-11-19: "remove the duplicate "your number" setting it's already handled under me").
  // Settings › Texts, while texts are off: passed by in the walkthrough (Matt, 2026-11-20: "rework the onboarding on
  // mobile so that SMS is not required and you can 'skip this step'"), turned on here when wanted.
  SettingsSection(
    id: 'texts',
    where: SettingsWhere.phone,
    label: 'Texts',
    icon: _icon(Lucide.messageSquare),
    hue: 'green',
    group: 'phone',
    when: (m) => Sms.textsOff && !Sms.remote && !Sms.standalone,
    summary: (m) => 'Off',
    page: _texts,
  ),
  SettingsSection(
    id: 'android',
    // The phone's own.
    where: SettingsWhere.phone,
    label: 'Android',
    icon: _icon(LucideMore.smartphone),
    hue: 'lime',
    group: 'phone',
    summary: (m) => m.status == null ? '' : (m.status!.isDefault ? 'Default SMS app' : 'Not the default SMS app'),
    page: _android,
  ),
  SettingsSection(
    id: 'keyboard',
    // The phone's own.
    where: SettingsWhere.phone,
    label: 'Ghost Keyboard',
    icon: _icon(LucideMore.keyboard),
    hue: 'yellow',
    group: 'phone',
    summary: (m) => !m.app.flag('kbd_codes') ? 'Sign-in codes not offered' : (m.keyboardHere ? 'Offers it sign-in codes' : 'Not on this phone'),
    page: _keyboard,
  ),
  SettingsSection(
    id: 'computers',
    // The computers paired with the phone: a computer has "Your phone" (lib/desktop/ui/desk_settings.dart).
    where: SettingsWhere.phone,
    label: 'Computers',
    icon: _icon(Lucide.laptop),
    hue: 'blue',
    group: 'phone',
    summary: (m) {
      if (m.computers.isEmpty) return 'None paired';
      final on = m.computers.where((c) => c.via != null).length;
      final names = m.computers.length == 1 ? m.computers.first.name : '${m.computers.length} computers';
      return on > 0 ? '$names · connected' : names;
    },
    page: computersPane,
  ),
  SettingsSection(
    id: 'network',
    // The routes run on the phone; a computer speaks through it.
    where: SettingsWhere.phone,
    // "Routes", not "Network": Connections is your linked accounts, and this is how messages travel (Matt, 2026-11-19:
    // "Rename 'Network' to 'Routes'").
    label: 'Routes',
    icon: _icon(Lucide.network),
    hue: 'blue',
    group: 'phone',
    summary: (m) => networkSummary(),
    page: networkPane,
  ),
  SettingsSection(
    id: 'updates',
    // The phone app's updates; a computer's are under "This Mac".
    where: SettingsWhere.phone,
    label: 'Updates',
    icon: _icon(Lucide.download),
    hue: 'mint',
    group: 'app',
    summary: (m) => updateSummary(m.update),
    page: _updates,
  ),
  SettingsSection(
    id: 'developer',
    // Hidden until developer mode is on, on the phone and the computer alike: twelve taps on Settings › About ›
    // Version turn it on (Matt, 2026-11-20: "make it enabled by tapping the version number 12 times"), and its own
    // switch turns it off again.
    when: (m) => m.app.flag('dev_mode', fallback: false),
    label: 'Developer',
    icon: _icon(Lucide.terminal),
    hue: 'graphite',
    group: 'app',
    summary: (m) => m.devLines.isEmpty ? 'Nothing in the log' : '${m.devLines.length} ${m.devLines.length == 1 ? 'line' : 'lines'} in the log',
    page: _developer,
  ),
  // Settings › API, in developer mode (lib/ui/api_pane.dart; Matt, 2026-11-17: "a API section of the settings that
  // shows up when developer mode is enabled").
  SettingsSection(
    id: 'api',
    where: SettingsWhere.phone,
    label: 'API',
    icon: _icon(Lucide.braces),
    hue: 'indigo',
    group: 'app',
    when: (m) => m.app.flag('dev_mode', fallback: false),
    summary: (m) => [if (ApiServer.on(m.app)) 'On this phone', if (ApiRemote.on(m.app)) 'Through the relay'].join(' · ').ifEmptyThen('Off'),
    page: apiPane,
  ),
  // Settings › Admin: souls and special badges given out, for @matt alone in developer mode (lib/ui/admin_page.dart;
  // Matt, 2026-11-19: "a simple admin page for me to login to ... hidden behind developer mode").
  SettingsSection(
    id: 'admin',
    where: SettingsWhere.everywhere,
    label: 'Admin',
    icon: _icon(Lucide.shieldCheck),
    hue: 'coral',
    group: 'app',
    when: adminOffered,
    summary: (m) => 'Souls and badges',
    page: adminPane,
  ),
  SettingsSection(
    id: 'about',
    // The phone app's; a computer's is under "This Mac".
    where: SettingsWhere.phone,
    label: 'About',
    icon: _icon(Lucide.info),
    hue: 'graphite',
    group: 'app',
    summary: (m) => 'Uplink ${m.update.current.isEmpty ? appVersion : m.update.current}',
    page: _about,
  ),
    ];

/// Settings › About › Sealed, end to end: where texts stay and which relay the rest goes through. It named gogho.st's
/// whatever relay the app used (GMFB-25).
String sealedWords(String hubUrl) {
  final u = Uri.tryParse(hubUrl);
  final host = hubUrl == Net.defaultHub || u == null || u.host.isEmpty ? 'gogho.st' : u.host;
  return 'Your texts stay on this phone. Friends, circles and spaces go through ${hubUrl == Net.defaultHub ? 'gogho.st\'s relay' : 'the relay you chose ($host)'}, sealed so it can\'t read them.';
}

/// The version this build is, where Android has not said (the screens drawn in tests).
const appVersion = '0.12.52';

// --- Language ---------------------------------------------------------------------------------------------------------

/// Settings › Language (GMFB-32, lib/l10n/words.dart): Automatic (the device's own where the app has it) or one of
/// the twenty, each named in itself, the one in use ticked.
List<Widget> _language(BuildContext context, SettingsModel m) {
  final app = m.app;
  final chosen = app.choice(Words.key, Words.automatic);
  Widget row(String code, String name, {String? hint}) => SettingRow(
        key: ValueKey('language-$code'),
        label: name,
        hint: hint == null ? null : Text(hint),
        value: chosen == code ? AppIcon(Lucide.check, size: 18, color: context.tokens.color('app-ink')) : null,
        onPress: () => app.set(Words.key, code),
      );
  return [
    PaneSection(
      title: 'Language',
      footer: Text(languageHint(Words.instance.language)),
      children: [
        row(Words.automatic, 'Automatic'.t, hint: Words.languages[Words.meant(Words.automatic)]),
        for (final e in Words.languages.entries) row(e.key, e.value),
      ],
    ),
  ];
}

// --- Appearance -------------------------------------------------------------------------------------------------------

/// Settings › Appearance: the look, the theme, your bubbles' colour and the size of a message's words.
List<Widget> _appearance(BuildContext context, SettingsModel m) {
  final app = m.app;
  final t = context.tokens;
  final palette = PhonePalette.current != null;
  final look = app.look;
  // A look of one's own in use (GMFB-41, lib/custom_theme.dart): it has one brightness, as some of the app's do.
  final own = CustomTheme.used(app);
  return [
    // Looks for the whole app (Matt, 2026-11-16: "spend some time making a few themes for ghost"), above Theme, which
    // only a look with both a light and a dark half has.
    PaneSection(
      title: 'Look',
      footer: const Tr('How the whole app looks. Each look brings its own colour for your bubbles, which you can still change below. Make your own from four colours and a font, and share it as a code or a file.'),
      children: [
        SettingRowBox(child: LookPicker(app: app)),
        // Your own looks (GMFB-41, from the Uplink gap review: "custom CSS-style themes"): made from four colours, or
        // taken in from a code someone shared.
        SettingRow(
          key: const ValueKey('make-own-look'),
          icon: _icon(Lucide.palette),
          label: 'Make your own look',
          hint: const Tr('Choose the background, surface, text and accent colours'),
          onPress: () => push<void>(context, (_) => CustomThemeEditor(app: app)),
        ),
        SettingRow(
          key: const ValueKey('paste-look'),
          icon: _icon(Lucide.clipboardPaste),
          label: 'Paste a look\'s code',
          hint: const Tr('One someone shared with you'),
          onPress: () => pasteTheme(context, app),
        ),
        // A look kept as a file (GMFB-41, "Custom themes as a file you can import/share (colours and fonts)"):
        // saved from the look's own menu or its editor, taken in here.
        if (lookFilesHere)
          SettingRow(
            key: const ValueKey('import-look'),
            icon: _icon(Lucide.folderOpen),
            label: 'Open a look from a file',
            hint: const Tr('A .ghostlook someone sent you, or one you saved'),
            onPress: () => importLook(context, app),
          ),
        // CSS of one's own over the look (GMFB-41; Matt, 2026-11-25: "if I search css or styles i don't see anything
        // in settings"): the label and hint carry the words a search would be made with.
        SettingRow(
          key: const ValueKey('custom-css'),
          icon: _icon(Lucide.braces),
          label: 'Custom CSS',
          hint: Text(CustomCss.on(app) ? 'Your own styles are in use over this theme' : 'Write your own styles over this theme'),
          onPress: () => push<void>(context, (_) => CustomCssEditor(app: app)),
        ),
      ],
    ),
    // What the look in use is drawn with (lib/ui/resource_packs_ui.dart): its own, or one of its packs. A look of
    // one's own has none.
    if (own == null) texturesSection(context, app),
    PaneSection(title: 'Theme', children: [
      if (own != null)
        SettingRow(
          icon: _icon(Lucide.sunMoon),
          label: 'Theme',
          hint: Text('${own.name} is always ${own.dark ? 'dark' : 'light'}, whatever the phone is set to.'),
        )
      else if (look.forced == null)
        SettingRow(
          icon: _icon(Lucide.sunMoon),
          label: 'Theme',
          layout: SettingRowLayout.stacked,
          control: GlacierSegmentedControl(
            fullWidth: true,
            value: app.theme,
            onValueChange: app.setTheme,
            options: [
              const GlacierSegmentedOption(value: 'system', label: Tr('System')),
              const GlacierSegmentedOption(value: 'light', label: Tr('Light')),
              const GlacierSegmentedOption(value: 'dark', label: Tr('Dark')),
            ],
          ),
        )
      else
        SettingRow(
          icon: _icon(Lucide.sunMoon),
          label: 'Theme',
          hint: Text('${look.label} is always ${look.forced}, whatever the phone is set to.'),
        ),
    ]),
    // Dial-Up's transcript has no bubbles and writes your name in its own red, so a colour chosen here would change
    // nothing seen there: not offered while it is the look.
    if (look != Look.dialup)
      PaneSection(
        title: 'Bubbles',
        footer: Text('The colour of your own bubbles in every conversation.${look != Look.ghost ? ' Theme is ${look.label}\'s own.' : ''} Uplink is Ghost Keyboard\'s teal, Ink is the page\'s own black and white${palette ? ', and Wallpaper is the accent Android takes from this phone\'s wallpaper' : ''}. A conversation can have a colour of its own, from the cog at its top.${Sms.remote ? '' : ' Ghost Keyboard offers the same colours for its enter key and keeps in step: choose one here or there and both change.'}'),
        children: [
          SettingRow(
            icon: _icon(Lucide.messageSquare),
            label: 'Your bubbles',
            layout: SettingRowLayout.stacked,
            control: BubbleSwatches(chosen: app.bubble == 'wallpaper' && !palette ? 'white' : app.bubble, onPick: app.setBubble),
          ),
        ],
      ),
    PaneSection(title: 'Text', footer: Text('${Sms.remote || Sms.browser ? 'The size of every word in the app.' : 'The size of every word in the app, on top of the phone\'s own font size.'} Readable draws everything in Atkinson Hyperlegible Next, made so that no two letters look alike: easier for many people with dyslexia or low vision.'), children: [
      // A face for reading (GMFB-41, from the Uplink gap review: "dyslexia font"), over any look's own.
      SettingRow(
        icon: _icon(LucideMore.type),
        label: 'Font',
        layout: SettingRowLayout.stacked,
        control: GlacierSegmentedControl(
          key: const ValueKey('font-choice'),
          fullWidth: true,
          value: app.font,
          onValueChange: app.setFont,
          options: const [
            GlacierSegmentedOption(value: 'default', label: Tr('Default')),
            GlacierSegmentedOption(value: 'readable', label: Tr('Readable')),
          ],
        ),
      ),
      // Every word in the app, 80% to 150% (GMFB-41: "a text-size slider"; lib/ui/text_scale.dart). A size chosen
      // from the four there were before stands until this is moved.
      SettingRow(
        icon: _icon(LucideMore.type),
        label: 'Text size',
        layout: SettingRowLayout.stacked,
        control: Row(children: [
          Expanded(child: TextSizeSlider(key: const ValueKey('text-size'), percent: app.textPercent, onChanged: app.setTextPercent)),
          SizedBox(width: t.space(3)),
          // Its own width, whatever the size chosen: the track must not move under the finger that drags it.
          SizedBox(width: 48, child: Text('${app.textPercent}%', textAlign: TextAlign.end, textScaler: TextScaler.noScaling, style: pageText(t, t.fontSize('sm'), color: t.color('app-ink-3')))),
        ]),
      ),
      SettingRowBox(child: BackgroundPreview(background: ChatBackground.everyChat(app))),
    ]),
  ];
}

// --- Emoji ------------------------------------------------------------------------------------------------------------

/// [set], its font asked for where sets are fetched only once wanted (a browser: [ensureEmojiFont]).
EmojiSet _fetched(EmojiSet set) {
  if (set.family != null) ensureEmojiFont(set.family!);
  return set;
}

List<Widget> _emoji(BuildContext context, SettingsModel m) {
  final t = context.tokens;
  final app = m.app;
  return [
    PaneSection(
      title: 'Emoji set',
      footer: const Tr('How emoji are drawn in this app. What the other person sees is drawn by their own phone.'),
      children: [
        for (final set in offeredEmojiSets)
          SettingRow(
            label: set.name,
            hint: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text(set.about),
              SizedBox(height: t.space(1)),
              // Each row in its own set, whichever is chosen: no fallback but the set's (or the phone's).
              Row(mainAxisSize: MainAxisSize.min, children: [
                for (final e in emojiSample)
                  Padding(
                    padding: EdgeInsetsDirectional.only(end: t.space(2)),
                    child: Text(e, style: TextStyle(inherit: false, fontFamily: set.family, fontFamilyFallback: const [], fontSize: t.lenOf('1.35rem'), height: 1.3, color: t.color('app-ink'))),
                  ),
              ]),
            ]),
            // In a browser each set is fetched as its row is first shown, and the one drawn where none was chosen is ticked.
            control: Pick(checked: PlatformInfo.isWeb ? emojiFamilyOf(app.emoji) == _fetched(set).family : app.emoji == set.id, label: 'Use ${set.name} emoji', onPress: () => app.setEmoji(set.id)),
          ),
      ],
    ),
    PaneSection(title: 'In a conversation', children: [
      SettingRow(
        icon: _icon(LucideMore.smile),
        label: 'Large emoji',
        hint: const Tr('A message of one to three emoji and nothing else is drawn large, with no bubble.'),
        control: GlacierSwitch(checked: app.bigEmoji, onCheckedChange: (v) => app.setFlag('big_emoji', v), ariaLabel: 'Large emoji'),
      ),
    ]),
  ];
}

// --- Effects ----------------------------------------------------------------------------------------------------------

/// Settings › Effects: the switch for message effects, and every effect listed.
List<Widget> _effects(BuildContext context, SettingsModel m) {
  final app = m.app;
  return [
    PaneSection(children: [
      SettingRow(
        icon: _icon(Lucide.sparkles),
        label: 'Message effects',
        hint: const Tr('Confetti for "Congratulations", balloons for "Happy birthday", and more, as a message arrives or is sent.'),
        control: GlacierSwitch(checked: app.effects, onCheckedChange: app.setEffects, ariaLabel: 'Message effects'),
      ),
    ]),
    PaneSection(
      title: 'Every effect',
      description: const Tr('Each with what sets it off. Tap one to play it here.'),
      footer: const Tr('An effect plays once, as its message arrives or is sent while the conversation is open. A message\'s menu can play it again.'),
      children: [
        for (final effect in ScreenEffect.values)
          SettingRow(
            label: effectLabel(effect),
            hint: Text(effectTriggers(effect)),
            onPress: () => EffectsHost.maybeOf(context)?.play(effect),
          ),
      ],
    ),
  ];
}

// --- Sounds -----------------------------------------------------------------------------------------------------------

/// The name of the sound chosen; the first one's where [id] is none of them.
String _choiceName(List<SoundChoice> choices, String id) => choices.firstWhere((c) => c.id == id, orElse: () => choices.first).label;

/// The app's sounds (lib/sounds.dart; Matt, 2026-11-16: "give me the options to pick from for the calling and
/// notification sounds", and "for most UI sounds (outside of calling and new messages) play them at 33% volume by
/// default").
List<Widget> _sounds(BuildContext context, SettingsModel m) {
  final s = Sounds.instance;
  final t = context.tokens;
  return [
    PaneSection(children: [
      SettingRow(
        icon: _icon(Lucide.audioLines),
        label: 'Sounds',
        hint: const Tr('A message in and out, friends, calls, muting, and the phone and computer connecting.'),
        control: GlacierSwitch(checked: s.on, onCheckedChange: s.setOn, ariaLabel: 'Sounds'),
      ),
    ]),
    PaneSection(
      title: 'New message',
      description: Text(Sms.remote ? 'Played as a text comes in. Tap one to hear it.' : 'Played as a text comes in, and the sound of its notification. Tap one to hear it.'),
      children: [
        for (final c in Sounds.messageChoices)
          SettingRow(
            icon: _icon(Lucide.messageSquare),
            label: c.label,
            control: Pick(checked: s.message == c.id, label: 'Use ${c.label} for new messages', onPress: () => s.setMessage(c.id)),
            onPress: () => s.setMessage(c.id),
          ),
      ],
    ),
    PaneSection(
      title: 'Ringing',
      description: const Tr('Played while a group calls you. Tap one to hear it.'),
      children: [
        for (final c in Sounds.ringChoices)
          SettingRow(
            icon: _icon(Lucide.bell),
            label: c.label,
            control: Pick(checked: s.ring == c.id, label: 'Use ${c.label} for ringing', onPress: () => s.setRing(c.id)),
            onPress: () => s.setRing(c.id),
          ),
      ],
    ),
    PaneSection(
      title: 'Everything else',
      footer: Text('How loud the other sounds are next to a new message and ringing: ${Sounds.quietDefault}% unless changed.'),
      children: [
        SettingRowBox(
          child: Row(children: [
            Expanded(child: VolumeSlider(value: s.quiet / 100, max: 1, label: 'Loudness of the other sounds', onChanged: (x) => s.setQuiet((x * 100).round()))),
            SizedBox(width: t.space(3)),
            SizedBox(width: t.lenOf('3rem'), child: Text('${s.quiet}%', textAlign: TextAlign.end, style: pageText(t, t.fontSize('sm'), color: t.color('app-ink-3')))),
          ]),
        ),
        SettingRow(icon: _icon(Lucide.volume2), label: 'Hear it', hint: const Tr('The sound of a reaction, at this loudness.'), onPress: () => s.play(UiSound.reaction)),
      ],
    ),
  ];
}

// --- Messages ---------------------------------------------------------------------------------------------------------

/// Settings › Messages: RCS where it is offered, how writing behaves, summaries of unread conversations, and
/// whether reaction texts are hung on their messages.
List<Widget> _messages(BuildContext context, SettingsModel m) {
  final app = m.app;
  return [
    // RCS through Google Messages, on the phone (lib/ui/rcs_setup.dart; Matt, 2026-11-15: "add a button under messages
    // settings to setup RCS if on an android phone and walk the user through how to enable the rcs sidecar").
    if (!Sms.remote)
      PaneSection(title: 'RCS', children: [
        SettingRow(
          icon: _icon(Lucide.messageSquare),
          label: m.status?.beside ?? false ? 'RCS is on, through Google Messages' : 'Set up RCS',
          hint: Text(m.status?.beside ?? false
              ? 'Uplink works beside Google Messages: RCS chats and texts in Uplink, Uplink\'s notifications. Open to check each step.'
              : 'Typing dots, read receipts, full-size pictures and group chats over the internet, through Google Messages. A few steps, one at a time.'),
          onPress: () => push(context, (_) => const RcsSetupScreen()),
        ),
        // Google Messages' web connection on the phone (lib/ui/gm_web_screen.dart; Matt, 2026-11-15: "Can you build the
        // on phone google messages connection too?").
        SettingRow(
          icon: _icon(Lucide.link),
          label: 'Google Messages connection',
          hint: const Tr('Pictures, reactions and read marks for RCS chats in Uplink, without Google Messages\' notifications. Paired once with another screen\'s help.'),
          onPress: () => push(context, (_) => const GmWebScreen()),
        ),
        // The same on a Mac or a PC, kept running (lib/ui/gm_guide_screen.dart; Matt, 2026-11-15: "Tell me how to setup
        // the sidecar on mac and PC in a guide found in settings").
        SettingRow(
          icon: _icon(Lucide.laptop),
          label: 'On a Mac or PC',
          hint: const Tr('How to run the Google Messages helper on your computer, and keep it running.'),
          onPress: () => push(context, (_) => const GmGuideScreen()),
        ),
      ]),
    PaneSection(title: 'Writing', children: [
      SettingRow(
        icon: _icon(LucideMore.keyboard),
        label: 'Enter sends',
        hint: const Tr('The keyboard\'s Enter key sends the message. Off, it starts a new line.'),
        control: GlacierSwitch(checked: app.enterSends, onCheckedChange: (v) => app.setFlag('enter_sends', v), ariaLabel: 'Enter sends'),
      ),
      // Turned off by "Delete, and don't ask again" on the question a slide asks (lib/ui/inbox_ui.dart deleteAskOff).
      SettingRow(
        icon: _icon(Lucide.trash2),
        label: 'Ask before a slide deletes',
        hint: const Tr('A conversation slid all the way asks first. Off, it is deleted straight away.'),
        control: GlacierSwitch(checked: app.flag('delete_ask', fallback: true), onCheckedChange: (v) => app.setFlag('delete_ask', v), ariaLabel: 'Ask before a slide deletes'),
      ),
    ]),
    // Summaries of unread conversations by the phone's own model (lib/summaries.dart; Matt, 2026-11-14: "Use a local
    // AI to summarize unread message conversations like apple does").
    PaneSection(
      title: 'Summaries',
      footer: Text(switch (Summaries.instance.status) {
        // A Mac's or an iPhone's are Apple Intelligence's (lib/local_ai.dart, macos/Runner/LocalAi.swift).
        'available' => 'Several unread texts in a row, or one long one, are summed up in a line in the list, marked with a sparkle. They are made on this ${Sms.remote ? 'device by Apple Intelligence' : 'phone by Android\'s own model'}; nothing is sent anywhere.',
        'downloading' || 'downloadable' => Sms.remote ? 'Apple Intelligence is still fetching its model. Summaries begin once it is here; nothing is sent anywhere.' : 'Android is fetching its on-phone model for this, over Wi-Fi. Summaries begin once it is here; nothing is sent anywhere.',
        'unknown' => 'Looking for this device\'s own model.',
        _ => Sms.remote ? 'Summaries are made by Apple Intelligence on a Mac or an iPhone that has it switched on, or by Android\'s own model on your phone.' : 'This phone has no on-phone model for summaries (Android\'s Gemini Nano, on newer phones). The list shows the texts as they came.',
      }),
      children: [
        SettingRow(
          icon: _icon(Lucide.sparkles),
          label: 'Summarize unread conversations',
          disabledReason: const {'available', 'downloading', 'downloadable', 'unknown'}.contains(Summaries.instance.status) ? null : Sms.remote ? 'Not on this device' : 'Not on this phone',
          control: GlacierSwitch(checked: Summaries.chosen(app), onCheckedChange: (v) => app.setFlag('summaries', v), ariaLabel: 'Summarize unread conversations'),
        ),
      ],
    ),
    PaneSection(
      title: 'Reactions',
      footer: const Tr('Other phones send a reaction as a text, like Loved “See you at 7”. On, it is drawn as a ❤️ on the message it names. Off, every text is shown as it came.'),
      children: [
        SettingRow(
          icon: _icon(Lucide.messageSquare),
          label: 'Attach reactions to messages',
          control: GlacierSwitch(checked: app.foldReactions, onCheckedChange: (v) => app.setFlag('fold_reactions', v), ariaLabel: 'Attach reactions to messages'),
        ),
      ],
    ),
  ];
}

// --- Receipts ---------------------------------------------------------------------------------------------------------

/// Settings › Receipts: delivery reports and read receipts, and what each tick beside a message means.
List<Widget> _receipts(BuildContext context, SettingsModel m) {
  final app = m.app;
  return [
    PaneSection(
      title: 'Ask for',
      footer: const Tr('Delivered is your carrier saying the message reached the other phone. Read exists only for picture and group messages, and only from phones that answer; a plain text has no way to say it was read.'),
      children: [
        SettingRow(
          icon: _icon(Lucide.check),
          label: 'Delivery reports',
          hint: const Tr('On every message you send.'),
          control: GlacierSwitch(checked: app.flag('delivery_reports'), onCheckedChange: (v) => app.setFlag('delivery_reports', v), ariaLabel: 'Delivery reports'),
        ),
        SettingRow(
          icon: _icon(Lucide.checkCheck),
          label: 'Read receipts',
          hint: const Tr('On picture and group messages.'),
          control: GlacierSwitch(checked: app.readReports, onCheckedChange: app.setReadReports, ariaLabel: 'Read receipts'),
        ),
      ],
    ),
    PaneSection(title: 'The ticks', children: [
      SettingRow(icon: _icon(Lucide.clock), label: 'A clock', hint: const Tr('Sending.')),
      SettingRow(icon: _icon(Lucide.check), label: 'One tick', hint: const Tr('Sent.')),
      SettingRow(icon: _icon(Lucide.checkCheck), label: 'Two ticks', hint: const Tr('Delivered. In colour: read.')),
      SettingRow(icon: _icon(Lucide.lock), label: 'A lock', hint: const Tr('It went encrypted (Settings › Encryption).')),
    ]),
  ];
}

// --- Notifications ----------------------------------------------------------------------------------------------------

/// Settings › Notifications › Bubbles' switch (android Bubbles.PREF): on unless switched off.
const bubblesKey = 'notif_bubbles';

/// Android's own bubble setting for the app ([SmsStatus.bubbles]), in a word or two.
String bubbleSettingWords(String? system) => switch (system) {
      'all' => 'All conversations',
      'selected' => 'Chosen conversations',
      'none' => 'Off',
      _ => '',
    };

/// What Android's bubble setting means for Uplink's bubbles, under its row.
String bubbleSettingHint(String? system, {required bool on}) {
  if (!on) return 'Uplink\'s bubbles are switched off above. This is Android\'s page for them, where it decides which conversations may bubble.';
  return switch (system) {
    'all' => 'Every conversation can bubble. Tap to change it on Android\'s page.',
    'none' => 'Android has bubbles off for Uplink, so none show. Tap to turn them on.',
    _ => 'Only the conversations you choose bubble: press a notification\'s bubble button. Tap to let every one bubble.',
  };
}

/// What the Language row says it is set to: Automatic, or the language chosen, named in itself.
String languageWords(String choice) => choice == Words.automatic || !Words.languages.containsKey(choice) ? 'Automatic'.t : Words.languages[choice]!;

/// Under the Language row: what changes, and what stays English.
String languageHint(String language) => language == 'en'
    ? 'The words of the app. Automatic follows your device\'s language where the app has it.'.t
    : 'The words of the app. What it puts together as it goes, like a name or a count, stays in English for now.'.t;

/// Settings › Notifications › While the app is closed (GMFB-28; lib/keep_running.dart): the switch that keeps the app
/// connected after its screen is closed, so a friend's call rings, and beside it, once it is on, whether Android lets
/// the app run while the phone sleeps ([battery]; null where that can't be told), with a press that asks.
PaneSection reachSection(AppState app, {required bool? battery, required void Function() askBattery}) {
  final on = KeepRunning.wanted(app);
  return PaneSection(
    title: 'While the app is closed',
    children: [
      SettingRow(
        key: const ValueKey('stay-reachable'),
        icon: _icon(LucideMore.phoneCall),
        label: KeepRunning.reachLabel,
        hint: const Text(KeepRunning.reachHint),
        control: GlacierSwitch(
          checked: on,
          ariaLabel: KeepRunning.reachLabel,
          onCheckedChange: (v) {
            app.setFlag(KeepRunning.key, v);
            // Asked at once where Android would hold the app back: without its leave a call can't ring on a sleeping phone.
            if (v && battery == false) askBattery();
          },
        ),
      ),
      if (on && battery != null)
        SettingRow(
          key: const ValueKey('stay-reachable-sleep'),
          icon: _icon(Lucide.sunMoon),
          label: KeepRunning.sleepLabel,
          hint: Text(battery ? KeepRunning.sleepAllowedHint : KeepRunning.sleepHint),
          value: Text(battery ? 'Allowed' : 'Not allowed'),
          onPress: battery ? null : askBattery,
        ),
    ],
  );
}

List<Widget> _notifications(BuildContext context, SettingsModel m) {
  final app = m.app;
  final s = m.status;
  return [
    PaneSection(title: 'Android', children: [
      SettingRow(
        icon: _icon(Lucide.bell),
        label: 'Notifications',
        hint: s != null && !s.notifications ? const Tr('Android isn\'t letting this app notify you. Tap to allow it.') : null,
        value: Text(s == null ? '' : (s.notifications ? 'Allowed' : 'Off')),
        onPress: s == null || s.notifications
            ? null
            : () async {
                await Sms.instance.requestPermissions();
                m.refresh();
              },
      ),
      SettingRow(
        icon: _icon(LucideMore.vibrate),
        label: 'Sound and vibration',
        hint: const Tr('Android\'s own page for this app: the sound, vibration, the lock screen and Do Not Disturb.'),
        onPress: () => Sms.instance.notificationSettings(),
      ),
    ]),
    // A friend's call ringing while the app is closed (GMFB-28): an Android phone's own choice. Asked again as the app
    // comes back from Android's question (SettingsScreen.didChangeAppLifecycleState).
    if (s != null && !Sms.remote && PlatformInfo.isAndroid) reachSection(app, battery: s.battery, askBattery: () => Sms.instance.askBattery()),
    PaneSection(
      title: 'What a notification shows',
      footer: const Tr('A conversation you muted arrives without a notification (long press it in the list).'),
      children: [
        SettingRow(
          icon: _icon(Lucide.eye),
          label: 'Message previews',
          hint: const Tr('The message\'s words. Off, a notification says "New message" and who it is from.'),
          control: GlacierSwitch(checked: app.flag('notif_preview'), onCheckedChange: (v) => app.setFlag('notif_preview', v), ariaLabel: 'Message previews'),
        ),
        SettingRow(
          icon: _icon(Lucide.copy),
          label: 'Copy code button',
          hint: const Tr('A text with a sign-in code gets a button that copies it.'),
          control: GlacierSwitch(checked: app.flag('notif_code'), onCheckedChange: (v) => app.setFlag('notif_code', v), ariaLabel: 'Copy code button'),
        ),
        // Matt, 2026-11-19: "Add mentions support to spaces and circles with the @user prefix".
        SettingRow(
          icon: _icon(Lucide.atSign),
          label: 'Mentions in spaces',
          hint: const Tr('A notification when someone writes @ and your name in a space or a circle. A space\'s other messages don\'t notify.'),
          control: GlacierSwitch(checked: app.flag('notif_mentions'), onCheckedChange: (v) => app.setFlag('notif_mentions', v), ariaLabel: 'Mentions in spaces'),
        ),
        // Matt, 2026-11-19: "add join notifications for memebers in circles".
        SettingRow(
          icon: _icon(Lucide.userPlus),
          label: 'Joins in circles',
          hint: const Tr('Told when someone new joins a circle you\'re in.'),
          control: GlacierSwitch(checked: app.flag('notif_joins'), onCheckedChange: (v) => app.setFlag('notif_joins', v), ariaLabel: 'Joins in circles'),
        ),
      ],
    ),
    // Conversation bubbles (android Bubbles.kt, GMFB-8, from @kevin: "It would be nice to have message bubbles that just
    // sit on the side of the screen like google messages and facebook messenger"; Matt asked for it to be built). On
    // Android 11 and later, where the phone has them; Android's own setting decides which conversations may bubble.
    if (s?.bubbles != null)
      PaneSection(
        title: 'Bubbles',
        footer: const Tr('A conversation\'s notification has a bubble button: press it to keep that conversation on the side of the screen. Drag a bubble to the X to put it away.'),
        children: [
          SettingRow(
            icon: _icon(LucideMore.messageCircle),
            label: 'Conversation bubbles',
            hint: const Tr('A conversation can sit on the side of the screen as a bubble and open over whatever you\'re doing.'),
            control: GlacierSwitch(checked: app.flag(bubblesKey), onCheckedChange: (v) => app.setFlag(bubblesKey, v), ariaLabel: 'Conversation bubbles'),
          ),
          SettingRow(
            icon: _icon(Lucide.settings),
            label: 'Android\'s bubble setting',
            hint: Text(bubbleSettingHint(s!.bubbles, on: app.flag(bubblesKey))),
            value: Text(bubbleSettingWords(s.bubbles)),
            // Asked again as the app comes back from Android's page (SettingsScreen.didChangeAppLifecycleState).
            onPress: () => Sms.instance.bubbleSettings(),
          ),
        ],
      ),
    // Beside Google Messages (android GmBridge.kt; Matt, 2026-11-15: "I can turn off notifications from google messages
    // or hide them and proxy everything through ghost").
    if (m.status?.beside ?? false)
      PaneSection(
        title: 'Beside Google Messages',
        footer: const Tr('Keep Google Messages\' notifications allowed (set them to Silent): Uplink reads them to see RCS chats. Turned off completely, Uplink sees nothing new.'),
        children: [
          SettingRow(
            icon: _icon(Lucide.bell),
            label: 'Uplink\'s notifications in place of Google Messages\'',
            hint: const Tr('Each Google Messages notification is hidden as it comes and Uplink shows its own. Replying from it goes through Google Messages, as RCS where the chat is RCS.'),
            control: GlacierSwitch(checked: app.flag('gm_proxy', fallback: true), onCheckedChange: (v) => app.setFlag('gm_proxy', v), ariaLabel: 'Uplink\'s notifications in place of Google Messages\''),
          ),
          SettingRow(
            icon: _icon(LucideMore.vibrate),
            label: 'Make Google Messages\' silent',
            hint: const Tr('Which of its notifications still make a sound, as of their last message, each with the way to silence it: its Incoming messages, and any conversation with a sound of its own.'),
            onPress: () => push(context, (_) => const RcsSetupScreen()),
          ),
        ],
      ),
  ];
}

// --- Encryption -------------------------------------------------------------------------------------------------------

/// Settings › Encryption: what it is and isn't, finding people who have the app, where it stands with each person,
/// and this phone's key.
List<Widget> _encryption(BuildContext context, SettingsModel m) {
  String stateLine(E2eState e) => switch (e.state) {
        'on' => e.verified ? 'On · verified' : 'On · not verified yet',
        'pending' => e.changed ? 'Sent a NEW key: review it' : 'Wants to encrypt: waiting for your yes',
        'offered' => 'Your key was sent: waiting for them',
        _ => 'Off',
      };
  return [
    PaneSection(
      title: 'What it is',
      children: [
        SettingRow(
          icon: _icon(Lucide.lock),
          label: 'Encrypted texts',
          hint: const Tr('With someone who also has Uplink, your texts go sealed so only your two phones can read them. Not your carrier, and not another app on either phone.'),
        ),
        SettingRow(
          icon: _icon(Lucide.info),
          label: 'What it doesn\'t cover',
          hint: const Tr('One person at a time: group conversations and pictures go as they always have. The keys travel by text, so compare the safety number in person or on a call to be sure nobody swapped one. There is no forward secrecy: this is not Signal\'s protocol. A sealed text is longer, so it can cost more texts. To any other app a sealed text is a line of letters.'),
        ),
      ],
    ),
    // The hello that finds people and the key are the phone's: a computer leaves them to it, and says so.
    if (!Sms.remote)
    PaneSection(
      title: 'Finding each other',
      footer: const Tr('The hello is three invisible characters at the end of a text, now and then, and only where they add nothing to what the text costs. Every other app draws them as nothing. Nothing else is sent: encryption starts only when one of you taps Turn on, which sends a key, and the other accepts. The safety number is how you check nobody is in the middle.'),
      children: [
        SettingRow(
          icon: _icon(Lucide.sparkles),
          label: 'Find people who have Uplink',
          hint: const Tr('When someone you text has Uplink too, the two phones recognise each other, and the conversation shows a banner offering to encrypt it. Off, your phone says nothing of itself, and you turn encryption on from a conversation\'s header.'),
          control: GlacierSwitch(checked: m.app.flag('e2e_detect'), onCheckedChange: (v) => m.app.setFlag('e2e_detect', v), ariaLabel: 'Find people who have Uplink'),
        ),
      ],
    ),
    PaneSection(
      title: 'People',
      footer: m.e2e.isEmpty ? const Tr('Nobody yet. A conversation with someone who has Uplink offers it in a banner, or open any conversation, tap the name at the top, and choose Encryption.') : null,
      children: [
        for (final e in m.e2e)
          SettingRow(
            icon: _icon(e.on ? (e.verified ? Lucide.shieldCheck : Lucide.lock) : Lucide.keyRound),
            label: (e.person ?? Person(address: e.address)).label,
            hint: Text(stateLine(e)),
            onPress: () => showEncryptionChoices(context, e.person ?? Person(address: e.address), e, m.refresh),
          ),
      ],
    ),
    if (Sms.remote)
      PaneSection(children: [
        SettingRow(
          icon: _icon(Lucide.keyRound),
          label: 'Your phone holds the key',
          hint: const Tr('The key, a new one, and finding people who have Uplink are set on the phone, under Settings › Encryption.'),
        ),
      ]),
    if (!Sms.remote)
    PaneSection(
      title: 'This phone',
      footer: const Tr('A new key ends encryption with everyone. Each conversation is exchanged again to go on, and texts sealed under the old key can no longer be opened.'),
      children: [
        SettingRow(
          icon: _icon(Lucide.keyRound),
          label: 'This phone\'s key',
          hint: Text(m.myKey == null ? 'Made the first time you send your key to someone.' : 'A short name for it. The private half never leaves this phone.'),
          value: m.myKey == null ? null : Text(m.myKey!),
        ),
        SettingRow(
          icon: _icon(Lucide.rotateCcw),
          label: 'New key for this phone',
          disabledReason: m.myKey == null ? 'There is no key yet.' : null,
          onPress: () => showChoices(
            context,
            title: 'Make a new key for this phone? Encryption ends with everyone until each conversation is exchanged again, and texts sealed under the old key can\'t be opened afterwards.',
            choices: [
              Choice('Make a new key', Lucide.rotateCcw, () async {
                await Sms.instance.e2eReset();
                await m.refresh();
                if (context.mounted) toast(context, 'This phone has a new key');
              }, danger: true),
            ],
          ),
        ),
      ],
    ),
  ];
}

// --- Blocked: numbers, and Telegram and Signal people (lib/ui/blocking.dart) -----------------------------------------

List<Widget> _blocked(BuildContext context, SettingsModel m) => const [BlockedList()];

// --- Android ----------------------------------------------------------------------------------------------------------

/// 12345 as 12,345.
String _thousands(int n) => n.toString().replaceAllMapped(RegExp(r'(?<=\d)(?=(\d{3})+$)'), (_) => ',');

/// Texts off: what Uplink does without them, and the same step as the walkthrough's to turn them on.
List<Widget> _texts(BuildContext context, SettingsModel m) => [
      PaneSection(
        title: 'Texts are off',
        description: const Tr('Uplink works without your texts: friends, circles, Telegram and Signal. Turn texts on to read and send your texts here too, as your texting app or beside Google Messages.'),
        children: [
          SettingRowBox(
            child: Padding(
              padding: EdgeInsets.all(context.tokens.space(3)),
              child: TextsStep(
                hue: context.tokens.color('app-accent'),
                onDone: () {
                  Sms.textsOff = false;
                  toast(context, 'Texts are on');
                  m.refresh();
                },
              ),
            ),
          ),
        ],
      ),
    ];

/// Settings › Android: how texts reach this phone (beside Google Messages, or coming from another app), picture
/// messages and a report on them, Android's store of texts, and what Android has allowed.
List<Widget> _android(BuildContext context, SettingsModel m) {
  final s = m.status;
  final a = m.arriving;
  // What Android's store holds, said so a person can tell "nothing was read" from "there was little to read".
  final held = a.texts == null
      ? null
      : '${_thousands(a.texts!)} ${a.texts == 1 ? 'text' : 'texts'}'
          '${a.pictures == null ? '' : ', ${_thousands(a.pictures!)} picture ${a.pictures == 1 ? 'message' : 'messages'}'}'
          '${a.recentTexts == null ? '' : ' · ${_thousands(a.recentTexts!)} in the last 30 days'}';
  return [
    // Beside Google Messages (android GmBridge.kt; Matt, 2026-11-15: "I'd like to have a way that people can reliably
    // get text in and out of ghost without needing to switch the default messaging app").
    if (s != null && (s.beside || (!s.isDefault && s.gmInstalled)))
      PaneSection(
        title: 'Beside Google Messages',
        description: const Tr('Google Messages is the default SMS app and keeps RCS. Uplink reads your texts from Android and RCS chats from Google Messages\' notifications, and replies through it.'),
        footer: const Tr('Not seen: chats muted in Google Messages, or open there when a message comes. RCS chats from before aren\'t brought over, and RCS pictures stay in Google Messages. New group chats and pictures open Google Messages to send.'),
        children: [
          SettingRow(
            icon: _icon(s.bridge ? Lucide.circleCheck : Lucide.triangleAlert),
            label: s.bridge ? 'Reading Google Messages\' notifications' : 'Notification access is off',
            hint: Text(s.bridge ? 'Only Google Messages\' notifications are read. Every other app\'s are ignored.' : 'Without it RCS chats don\'t reach Uplink. Turn it on for Uplink.'),
            onPress: () => Sms.instance.openBridgeAccess(),
          ),
          SettingRow(
            icon: _icon(Lucide.rotateCcw),
            label: 'Make Uplink the default instead',
            hint: const Tr('Everything then goes through Uplink, pictures and group chats too, and RCS is turned off for your number.'),
            onPress: () => Sms.instance.openDefaultApps(),
          ),
        ],
      ),
    if (a.rcsLikely && !(s?.beside ?? false))
      PaneSection(
        title: 'Coming from ${a.app}',
        description: Text('Android can\'t tell this app whether RCS chats are on for your number. ${a.app} is on this phone, and RCS chats are on there unless you turned them off.'),
        footer: const Tr('After RCS is off, people\'s phones go back to sending you texts. It can take a few minutes to a few hours for their phones to notice.'),
        children: [
          SettingRow(
            icon: _icon(Lucide.triangleAlert),
            label: 'Texts from some people not arriving',
            hint: Text('While RCS chats are on in ${a.app}, people who use RCS keep sending you chats there, not texts. They never reach this app. Turn RCS chats off one of the two ways below.'),
          ),
          SettingRow(
            icon: _icon(Lucide.keyRound),
            label: 'Turn RCS off with a code',
            hint: const Tr('Google\'s page asks for your number and texts you a six-digit code. The text arrives here. Type the code there and RCS is off for your number. No need to switch apps.'),
            onPress: () => Sms.instance.openRcsOff(),
          ),
          SettingRow(
            icon: _icon(Lucide.rotateCcw),
            label: 'Or turn it off in ${a.app}',
            hint: Text('Make ${a.app} the default SMS app again here, open its settings, switch off RCS chats, then come back and make Uplink the default.'),
            onPress: () => Sms.instance.openDefaultApps(),
          ),
          SettingRow(
            icon: _icon(Lucide.messageSquare),
            label: 'Your old chats',
            hint: Text('RCS chats are kept inside ${a.app}, where Android lets no other app read them. They are not deleted: they show again whenever ${a.app} is the default. Texts and picture messages are Android\'s, and all of them show here.'
                '${a.samsungChats != null && a.samsungChats! > 0 ? ' Samsung Messages is keeping ${_thousands(a.samsungChats!)} RCS chat messages.' : ''}'),
          ),
        ],
      ),
    // Picture messages: what would stop them, how the last ones went, and all of it to copy (Matt, 2026-11-13: "It
    // seems like picture sending is also not working at all almost like MMS isn't working").
    PaneSection(
      title: 'Picture messages',
      description: const Tr('Pictures, stickers and group messages travel as picture messages (MMS), over mobile data even when the phone is on Wi-Fi.'),
      footer: const Tr('A picture message that fails says why under it in the conversation. If they keep failing, copy the report and send it to whoever is helping.'),
      children: [
        SettingRow(
          icon: _icon(m.mms.obstacle == null ? Lucide.image : Lucide.triangleAlert),
          label: m.mms.obstacle == null ? 'Nothing seen to stop them' : 'They can\'t go just now',
          hint: Text(m.mms.obstacle == null
              ? 'Mobile data is ${m.mms.dataOn == null ? 'not reported' : 'on'}${m.mms.carrier == null ? '' : ' with ${m.mms.carrier}'}'
                  '${m.mms.maxBytes == null ? '' : ', which carries up to ${m.mms.maxBytes! ~/ 1024} KB a message'}.'
              : '${m.mms.obstacle}.'),
        ),
        if (m.mms.lastSend != null)
          SettingRow(icon: _icon(m.mms.lastSend!.ok ? Lucide.check : Lucide.circleAlert), label: 'Last one sent', hint: Text('${m.mms.lastSend!.ok ? 'Went' : 'Did not go'}: ${m.mms.lastSend!.detail} · ${listWhen(m.mms.lastSend!.at)}')),
        if (m.mms.lastDownload != null)
          SettingRow(icon: _icon(m.mms.lastDownload!.ok ? Lucide.check : Lucide.circleAlert), label: 'Last one received', hint: Text('${m.mms.lastDownload!.ok ? 'Came' : 'Did not come'}: ${m.mms.lastDownload!.detail} · ${listWhen(m.mms.lastDownload!.at)}')),
        if (m.mms.waiting > 0)
          SettingRow(
            icon: _icon(Lucide.rotateCcw),
            label: '${m.mms.waiting} waiting to be fetched',
            hint: const Tr('Announced by the carrier and not yet fetched. They are asked for again each time the app opens; tap to ask now.'),
            onPress: () async {
              final n = await Sms.instance.mmsRetry();
              if (context.mounted) toast(context, n == 0 ? 'Already being fetched' : 'Asking for $n again');
            },
          ),
        SettingRow(
          icon: _icon(Lucide.copy),
          label: 'Copy a report',
          hint: const Tr('The lines above as text. No messages, names or numbers are in it.'),
          onPress: () async {
            await Clipboard.setData(ClipboardData(text: m.mms.report(appVersion)));
            if (context.mounted) toast(context, 'Report copied');
          },
        ),
      ],
    ),
    PaneSection(
      title: 'Android\'s store of texts',
      footer: Text(a.recentTexts != null && a.rcsLikely && a.recentTexts! < 10
          ? 'Few of your recent messages are texts, so most of your chats were probably RCS. Those are in ${a.app}.'
          : 'What this app reads and shows. If these numbers are right and the list is not, pull the list down to read it again.'),
      children: [
        SettingRow(icon: _icon(Lucide.archive), label: 'Held on this phone', hint: Text(held ?? 'Android hasn\'t said. It says once this is the default SMS app.')),
        if (a.lastReceived != null) SettingRow(icon: _icon(Lucide.clock), label: 'Last text received', value: Text('${listWhen(a.lastReceived!)}${listWhen(a.lastReceived!) == clock(a.lastReceived!) ? '' : ', ${clock(a.lastReceived!)}'}')),
      ],
    ),
    if (a.sideloaded)
      PaneSection(
        title: 'Until it is on the Play Store',
        footer: const Tr('Android does this to every app installed from a file. It is asked once.'),
        children: [
          SettingRow(
            icon: _icon(LucideMore.shieldCheck),
            label: 'Allow restricted settings',
            hint: const Tr('If Android says a setting is restricted or unavailable (the default SMS app, a permission), open Android\'s page for Uplink, tap ⋮ at the top, and choose Allow restricted settings. Then try again.'),
            onPress: () => Sms.instance.openAppInfo(),
          ),
        ],
      ),
    PaneSection(
      title: 'What Android has allowed',
      footer: const Tr('Your messages are kept by Android, not by this app: every one is still there if you make another app the default.'),
      children: [
        SettingRow(
          icon: _icon(Lucide.messageSquare),
          label: 'Default SMS app',
          hint: const Tr('Only the default app may send texts and is handed the ones that arrive.'),
          value: Text(s == null ? '' : (s.isDefault ? 'Yes' : 'No')),
          onPress: s == null || s.isDefault
              ? null
              : () async {
                  await Sms.instance.requestDefault();
                  m.refresh();
                },
        ),
        SettingRow(
          icon: _icon(Lucide.users),
          label: 'Contacts',
          // Plugins from other developers see only strangers, which can't be told from contacts without it (lib/plugins/
          // pack/format.dart packSees).
          hint: const Tr('Names and photos in place of numbers. Plugins from other developers see nothing without it, as they can\'t tell your contacts from strangers.'),
          value: Text(s == null ? '' : (s.contacts ? 'Allowed' : 'Off')),
          onPress: s == null || s.contacts
              ? null
              : () async {
                  await Sms.instance.requestPermissions();
                  m.refresh();
                },
        ),
        SettingRow(
          icon: _icon(Lucide.phone),
          label: 'Phone number',
          hint: const Tr('So Android can say this phone\'s number, for group messages.'),
          value: Text(s == null ? '' : (s.phone ? 'Allowed' : 'Off')),
          onPress: s == null || s.phone
              ? null
              : () async {
                  await Sms.instance.requestPermissions();
                  m.refresh();
                },
        ),
      ],
    ),
  ];
}

// --- Ghost Keyboard ---------------------------------------------------------------------------------------------------

/// Settings › Ghost Keyboard: offering sign-in codes from texts to Ghost Keyboard, and why that is needed.
List<Widget> _keyboard(BuildContext context, SettingsModel m) {
  final app = m.app;
  return [
    PaneSection(
      title: 'Sign-in codes',
      footer: Text(m.keyboardHere
          ? 'Ghost Keyboard is on this phone. Its own switch is in its Settings › Row tools.'
          : 'Ghost Keyboard isn\'t on this phone (ghostkbd.com). Nothing is offered to any other app.'),
      children: [
        SettingRow(
          icon: _icon(Lucide.keyRound),
          label: 'Offer sign-in codes to Ghost Keyboard',
          hint: const Tr('When a text arrives with a code, like "Your code is 482913", Ghost Keyboard shows the code above its keys to tap in. Only the code is handed over, for ten minutes, and only to Ghost Keyboard, which is checked by its signature.'),
          control: GlacierSwitch(checked: app.flag('kbd_codes'), onCheckedChange: (v) => app.setFlag('kbd_codes', v), ariaLabel: 'Offer sign-in codes to Ghost Keyboard'),
        ),
      ],
    ),
    PaneSection(title: 'Why', children: [
      SettingRow(
        icon: _icon(Lucide.info),
        label: 'Android keeps codes from keyboards',
        hint: const Tr('A keyboard needs Android\'s permission to receive texts, which newer versions refuse apps from outside a store, and Android 17 holds code texts back from every app but the default SMS app. This app is the default SMS app, so it has the code at once.'),
      ),
    ]),
  ];
}

// --- Updates ----------------------------------------------------------------------------------------------------------

String _host(UpdateState u) => u.source.isEmpty ? 'gogho.st' : u.source.replaceFirst('https://', '');

/// Whether the look for an update failed because the site is not there to ask: no certificate, no such name, nothing
/// answering, or no release published (Updater.kt says `notServing`; the words are what a copy before 0.4.0's
/// native half would say).
bool _notServing(UpdateState u) {
  final e = (u.error ?? '').toLowerCase();
  return e == 'notserving' || e.contains('ssl') || e.contains('handshake') || e.contains('certpath') || e.contains('trust anchor') || e.contains('answered 404') || e.contains('unable to resolve host') || e.contains('failed to connect');
}

/// Where the update stands, in a sentence.
String updateLine(UpdateState u) => switch (u.phase) {
      'checking' => 'Checking ${_host(u)}…',
      'upToDate' => 'Up to date.',
      'available' => '${u.available} is available.',
      'downloading' => 'Downloading ${u.available}${u.progress == null ? '' : ' · ${(u.progress! * 100).round()}%'}',
      'ready' => u.error == 'needsPermission' || !u.canInstall
          ? '${u.available} is downloaded. Allow Uplink to install its own updates, then tap Update now.'
          : '${u.available} is downloaded and ready.',
      'installing' => 'Installing ${u.available}…',
      'failed' => u.error == 'offline'
          ? 'This phone is offline. It will look again the next time the app is in front.'
          : u.error != null && u.error!.contains('not signed by this app')
              ? 'This copy is a test build, signed differently from the release. Install the release from ${_host(u)} once, and it updates itself from then on.'
              : _notServing(u)
                  ? '${_host(u)} isn\'t serving updates yet.'
                  : 'Couldn\'t update: ${u.error ?? 'something went wrong'}',
      'disabled' => 'Updates are off in debug builds.',
      _ => 'Looks for a new version whenever the app is in front.',
    };

/// The same, short, for the row on Settings' list.
String updateSummary(UpdateState u) => switch (u.phase) {
      'upToDate' => 'Up to date',
      'available' || 'ready' => '${u.available} is available',
      'downloading' => 'Downloading ${u.available}',
      'installing' => 'Installing ${u.available}',
      'checking' => 'Checking…',
      'failed' => u.error == 'offline' ? 'Offline' : (_notServing(u) ? '${_host(u)} isn\'t serving updates yet' : 'Couldn\'t update'),
      'disabled' => 'Off in debug builds',
      _ => u.auto ? 'Automatic' : 'Automatic updates off',
    };

/// Settings › Updates: automatic updates, and checking for or installing one now.
List<Widget> _updates(BuildContext context, SettingsModel m) {
  final u = m.update;
  return [
    PaneSection(
      title: 'Updates',
      footer: Text(updateLine(u)),
      children: [
        SettingRow(
          icon: _icon(Lucide.download),
          label: 'Automatic updates',
          hint: Text('New versions from ${_host(u)}, downloaded and installed by the app.'),
          control: GlacierSwitch(
            checked: u.auto,
            ariaLabel: 'Automatic updates',
            onCheckedChange: (on) async {
              await Sms.instance.setAutoUpdate(on);
              m.refresh();
            },
          ),
        ),
        if (u.phase == 'downloading') SettingRowBox(child: GlacierProgressBar(value: (u.progress ?? 0) * 100, ariaLabel: 'Downloading the update')),
        if (u.phase == 'ready' && (!u.canInstall || u.error == 'needsPermission'))
          SettingRow(icon: _icon(LucideMore.settings), label: 'Allow installing updates', onPress: () => Sms.instance.allowInstalls()),
        if (const {'available', 'ready', 'failed'}.contains(u.phase) && u.available != null)
          SettingRow(icon: _icon(Lucide.rotateCcw), label: 'Update now', value: Text(u.available!), onPress: () => Sms.instance.updateInstall())
        else if (!const {'checking', 'downloading', 'installing', 'disabled'}.contains(u.phase))
          SettingRow(icon: _icon(Lucide.refreshCw), label: 'Check for updates', onPress: () => Sms.instance.updateCheck()),
      ],
    ),
  ];
}

// --- About ------------------------------------------------------------------------------------------------------------

/// Settings › Developer (Matt, 2026-11-13: "Maybe it would be good to include a developer setting with copying
/// errors and reporting"): the app's own log of what went wrong and how its picture messages went, to copy or to
/// send to whoever is helping. A phone that is not plugged into a computer has no other way to say.
List<Widget> _developer(BuildContext context, SettingsModel m) {
  final t = context.tokens;
  // The settings' own state: a search builds this page with no app around it.
  final app = m.app;
  // The newest first: what just happened is what is being looked for.
  final lines = m.devLines.reversed.toList();
  return [
    // Developer mode: Settings › API, and what else is for developers (Matt, 2026-11-17: "shows up when developer mode
    // is enabled").
    PaneSection(
      children: [
        SettingRow(
          icon: _icon(Lucide.braces),
          label: 'Developer mode',
          hint: const Tr('Shows Settings › API, Plugins in development below, and the Marketplace\'s In development.'),
          control: GlacierSwitch(checked: app.flag('dev_mode', fallback: false), onCheckedChange: (on) => app.setFlag('dev_mode', on), ariaLabel: 'Developer mode'),
        ),
      ],
    ),
    // Plugins you're making, loaded to try them here (lib/ui/market/dev_plugins.dart; Matt, 2026-11-20: "please add a
    // developer setting for users to be able to manually upload plugins for development testing"). None in an App
    // Store build.
    ...devPluginsPane(context, app),
    // How the app is got round (Matt, 2026-11-19: "work on a unified navigation across the whole app instead of it
    // changing navigations on every page ... give me a setting in developer settings to switch between the different
    // views"; lib/ui/nav_style.dart).
    PaneSection(
      title: 'Navigation',
      description: const Tr('How you get round the app. The two newer ways are the same on every page; the rail adds your circles down the left, as Discord and Slack have.'),
      children: [
        for (final n in NavStyle.values)
          SettingRow(
            key: ValueKey('nav-style-${n.name}'),
            icon: _icon(n.icon),
            label: '${n.label}${n == NavStyle.fallback ? ' (default)' : ''}',
            hint: Text(n.description),
            value: n == NavStyle.of(app) ? AppIcon(Lucide.check, size: 18, color: t.color('app-ink')) : null,
            onPress: () => app.set(NavStyle.pref, n.name),
          ),
      ],
    ),
    PaneSection(
      title: 'Report',
      description: const Tr('What this phone is, how picture messages stand, and the log below, as text.'),
      footer: const Tr('It holds no message\'s words, and anything that looks like a phone number is struck out. It leaves the phone only if you copy or share it.'),
      children: [
        SettingRow(
          icon: _icon(Lucide.copy),
          label: 'Copy the report',
          onPress: () async {
            await Clipboard.setData(ClipboardData(text: m.devReport));
            if (context.mounted) toast(context, 'Report copied');
          },
        ),
        SettingRow(
          icon: _icon(Lucide.send),
          label: 'Share the report',
          hint: const Tr('To an email, a note or another app.'),
          onPress: () => Sms.instance.shareText('Uplink report', m.devReport),
        ),
        SettingRow(
          icon: _icon(Lucide.trash2),
          label: 'Clear the log',
          onPress: lines.isEmpty
              ? null
              : () async {
                  await Sms.instance.devLogClear();
                  await m.refresh();
                  if (context.mounted) toast(context, 'Log cleared');
                },
        ),
      ],
    ),
    PaneSection(
      title: lines.isEmpty ? 'Log' : 'Log · ${lines.length} ${lines.length == 1 ? 'line' : 'lines'}, newest first',
      footer: const Tr('Errors, and each picture message: what it was made into, how large, and what the carrier answered. The last 300 lines are kept.'),
      children: [
        SettingRowBox(
          child: lines.isEmpty
              ? Text('Nothing has gone wrong that the app knows of.', style: TextStyle(fontSize: t.fontSize('sm'), color: t.color('app-ink-3')))
              : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  for (final line in lines.take(120))
                    Padding(
                      padding: EdgeInsets.only(bottom: t.space(2)),
                      child: Text(line, style: TextStyle(fontFamily: 'JetBrains Mono Variable', fontSize: t.fontSize('xs'), height: 1.4, color: t.color('app-ink-2'))),
                    ),
                ]),
        ),
      ],
    ),
  ];
}

/// How many taps on Version turn developer mode on, as Android's own build number does (Matt, 2026-11-20).
const devModeTaps = 12;
int _versionTaps = 0;
DateTime _lastVersionTap = DateTime.fromMillisecondsSinceEpoch(0);

/// A tap on Settings › About › Version. Taps more than two seconds apart start the count again; from the eighth on
/// a toast says how many are left, and the twelfth turns developer mode on, which shows Settings › Developer.
void versionTapped(BuildContext context, AppState app, {DateTime? now}) {
  final at = now ?? DateTime.now();
  if (at.difference(_lastVersionTap) > const Duration(seconds: 2)) _versionTaps = 0;
  _lastVersionTap = at;
  if (app.flag('dev_mode', fallback: false)) {
    _versionTaps = 0;
    toast(context, 'Developer mode is already on: Settings › Developer.');
    return;
  }
  _versionTaps++;
  final left = devModeTaps - _versionTaps;
  if (left <= 0) {
    _versionTaps = 0;
    app.setFlag('dev_mode', true);
    toast(context, 'Developer mode is on: Settings › Developer.', tone: GlacierToastTone.success);
  } else if (left <= 4) {
    toast(context, left == 1 ? 'One more tap to turn on developer mode.' : '$left more taps to turn on developer mode.');
  }
}

/// Settings › About: the version (tapped several times for developer mode), what's new, the docs, and how texts
/// and sealed messages travel.
List<Widget> _about(BuildContext context, SettingsModel m) {
  return [
    PaneSection(
      title: 'Uplink',
      footer: const Tr('Your messages stay in Android\'s own message store, so they\'re all still there if you switch back to another app.'),
      children: [
        SettingRow(icon: _icon(Lucide.ghost), label: 'Version', value: Text(m.update.current.isEmpty ? appVersion : m.update.current), onPress: () => versionTapped(context, m.app)),
        // The release notes again (lib/ui/whats_new.dart).
        SettingRow(icon: _icon(Lucide.sparkles), label: 'What\'s new', hint: const Tr('What the last update brought.'), onPress: () => showWhatsNew(context)),
        // The first-run walkthrough again (lib/onboarding), on the phone, whose setup it is.
        if (!Sms.remote) SettingRow(icon: _icon(LucideMore.rocket), label: 'Watch the walkthrough again', onPress: () => openOnboarding(context)),
        // gogho.st/docs, in the browser.
        SettingRow(icon: _icon(Lucide.bookOpen), label: 'Help and docs', hint: const Tr('How everything works, step by step, at gogho.st/docs.'), onPress: openDocs),
        SettingRow(
          icon: _icon(Lucide.info),
          label: 'Texts and picture messages',
          hint: const Tr('SMS and MMS through your carrier. RCS and iMessage aren\'t available to apps other than Google\'s and Apple\'s own.'),
        ),
        SettingRow(
          icon: _icon(Lucide.lock),
          // Since accounts, friends and circles, the relay at gogho.st carries sealed messages: said as it is.
          label: 'Sealed, end to end',
          hint: Text(sealedWords(Net.instance.hubUrl)),
        ),
      ],
    ),
    aboutLicences(),
  ];
}

/// Whose work the app draws with: on About, the phone's and a computer's (lib/desktop/ui/desk_settings.dart).
PaneSection aboutLicences() => PaneSection(title: 'Licences', children: [
      SettingRow(
        icon: _icon(LucideMore.smile),
        label: 'Emoji sets',
        hint: const Tr('Noto Color Emoji and Noto Emoji © Google (SIL OFL 1.1). Twemoji © Twitter and contributors (CC-BY 4.0). All emojis designed by OpenMoji, the open-source emoji and icon project (CC BY-SA 4.0).'),
      ),
      SettingRow(icon: _icon(Lucide.info), label: 'Icons', hint: const Tr('Lucide (ISC licence).')),
    ]);

extension on String {
  String ifEmptyThen(String other) => isEmpty ? other : this;
}
