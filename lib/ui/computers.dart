/// Settings › Computers on the phone: the computers it is paired with, and pairing with another (Matt, 2026-11-13:
/// "a companion desktop app that can proxy messages encrypted from my phone to my desktop", and "I'd like to support
/// both a relay server and local networking, it should attempt to use local networking by default and show the
/// option for both in the setup wizard"; docs/desktop.md). What is paired, and the pairing itself, are Android's
/// (android/.../Desk.kt); this is the screen over them. The Mac's wizard (lib/desktop) uses the same three choices.
library;

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../account/handover.dart' show HandoverCode;
import '../art/app_icon.dart';
import '../art/lucide.g.dart';
import '../art/lucide_more.dart';
import '../kit/settings_kit.dart';
import '../kit/settings_type.dart';
import '../sms.dart';
import 'common.dart';
import 'dialup/dialup.dart';
import 'handover_screens.dart' show HandoverApproveScreen;
import 'settings.dart';
import '../l10n/words.dart';

/// One of the three ways a phone and a computer reach each other.
class ConnectionMode {
  const ConnectionMode(this.id, this.label, this.hint, this.icon);
  final String id;
  final String label;
  final String hint;
  final LucideIcon icon;
}

/// The three ways a phone and a computer connect, by the ids Android keeps them under; the first is the default.
const connectionModes = [
  ConnectionMode('both', 'Local network, then relay', 'Tries the network the two share first, and the relay when they are apart.', Lucide.network),
  ConnectionMode('local', 'Local network only', 'Only while the phone and the computer are on the same network. Nothing leaves it.', Lucide.wifi),
  ConnectionMode('relay', 'Relay only', 'Always through the relay, which passes sealed data it cannot read.', LucideMore.cloud),
];

/// A mode's name by its id; the first mode's for an id that is not known.
String connectionLabel(String mode) => connectionModes.firstWhere((m) => m.id == mode, orElse: () => connectionModes.first).label;

/// A relay's address as a person reads it: its host, without the scheme or the path.
String relayHost(String relay) {
  final uri = Uri.tryParse(relay.trim());
  if (uri == null || uri.host.isEmpty) return relay.trim();
  return uri.hasPort ? '${uri.host}:${uri.port}' : uri.host;
}

/// The three ways to connect, one of them chosen. With no [relay] to use, the two that need one are not offered.
class ConnectionChoice extends StatelessWidget {
  const ConnectionChoice({super.key, required this.value, required this.onChanged, required this.relay, this.title = 'How to connect', this.footer});
  final String value;
  final ValueChanged<String> onChanged;
  final String relay;
  final String title;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final none = relay.trim().isEmpty;
    return PaneSection(
      title: title,
      footer: footer ??
          Text(none
              ? 'No relay address is set, so only the local network can be used.'
              : 'The relay is ${relayHost(relay)}. It passes sealed data between the two while both are connected, and keeps none of it.'),
      children: [
        for (final m in connectionModes)
          SettingRow(
            icon: AppIcon(m.icon, size: 18),
            label: m.label,
            hint: Text(m.hint),
            disabledReason: none && m.id != 'local' ? 'There is no relay to use.' : null,
            control: Pick(checked: value == m.id, label: 'Use ${m.label.toLowerCase()}', onPress: () => onChanged(m.id), disabled: none && m.id != 'local'),
          ),
      ],
    );
  }
}

/// How long ago in words: minutes, then hours, and from a day on the date as the list of conversations writes it.
String _ago(DateTime? when) {
  if (when == null) return 'never';
  final d = DateTime.now().difference(when);
  if (d.inMinutes < 2) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes} minutes ago';
  if (d.inHours < 24) return d.inHours == 1 ? 'an hour ago' : '${d.inHours} hours ago';
  return listWhen(when);
}

/// How a paired computer stands, in a line: connected and how, or when it was last seen.
String computerLine(Computer c) => switch (c.via) {
      'local' => 'Connected over the local network',
      'relay' => 'Connected through the relay',
      _ => c.seen == null ? 'Not seen yet' : 'Last seen ${_ago(c.seen)}',
    };

