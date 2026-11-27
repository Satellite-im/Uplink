/// Settings › Keyboard shortcuts (Matt, 2026-11-20: "add push to talk and full keyboard commands with a keyboard
/// shortcuts setting in settings"): push to talk, every command with the keys it is on, and a way to put each on
/// other keys, take it off them, or put it back. What they do is lib/keys.dart's; the frame hears them
/// (lib/ui/shell.dart).
library;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../art/app_icon.dart';
import '../art/lucide.g.dart';
import '../art/lucide_more.dart';
import '../kit/settings_kit.dart';
import '../kit/settings_type.dart';
import '../keys.dart';
import '../sms.dart' show Sms;
import 'common.dart';
import 'settings.dart';
import '../l10n/words.dart';

Widget _icon(LucideIcon icon) => AppIcon(icon, size: 18);

// Where there are no calls (a browser, for now: Sms.callsHere) there is no push to talk to speak of, nor the calls'
// commands to put on keys.
String shortcutsSummary(SettingsModel m) => !Sms.callsHere
    ? 'Every command and its keys'
    : Keys.instance.pushToTalk
        ? 'Push to talk on ${Keys.instance.of(KeyCommand.pushToTalk)?.label ?? 'no key'}'
        : 'Push to talk off';

/// The pane's rows: the push to talk switch, every command under its group's heading, and "Put every shortcut back".
List<Widget> shortcutsPane(BuildContext context, SettingsModel m) {
  final keys = Keys.instance;
  final groups = <String, List<KeyCommand>>{};
  // Only what this device has (Keys.offered): in a browser, no calls' commands and no Marketplace.
  for (final c in KeyCommand.values) {
    if (!Keys.offered(c)) continue;
    (groups[c.group] ??= []).add(c);
  }
  return [
    if (Sms.callsHere) PaneSection(
      footer: Text('In a call your microphone stays off, and is on only while you hold ${keys.of(KeyCommand.pushToTalk)?.label ?? 'its key'}. It works while Uplink is the app in front.'),
      children: [
        SettingRow(
          icon: _icon(Lucide.mic),
          label: 'Push to talk',
          hint: const Tr('Hold a key to talk in calls'),
          control: GlacierSwitch(checked: keys.pushToTalk, onCheckedChange: keys.setPushToTalk, ariaLabel: 'Push to talk'),
        ),
      ],
    ),
    for (final group in groups.entries)
      PaneSection(
        title: group.key,
        footer: group.key == 'Writing'
            ? const Tr('In a chat with a friend, a group or a space: the markers go round the words chosen. A text message shows them as written, so they are not added there.')
            : group.key == 'Conversations'
                ? const Tr('Next and previous go down and up the list as it is shown. Jump finds any conversation by name or number, and the app\'s places.')
                : null,
        children: [for (final c in group.value) _ShortcutRow(command: c)],
      ),
    PaneSection(
      footer: const Tr('A command on a key alone, such as push to talk on `, waits while you are typing, so the key still types. One with Cmd, Ctrl or Alt works anywhere.'),
      children: [
        SettingRow(icon: _icon(Lucide.rotateCcw), label: 'Put every shortcut back', disabled: !KeyCommand.values.any(keys.changed), onPress: () {
          keys.resetAll();
          toast(context, 'Every shortcut is back on its own keys');
        }),
      ],
    ),
  ];
}

/// One command and the keys it is on. Pressed, it offers to change the keys, take it off them, or put it back on
/// its own.
class _ShortcutRow extends StatelessWidget implements PaneRow {
  const _ShortcutRow({required this.command});
  final KeyCommand command;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final keys = Keys.instance;
    final b = keys.of(command);
    return SettingRow(
      label: command.label,
      hint: command.hint == null ? null : Text(command.hint!),
      value: _KeyCap(text: b?.label ?? 'None', faint: b == null, t: t),
      onPress: () => showChoices(context, title: '${command.label}: ${b?.label ?? 'on no key'}', choices: [
        Choice('Change the keys', LucideMore.keyboard, () => push<void>(context, (_) => KeyRecorder(command: command))),
        if (b != null) Choice('Use no key', Lucide.x, () => keys.set(command, null)),
        if (keys.changed(command) || b == null)
          Choice('Put back on ${Keys.defaults[command]?.label ?? 'no key'}', Lucide.rotateCcw, () => keys.reset(command)),
      ]),
    );
  }
}

