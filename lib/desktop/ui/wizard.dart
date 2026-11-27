import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../platform.dart';
import 'package:glacier/glacier.dart';

import '../../art/app_icon.dart';
import '../../art/lucide.g.dart';
import '../../art/lucide_more.dart';
import '../../kit/settings_kit.dart';
import '../../kit/settings_type.dart';
import '../../ui/common.dart';
import '../../ui/computers.dart';
import '../desk.dart';
import '../link/link.dart';
import 'qr.dart';
import '../../kit/semantic_colors.dart';

/// The Mac's setup wizard (Matt, 2026-11-13: "it should attempt to use local networking by default and show the
/// option for both in the setup wizard"): how to connect, the code for the phone to scan, the six digits to compare.
/// What it drives is [PhoneLink]; the phone's half of it is lib/ui/computers.dart.
class PairWizard extends StatefulWidget {
  const PairWizard({super.key, this.skipLabel, this.onSkip});

  /// A way past linking a phone, which is never required (Matt, 2026-11-18: "make setting up SMS and such and linking
  /// to a phone an optional step"): "Not now", or "Use without a phone". None where not given.
  final String? skipLabel;
  final VoidCallback? onSkip;

  @override
  State<PairWizard> createState() => _PairWizardState();
}

class _PairWizardState extends State<PairWizard> {
  /// How the two may connect: 'local', 'relay' or 'both'. Kept in the store's prefs with the relay's address.
  String _mode = 'both';
  late final TextEditingController _relay;

  /// Whether a relay answered at the address typed; null while it is being asked, or with no address.
  bool? _relayThere;
  Timer? _probe;

  /// The controller and the kept prefs are read once, on the first run of didChangeDependencies.
  bool _started = false;

  /// True for two seconds after the code is copied, while the button says so.
  bool _copied = false;

