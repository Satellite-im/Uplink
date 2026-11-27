/// The plugins the app has and what the ones that are switched on add (the contract is plugin.dart). A screen asks
/// here: which tags a conversation has, which section it is in, what there is for a slot, what to do with a message
/// that has just come. A plugin that is off is never asked, and one that throws is left out and said in the
/// Developer log, so a bad plugin costs its own part and not the list.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';

import '../app_state.dart';
import '../sms.dart';
import 'notion.dart';
import 'actions.dart';
import 'auto_leveler.dart';
import 'codes.dart';
import 'cleaner.dart';
import 'embeds.dart';
import 'game_activity.dart';
import 'performance.dart';
import 'human_check.dart';
import 'kinds.dart';
import 'live_captions.dart';
import 'networks.dart';
import 'pack/format.dart' show packMayAct;
import 'pack/pack_plugin.dart' show PackPlugin;
import 'quiet.dart';
import 'record_call.dart';
import 'scribe.dart';
import 'replies.dart';
import 'strangers.dart';
import 'plugin.dart';
import 'soundboard.dart';
import 'spam.dart';
import 'spotify.dart';
import 'translate.dart';
import 'translate_host.dart';
import 'voice_changer.dart';
import 'watch_together.dart';

/// The plugins the app ships with, in the order Settings › Plugins lists them and their sections are asked: a text
/// that is a sign-in code is in Codes whatever the spam filter makes of it.
// Kinds before Spam: a text that is plainly political or a debt collector is that, whatever else it shows; the kinds
// that are shown (deliveries, reminders) leave a text that looks like spam to Spam.
// Translate last: it adds to a conversation and takes nothing from the list, and is off until it is added.
const List<GhostPlugin> shippedPlugins = [CodesPlugin(), KindsPlugin(), SpamPlugin(), EmbedsPlugin(), ActionsPlugin(), RepliesPlugin(), QuietPlugin(), StrangersPlugin(), HumanCheckPlugin(), CleanerPlugin(), TranslatePlugin(), RecordCallPlugin(), ScribePlugin(), LiveCaptionsPlugin(), WatchTogetherPlugin(), SoundboardPlugin(), AutoLevelerPlugin(), VoiceChangerPlugin(), GameActivityPlugin(), PerformancePlugin(), NotionPlugin(), SpotifyPlugin(), ...networkPlugins];

/// The person's choices as the plugins' side reads and writes them: the app's own ([AppStore]), or a map in a test.
abstract interface class PluginStore {
  String? read(String key);
  void write(String key, String value);

  /// Goes up whenever a plugin's switch or one of its choices changes: what was worked out from them is worked out
  /// again.
  int get stamp;

  /// The choices whose keys start with [prefix]: one plugin's own (`plugin_<id>_`), for [PluginRegistry.textMark].
  Map<String, String> withPrefix(String prefix);
}

/// The plugins' choices in the app's own ([AppState]), which keeps them in Android's preferences with the rest.
class AppStore implements PluginStore {
  const AppStore(this.app);
  final AppState app;

  @override
  String? read(String key) {
    final value = app.choice(key, '');
    return value.isEmpty ? null : value;
  }

  @override
  void write(String key, String value) => app.set(key, value);

  @override
  int get stamp => app.pluginsStamp;

  @override
  Map<String, String> withPrefix(String prefix) => app.withPrefix(prefix);
}

/// Choices kept in memory: a test's, or a page drawn with no app round it.
class MemoryStore implements PluginStore {
  MemoryStore([Map<String, String>? values]) : values = {...?values};
  final Map<String, String> values;

  @override
  int stamp = 0;

  @override
  String? read(String key) {
    final value = values[key];
    return value == null || value.isEmpty ? null : value;
  }

  @override
  void write(String key, String value) {
    values[key] = value;
    stamp++;
  }

  @override
  Map<String, String> withPrefix(String prefix) => {for (final e in values.entries) if (e.key.startsWith(prefix)) e.key: e.value};
}

/// One plugin's own choices: the person's, each read and written under the plugin's [prefix] (`plugin_<id>_`).
class _Prefs implements PluginPrefs {
  const _Prefs(this.store, this.prefix, {this.tunes = false});
  final PluginStore store;
  final String prefix;

