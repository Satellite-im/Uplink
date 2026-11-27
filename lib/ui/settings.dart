/// Uplink's Settings, in Ghost Keyboard's shape (its lib/settings/settings_screen.dart; Matt, 2026-11-13:
/// "make the settings page more like ghost kbd where it's nested sections and expand on the settings available"):
/// a search field over a list of sections in groups, each a row with its icon on a chip in the section's colour, its
/// name and a line of its state, opening the section's page; a page is the kit's cards (kit/settings_kit.dart) under
/// the bar with the way back. The sections themselves are settings_panes.dart.
library;

import 'dart:async';

import 'package:flutter/rendering.dart' show RenderAbstractViewport;
import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../me/me.dart';
import '../app_state.dart';
import '../effects.dart';
import '../kit/fold.dart';
import '../l10n/words.dart';
import '../kit/settings_icons.dart';
import '../kit/settings_kit.dart';
import '../kit/settings_type.dart';
import '../net/net.dart';
import '../plugins/pack/pack.dart' show InstalledPlugins;
import '../plugins/plugin.dart' show MessageFacts;
import '../sms.dart';
import 'common.dart';
import 'nav_bar.dart';
import 'nav_style.dart';
import 'settings_panes.dart';
import 'shell.dart';

/// What Settings shows that is not a choice of the person's: what Android has allowed, this phone's number, where
/// the app's update stands, who encryption is on with, the blocked numbers. Asked for as Settings opens and again
/// after anything changes it; the choices themselves are [app].
class SettingsModel extends ChangeNotifier {
  SettingsModel(this.app) {
    app.addListener(notifyListeners);
  }

  final AppState app;
  SmsStatus? status;
  String? ownNumber;
  UpdateState update = const UpdateState();
  List<E2eState> e2e = const [];

  /// A short name for this phone's encryption key; null until one is made (the first time a key is sent).
  String? myKey;
  List<Person> blocked = const [];
  int archived = 0;

  /// Ghost Keyboard is on this phone (and is the real one, by its certificate).
  bool keyboardHere = false;

  /// What can be seen of the texting app this one replaced, and of Android's store of texts.
  Arriving arriving = const Arriving();

  /// The computers this phone is paired with (android/.../Desk.kt), and whether Android lets the app use the network
  /// in deep sleep.
  List<Computer> computers = const [];
  bool unrestricted = false;

  /// Where this phone listens on the local network, for a computer that cannot find it by itself.
  List<String> phoneAddresses = const [];

  /// Whether picture messages can go from this phone, and how the last ones went (Settings › Android).
  MmsStatus mms = const MmsStatus();

  /// The app's own log of what went wrong (Settings › Developer): its lines, the newest last, and the report whole.
  List<String> devLines = const [];
  String devReport = '';

  /// The model the pages of Settings that are open share, and how many of them hold it: the list of sections in
  /// the list's place and the page of one beside it (lib/ui/shell.dart) read the same answers, so what one changes
  /// the other shows.
  static SettingsModel? _shared;
  int _users = 0;

  /// The shared model for [app], started; [give] it back when done with it.
  static SettingsModel take(AppState app) {
    final had = _shared;
    if (had != null && identical(had.app, app)) {
      had._users++;
      return had;
    }
    final made = SettingsModel(app)
      .._users = 1
      ..start();
    return _shared = made;
  }

  /// Done with it: the last to say so ends it.
  void give() {
    if (--_users > 0) return;
    if (identical(_shared, this)) _shared = null;
    dispose();
  }

  StreamSubscription<UpdateState>? _updates;
  StreamSubscription<int>? _changes;
  StreamSubscription<void>? _computers;
  List<Listenable> _watching = const [];
  InstalledPlugins? _installed;
  bool _gone = false;

