import 'dart:convert';
import 'platform_info.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'app_state.dart';
import 'desktop/mini_window.dart' show CallMini;
import 'sms.dart' show Sms;
import 'ui/markdown_field.dart';

/// The app's keyboard commands and push to talk (Matt, 2026-11-20: "add push to talk and full keyboard commands with a
/// keyboard shortcuts setting in settings"): what each does, the keys it is on unless changed, and the keys the person
/// chose, kept with the app's choices ('keys'). Settings › Keyboard shortcuts lists and changes them
/// (lib/ui/settings_panes.dart); the frame listens for them (lib/ui/shell.dart).
///
/// They are heard while the app is in front, on a computer and on a phone or tablet with a keyboard. A command with
/// Cmd (Ctrl on Windows and a phone), Ctrl or Alt in it works while typing; one on a key alone (push to talk's ` and
/// the like) does not fire while the cursor is in a text field, so it can still be typed.
enum KeyCommand {
  pushToTalk('Push to talk', 'Hold to talk in a call while push to talk is on', group: 'Calls'),
  toggleMute('Mute or unmute', 'In a call', group: 'Calls'),
  toggleDeafen('Deafen or undeafen', 'In a call', group: 'Calls'),
  leaveCall('Leave the call', 'In a call', group: 'Calls'),
  // GMFB-41 ("An always-on-top call overlay for games on desktop"): lib/desktop/mini_window.dart.
  miniWindow('Mini window', 'The call in a small window above every other, and back', group: 'Calls'),
  newChat('Start something new', 'A chat, a group, a space or a circle', group: 'Go to'),
  search('Search', 'The conversations\' search', group: 'Go to'),
  messages('Messages', 'The list of conversations', group: 'Go to'),
  contacts('Contacts', null, group: 'Go to'),
  archive('Archive', null, group: 'Go to'),
  voice('Spaces', 'Spaces and the call you are in', group: 'Go to'),
  settings('Settings', null, group: 'Go to'),
  marketplace('Marketplace', null, group: 'Go to'),
  closePage('Close the page', 'The conversation or page open beside the list', group: 'Go to'),
  toggleSidebar('Show or hide the list', 'Beside a conversation, on a wide window', group: 'Go to'),
  shortcuts('Keyboard shortcuts', 'This list', group: 'Go to'),
  // GMFB-41 (from the Uplink gap review: "Customization: ... keybinds"): moving between conversations and formatting
  // what is written.
  quickSwitch('Jump to a conversation', 'Type a name to go straight there', group: 'Conversations'),
  nextChat('Next conversation', 'The one below in the list', group: 'Conversations'),
  previousChat('Previous conversation', 'The one above in the list', group: 'Conversations'),
  markRead('Mark all as read', 'Every conversation in the tab shown', group: 'Conversations'),
  bold('Bold', 'The words chosen, or what you type next', group: 'Writing'),
  italic('Italic', 'The words chosen, or what you type next', group: 'Writing'),
  code('Code', 'The words chosen, or what you type next', group: 'Writing'),
  // GMFB-35 ("Composer shortcuts"): the rest of what a message can be written with.
  strike('Strikethrough', 'The words chosen, or what you type next', group: 'Writing'),
  spoiler('Spoiler', 'Hidden until pressed: the words chosen, or what you type next', group: 'Writing'),
  quote('Quote', 'The lines chosen, or the line the cursor is on', group: 'Writing');

  const KeyCommand(this.label, this.hint, {required this.group});

  /// What Settings calls it, the line under that where it has one, and the heading it is listed under.
  final String label;
  final String? hint;
  final String group;
}

/// A key and what is held with it. [primary] is Cmd on a Mac and Ctrl elsewhere, as an app's shortcuts are.
@immutable
class KeyBinding {
  const KeyBinding(this.key, {this.primary = false, this.shift = false, this.alt = false, this.control = false});

  final LogicalKeyboardKey key;
  final bool primary;
  final bool shift;
  final bool alt;

  /// Ctrl as itself on a Mac, where [primary] is Cmd; on the others it is [primary].
  final bool control;

  /// Whether this is the Mac app (never a browser, even on a Mac).
  static bool get _mac => !kIsWeb && PlatformInfo.isMacOS;

  /// Whether it holds a key that is not typed: it works while the cursor is in a field.
  bool get chord => primary || alt || control;

  /// As it is kept: the key's id under 'k', and a 1 under 'p', 's', 'a' or 'c' for each thing held with it.
  Map<String, Object> toJson() => {'k': key.keyId, if (primary) 'p': 1, if (shift) 's': 1, if (alt) 'a': 1, if (control) 'c': 1};