  /// The plugin has a tuned classifier: a change is told to [PluginRegistry.switches].
  final bool tunes;

  @override
  String? get(String key) => store.read('$prefix$key');

  @override
  void set(String key, String value) {
    if (store.read('$prefix$key') == value) return;
    store.write('$prefix$key', value);
    if (tunes) store.write(PluginRegistry.tunedKey, '${(int.tryParse(store.read(PluginRegistry.tunedKey) ?? '') ?? 0) + 1}');
  }

  @override
  bool flag(String key, {bool fallback = true}) {
    final value = get(key);
    return value == null ? fallback : value == 'on';
  }

  @override
  void setFlag(String key, bool on) => set(key, on ? 'on' : 'off');
}

/// Where the person (or a plugin's rule) has filed conversations by hand, which holds whatever the classifiers say:
/// a conversation's number to a section's id, or to [main] for one kept in the main list. Kept in one choice,
/// `plugins_filed`, as `12:codes,40:,77:spam`.
@immutable
class Filing {
  const Filing._(this._by);

  factory Filing.parse(String? raw) {
    if (raw == null || raw.isEmpty) return none;
    final by = <int, String>{};
    for (final part in raw.split(',')) {
      final at = part.indexOf(':');
      final thread = at < 0 ? null : int.tryParse(part.substring(0, at));
      if (thread != null) by[thread] = part.substring(at + 1);
    }
    return by.isEmpty ? none : Filing._(by);
  }

  static const key = 'plugins_filed';
  static const none = Filing._({});

  /// Filed in the main list: no section takes it.
  static const main = '';

  final Map<int, String> _by;

  /// The section [thread] is filed in, [main] for the main list, or null where it was never filed.
  String? of(int thread) => _by[thread];

  /// Every conversation filed by hand, and where: for the phone's side, which hushes the notifications of a conversation
  /// filed in a kind the filter hides (lib/plugins/notify_hush.dart).
  Map<int, String> get all => Map.unmodifiable(_by);

  Filing _with(int thread, String? section) {
    final by = {..._by};
    section == null ? by.remove(thread) : by[thread] = section;
    return Filing._(by);
  }

  String _encode() => [for (final e in _by.entries) '${e.key}:${e.value}'].join(',');
}

/// A section, and the plugin whose it is.
@immutable
class PluginSection {
  const PluginSection(this.plugin, this.section);
  final GhostPlugin plugin;
  final ListSection section;
  String get id => section.id;
}

/// Something to press, and the plugin whose it is: the host it is run with has that plugin's choices.
@immutable
class BoundAction {
  const BoundAction(this.plugin, this.action);
  final GhostPlugin plugin;
  final PluginAction action;
}

/// What one plugin asks for of a message that has just come.
@immutable
class BoundIncoming {
  const BoundIncoming(this.plugin, this.action);
  final GhostPlugin plugin;
  final IncomingAction action;
}

/// What a plugin adds, read once when the registry is made: a plugin's lists are not asked for again.
class _Entry {
  _Entry(this.plugin)
      : classifiers = List.of(plugin.classifiers),
        tuned = List.of(plugin.tuned),
        sections = [for (final s in plugin.sections) PluginSection(plugin, s)],
        slots = List.of(plugin.slots),
        incoming = List.of(plugin.incoming),
        settings = List.of(plugin.settings),
        text = List.of(plugin.text);
  final GhostPlugin plugin;
  final List<Classifier> classifiers;
  final List<TunedClassifier> tuned;
  final List<PluginSection> sections;
  final List<SlotFill> slots;
  final List<IncomingRule> incoming;
  final List<PluginSetting> settings;
  final List<TextRule> text;
}

/// A rule for a message's words, and the plugin whose it is ([PluginRegistry.textRules]).
@immutable
class BoundText {
  const BoundText(this.plugin, this.rule, this.prefs);
  final GhostPlugin plugin;
  final TextRule rule;
  final PluginPrefs prefs;
}