  /// Starts listening to everything Settings shows the state of, so its pages draw again as any of it changes, and
  /// reads it all once.
  void start() {
    _updates = Sms.instance.updates.stream.listen((u) {
      update = u;
      _say();
    });
    _changes = Sms.instance.changes.stream.listen((_) => refresh());
    // The app's routes come and go on their own (lib/net/net.dart): Settings › Network is drawn again as they do.
    Net.instance.addListener(_say);
    // And as the direct route's devices and links change (Settings › Routes › Direct).
    Net.instance.direct.addListener(_say);
    // And as the route that last carried something to or from someone changes (Settings › Routes › Which route each
    // conversation is on).
    Net.instance.routesUsed.addListener(_say);
    Me.instance.addListener(_say);
    // The packs on this device (lib/plugins/pack): Settings › Developer's Plugins in development lists them, and the
    // search reads their switches.
    _installed = InstalledPlugins.instance..addListener(_say);
    // And whatever the sections that come from outside are read from (a computer's link to its phone).
    _watching = SettingsSources.watched;
    for (final w in _watching) {
      w.addListener(_say);
    }
    _computers = Sms.instance.computersChanged.stream.listen((_) async {
      try {
        computers = await Sms.instance.computers();
        _say();
      } catch (_) {}
    });
    refresh();
  }

  /// Tells the listeners, unless the model has been let go: an answer may land after it has.
  void _say() {
    if (!_gone) notifyListeners();
  }

  /// Each asked for on its own: one that Android refuses leaves the rest.
  Future<void> refresh() async {
    Future<void> ask(Future<void> Function() what) async {
      try {
        await what();
      } catch (_) {}
    }

    await Future.wait([
      ask(() async => MessageFacts.heardStatus(status = await Sms.instance.status())),
      ask(() async => ownNumber = await Sms.instance.ownNumber()),
      ask(() async => update = await Sms.instance.update()),
      ask(() async => e2e = await Sms.instance.e2eList()),
      ask(() async => myKey = await Sms.instance.e2eMine()),
      ask(() async => blocked = await Sms.instance.blockedNumbers()),
      ask(() async => keyboardHere = await Sms.instance.keyboardHere()),
      ask(() async => arriving = await Sms.instance.arriving()),
      ask(() async => computers = await Sms.instance.computers()),
      ask(() async => unrestricted = await Sms.instance.unrestrictedBattery()),
      ask(() async => phoneAddresses = await Sms.instance.phoneAddresses()),
      ask(() async => mms = await Sms.instance.mmsStatus()),
      ask(() async {
        final (lines, report) = await Sms.instance.devLogRead(appVersion);
        devLines = lines;
        devReport = report;
      }),
      ask(() async => archived = await Sms.instance.archivedCount()),
    ]);
    _say();
  }

  @override
  void dispose() {
    _gone = true;
    Net.instance.removeListener(_say);
    Net.instance.direct.removeListener(_say);
    Net.instance.routesUsed.removeListener(_say);
    Me.instance.removeListener(_say);
    _installed?.removeListener(_say);
    for (final w in _watching) {
      w.removeListener(_say);
    }
    app.removeListener(notifyListeners);
    _updates?.cancel();
    _changes?.cancel();
    _computers?.cancel();
    super.dispose();
  }
}

/// Which kind of device a section is for. The phone and a computer share Settings and its pages (Matt, 2026-11-14:
/// "desktop and mobile should also share the same settings pages"); the few that are about one of them alone say
/// so, and are left out on the other.
enum SettingsWhere { everywhere, phone, computer }

/// Sections that come from outside the list in settings_panes.dart: a plugin's own page (lib/plugins/settings.dart),
/// a computer's own sections (lib/desktop/ui/desk_settings.dart), and whatever else has something to set (Matt,
/// 2026-11-14: "the plugins and all being able to make their own setting sections"). A source is asked each time
/// Settings is drawn, so what it gives can come and go (a plugin switched off takes its page with it).
abstract final class SettingsSources {
  static final List<List<SettingsSection> Function()> _first = [];
  static final List<List<SettingsSection> Function()> _after = [];
  static final Map<List<SettingsSection> Function(), List<Listenable>> _watch = {};