/// A command's keys drawn as a small bordered cap; [faint] for "None".
class _KeyCap extends StatelessWidget {
  const _KeyCap({required this.text, required this.t, this.faint = false});
  final String text;
  final Tokens t;
  final bool faint;

  @override
  Widget build(BuildContext context) => Container(
        padding: EdgeInsets.symmetric(horizontal: t.space(2), vertical: 2),
        decoration: BoxDecoration(
          color: t.color('app-paper-2'),
          borderRadius: BorderRadius.circular(t.radius('sm')),
          border: Border.all(color: t.color('glacier-border-subtle')),
        ),
        child: Text(text, style: pageText(t, t.fontSize('sm'), weight: 'medium', color: t.color(faint ? 'app-ink-3' : 'app-ink'))),
      );
}

/// Waiting for the keys to put [command] on: the next key pressed, with what is held with it. Esc alone puts it away
/// unchanged. While it waits the app's own commands are not heard (lib/ui/shell.dart).
class KeyRecorder extends StatefulWidget {
  const KeyRecorder({super.key, required this.command});
  final KeyCommand command;

  /// A page like this one is open: the frame leaves keys to it.
  static bool listening = false;

  @override
  State<KeyRecorder> createState() => _KeyRecorderState();
}

class _KeyRecorderState extends State<KeyRecorder> {
  KeyBinding? _got;

  @override
  void initState() {
    super.initState();
    KeyRecorder.listening = true;
    HardwareKeyboard.instance.addHandler(_key);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_key);
    KeyRecorder.listening = false;
    super.dispose();
  }

  /// Every key pressed while the page is open: always answers true, so nothing else in the app acts on it.
  bool _key(KeyEvent e) {
    if (e is! KeyDownEvent) return true;
    final held = HardwareKeyboard.instance;
    if (e.logicalKey == LogicalKeyboardKey.escape && !held.isMetaPressed && !held.isControlPressed && !held.isAltPressed && !held.isShiftPressed) {
      Navigator.of(context).maybePop();
      return true;
    }
    final b = KeyBinding.pressed(e);
    if (b == null) return true;
    setState(() => _got = b);
    return true;
  }

  /// Puts the command on the keys pressed and says so, naming the command that had them before, if one did.
  void _save() {
    final b = _got;
    if (b == null || Keys.reservedFor(b) != null) return;
    final keys = Keys.instance;
    final other = keys.usedBy(b, except: widget.command);
    keys.set(widget.command, b);
    toast(context, other == null ? '${widget.command.label} is on ${b.label}' : '${widget.command.label} is on ${b.label}. ${other.label} is on no key now.');
    Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final got = _got;
    final taken = got == null ? null : Keys.instance.usedBy(got, except: widget.command);
    // Copy, paste and the rest are every field's: never taken (Keys.reservedFor).
    final reserved = got == null ? null : Keys.reservedFor(got);
    return GhostPage(
      title: widget.command.label,
      body: SettingsPaneScope(
        finder: SettingsFinder(),
        child: ListView(
          padding: EdgeInsetsDirectional.fromSTEB(t.space(4), t.space(2), t.space(4), t.space(8)),
          children: [
            PaneSection(
              description: Text(got == null ? 'Press the keys you want, all together. Esc leaves it as it was.' : 'Press other keys to change them, or save these.'),
              footer: reserved != null
                  ? Text('${got!.label} is $reserved everywhere you type. Choose other keys.', key: const ValueKey('reserved-keys'), style: TextStyle(color: t.colorOf('#c27c0e')))
                  : taken == null
                      ? null
                      : Text('${taken.label} is on these keys now. Saving takes them from it.', key: const ValueKey('clashing-keys'), style: TextStyle(color: t.colorOf('#c27c0e'))),
              children: [
                SettingRowBox(
                  child: Padding(
                    padding: EdgeInsets.symmetric(vertical: t.space(6)),
                    child: Center(child: Text(got?.label ?? 'Waiting for keys…', key: const ValueKey('recorded-keys'), style: pageText(t, t.lenOf('1.6rem'), weight: 'bold', color: t.color(got == null ? 'app-ink-3' : 'app-ink')))),
                  ),
                ),
                SettingRow(icon: _icon(Lucide.check), label: 'Save', disabled: got == null || reserved != null, onPress: _save),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