/// It tells its listeners when a plugin is installed, replaced or uninstalled while the app runs: the packs from the
/// Marketplace and in development (lib/plugins/pack; Matt, 2026-11-20: "I would like users to be able to develop and
/// submit their own plugins to our plugin marketplace"), which come and go after the app has started.
class PluginRegistry with ChangeNotifier {
  /// Validates [plugins] and throws for a bad id or two of one name: the built-ins' and a test's, which are wrong in
  /// the code. A plugin that comes later goes through [install], which never throws.
  PluginRegistry(Iterable<GhostPlugin> plugins, {this.onError}) : _entries = [for (final p in plugins) _Entry(p)] {
    final ids = <String>{};
    final sections = <String>{};
    for (final e in _entries) {
      if (!_name.hasMatch(e.plugin.id)) throw ArgumentError('A plugin\'s id is lower-case letters and digits: "${e.plugin.id}"');
      if (!ids.add(e.plugin.id)) throw ArgumentError('Two plugins are called "${e.plugin.id}"');
      for (final s in e.sections) {
        if (!_name.hasMatch(s.id)) throw ArgumentError('A section\'s id is lower-case letters and digits: "${s.id}"');
        if (!sections.add(s.id)) throw ArgumentError('Two sections are called "${s.id}"');
      }
    }
  }

  /// The app's own: the plugins it ships with. A test puts its own here; the app never puts another here once it has
  /// started (screens and the API hold this one), and adds packs to it with [install]. Its errors go to the Developer
  /// log from the start, not only once a list of conversations exists to say where they go.
  static PluginRegistry instance = PluginRegistry(shippedPlugins, onError: logPluginError);

  /// The ids and section ids of the plugins the app ships with: never replaced or uninstalled, and never a pack's
  /// (a pack's start with x: lib/plugins/pack/format.dart).
  static final Set<String> shippedIds = {for (final p in shippedPlugins) p.id};
  static final Set<String> shippedSectionIds = {for (final p in shippedPlugins) for (final s in p.sections) s.id};

  static final _name = RegExp(r'^[a-z0-9]+$');

  // A plugin that comes later is held to more than the constructor's rule: an id no longer than a PluginChatNote may
  // name (32), and no section called 'other', whose filter choice would be the list's own filter_other.
  static final _installedName = RegExp(r'^[a-z0-9]{1,32}$');
  static final _installedSection = RegExp(r'^[a-z0-9]{1,48}$');

  final List<_Entry> _entries;

  /// Told when a plugin throws while being asked something: which one, and what it threw.
  void Function(GhostPlugin plugin, Object error)? onError;

  final List<void Function(GhostPlugin plugin, Object error)> _errorListeners = [];

  /// Also told what [onError] is told, after it: what keeps a pack's own errors (lib/plugins/pack/installed.dart).
  void addErrorListener(void Function(GhostPlugin plugin, Object error) listener) => _errorListeners.add(listener);
  void removeErrorListener(void Function(GhostPlugin plugin, Object error) listener) => _errorListeners.remove(listener);

  /// Says what [plugin] threw to [onError] and to each listener, each on its own: one that throws itself stops none
  /// of the others, nor whatever was asking the plugin.
  void _tell(GhostPlugin plugin, Object error) {
    try {
      onError?.call(plugin, error);
    } catch (_) {}
    for (final listener in List.of(_errorListeners)) {
      try {
        listener(plugin, error);
      } catch (_) {}
    }
  }

  int _version = 0;

  /// Goes up on every install, replace and uninstall.
  int get version => _version;

  /// Adds [plugin] after every plugin here now, and tells listeners. Never throws: null when it is in, else why not:
  /// 'bad_id' (not ^[a-z0-9]{1,32}$), 'id_taken', 'bad_section' (not ^[a-z0-9]{1,48}$, or 'other'),
  /// 'section_taken', 'threw' (a getter threw while its lists were read).
  String? install(GhostPlugin plugin) {
    final String id;
    final _Entry entry;
    try {
      id = plugin.id;
      entry = _Entry(plugin);
    } catch (_) {
      return 'threw';
    }
    if (!_installedName.hasMatch(id)) return 'bad_id';
    if (_entries.any((e) => e.plugin.id == id)) return 'id_taken';
    final refused = _sectionsRefused(entry, besides: null);
    if (refused != null) return refused;
    _entries.add(entry);
    _changed();
    return null;
  }