  /// Adds a source. Its sections follow the app's own, in the groups they name; [first] puts them before. Settings
  /// is drawn again whenever one of [watch] changes: what the source's rows and pages say is read from them.
  static void add(List<SettingsSection> Function() source, {bool first = false, List<Listenable> watch = const []}) {
    remove(source);
    (first ? _first : _after).add(source);
    if (watch.isNotEmpty) _watch[source] = watch;
  }

  static void remove(List<SettingsSection> Function() source) {
    _first.remove(source);
    _after.remove(source);
    _watch.remove(source);
  }

  /// What the sources' sections are read from.
  static List<Listenable> get watched => [for (final w in _watch.values) ...w];

  /// [own], with every source's sections before and after it, and those not for this kind of device ([here]: a
  /// computer where the phone is reached through a link, a phone otherwise) left out.
  static List<SettingsSection> around(List<SettingsSection> own, {SettingsWhere? here}) {
    here ??= Sms.remote ? SettingsWhere.computer : SettingsWhere.phone;
    final all = [for (final source in _first) ...source(), ...own, for (final source in _after) ...source()];
    // Plugins at the very top of the list, above even a computer's own sections (Matt, 2026-11-17: "move plugins to the
    // very top of settings list"): the band to the Plugins page, and the plugins' own sections after it.
    bool plugin(SettingsSection s) => s.group == 'plugins';
    return [
      for (final s in [...all.where(plugin), ...all.where((s) => !plugin(s))])
        if (s.where == SettingsWhere.everywhere || s.where == here) s,
    ];
  }
}

/// One section: a row on the list and the page it opens.
@immutable
class SettingsSection {
  const SettingsSection({required this.id, required String label, required this.icon, required this.hue, required this.group, required this.page, this.summary, this.screen, this.where = SettingsWhere.everywhere, this.when, this.listed = true, this.entry}) : english = label;

  /// The kind of device it is for.
  final SettingsWhere where;

  /// Whether it is there at all, as the person's choices stand: a plugin's own section, while the plugin is on.
  /// Always, where not given.
  final bool Function(SettingsModel model)? when;

  final String id;

  /// Its name as written; [label] is it in the language drawn (lib/l10n/words.dart).
  final String english;
  String get label => english.t;
  final Widget icon;

  /// Its colour, by the names settings.css keeps (kit/settings_css.dart).
  final String hue;

  /// Rows with the same group share one card.
  final String group;

  /// The row's second line, read live.
  final String Function(SettingsModel model)? summary;

  /// Its page's cards.
  final List<Widget> Function(BuildContext context, SettingsModel model) page;

  /// A screen of its own in place of a page of cards: Archived, the chat background.
  final Widget Function(BuildContext context, SettingsModel model)? screen;

  /// Whether it has a row in Settings' list and the Settings ring's menu. One that is not (a plugin's own page, which
  /// the Plugins page leads to now) is still opened by its id, and Settings' search still finds what is on it.
  final bool listed;

  /// What stands in Settings' list in place of its row, on a card of its own: the Plugins page's way in, a band in
  /// colour with the plugins' tiles on it (Matt, 2026-11-17: "redo how the plugins look with their own dedicated
  /// plugins page with a marketplace like look how ghostmd has"). [open] opens it; [selected] is that its page is the
  /// one beside the list. A search's hit for it is a plain row, as every other section's.
  final Widget Function(BuildContext context, SettingsModel model, VoidCallback open, bool selected)? entry;
}

/// The setting a search found on a section that draws a screen of its own ([SettingsSection.screen]), for that screen
/// to show: the Plugins page opens the plugin of that name.
class SettingsSeek extends InheritedWidget {
  const SettingsSeek({super.key, required this.seek, required super.child});
  final String? seek;

  static String? of(BuildContext context) => context.getInheritedWidgetOfExactType<SettingsSeek>()?.seek;

  @override
  bool updateShouldNotify(SettingsSeek old) => old.seek != seek;
}