/// The page's cards: the paired computers, pairing another, and what keeps the phone reachable.
List<Widget> computersPane(BuildContext context, SettingsModel m) {
  Widget icon(LucideIcon i) => AppIcon(i, size: 18);

  // A paired computer's menu: how it connects (the relay's ways only where it was paired with a relay), and the rest.
  void manage(Computer c) {
    showChoices(context, title: '${c.name}\n${computerLine(c)} · paired ${c.since == null ? '' : listWhen(c.since!)}', choices: [
      for (final mode in connectionModes)
        if (mode.id == 'local' || c.relay.isNotEmpty)
          Choice('${mode.label}${c.mode == mode.id ? '  ✓' : ''}', mode.icon, () async {
            try {
              await Sms.instance.setComputerMode(c.id, mode.id);
            } catch (e) {
              if (context.mounted) toast(context, 'Couldn\'t change it: $e', tone: GlacierToastTone.danger);
            }
            m.refresh();
          }),
      Choice('Unpair', Lucide.unlink, () {
        showChoices(context, title: 'Unpair ${c.name}? It stops showing this phone\'s texts, and its key is deleted from this phone.', choices: [
          Choice('Unpair', Lucide.unlink, () async {
            await Sms.instance.unpairComputer(c.id);
            await m.refresh();
            if (context.mounted) toast(context, '${c.name} is unpaired');
          }, danger: true),
        ]);
      }, danger: true),
    ]);
  }

  return [
    PaneSection(
      title: 'Paired computers',
      footer: m.computers.isEmpty ? const Tr('None yet. Uplink on a computer shows this phone\'s conversations and sends texts through it. The phone stays the only thing that texts.') : null,
      children: [
        for (final c in m.computers)
          SettingRow(
            icon: icon(Lucide.laptop),
            label: c.name,
            hint: Text('${computerLine(c)} · ${connectionLabel(c.mode).toLowerCase()}'),
            onPress: () => manage(c),
          ),
        SettingRow(
          icon: icon(LucideMore.qrCode),
          label: 'Pair a computer',
          hint: const Tr('Scan the code Uplink shows on the computer.'),
          onPress: () async {
            await push<void>(context, (_) => const PairComputerScreen());
            m.refresh();
          },
        ),
      ],
    ),
    PaneSection(
      title: 'What it is',
      children: [
        SettingRow(
          icon: icon(Lucide.lock),
          label: 'Sealed between the two',
          hint: const Tr('Everything the phone and a paired computer say to each other is sealed with a key only they hold, made when they pair. On the local network it goes straight from one to the other. A relay only ever carries the sealed data: it learns that the two are paired, and nothing they say.'),
        ),
        SettingRow(
          icon: icon(Lucide.info),
          label: 'What a computer can do',
          hint: const Tr('Read your conversations and pictures, send texts through this phone, mark as read, pin, mute and archive. It cannot delete, block, or change encryption. Texts are not kept on the computer\'s disk.'),
        ),
      ],
    ),
    if (m.computers.isNotEmpty)
      PaneSection(
        title: 'Staying reachable',
        footer: const Tr('In deep sleep (still, unplugged, screen off for a long while) Android cuts every app\'s network. New texts still reach the computer, since Android lets them through. What you type on the computer waits there until the phone wakes, unless battery use is Unrestricted.'),
        children: [
          SettingRow(
            icon: icon(Lucide.bell),
            label: 'The "Paired with…" notification',
            hint: const Tr('Android stops an app minutes after the screen goes off unless it shows a notification, and won\'t let the app hide it. It is as quiet as Android allows: one line at the foot of the shade, no icon, no sound. Press to turn it off on Android\'s page; the computer still reaches the phone.'),
            onPress: () => Sms.instance.deskNotificationSettings(),
          ),
          if (m.phoneAddresses.isNotEmpty)
            SettingRow(
              icon: icon(Lucide.network),
              label: 'This phone\'s address',
              hint: Text('${m.phoneAddresses.join(', ')}. Only needed where a network keeps the computer from finding the phone: it is typed in the computer\'s Settings.'),
            ),
          SettingRow(
            icon: icon(Lucide.hourglass),
            label: 'Battery use',
            hint: Text(m.unrestricted ? 'Unrestricted: the computer can reach the phone in deep sleep too.' : 'Optimised. Set it to Unrestricted on Android\'s page for the app to be reachable in deep sleep too.'),
            onPress: () => Sms.instance.openAppInfo(),
          ),
        ],
      ),
  ];
}

/// Pairing with a computer, start to end: scan its code (or paste it), choose how the two connect, compare the six
/// digits, done.
class PairComputerScreen extends StatefulWidget {
  const PairComputerScreen({super.key, this.offered});

  /// A pairing code that came from outside the app: the phone's camera opened the link in a computer's QR code, or
  /// something else did. It is not acted on until the person says so here, since anything can open a link: a page
  /// that wanted this phone's texts could offer a code of its own.
  final String? offered;