  /// Puts [plugin] where the plugin with its id is (an update), keeping its place and so its sections' precedence.
  /// Never throws: null when done; 'missing', 'built_in' (a shipped id), or install's codes for its sections.
  String? replace(GhostPlugin plugin) {
    final String id;
    final _Entry entry;
    try {
      id = plugin.id;
      entry = _Entry(plugin);
    } catch (_) {
      return 'threw';
    }
    if (shippedIds.contains(id)) return 'built_in';
    final at = _entries.indexWhere((e) => e.plugin.id == id);
    if (at < 0) return 'missing';
    final refused = _sectionsRefused(entry, besides: _entries[at]);
    if (refused != null) return refused;
    _entries[at] = entry;
    _changed();
    return null;
  }

  /// Takes the plugin [id] out and tells listeners; false for a shipped plugin or an id not here.
  bool uninstall(String id) {
    if (shippedIds.contains(id)) return false;
    final at = _entries.indexWhere((e) => e.plugin.id == id);
    if (at < 0) return false;
    _entries.removeAt(at);
    _changed();
    return true;
  }

  /// Why [entry]'s sections can't be among the others here ([besides] is the entry it takes the place of), or null.
  String? _sectionsRefused(_Entry entry, {required _Entry? besides}) {
    final taken = {for (final e in _entries) if (!identical(e, besides)) for (final s in e.sections) s.id};
    final own = <String>{};
    for (final s in entry.sections) {
      if (!_installedSection.hasMatch(s.id) || s.id == 'other') return 'bad_section';
      if (taken.contains(s.id) || !own.add(s.id)) return 'section_taken';
    }
    return null;
  }

  void _changed() {
    _version++;
    notifyListeners();
  }

  List<GhostPlugin> get plugins => [for (final e in _entries) e.plugin];

  /// There are no plugins at all: nothing is worked out for anyone.
  bool get isEmpty => _entries.isEmpty;

  // --- the switch ---------------------------------------------------------------------------------------------------

  /// The choice a plugin's switch is kept under.
  static String switchKey(GhostPlugin plugin) => 'plugin_${plugin.id}';

  /// Whether the person has [plugin] switched on; as the plugin starts ([GhostPlugin.onByDefault]) where they never
  /// chose.
  bool isOn(GhostPlugin plugin, PluginStore store) {
    if (plugin is OwnSwitch) return (plugin as OwnSwitch).on;
    final value = store.read(switchKey(plugin));
    return value == null ? plugin.onByDefault : value == 'on';
  }

  /// Told of every switch moved through [setOn]: the person's (a switch, Add, Remove, the app's API), and a pack added
  /// switched on. Plugin sync listens (lib/plugins/plugin_sync.dart, GMFB-9) and tells its own moves from the person's.
  static void Function(GhostPlugin plugin, bool on)? switched;

  /// Switches [plugin] on or off: its choice in [store], or its own switch where it keeps one ([OwnSwitch]).
  void setOn(GhostPlugin plugin, PluginStore store, bool on) {
    try {
      switched?.call(plugin, on);
    } catch (_) {}
    if (plugin is OwnSwitch) {
      // Its own switch, which says so itself once it has moved (Inbox.notifyChange).
      unawaited((plugin as OwnSwitch).turn(on));
      return;
    }
    store.write(switchKey(plugin), on ? 'on' : 'off');
  }

  /// Whether [plugin] is on where [circleOn] says what a circle has said of it: in a circle's space a plugin a circle
  /// may hold ([PluginScope.circle]) is on as the circle says (null: the circle has said nothing, so off), whatever this
  /// device's switch; anywhere else, and for any other plugin, as this device's switch says.
  bool isOnIn(GhostPlugin plugin, PluginStore store, {bool inCircle = false, bool? circleOn}) {
    if (inCircle && plugin.scopes.contains(PluginScope.circle)) return circleOn ?? false;
    return isOn(plugin, store);
  }