/// A section's page can play a message effect over itself (Effects): asked for from a row on it.
class EffectsHost extends InheritedWidget {
  const EffectsHost({super.key, required this.play, required super.child});
  final void Function(ScreenEffect effect) play;

  static EffectsHost? maybeOf(BuildContext context) => context.getInheritedWidgetOfExactType<EffectsHost>();

  @override
  bool updateShouldNotify(EffectsHost old) => false;
}

/// Settings' home: a search field over the list of sections. While words are typed the list gives way to what they
/// find: sections and settings, each with where it is, opening there.
///
/// In the app's frame (lib/ui/shell.dart) it stands in the list's place, and a section's page opens in the pane:
/// over it on a phone, beside it in a window with room, where the first section is open from the start and the
/// row of the one open is marked. That is Ghost.md's Settings in a window (Matt, 2026-11-14: "a full features
/// settings page like the ghost markdown app ... instead of the one small settings panel we have now"; "when the
/// settings is open on desktop replace the normal sidebar so it's only a two pane layout not a three pane").
/// With no frame round it (a test of the one screen) a section's page opens over it.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> with WidgetsBindingObserver {
  SettingsModel? _model;
  String _query = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _model ??= SettingsModel.take(AppState.of(context));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _model?.give();
    super.dispose();
  }

  /// Back from one of Android's own pages (a permission, the default SMS app): what it allowed is asked again.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _model?.refresh();
  }

  /// Opens a section: in the frame's pane where there is a frame, over this page where there is none. A plugin's, or
  /// one of its settings, is the Marketplace's now (Matt, 2026-11-20: "Move plugins out of settings into a
  /// marketplace button on the navigation rail with a marketplace icon"): Discover at that plugin, the setting lit. A
  /// hit in the unlisted Plugins section itself (Record call, Scribe, every pack's switch and cards are only there)
  /// carries its words as the seek, which alone makes it Discover, on a phone as beside the list.
  void _open(SettingsSection s, {String? seek}) {
    final shell = AppShell.maybeOf(context);
    if (shell != null && s.group == 'plugins') return shell.marketplace(section: 'discover', plugin: s.id.startsWith('plugin-') ? s.id.substring('plugin-'.length) : null, seek: seek);
    if (shell != null) return shell.settings(s.id, seek);
    final model = _model!;
    push<void>(context, (context) => s.screen != null ? SettingsSeek(seek: seek, child: Builder(builder: (context) => s.screen!(context, model))) : SectionPage(section: s, model: model, seek: seek));
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final model = _model!;
    final shell = AppShell.maybeOf(context);
    // Beside its page: the frame's list and pane are side by side.
    final beside = shell != null && AppShell.wideOf(context);
    return ListenableBuilder(
      listenable: Listenable.merge([model, ?shell?.settingsSection]),
      builder: (context, _) {
        final all = [for (final s in settingsSections) if (s.when?.call(model) ?? true) s];
        final sections = [for (final s in all) if (s.listed) s];
        final query = _query.trim();
        final hits = query.isEmpty ? const <SettingsHit>[] : searchSettings(context, model, all, query);
        final chosen = beside ? shell.settingsSection.value : null;
        // Beside the pane there is always a section in it: the first, until another is pressed.
        if (beside && chosen == null && sections.isNotEmpty) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && shell.settingsOpen && shell.wide && shell.settingsSection.value == null) shell.settings(sections.first.id);
          });
        }
        return GhostPage(
          title: 'Settings',
          // A back arrow always (Matt, 2026-11-18: "add a back arrow to the settings page"): on a phone it is the page's
          // own, beside its page it takes Settings away, back to the conversations or the circle it was opened from.
          onBack: beside ? shell.closeSettings : null,
          bigTitle: beside ? true : null,
          body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Padding(
              padding: EdgeInsetsDirectional.fromSTEB(t.space(4), t.space(1), t.space(4), t.space(3)),
              child: GlacierSearchField(placeholder: 'Search settings'.t, size: GlacierFieldSize.md, onValueChange: (v) => setState(() => _query = v)),
            ),
            // The header ends under the search field, as the conversations' does: what hangs under a header (the
            // update banner) hangs under this one, in this column.
            const HeaderEnd(),
            Expanded(
              child: ListView(
                padding: EdgeInsetsDirectional.fromSTEB(t.space(4), t.space(2), t.space(4), MediaQuery.paddingOf(context).bottom + (beside && !AppShell.railOf(context) ? NavPill.clearance(t) : (AppShell.maybeOf(context) != null && NavStyle.of(AppState.of(context)).unified ? AppShell.pillRoom(context) + t.space(4) : t.space(8)))),
                keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                children: [
                  if (query.isEmpty)
                    SettingsList(model: model, sections: sections, chosen: chosen, beside: beside, onOpen: _open)
                  else if (hits.isEmpty)
                    Padding(
                      padding: EdgeInsets.all(t.space(4)),
                      child: Text('Nothing called “$query”.', textAlign: TextAlign.center, style: pageText(t, t.fontSize('sm'), color: t.color('app-ink-2'))),
                    )
                  else
                    SettingsGroup(rows: [
                      for (var i = 0; i < hits.length; i++)
                        SettingsSectionRow(
                          label: hits[i].setting ?? hits[i].section.label,
                          icon: hits[i].section.icon,
                          hue: hits[i].section.hue,
                          // A setting says where it is; a section, what it is set to.
                          summary: hits[i].setting != null ? hits[i].section.label : hits[i].section.summary?.call(model),
                          index: i,
                          chevron: !beside,
                          onPress: () => _open(hits[i].section, seek: hits[i].setting),
                        ),
                    ]),
                ],
              ),
            ),
          ]),
        );
      },
    );
  }
}