  @override
  State<PairComputerScreen> createState() => _PairComputerScreenState();
}

class _PairComputerScreenState extends State<PairComputerScreen> {
  PairingState _state = const PairingState();
  StreamSubscription<void>? _changes;
  Timer? _tick;
  final _code = TextEditingController();
  bool _pasting = false;
  String? _problem;

  /// The computer an offered code is from, once it has been read; and whether the person has said to go on.
  String? _offeredName;
  bool _accepted = false;

  @override
  void initState() {
    super.initState();
    _changes = Sms.instance.computersChanged.stream.listen((_) => _read());
    // A code that runs out is noticed when asked about: asked now and then while the page waits.
    _tick = Timer.periodic(const Duration(seconds: 5), (_) => _read());
    _read();
    final offered = widget.offered;
    if (offered != null) {
      Sms.instance.pairingCodeName(offered).then((name) {
        if (mounted) setState(() => _offeredName = name);
      }).catchError((Object _) {
        if (mounted) {
          setState(() {
            _accepted = true;
            _problem = 'That link isn\'t an Uplink pairing code.';
          });
        }
      });
    }
  }

  @override
  void dispose() {
    _changes?.cancel();
    _tick?.cancel();
    _code.dispose();
    // Left before it was finished: the pairing is dropped, so a code scanned and walked away from does nothing.
    if (_state.phase == 'waiting' || _state.phase == 'code') Sms.instance.cancelPairing();
    if (_state.phase == 'done' || _state.phase == 'failed') Sms.instance.pairingShown();
    super.dispose();
  }

  /// Asks Android where the pairing stands, and shows that.
  Future<void> _read() async {
    try {
      final s = await Sms.instance.pairing();
      if (mounted) setState(() => _state = s);
    } catch (_) {}
  }

  /// Starts pairing with the computer whose code this is; a code that can't be used is said under the buttons.
  Future<void> _begin(String code) async {
    try {
      final s = await Sms.instance.beginPairing(code.trim());
      if (mounted) {
        setState(() {
          _state = s;
          _problem = null;
        });
      }
    } on PlatformException catch (e) {
      if (mounted) setState(() => _problem = e.message ?? 'That code could not be used.');
    } catch (e) {
      if (mounted) setState(() => _problem = '$e');
    }
  }

  /// Scans the computer's code with the camera and begins with what it read.
  Future<void> _scan() async {
    final r = await Sms.instance.scanPairingCode();
    if (!mounted) return;
    if (r.denied) {
      setState(() => _problem = 'The camera was refused. Paste the code instead, or allow the camera on Android\'s page for the app.');
      return;
    }
    final text = r.text;
    if (text == null) return;
    // The same camera reads a new device's sign-in code (GMFB-45): that one goes to its own screen, where it is
    // compared and asked about, and nothing is paired.
    if (HandoverCode.isOne(text)) {
      Navigator.of(context).pushReplacement(PageRouteBuilder<void>(pageBuilder: (_, _, _) => HandoverApproveScreen(code: text)));
      return;
    }
    _begin(text);
  }