  static KeyBinding? fromJson(Object? j) {
    if (j is! Map || j['k'] is! int) return null;
    final key = LogicalKeyboardKey.findKeyByKeyId(j['k'] as int);
    if (key == null) return null;
    return KeyBinding(key, primary: j['p'] == 1, shift: j['s'] == 1, alt: j['a'] == 1, control: j['c'] == 1);
  }

  /// The binding made by a key pressed now, with what is held: what a person sets in Settings.
  static KeyBinding? pressed(KeyEvent e) {
    final k = e.logicalKey;
    if (_modifier(k)) return null;
    final held = HardwareKeyboard.instance;
    final meta = held.isMetaPressed, ctrl = held.isControlPressed;
    return KeyBinding(
      k,
      primary: _mac ? meta : ctrl,
      control: _mac && ctrl,
      shift: held.isShiftPressed,
      alt: held.isAltPressed,
    );
  }

  /// A key that is only ever held with another: pressed by itself it is no binding.
  static bool _modifier(LogicalKeyboardKey k) => {
        LogicalKeyboardKey.shiftLeft, LogicalKeyboardKey.shiftRight, LogicalKeyboardKey.shift,
        LogicalKeyboardKey.controlLeft, LogicalKeyboardKey.controlRight, LogicalKeyboardKey.control,
        LogicalKeyboardKey.altLeft, LogicalKeyboardKey.altRight, LogicalKeyboardKey.alt,
        LogicalKeyboardKey.metaLeft, LogicalKeyboardKey.metaRight, LogicalKeyboardKey.meta,
        LogicalKeyboardKey.fn, LogicalKeyboardKey.capsLock,
      }.contains(k);

  /// Whether [e] is this key with exactly what this holds held (Shift and the rest must match, so Cmd+Shift+M is not
  /// Cmd+M).
  bool matches(KeyEvent e) {
    if (!_same(e.logicalKey, key)) return false;
    final held = HardwareKeyboard.instance;
    final meta = held.isMetaPressed, ctrl = held.isControlPressed;
    final wantMeta = _mac && primary, wantCtrl = _mac ? control : primary;
    return meta == wantMeta && ctrl == wantCtrl && held.isShiftPressed == shift && held.isAltPressed == alt;
  }

  /// The same key, either side's for a modifier used alone and the number row's or the keypad's Enter.
  static bool _same(LogicalKeyboardKey a, LogicalKeyboardKey b) {
    if (a == b) return true;
    bool enter(LogicalKeyboardKey k) => k == LogicalKeyboardKey.enter || k == LogicalKeyboardKey.numpadEnter;
    return enter(a) && enter(b);
  }

  /// How it is written: "Cmd+Shift+M" on a Mac, "Ctrl+Shift+M" elsewhere.
  String get label {
    final name = _keyName(key);
    // In words, not ⌘ and ⇧: the app's own font has no such signs.
    if (_mac) return [if (primary) 'Cmd', if (control) 'Ctrl', if (alt) 'Option', if (shift) 'Shift', name].join('+');
    return [if (primary || control) 'Ctrl', if (alt) 'Alt', if (shift) 'Shift', name].join('+');
  }

  static String _keyName(LogicalKeyboardKey k) {
    if (k == LogicalKeyboardKey.backquote) return '`';
    if (k == LogicalKeyboardKey.space) return 'Space';
    if (k == LogicalKeyboardKey.escape) return 'Esc';
    if (k == LogicalKeyboardKey.comma) return ',';
    if (k == LogicalKeyboardKey.slash) return '/';
    if (k == LogicalKeyboardKey.enter) return 'Enter';
    if (k == LogicalKeyboardKey.backslash) return '\\';
    if (k == LogicalKeyboardKey.arrowUp) return 'Up';
    if (k == LogicalKeyboardKey.arrowDown) return 'Down';
    if (k == LogicalKeyboardKey.arrowLeft) return 'Left';
    if (k == LogicalKeyboardKey.arrowRight) return 'Right';
    final label = k.keyLabel;
    return label.isEmpty ? (k.debugName ?? '?') : (label.length == 1 ? label.toUpperCase() : label);
  }

  @override
  bool operator ==(Object other) => other is KeyBinding && other.key == key && other.primary == primary && other.shift == shift && other.alt == alt && other.control == control;

  @override
  int get hashCode => Object.hash(key, primary, shift, alt, control);
}

/// Which keys each command is on now: its own unless the person chose others. Tells its listeners on any change.
class Keys extends ChangeNotifier {
  Keys._();
  static final Keys instance = Keys._();

  /// A fresh one, for a test.
  @visibleForTesting
  factory Keys.forTest() => Keys._();

  AppState? _app;

  /// The person's own choices: a command not in here is on its default, one here with null is on no key.
  final Map<KeyCommand, KeyBinding?> _chosen = {};

  /// The conversation list's search field, while it is on the screen: what [KeyCommand.search] puts the cursor in.
  static final searchFocus = FocusNode(debugLabel: 'conversations search');