/// A section's page: its cards, staggered in as Ghost Keyboard's arrive. Opened from a search with [seek], the
/// setting of that name is scrolled into view and lit once the page is drawn.
class SectionPage extends StatefulWidget {
  const SectionPage({super.key, required this.section, required this.model, this.seek});

  final SettingsSection section;
  final SettingsModel model;
  final String? seek;

  @override
  State<SectionPage> createState() => _SectionPageState();
}

class _SectionPageState extends State<SectionPage> {
  final _finder = SettingsFinder();
  final _effects = GlobalKey<EffectLayerState>();

  @override
  void initState() {
    super.initState();
    final seek = widget.seek;
    if (seek == null) return;
    // Two frames: one to build the page whole, one for it to be laid out.
    WidgetsBinding.instance.addPostFrameCallback((_) => WidgetsBinding.instance.addPostFrameCallback((_) {
          final found = _finder.find(seek);
          if (found == null || !mounted) return;
          Scrollable.ensureVisible(found.context, alignment: 0.25, duration: const Duration(milliseconds: 320), curve: Curves.easeOutCubic);
          found.light();
        }));
  }

  @override
  Widget build(BuildContext context) {
    final section = widget.section;
    final model = widget.model;
    return GlacierScope(
      attrs: {'hue': section.hue},
      child: ListenableBuilder(
        listenable: model,
        builder: (context, _) {
          final t = context.tokens;
          return SettingsPaneScope(
            finder: _finder,
            whole: widget.seek != null,
            seeking: widget.seek,
            child: EffectsHost(
              play: (effect) => _effects.currentState?.play(effect, text: effectLabel(effect)),
              child: GhostPage(
                title: section.label,
                body: Stack(children: [
                  Positioned.fill(
                    child: ListView(
                      padding: EdgeInsetsDirectional.fromSTEB(t.space(4), t.space(2), t.space(4), t.space(8) + MediaQuery.paddingOf(context).bottom),
                      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                      children: [Builder(builder: (context) => PaneBody(children: section.page(context, model)))],
                    ),
                  ),
                  Positioned.fill(child: EffectLayer(key: _effects, style: pageText(t, 26, color: t.color('app-ink')))),
                ]),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// One section's page by its [id]: what the frame puts in its pane for a row of Settings' list, and the way in
/// from outside Settings. [seek] is a setting on it to scroll to and light (a search found it).
class SettingsSectionScreen extends StatefulWidget {
  const SettingsSectionScreen(this.id, {super.key, this.seek});
  final String id;
  final String? seek;

  @override
  State<SettingsSectionScreen> createState() => _SettingsSectionScreenState();
}

class _SettingsSectionScreenState extends State<SettingsSectionScreen> {
  SettingsModel? _model;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _model ??= SettingsModel.take(AppState.of(context));
  }

  @override
  void dispose() {
    _model?.give();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final model = _model!;
    return ListenableBuilder(
      listenable: model,
      builder: (context, _) {
        final section = [for (final s in settingsSections) if (s.id == widget.id && (s.when?.call(model) ?? true)) s].firstOrNull;
        // A section that is not here (another kind of device's, a plugin's that was switched off): Settings itself.
        // In the frame that is the list this page was opened from, so the page only has to go.
        if (section == null) {
          final shell = AppShell.maybeOf(context);
          if (shell == null) return const SettingsScreen();
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && shell.settingsSection.value == widget.id) shell.settingsGone();
          });
          return ColoredBox(color: context.tokens.color('glacier-bg'), child: const SizedBox.expand());
        }
        return section.screen != null ? SettingsSeek(seek: widget.seek, child: Builder(builder: (context) => section.screen!(context, model))) : SectionPage(section: section, model: model, seek: widget.seek);
      },
    );
  }
}

/// The list of sections: Settings' home.
class SettingsList extends StatelessWidget {
  const SettingsList({super.key, required this.model, required this.sections, this.onOpen, this.chosen, this.beside = false});

  final SettingsModel model;
  final List<SettingsSection> sections;

  /// Asked to open a section; where not given, its page opens over the list.
  final ValueChanged<SettingsSection>? onOpen;

  /// The section whose page is shown beside the list, which its row is marked for.
  final String? chosen;

  /// A section's page is beside the list, not over it: a row leads nowhere else, so it has no chevron.
  final bool beside;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final groups = <String, List<SettingsSection>>{};
    for (final section in sections) {
      groups.putIfAbsent(section.group, () => []).add(section);
    }
    var index = 0;
    void open(SettingsSection section) => onOpen != null ? onOpen!(section) : push<void>(context, (context) => section.screen != null ? section.screen!(context, model) : SectionPage(section: section, model: model));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final group in groups.values) ...[
          // A section with an entry of its own (the Plugins page's band) stands on its own above its group's card.
          for (final section in group)
            if (section.entry != null) ...[
              SettingsReveal(
                shown: beside && section.id == chosen,
                foot: beside && !AppShell.railOf(context) ? NavPill.clearance(t) : 0,
                child: section.entry!(context, model, () => open(section), beside && section.id == chosen),
              ),
              if (group.any((s) => s.entry == null)) SizedBox(height: t.space(3)),
            ],
          if (group.any((s) => s.entry == null)) SettingsGroup(rows: [
            for (final section in group.where((s) => s.entry == null))
              SettingsReveal(
                // The row of the section open beside the list is brought into view when it was not: a section
                // jumped to from somewhere else (a search, the Settings ring's menu) is marked where it can be seen.
                shown: beside && section.id == chosen,
                foot: beside && !AppShell.railOf(context) ? NavPill.clearance(t) : 0,
                child: SettingsSectionRow(
                  label: section.label,
                  icon: section.icon,
                  hue: section.hue,
                  summary: section.summary?.call(model),
                  index: index++,
                  selected: beside && section.id == chosen,
                  chevron: !beside,
                  onPress: () => open(section),
                ),
              ),
          ]),
          SizedBox(height: t.space(5)),
        ],
      ],
    );
  }
}