  /// What the plugins that are on in a call (or a circle) have to press at [slot]: [circleOn] says what the circle has
  /// said of each plugin, by its id ([isOnIn]).
  List<BoundAction> actionsIn<P>(ActionSlot<P> slot, P place, PluginStore store, {bool inCircle = false, bool? Function(String id)? circleOn}) {
    final out = <BoundAction>[];
    for (final e in _entries) {
      if (!isOnIn(e.plugin, store, inCircle: inCircle, circleOn: circleOn?.call(e.plugin.id))) continue;
      for (final fill in e.slots) {
        if (fill is! ActionFill<P> || fill.slot.name != slot.name) continue;
        for (final action in _ask(e.plugin, const <PluginAction>[], () => fill.build(place, prefsOf(e.plugin, store)))) {
          out.add(BoundAction(e.plugin, action));
        }
      }
    }
    return out;
  }

  /// The widgets the plugins that are on in a call (or a circle) put at [slot] ([actionsIn]).
  List<Widget> widgetsIn<P>(WidgetSlot<P> slot, BuildContext context, P place, PluginStore store, {bool inCircle = false, bool? Function(String id)? circleOn}) {
    final out = <Widget>[];
    for (final e in _entries) {
      if (!isOnIn(e.plugin, store, inCircle: inCircle, circleOn: circleOn?.call(e.plugin.id))) continue;
      for (final fill in e.slots) {
        if (fill is! WidgetFill<P> || fill.slot.name != slot.name) continue;
        out.addAll(_ask(e.plugin, const <Widget>[], () => fill.build(context, place, prefsOf(e.plugin, store))));
      }
    }
    return out;
  }

  /// The plugins a circle may hold, for Circle settings › Plugins.
  List<GhostPlugin> get circlePlugins => [for (final e in _entries) if (e.plugin.scopes.contains(PluginScope.circle)) e.plugin];

  /// Which plugins are on, as a mark that changes only when one is switched. What the classifiers said of a
  /// conversation holds until it does: they are given none of the person's other choices.
  /// A tuned classifier is told its plugin's choices ([TunedClassifier]): any of them changing is a change here too.
  /// It starts with [version]: a pack replaced by its update (or a reload in development) keeps its place and its
  /// switch, so without it every conversation would keep the old copy's tags.
  /// Whether the phone's contacts can be read is in it too: a pack sees only strangers it can tell from contacts, so
  /// once that changes every conversation's tags are worked out again (lib/plugins/pack/format.dart packSees).
  String switches(PluginStore store) => '$version:${MessageFacts.contactsReadable ? 'c' : 'n'}:${[for (final e in _entries) isOn(e.plugin, store) ? '1' : '0'].join()}:${store.read(tunedKey) ?? ''}';

  /// What the text rules' answers are worked out from: which of their plugins are on, and those plugins' own choices.
  /// Not [PluginStore.stamp], which goes up for every plugin's every choice (a conversation filed, Spam's strictness,
  /// Android's preferences read again): each of those asked every bubble on the screen again, on a computer one
  /// round trip to the phone each.
  String textMark(PluginStore store) {
    final parts = <String>[];
    for (final e in _entries) {
      if (e.text.isEmpty) continue;
      final own = store.withPrefix('plugin_${e.plugin.id}_').entries.toList()..sort((a, b) => a.key.compareTo(b.key));
      parts.add('${e.plugin.id}:${isOn(e.plugin, store) ? 1 : 0}:${[for (final c in own) '${c.key}=${c.value}'].join('&')}');
    }
    return parts.join('|');
  }

  /// Bumped whenever a plugin's own choice changes, for [switches].
  static const tunedKey = 'plugins_tuned';

  /// The plugin's own choices, kept under its name (`plugin_<id>_<key>`).
  PluginPrefs prefsOf(GhostPlugin plugin, PluginStore store) => _Prefs(store, 'plugin_${plugin.id}_', tunes: _entries.any((e) => identical(e.plugin, plugin) && e.tuned.isNotEmpty));

  /// The rows a plugin gives its card on Settings › Plugins.
  List<PluginSetting> settingsOf(GhostPlugin plugin) => [for (final e in _entries) if (identical(e.plugin, plugin)) ...e.settings];