  /// Begins with a pairing code on the clipboard where there is one; otherwise shows the field to type one into.
  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';
    if (text.startsWith('GHOSTPAIR1:') || text.toLowerCase().startsWith('ghostmsg://pair/')) {
      _code.text = text;
      _begin(text);
    } else if (mounted) {
      setState(() => _pasting = true);
    }
  }

  /// Chooses how the two connect once paired, while the pairing is still under way.
  Future<void> _mode(String mode) async {
    try {
      final s = await Sms.instance.setPairingMode(mode);
      if (mounted) setState(() => _state = s);
    } on PlatformException catch (e) {
      if (mounted) toast(context, e.message ?? 'Couldn\'t change it', tone: GlacierToastTone.danger);
    }
  }

  /// After a failure: the old pairing is put away and the page is back at its start.
  Future<void> _again() async {
    await Sms.instance.pairingShown();
    await Sms.instance.cancelPairing();
    if (mounted) {
      setState(() {
        _state = const PairingState();
        _problem = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final s = _state;
    final children = switch (s.phase) {
      'waiting' => _waiting(t, s),
      'code' => _compare(t, s),
      'done' => _done(t, s),
      'failed' => _failed(t, s),
      _ => widget.offered != null && !_accepted ? _asked(t) : _start(t),
    };
    return GhostPage(
      title: 'Pair a computer',
      actions: [docsButton('pairing')],
      body: ListView(
        padding: EdgeInsetsDirectional.fromSTEB(t.space(4), t.space(2), t.space(4), t.space(8) + MediaQuery.paddingOf(context).bottom),
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        children: [
          for (var i = 0; i < children.length; i++) ...[if (i > 0) SizedBox(height: t.space(4)), children[i]],
        ],
      ),
    );
  }

  /// A code that came by a link: who it is from, and a yes before anything is sent or listened for.
  List<Widget> _asked(Tokens t) {
    final name = _offeredName;
    if (name == null) return [const _Lead(icon: Lucide.laptop, title: 'Reading the code', body: 'A moment.', busy: true)];
    return [
      _Lead(
        icon: Lucide.laptop,
        title: 'Pair with $name?',
        body: 'It will show this phone\'s conversations and send texts through this phone. Go on only if you are setting up Uplink on your own computer right now, and it is showing this code. You will compare six digits with it before anything is shared.',
      ),
      PairButton(
        label: 'Pair with $name',
        icon: Lucide.link,
        onPressed: () {
          setState(() => _accepted = true);
          _begin(widget.offered!);
        },
      ),
      PairButton(label: 'Not now', icon: Lucide.x, quiet: true, onPressed: () => Navigator.of(context).maybePop()),
    ];
  }

  // What the page shows at each phase of the pairing, in the order they come: nothing begun, looking for the
  // computer, the six digits to compare, paired, and not paired.
  List<Widget> _start(Tokens t) => [
        _Lead(icon: Lucide.laptop, title: 'Your texts on your computer', body: 'Open Uplink on the computer. It shows a code to scan. The phone stays the only thing that sends and receives; the computer shows your conversations and sends through it, sealed between the two.'),
        PairButton(label: 'Scan the code', icon: LucideMore.qrCode, onPressed: _scan),
        PairButton(label: 'Paste the code instead', icon: Lucide.clipboardPaste, quiet: true, onPressed: _paste),
        if (_pasting) ...[
          GlacierInput(
            controller: _code,
            placeholder: 'GHOSTPAIR1:…'.t,
            ariaLabel: 'The pairing code',
            autoCorrect: false,
            autoCapitalize: TextCapitalization.none,
            size: GlacierFieldSize.md,
            onSubmitted: _begin,
          ),
          PairButton(label: 'Pair with this code', icon: Lucide.link, quiet: true, onPressed: () => _begin(_code.text)),
        ],
        if (_problem != null) SettingsCallout(icon: const AppIcon(Lucide.triangleAlert, size: 18), child: Text(_problem!)),
      ];

  List<Widget> _waiting(Tokens t, PairingState s) => [
        _Lead(
          icon: Lucide.laptop,
          title: 'Looking for ${s.name}',
          body: switch (s.offered) {
            'local' => 'It is being looked for on this network. Keep the phone and the computer on the same Wi-Fi.',
            'relay' => 'It is being reached through the relay (${relayHost(s.relay)}).',
            _ => 'On this network first, then through the relay (${relayHost(s.relay)}).',
          },
          busy: true,
        ),
        ConnectionChoice(value: s.mode, onChanged: _mode, relay: s.relay, title: 'From then on, connect by'),
        PairButton(label: 'Cancel', icon: Lucide.x, quiet: true, onPressed: () async {
          await Sms.instance.cancelPairing();
          if (mounted) Navigator.of(context).maybePop();
        }),
      ];

  List<Widget> _compare(Tokens t, PairingState s) => [
        _Lead(icon: Lucide.shieldCheck, title: 'Does ${s.name} show the same six digits?', body: 'They are made from the key the two just agreed on. The same on both means nobody is in the middle.'),
        PairingCode(code: s.code ?? ''),
        ConnectionChoice(value: s.mode, onChanged: _mode, relay: s.relay, title: 'From then on, connect by'),
        if (!s.mine)
          PairButton(label: 'They match', icon: Lucide.check, onPressed: () async {
            await Sms.instance.confirmPairing();
            _read();
          })
        else
          _Lead(icon: Lucide.hourglass, title: 'Now say so on the computer', body: 'Press "They match" there too.', busy: true),
        PairButton(label: 'They don\'t match', icon: Lucide.x, quiet: true, onPressed: () async {
          await Sms.instance.cancelPairing();
          if (mounted) setState(() => _state = const PairingState(phase: 'failed', error: 'The digits were different, so nothing was paired. Show a new code on the computer and scan it again.'));
        }),
      ];

  List<Widget> _done(Tokens t, PairingState s) => [
        _Lead(icon: Lucide.circleCheck, title: 'Paired with ${s.name}', body: 'Your conversations are on it now, by ${connectionLabel(s.mode).toLowerCase()}. A quiet notification stays while a computer is paired, so Android keeps the phone reachable.'),
        PairButton(label: 'Done', icon: Lucide.check, onPressed: () => Navigator.of(context).maybePop()),
      ];

  List<Widget> _failed(Tokens t, PairingState s) => [
        _Lead(icon: Lucide.triangleAlert, title: 'Not paired', body: s.error ?? 'Something went wrong.'),
        PairButton(label: 'Try again', icon: Lucide.rotateCcw, onPressed: _again),
      ];
}

/// The six digits both show, in two groups of three, large enough to read across a desk.
class PairingCode extends StatelessWidget {
  const PairingCode({super.key, required this.code});
  final String code;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final shown = code.length == 6 ? '${code.substring(0, 3)} ${code.substring(3)}' : code;
    return Semantics(
      label: 'The code is ${code.split('').join(' ')}',
      child: ExcludeSemantics(
        child: Container(
          padding: EdgeInsets.symmetric(vertical: t.space(5)),
          decoration: BoxDecoration(color: t.color('app-paper-2'), borderRadius: BorderRadius.circular(t.radius('lg'))),
          alignment: Alignment.center,
          child: Text(shown, style: pageText(t, t.lenOf('2.6rem'), weight: 'bold', color: t.color('app-ink'), mono: true, tracking: 2)),
        ),
      ),
    );
  }
}

/// A step's heading: an icon, what is happening, and a sentence under it.
class _Lead extends StatelessWidget {
  const _Lead({required this.icon, required this.title, required this.body, this.busy = false});
  final LucideIcon icon;
  final String title;
  final String body;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: t.space(2), vertical: t.space(2)),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(padding: const EdgeInsets.only(top: 2), child: busy ? const GhostSpinner(size: 22) : AppIcon(icon, size: 22, color: t.color('app-ink'))),
        SizedBox(width: t.space(3)),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text(title, style: pageText(t, t.fontSize('lg'), weight: 'semibold', color: t.color('app-ink'), height: 1.25)),
            SizedBox(height: t.space(1)),
            Text(body, style: pageText(t, t.fontSize('sm'), color: t.color('app-ink-2'), height: 1.45)),
          ]),
        ),
      ]),
    );
  }
}