/// Scrolls its child into view when [shown] becomes true and the child is not wholly seen ([foot]: how much of
/// the list's end something stands over, which is not seen either). The Marketplace's list marks its rows so too.
class SettingsReveal extends StatefulWidget {
  const SettingsReveal({super.key, required this.shown, required this.child, this.foot = 0});
  final bool shown;
  final double foot;
  final Widget child;

  @override
  State<SettingsReveal> createState() => _SettingsRevealState();
}

class _SettingsRevealState extends State<SettingsReveal> {
  @override
  void initState() {
    super.initState();
    if (widget.shown) _reveal();
  }

  @override
  void didUpdateWidget(SettingsReveal old) {
    super.didUpdateWidget(old);
    if (widget.shown && !old.shown) _reveal();
  }

  /// Scrolls the list, once this frame is laid out, so the row is seen whole.
  void _reveal() => WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final box = context.findRenderObject();
        final position = Scrollable.maybeOf(context)?.position;
        if (box is! RenderBox || !box.attached || position == null) return;
        final viewport = RenderAbstractViewport.maybeOf(box);
        if (viewport == null) return;
        // Where the list would stand with the row's top at its top, and with the row's foot at its foot.
        final top = viewport.getOffsetToReveal(box, 0).offset, foot = viewport.getOffsetToReveal(box, 1).offset + widget.foot;
        // Seen whole already (a press on it): nothing moves.
        if (position.pixels <= top && position.pixels >= foot) return;
        Scrollable.ensureVisible(context, alignment: 0.5, duration: const Duration(milliseconds: 220), curve: Curves.easeOutCubic);
      });

  @override
  Widget build(BuildContext context) => widget.child;
}