  Iterable<_Entry> _on(PluginStore store) => _entries.where((e) => isOn(e.plugin, store));

  /// Everything asked of a plugin goes through here: what it throws is told ([_tell]) and [otherwise] stands in, so
  /// one plugin's fault never breaks the screen that asked.
  T _ask<T>(GhostPlugin plugin, T otherwise, T Function() ask) {
    try {
      return ask();
    } catch (error) {
      _tell(plugin, error);
      return otherwise;
    }
  }

  // --- (a) tags -----------------------------------------------------------------------------------------------------

  /// What every classifier of the plugins that are on says of [facts]. Not kept: [TagStore] keeps it for the list.
  TagSet classify(MessageFacts facts, PluginStore store) {
    List<Tag>? found;
    for (final e in _on(store)) {
      for (final classifier in e.classifiers) {
        final tags = _ask(e.plugin, const <Tag>[], () => classifier(facts));
        if (tags.isNotEmpty) (found ??= []).addAll(tags);
      }
      if (e.tuned.isEmpty) continue;
      final prefs = prefsOf(e.plugin, store);
      for (final classifier in e.tuned) {
        final tags = _ask(e.plugin, const <Tag>[], () => classifier(facts, prefs));
        if (tags.isNotEmpty) (found ??= []).addAll(tags);
      }
    }
    return found == null ? TagSet.none : TagSet(found);
  }

  // --- (b) sections -------------------------------------------------------------------------------------------------

  /// The sections of the plugins that are on, in the order they are asked.
  List<PluginSection> sections(PluginStore store) => [for (final e in _on(store)) ...e.sections];

  String? _filedRaw;
  Filing _filed = Filing.none;

  /// Where conversations have been filed by hand.
  Filing filing(PluginStore store) {
    final raw = store.read(Filing.key);
    if (raw != _filedRaw) {
      _filedRaw = raw;
      _filed = Filing.parse(raw);
    }
    return _filed;
  }

  /// The first of [sections] that takes the conversation, in their order; null where none does.
  PluginSection? _taker(MessageFacts facts, TagSet tags, PluginStore store, List<PluginSection> sections) {
    for (final s in sections) {
      if (_ask(s.plugin, false, () => s.section.takes(facts, tags, prefsOf(s.plugin, store)))) return s;
    }
    return null;
  }

  /// The section a conversation is in, or null for the main list: where it was filed by hand if it was (and that
  /// section's plugin is still on), else the first section that takes it. [among] is [sections], where the caller
  /// has them already.
  PluginSection? sectionOf(MessageFacts facts, TagSet tags, PluginStore store, {List<PluginSection>? among}) {
    final sections = among ?? this.sections(store);
    if (sections.isEmpty) return null;
    final filed = filing(store).of(facts.thread);
    if (filed != null) {
      if (filed == Filing.main) return null;
      for (final s in sections) {
        if (s.id != filed) continue;
        // Filed into a plugin from another developer's section, it stays only while that plugin may act on the
        // conversation (lib/plugins/pack/format.dart packMayAct) and isn't paused: one press of its move can never keep
        // a bank's codes, or a contact's texts, in its tab. Passed over, the sections decide as if it weren't filed;
        // the filing is kept, and holds again if the facts change back.
        if (s.plugin.source == PluginSource.builtIn) return s;
        final plugin = s.plugin;
        if (packMayAct(facts) && !(plugin is PackPlugin && plugin.paused)) return s;
        break;
      }
    }
    return _taker(facts, tags, store, sections);
  }

  /// Files a conversation in [section] (null: the main list), to stay there. Where that is where the sections would
  /// put it anyway, what was filed is forgotten and they decide again from then on.
  void move(MessageFacts facts, TagSet tags, String? section, PluginStore store) {
    final byRules = _taker(facts, tags, store, sections(store))?.id;
    final filed = filing(store);
    final next = filed._with(facts.thread, byRules == section ? null : (section ?? Filing.main));
    store.write(Filing.key, next._encode());
  }