  /// The keys each command is on until changed.
  static const defaults = {
    KeyCommand.pushToTalk: KeyBinding(LogicalKeyboardKey.backquote),
    KeyCommand.toggleMute: KeyBinding(LogicalKeyboardKey.keyM, primary: true, shift: true),
    KeyCommand.toggleDeafen: KeyBinding(LogicalKeyboardKey.keyD, primary: true, shift: true),
    KeyCommand.leaveCall: KeyBinding(LogicalKeyboardKey.keyE, primary: true, shift: true),
    // O for overlay, with Shift as the calls' others are.
    KeyCommand.miniWindow: KeyBinding(LogicalKeyboardKey.keyO, primary: true, shift: true),
    KeyCommand.newChat: KeyBinding(LogicalKeyboardKey.keyN, primary: true),
    // Cmd+K jumps to a conversation, as most messengers have it; Search moved to Cmd+F for it (GMFB-41).
    KeyCommand.search: KeyBinding(LogicalKeyboardKey.keyF, primary: true),
    KeyCommand.messages: KeyBinding(LogicalKeyboardKey.digit1, primary: true),
    KeyCommand.contacts: KeyBinding(LogicalKeyboardKey.digit2, primary: true),
    KeyCommand.archive: KeyBinding(LogicalKeyboardKey.digit3, primary: true),
    KeyCommand.voice: KeyBinding(LogicalKeyboardKey.digit4, primary: true),
    KeyCommand.settings: KeyBinding(LogicalKeyboardKey.comma, primary: true),
    KeyCommand.marketplace: KeyBinding(LogicalKeyboardKey.digit5, primary: true),
    KeyCommand.closePage: KeyBinding(LogicalKeyboardKey.keyW, primary: true),
    KeyCommand.shortcuts: KeyBinding(LogicalKeyboardKey.slash, primary: true),
    KeyCommand.toggleSidebar: KeyBinding(LogicalKeyboardKey.backslash, primary: true),
    KeyCommand.quickSwitch: KeyBinding(LogicalKeyboardKey.keyK, primary: true),
    KeyCommand.nextChat: KeyBinding(LogicalKeyboardKey.arrowDown, alt: true),
    KeyCommand.previousChat: KeyBinding(LogicalKeyboardKey.arrowUp, alt: true),
    KeyCommand.markRead: KeyBinding(LogicalKeyboardKey.keyR, primary: true, shift: true),
    KeyCommand.bold: KeyBinding(LogicalKeyboardKey.keyB, primary: true),
    KeyCommand.italic: KeyBinding(LogicalKeyboardKey.keyI, primary: true),
    KeyCommand.code: KeyBinding(LogicalKeyboardKey.keyE, primary: true),
    // With Shift, on letters: Cmd+X is Cut, and a number or a sign with Shift is another key on some keyboards.
    // Strikethrough and Spoiler where other messengers have them; B for a block quote (Cmd+Shift+Q logs out of a Mac).
    KeyCommand.strike: KeyBinding(LogicalKeyboardKey.keyX, primary: true, shift: true),
    KeyCommand.spoiler: KeyBinding(LogicalKeyboardKey.keyP, primary: true, shift: true),
    KeyCommand.quote: KeyBinding(LogicalKeyboardKey.keyB, primary: true, shift: true),
  };

  /// The formatting each of the Writing commands puts round the words chosen (lib/message_format.dart). Quote is not
  /// here: it goes before each line ([format]).
  static const markers = {KeyCommand.bold: '**', KeyCommand.italic: '*', KeyCommand.code: '`', KeyCommand.strike: '~~', KeyCommand.spoiler: '||'};

  void start(AppState app) {
    _app = app;
    _chosen.clear();
    try {
      final kept = jsonDecode(app.choice('keys', '{}')) as Map;
      for (final c in KeyCommand.values) {
        if (!kept.containsKey(c.name)) continue;
        // null kept: the person took the command off any key.
        _chosen[c] = KeyBinding.fromJson(kept[c.name]);
      }
    } catch (_) {}
    notifyListeners();
  }

  /// Push to talk: in a call the microphone is off unless its key is held. Off unless switched on.
  bool get pushToTalk => _app?.flag('push_to_talk', fallback: false) ?? false;
  void setPushToTalk(bool on) {
    _app?.setFlag('push_to_talk', on);
    notifyListeners();
  }

  /// The keys [c] is on: the person's, or its own; null where it is on none.
  KeyBinding? of(KeyCommand c) => _chosen.containsKey(c) ? _chosen[c] : defaults[c];

  /// Whether [c] is on other keys than its own: Settings then offers to put it back.
  bool changed(KeyCommand c) => _chosen.containsKey(c) && _chosen[c] != defaults[c];