/// `.settingsScreen__group`: rows sharing one card, a hairline between them. The Marketplace's list's too.
class SettingsGroup extends StatelessWidget {
  const SettingsGroup({super.key, required this.rows});
  final List<Widget> rows;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final hairline = t.len('glacier-hairline');
    final rule = t.color('app-rule');
    return GlacierScope(
      classes: const {'settingsScreen__group'},
      child: ClipRRect(
        borderRadius: BorderRadius.circular(t.radius('lg')),
        child: ColoredBox(
          color: t.color('app-paper-2'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < rows.length; i++)
                i == 0 ? rows[i] : DecoratedBox(decoration: BoxDecoration(border: Border(top: BorderSide(color: rule, width: hairline))), child: Padding(padding: EdgeInsets.only(top: hairline), child: rows[i])),
            ],
          ),
        ),
      ),
    );
  }
}

/// `.settingsScreen__row`: the section's chip in its colour, its name and a line under it, and a chevron. The
/// Marketplace's list draws its sections with it.
class SettingsSectionRow extends StatelessWidget {
  const SettingsSectionRow({super.key, required this.label, required this.icon, required this.hue, required this.summary, required this.index, required this.onPress, this.selected = false, this.chevron = true, this.summaryDanger = false});

  final String label;
  final Widget icon;
  final String hue;
  final String? summary;
  final int index;
  final VoidCallback onPress;

  /// Its line is something to act on, in the danger tone: My submissions' "1 needs changes".
  final bool summaryDanger;

  /// Its page is the one shown beside the list.
  final bool selected;