  /// How a section draws a conversation of its own, or null for the main list's row.
  RowLook? look(PluginSection s, MessageFacts facts, TagSet tags, PluginStore store) {
    final row = s.section.row;
    return row == null ? null : _ask(s.plugin, null, () => row(facts, tags, prefsOf(s.plugin, store)));
  }

  // --- (c) slots ----------------------------------------------------------------------------------------------------

  /// What the plugins that are on have to press at [slot], each with the plugin whose it is.
  List<BoundAction> actions<P>(ActionSlot<P> slot, P place, PluginStore store) {
    final out = <BoundAction>[];
    for (final e in _on(store)) {
      for (final fill in e.slots) {
        if (fill is! ActionFill<P> || fill.slot.name != slot.name) continue;
        for (final action in _ask(e.plugin, const <PluginAction>[], () => fill.build(place, prefsOf(e.plugin, store)))) {
          out.add(BoundAction(e.plugin, action));
        }
      }
    }
    return out;
  }

  /// What the plugins that are on have to press at [slot], those of [only] alone ([actions] for every plugin's).
  List<BoundAction> actionsOf<P>(ActionSlot<P> slot, P place, PluginStore store, GhostPlugin only) => [for (final b in actions(slot, place, store)) if (identical(b.plugin, only)) b];

  /// The widgets the plugins that are on put at [slot]; those of [only] alone, where given.
  List<Widget> widgets<P>(WidgetSlot<P> slot, BuildContext context, P place, PluginStore store, {GhostPlugin? only}) {
    final out = <Widget>[];
    for (final e in _on(store)) {
      if (only != null && !identical(only, e.plugin)) continue;
      for (final fill in e.slots) {
        if (fill is! WidgetFill<P> || fill.slot.name != slot.name) continue;
        out.addAll(_ask(e.plugin, const <Widget>[], () => fill.build(context, place, prefsOf(e.plugin, store))));
      }
    }
    return out;
  }

  // --- (e) what a message's words are shown as ---------------------------------------------------------------------

  /// The device's own language tools, as the plugins' text rules are handed them: the phone's (or, on a computer,
  /// the paired phone's) translation. A test puts a fake here.
  static TextHost textHost = const DeviceTextHost();

  /// The text rules of the plugins that are on, in order, each with its plugin's choices: the first to answer has the
  /// bubble (shown_store.dart asks them and keeps the answers).
  List<BoundText> textRules(PluginStore store) => [
        for (final e in _on(store))
          if (e.text.isNotEmpty)
            for (final rule in e.text) BoundText(e.plugin, rule, prefsOf(e.plugin, store)),
      ];

  /// Tells [onError], and each error listener, that [plugin] threw while being asked something away from the registry
  /// (a text rule's future, a button's run).
  void failed(GhostPlugin plugin, Object error) => _tell(plugin, error);

  // --- (d) messages that have just come -----------------------------------------------------------------------------

  /// What the plugins that are on ask for of a conversation whose newest message has just come.
  List<BoundIncoming> incoming(MessageFacts facts, TagSet tags, PluginStore store) {
    final out = <BoundIncoming>[];
    String? section;
    var placed = false;
    for (final e in _on(store)) {
      if (e.incoming.isEmpty) continue;
      if (!placed) {
        section = sectionOf(facts, tags, store)?.id;
        placed = true;
      }
      for (final rule in e.incoming) {
        for (final action in _ask(e.plugin, const <IncomingAction>[], () => rule(facts, tags, section, prefsOf(e.plugin, store)))) {
          out.add(BoundIncoming(e.plugin, action));
        }
      }
    }
    return out;
  }
}

/// The app's own registry's onError: a line in the Developer log, as the list has always written one (Sms.devLog
/// swallows its own failures).
void logPluginError(GhostPlugin plugin, Object error) => Sms.instance.devLog('plugin', '${plugin.id}: ${'$error'.split('\n').first}');

/// Runs [action] with [host], telling [registry] (onError and every error listener) what it throws: a plugin's button
/// never breaks the screen it is on.
Future<void> runPluginAction(PluginRegistry registry, GhostPlugin plugin, PluginAction action, PluginHost host) async {
  try {
    await action.run(host);
  } catch (error) {
    registry.failed(plugin, error);
  }
}