/// A wide button: the step's one action filled with ink, the others outlined ([quiet]).
class PairButton extends StatelessWidget {
  const PairButton({super.key, required this.label, required this.icon, required this.onPressed, this.quiet = false});
  final String label;
  final LucideIcon icon;
  final VoidCallback? onPressed;
  final bool quiet;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    // Under the bevelled chrome (Dial-Up, Runestone): a push button as wide as the page, the step's one action in the
    // frame the era put round the button Enter presses. Filled with ink it was a bar of Runestone's yellow.
    if (isBevelChrome(t)) return RetroButton(onPressed: onPressed, icon: icon, label: label, primary: !quiet, bold: !quiet, faceHeight: 44, minFaceWidth: double.infinity);
    final off = onPressed == null;
    final ink = quiet ? t.color('app-ink') : t.color('app-paper');
    return GlacierPressable(
      onPressed: onPressed,
      semanticLabel: label,
      builder: (context, state) => AnimatedScale(
        scale: state.pressed ? 0.98 : 1,
        duration: const Duration(milliseconds: 120),
        child: Opacity(
          opacity: off ? 0.45 : 1,
          child: Container(
            constraints: BoxConstraints(minHeight: t.lenOf('3rem')),
            padding: EdgeInsets.symmetric(horizontal: t.space(4), vertical: t.space(2)),
            decoration: BoxDecoration(
              color: quiet ? (state.pressed ? t.color('app-paper-3') : const Color(0x00000000)) : t.color('app-ink'),
              borderRadius: BorderRadius.circular(t.radius('lg')),
              border: quiet ? Border.all(color: t.color('app-ink-4')) : null,
            ),
            child: Row(mainAxisAlignment: MainAxisAlignment.center, mainAxisSize: MainAxisSize.max, children: [
              AppIcon(icon, size: 18, color: ink, wash: false),
              SizedBox(width: t.space(2)),
              Flexible(child: Text(label, textAlign: TextAlign.center, style: pageText(t, t.fontSize('md'), weight: 'semibold', color: ink))),
            ]),
          ),
        ),
      ),
    );
  }
}