  PhoneLink get _link => DeskScope.of(context).link;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    final scope = DeskScope.of(context);
    _relay = TextEditingController(text: defaultRelay);
    scope.store.prefs().then((p) {
      if (!mounted) return;
      final kept = p['relay'];
      if (kept != null) _relay.text = kept;
      _mode = p['mode'] ?? 'both';
      _ask();
    });
  }

  @override
  void dispose() {
    _probe?.cancel();
    _relay.dispose();
    super.dispose();
  }

  /// Whether a relay answers at the address typed: asked a moment after the typing stops.
  void _ask() {
    _probe?.cancel();
    setState(() => _relayThere = null);
    final relay = _relay.text.trim();
    if (relay.isEmpty) return;
    _probe = Timer(const Duration(milliseconds: 500), () async {
      final there = await relayAnswers(relay);
      if (mounted && relay == _relay.text.trim()) setState(() => _relayThere = there);
    });
  }

  /// Keeps the choice and starts a pairing attempt, which puts the code on the screen. With no relay address the
  /// attempt is local only, whatever was chosen.
  Future<void> _show() async {
    final scope = DeskScope.of(context);
    final relay = _relay.text.trim();
    final prefs = await scope.store.prefs();
    await scope.store.savePrefs({...prefs, 'relay': relay, 'mode': _mode});
    scope.link.beginPairing(mode: relay.isEmpty ? 'local' : _mode, relay: relay);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final link = _link;
    return ColoredBox(
      color: t.color('glacier-bg'),
      child: ListenableBuilder(
        listenable: link,
        builder: (context, _) {
          final a = link.attempt;
          // One step for each phase of the attempt; with no attempt, the choice of how to connect.
          final children = switch (a?.phase) {
            'showing' => _showing(t, a!),
            'code' => _compare(t, a!),
            'failed' => _failed(t, a!),
            _ => _choose(t),
          };
          // A step's buttons stay at the window's foot, in view however short the window: what is above them scrolls.
          final body = [for (final c in children) if (c is! PairButton) c];
          final buttons = [for (final c in children) if (c is PairButton) c];
          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    padding: EdgeInsetsDirectional.fromSTEB(t.space(6), t.space(8), t.space(6), t.space(4)),
                    children: [
                      for (var i = 0; i < body.length; i++) ...[if (i > 0) SizedBox(height: t.space(4)), body[i]],
                    ],
                  ),
                ),
                Padding(
                  padding: EdgeInsetsDirectional.fromSTEB(t.space(6), 0, t.space(6), t.space(6)),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
                    for (var i = 0; i < buttons.length; i++) ...[if (i > 0) SizedBox(height: t.space(3)), buttons[i]],
                  ]),
                ),
              ]),
            ),
          );
        },
      ),
    );
  }

  /// A step's heading and the words under it; [mark] puts the app's mark above them, as the first step has.
  Widget _title(Tokens t, String title, String body, {bool mark = false}) => Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        if (mark) ...[
          Container(
            width: t.lenOf('4rem'),
            height: t.lenOf('4rem'),
            decoration: BoxDecoration(color: const Color(0xFF000000), borderRadius: BorderRadius.circular(t.lenOf('1rem')), border: Border.all(color: t.color('app-rule'))),
            alignment: Alignment.center,
            child: Image.asset('assets/art/ghost-mark.png', width: t.lenOf('3.2rem'), height: t.lenOf('3.2rem')),
          ),
          SizedBox(height: t.space(5)),
        ],
        Text(title, style: pageText(t, t.fontSize('2xl'), weight: 'bold', color: t.color('app-ink'), height: 1.2)),
        SizedBox(height: t.space(2)),
        Text(body, style: pageText(t, t.fontSize('md'), color: t.color('app-ink-2'), height: 1.45)),
      ]);

  /// The first step: how to connect, the relay's address and whether it answers.
  List<Widget> _choose(Tokens t) {
    final relay = _relay.text.trim();
    return [
      _title(t, 'Your texts, on your $computerWord', 'Pair this $computerWord with Uplink on your Android phone to text from it. The phone stays the only thing that sends and receives texts; the $computerWord shows your conversations and sends through it. Everything between the two is sealed with a key only they hold. Friends, circles, Telegram and Signal work without it.', mark: true),
      ConnectionChoice(
        value: relay.isEmpty ? 'local' : _mode,
        onChanged: (m) => setState(() => _mode = m),
        relay: relay,
        footer: Text(switch ((relay.isEmpty, _relayThere)) {
          (true, _) => 'With no relay address, only the local network can be used.',
          (_, true) => 'A relay is answering at ${relayHost(relay)}. It passes sealed data between the two while both are connected, and keeps none of it.',
          (_, false) => 'No relay is answering at ${relayHost(relay)} yet. The local network works without it, and the relay is used from the day it is there.',
          _ => 'Asking ${relayHost(relay)}…',
        }),
      ),
      PaneSection(title: 'Relay address', children: [
        SettingRowBox(
          child: GlacierInput(
            controller: _relay,
            placeholder: defaultRelay,
            ariaLabel: 'The relay\'s address',
            autoCorrect: false,
            autoCapitalize: TextCapitalization.none,
            size: GlacierFieldSize.md,
            onChange: (_) => _ask(),
          ),
        ),
      ]),
      PairButton(label: 'Show the pairing code', icon: LucideMore.qrCode, onPressed: _show),
      if (widget.onSkip != null) PairButton(label: widget.skipLabel ?? 'Not now', icon: Lucide.arrowRight, quiet: true, onPressed: widget.onSkip),
    ];
  }

  /// The code for the phone to scan, or to copy and paste there, while this side waits for it.
  List<Widget> _showing(Tokens t, PairingAttempt a) => [
        _title(t, 'Scan this with your phone', 'Point the phone\'s camera at it and open the link in Uplink. Or, in Uplink on the phone: Settings › Computers › Pair a computer.'),
        // The code as a link: the phone's own camera opens it in Uplink, and the app's scanner reads it too.
        Center(child: QrView(data: a.offer.link)),
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          const GhostSpinner(size: 16),
          SizedBox(width: t.space(2)),
          Flexible(
            child: Text(
              switch (a.offer.mode) {
                'local' => 'Waiting for the phone, on this network',
                'relay' => 'Waiting for the phone, through the relay',
                _ => 'Waiting for the phone: on this network first, then through the relay',
              },
              style: pageText(t, t.fontSize('sm'), color: t.color('app-ink-2')),
            ),
          ),
        ]),
        PairButton(
          label: _copied ? 'Copied' : 'Copy the code, to paste on the phone',
          icon: _copied ? Lucide.check : Lucide.copy,
          quiet: true,
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: a.offer.text));
            if (!mounted) return;
            setState(() => _copied = true);
            Timer(const Duration(seconds: 2), () {
              if (mounted) setState(() => _copied = false);
            });
          },
        ),
        PairButton(label: 'Back', icon: Lucide.arrowLeft, quiet: true, onPressed: () => _link.cancelPairing()),
      ];

  /// The six digits to compare with the phone's. Once this side has said they match, it waits for the phone to.
  List<Widget> _compare(Tokens t, PairingAttempt a) => [
        _title(t, 'Does ${a.phoneName} show the same six digits?', 'They are made from the key the two just agreed on. The same on both means nobody is in the middle. From then on they connect by ${connectionLabel(a.mode).toLowerCase()}, as chosen on the phone.'),
        PairingCode(code: a.code ?? ''),
        if (!a.mine)
          PairButton(label: 'They match', icon: Lucide.check, onPressed: _link.confirmPairing)
        else
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            const GhostSpinner(size: 16),
            SizedBox(width: t.space(2)),
            Text('Now press "They match" on the phone', style: pageText(t, t.fontSize('sm'), color: t.color('app-ink-2'))),
          ]),
        PairButton(label: 'They don\'t match', icon: Lucide.x, quiet: true, onPressed: () => _link.cancelPairing()),
      ];

  List<Widget> _failed(Tokens t, PairingAttempt a) => [
        _title(t, 'Not paired', a.error ?? 'Something went wrong.'),
        PairButton(label: 'Try again', icon: Lucide.rotateCcw, onPressed: _link.pairingShown),
      ];
}

/// A line that says how the phone is connected, for the window's foot and the settings.
String linkLine(PhoneLink link) {
  if (link.refused) return 'Your phone no longer has this pairing';
  return switch (link.via) {
    'local' => 'Connected over the local network',
    'relay' => 'Connected through the relay',
    _ => 'Waiting for your phone',
  };
}

/// The same, with its icon.
class LinkStatus extends StatelessWidget {
  const LinkStatus({super.key, required this.link, this.waiting = 0});
  final PhoneLink link;

  /// Texts written here that have not reached the phone yet, said after the line where there are any.
  final int waiting;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final ink = t.color('app-ink-3');
    final on = link.via != null;
    return Row(children: [
      if (on)
        AppIcon(link.via == 'local' ? Lucide.wifi : LucideMore.cloud, size: 14, color: ink, wash: false)
      else if (link.refused)
        AppIcon(Lucide.triangleAlert, size: 14, color: t.warn)
      else
        const GhostSpinner(size: 14),
      SizedBox(width: t.space(2)),
      Expanded(
        child: Text(
          '${linkLine(link)}${waiting > 0 ? ' · $waiting ${waiting == 1 ? 'text' : 'texts'} waiting' : ''}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: pageText(t, t.fontSize('xs'), color: ink),
        ),
      ),
      if (on) AppIcon(Lucide.lock, size: 12, strokeWidth: 2.4, wash: false, color: ink, semanticLabel: 'Sealed'),
    ]);
  }
}