  /// What [b] already is to every text field or to the computer itself, where it is something a command must not take:
  /// copy, paste and the like, and quitting. Null where it is free. Settings will not put a command on these
  /// (lib/ui/settings_shortcuts.dart).
  static String? reservedFor(KeyBinding b) {
    if (!b.primary || b.alt || b.control) return null;
    final k = b.key;
    if (b.shift) return k == LogicalKeyboardKey.keyZ ? 'Redo' : null;
    if (k == LogicalKeyboardKey.keyC) return 'Copy';
    if (k == LogicalKeyboardKey.keyV) return 'Paste';
    if (k == LogicalKeyboardKey.keyX) return 'Cut';
    if (k == LogicalKeyboardKey.keyA) return 'Select all';
    if (k == LogicalKeyboardKey.keyZ) return 'Undo';
    if (k == LogicalKeyboardKey.keyQ) return 'Quit';
    if (k == LogicalKeyboardKey.keyY && !KeyBinding._mac) return 'Redo';
    return null;
  }

  /// The command already on [b], other than [except]: what a new binding would take it from.
  KeyCommand? usedBy(KeyBinding b, {KeyCommand? except}) =>
      KeyCommand.values.where((c) => c != except && of(c) == b).firstOrNull;

  /// Puts [c] on [b] (null: on no key). Another command on the same keys is taken off them.
  void set(KeyCommand c, KeyBinding? b) {
    if (b != null) {
      final other = usedBy(b, except: c);
      if (other != null) _chosen[other] = null;
    }
    _chosen[c] = b;
    _save();
  }

  /// Puts [c] back on its own keys. Another command the person had put on those keys is taken off them.
  void reset(KeyCommand c) {
    _chosen.remove(c);
    final mine = defaults[c];
    if (mine != null) {
      final other = usedBy(mine, except: c);
      if (other != null) _chosen[other] = null;
    }
    _save();
  }

  void resetAll() {
    _chosen.clear();
    _save();
  }

  void _save() {
    _app?.set('keys', jsonEncode({for (final e in _chosen.entries) e.key.name: e.value?.toJson()}));
    notifyListeners();
  }

  /// Whether [c] is a command of something this device has: not the calls' where there are no calls (a browser, for
  /// now: Sms.callsHere), nor the Marketplace where there is none (a browser, which has nowhere to keep a plugin). One
  /// that isn't is on no key ([commandFor]), and in neither Settings' list of shortcuts nor the quick switcher
  /// (lib/ui/settings_shortcuts.dart, lib/ui/shell.dart). Everywhere else, every one is.
  static bool offered(KeyCommand c) => c == KeyCommand.miniWindow ? CallMini.here : c.group == 'Calls' ? Sms.callsHere : c == KeyCommand.marketplace ? !Sms.browser : true;

  /// The command [e] is, given whether the cursor is in a text field ([typing]): one on a key alone is not taken
  /// from someone typing, and one of something this device hasn't got ([offered]) is no command here.
  KeyCommand? commandFor(KeyEvent e, {required bool typing}) {
    for (final c in KeyCommand.values) {
      if (!offered(c)) continue;
      final b = of(c);
      if (b == null || !b.matches(e)) continue;
      if (typing && !b.chord) continue;
      return c;
    }
    return null;
  }

  /// The field the cursor is in, where it is one that formats its words (the composer of a chat that shows
  /// formatting: not a text, which would show the asterisks as written). Null anywhere else.
  static MarkdownController? get formatting {
    final ctx = FocusManager.instance.primaryFocus?.context;
    if (ctx == null) return null;
    final field = ctx.widget is EditableText ? ctx.widget as EditableText : ctx.findAncestorWidgetOfExactType<EditableText>();
    final c = field?.controller;
    if (c is! MarkdownController || !(c.dims?.call() ?? true)) return null;
    return c;
  }

  /// Puts [command]'s markers round the words chosen in the field the cursor is in, or for Quote "> " before each of
  /// their lines: false where it is in none that formats, so the key goes on to whatever else wants it.
  static bool format(KeyCommand command) {
    final marker = markers[command];
    final field = formatting;
    if (field == null || (marker == null && command != KeyCommand.quote)) return false;
    if (marker == null) {
      field.quoteSelection();
    } else {
      field.wrapSelection(marker);
    }
    return true;
  }

  /// Where Next and Previous conversation go in a list of [length]: [by] rows on from [at], held at the ends; the first
  /// or the last where [at] is -1 (none of the list's is open).
  static int stepTo(int length, int at, int by) => at < 0 ? (by > 0 ? 0 : length - 1) : (at + by).clamp(0, length - 1);

  /// Whether the cursor is in a text field now.
  static bool get typing {
    final ctx = FocusManager.instance.primaryFocus?.context;
    if (ctx == null) return false;
    return ctx.widget is EditableText || ctx.findAncestorWidgetOfExactType<EditableText>() != null;
  }
}