  /// Whether it leads somewhere else (a page over the list); beside its page it does not.
  final bool chevron;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final gap = t.space(3);
    final chip = t.lenOf('1.85rem');
    final hasSummary = summary != null && summary!.isNotEmpty;
    return SettingsRise(
      index: index,
      child: GlacierPressable(
        onPressed: onPress,
        semanticLabel: label,
        builder: (context, state) => ColoredBox(
          color: selected || state.pressed ? t.color('app-paper-3') : const Color(0x00000000),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: t.lenOf('3.5rem')),
            child: Padding(
              padding: EdgeInsets.all(gap),
              child: Row(
                children: [
                  GlacierScope(
                    attrs: {'hue': hue},
                    child: Builder(
                      builder: (context) {
                        final hued = context.tokens;
                        return Container(
                          width: chip,
                          height: chip,
                          decoration: BoxDecoration(color: settingsHueWash(hued), borderRadius: BorderRadius.circular(t.lenOf('0.55rem'))),
                          alignment: Alignment.center,
                          child: ExcludeSemantics(child: IconTheme.merge(data: IconThemeData(color: settingsHue(hued)), child: icon)),
                        );
                      },
                    ),
                  ),
                  SizedBox(width: gap),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(label, style: pageText(t, t.fontSize('md'), weight: 'medium', color: t.color('app-ink'))),
                        if (hasSummary) ...[
                          SizedBox(height: t.lenOf('0.1rem')),
                          Text(translatedParts(summary!), maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('sm'), color: t.color(summaryDanger ? 'app-danger' : 'app-ink-3'))),
                        ],
                      ],
                    ),
                  ),
                  if (chevron) ...[SizedBox(width: gap), ExcludeSemantics(child: SettingsIcon(SettingsGlyph.chevronRight, size: 18, color: t.color('app-ink-4')))],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// --- the search -------------------------------------------------------------------------------------------------------
// Ghost Keyboard's settings_search.dart: nothing is listed by hand. The index is read off the pages themselves (each
// is a list of the kit's cards and rows, which say their own names), so a setting is found the day it is added.

final RegExp _notWord = RegExp(r'[^\p{L}\p{N}]+', unicode: true);

/// [text] as its words, folded for matching: letters and numbers kept, everything else a gap.
List<String> _words(String text) => fold(text).split(_notWord).where((w) => w.isNotEmpty).toList();

/// Every word of [query] starts a word of [text].
bool settingsMatch(String query, String text) {
  final want = _words(query);
  if (want.isEmpty) return false;
  final have = _words(text);
  return want.every((w) => have.any((h) => h.startsWith(w)));
}

/// One thing found: a section, or a setting on its page.
class SettingsHit {
  const SettingsHit(this.section, {this.setting});
  final SettingsSection section;

  /// The setting found on the section's page, as the page names it; null when the section itself was found.
  final String? setting;
}

/// What a page draws that can be looked for: each card's title, each row's label with its hint. A card is found by
/// its title alone: what its footnote says is about its rows, which are found themselves.
List<(String, String)> pageEntries(List<Widget> widgets) {
  final out = <(String, String)>[];
  String textOf(Widget? w) => w is Tr ? w.words.t : (w is Text ? (w.data ?? '') : '');
  void walk(Widget w) {
    if (w is PaneSection) {
      if ((w.title ?? '').isNotEmpty) out.add((w.title!.t, ''));
      for (final c in w.children) {
        walk(c);
      }
    } else if (w is SettingRow) {
      out.add((w.label.t, textOf(w.hint)));
    } else if (w is PaneHero) {
      out.add((w.title.t, textOf(w.meta)));
    }
  }

  for (final w in widgets) {
    walk(w);
  }
  return out;
}

/// What [query] finds: sections by their names and state lines first, then settings on their pages by their names
/// and hints (with their section's name counting too, so "notifications preview" finds the switch).
List<SettingsHit> searchSettings(BuildContext context, SettingsModel model, List<SettingsSection> sections, String query, {int limit = 40}) {
  final found = <SettingsHit>[];
  final settings = <SettingsHit>[];
  final seen = <String>{};
  for (final s in sections) {
    if (settingsMatch(query, '${s.label} ${s.summary?.call(model) ?? ''}')) found.add(SettingsHit(s));
    // A section with a screen of its own is searched by its page too, which is empty for most (Archived), and for
    // the Plugins page is every plugin by name: a hit opens the screen at it ([SettingsSeek]).
    for (final (label, detail) in pageEntries(s.page(context, model))) {
      if (label == s.label || !seen.add('${s.id}|$label')) continue;
      if (settingsMatch(query, '$label $detail ${s.label}')) settings.add(SettingsHit(s, setting: label));
    }
  }
  return [...found, ...settings].take(limit).toList();
}
