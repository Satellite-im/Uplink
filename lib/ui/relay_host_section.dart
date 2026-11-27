import 'dart:async';

import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../art/app_icon.dart';
import '../art/lucide.g.dart';
import '../art/lucide_more.dart';
import '../desktop/ui/qr.dart';
import '../kit/settings_kit.dart';
import '../kit/settings_type.dart';
import '../net/net.dart';
import '../net/relay_choice.dart';
import '../platform_info.dart';
import '../relay_host/address.dart';
import '../relay_host/hosting.dart';
import '../relay_host/words.dart';
import '../sms.dart';
import 'common.dart';
import 'network.dart' show movingWords, relayLimitsWords;
import '../l10n/words.dart';

/// Settings › Routes › Host a relay on this device (lib/relay_host; docs/OPEN_NETWORK.md, section 5; Matt, 2026-11-22:
/// "i'd like everyone to be able to host a relay from their client"): the switch, said before it is pressed (what the
/// host sees, how long it runs, the firewall's question, what a local network sees, and that gogho.st won't take its
/// link yet); while it runs, how it stands and its limits, this app on it, its addresses on the network (with a QR code
/// and a link to open) and over Direct, its port, its pass phrase, its link to gogho.st, and what its folder keeps. None
/// on an iPhone or in a browser, which can't host one.
List<Widget> relayHostSections(BuildContext context, Net net) {
  final host = net.relayHost;
  if (host == null) return const [];
  Widget icon(LucideIcon i) => AppIcon(i, size: 18);
  final up = host.state == HostState.up;
  return [
    PaneSection(
      title: 'Host a relay',
      description: Text(host.on ? hostSeesWords : hostOffHint),
      footer: host.on ? const Text(keptWords) : null,
      children: [
        SettingRow(
          key: const ValueKey('host-on'),
          icon: icon(Lucide.hardDrive),
          label: hostLabel,
          hint: Text(host.on ? hostStateWords(host) : 'Off'),
          control: GlacierSwitch(checked: host.on, onCheckedChange: (v) => v ? askToHost(context, host) : askToStopHosting(context, host), ariaLabel: hostLabel),
        ),
        if (host.on && host.problem != null) SettingRow(key: const ValueKey('host-problem'), icon: icon(Lucide.circleAlert), label: host.problem!),
        if (host.on) SettingRow(key: const ValueKey('host-limits'), icon: icon(Lucide.info), label: 'What it holds', hint: const Text(hostLimitsWords)),
        if (host.on) SettingRow(key: const ValueKey('host-via'), icon: icon(Lucide.globe), label: viaWords(host.viaLink, host.via)),
        if (host.on) SettingRowBox(child: RelayHostViaBox(host: host)),
        if (up && host.inUse)
          SettingRow(key: const ValueKey('host-in-use'), icon: icon(Lucide.check), label: 'This app uses it', hint: const Tr('To leave it, go back to Uplink\'s relay above, or switch it off.'))
        else if (up && host.phone)
          SettingRow(key: const ValueKey('host-use-not'), icon: icon(Lucide.info), label: 'Not for this app on a phone', hint: const Text(phoneNotHereWords))
        else if (up && host.viaLink.kind != ViaKind.stays)
          // Only once its public relay lets it stay (found in the second review, 2026-11-23: offered whatever it said).
          SettingRow(key: const ValueKey('host-use-not'), icon: icon(Lucide.info), label: 'Not for this app yet', hint: const Text(hostedNotLinkedWords))
        else if (up)
          SettingRow(
            key: const ValueKey('host-use'),
            icon: icon(Lucide.check),
            label: 'Use it for this app',
            hint: Text('In place of ${relayInUseWords(net.hubUrl).replaceFirst('Your own relay: ', '')}.'),
            onPress: () => askToUseHere(context, host, net),
          ),
      ],
    ),
    if (host.on)
      PaneSection(
        title: 'On this network',
        description: const Text(lanSeenWords),
        children: [
          SettingRow(
            key: const ValueKey('host-lan'),
            icon: icon(Lucide.wifi),
            label: 'Devices on this network',
            hint: Text(host.lan ? (host.lanUrls.isEmpty ? (up ? 'This device has no address on a network now.' : 'While it runs.') : 'They use it at the address below.') : 'Off: only this app, and Direct, reach it.'),
            control: GlacierSwitch(checked: host.lan, onCheckedChange: host.setLan, ariaLabel: 'Devices on this network'),
          ),
          if (host.lan)
            for (final (i, url) in host.lanUrls.indexed)
              SettingRow(
                key: ValueKey('host-lan-$i'),
                icon: icon(Lucide.link),
                label: url,
                hint: const Tr('Copy'),
                onPress: () => _copy(context, url, 'Copied its address on this network'),
              ),
          if (host.lan && host.lanUrls.isNotEmpty) ...[
            SettingRow(key: const ValueKey('host-lan-qr'), icon: AppIcon(LucideMore.qrCode, size: 18), label: 'Show the QR code', hint: const Tr('A phone\'s camera opens it in Uplink, at "Use this relay?".'), onPress: () => showRelayCode(context, host.lanUrls.first)),
            SettingRow(icon: icon(Lucide.share2), label: 'Share the link', onPress: () => Sms.instance.shareText('A relay on our network', relayLink(host.lanUrls.first))),
          ],
          if (host.lan) SettingRowBox(child: RelayHostPortBox(host: host)),
        ],
      ),
    if (host.on)
      PaneSection(
        title: 'From anywhere, over Direct',
        children: [
          if (!host.directBuilt)
            SettingRow(key: const ValueKey('host-direct'), icon: icon(Lucide.link2), label: 'Over Direct', hint: const Text(directNoneWords))
          else if (!host.directOn)
            SettingRow(key: const ValueKey('host-direct'), icon: icon(Lucide.link2), label: 'Over Direct', hint: const Text(directOffWords))
          else if (host.directUrl == null)
            SettingRow(key: const ValueKey('host-direct'), icon: icon(Lucide.link2), label: 'Over Direct', hint: Text(up ? 'Bringing Direct up…' : 'While it runs.'))
          else ...[
            SettingRow(key: const ValueKey('host-direct'), icon: icon(Lucide.link2), label: host.directUrl!, hint: const Text('Copy. $directOnHint'), onPress: () => _copy(context, host.directUrl!, 'Copied its address over Direct')),
            if (!host.directHelped) SettingRow(key: const ValueKey('host-direct-helper'), icon: icon(Lucide.info), label: 'Not findable from afar yet', hint: const Text(directNoHelperWords)),
            SettingRow(key: const ValueKey('host-direct-qr'), icon: AppIcon(LucideMore.qrCode, size: 18), label: 'Show the QR code', onPress: () => showRelayCode(context, host.directUrl!)),
            SettingRow(icon: icon(Lucide.share2), label: 'Share the link', onPress: () => Sms.instance.shareText('My relay on Uplink', relayLink(host.directUrl!))),
          ],
        ],
      ),
    if (host.on)
      PaneSection(
        title: 'Pass phrase',
        description: Text(host.hasPass ? passWords : noPassWords),
        children: [SettingRowBox(child: RelayHostPassBox(host: host))],
      ),
  ];
}

void _copy(BuildContext context, String text, String said) {
  unawaited(Clipboard.setData(ClipboardData(text: text)));
  toast(context, said);
}

/// What is said before it is switched on, in order: what the host sees, how long it runs, what a local network sees
/// and the firewall's question (where it opens a door there), and its link to gogho.st, which gogho.st doesn't take
/// yet.
List<String> hostOnWords(RelayHosting host, {String? os}) {
  final system = os ?? PlatformInfo.operatingSystem;
  final viaHost = Uri.tryParse(host.via)?.host ?? host.via;
  final firewall = firewallWords(system, host.port == 0 ? 7787 : host.port);
  return [
    hostSeesWords,
    hostRunsWords(phone: system == 'android'),
    if (host.lan) lanSeenWords,
    if (host.lan && firewall.isNotEmpty) firewall,
    'It stays linked to $viaHost, so friends on other relays can reach its people. $viaHost doesn\'t take links from relays hosted from an app yet: until it does, the people on yours reach only each other.',
  ];
}

/// Asks before switching it on, then switches it on.
Future<void> askToHost(BuildContext context, RelayHosting host) async {
  var yes = false;
  await showChoices(
    context,
    title: '$hostLabel?',
    header: _words(context, hostOnWords(host)),
    choices: [Choice('Host it', Lucide.hardDrive, () => yes = true, hint: 'Off again whenever you like.')],
  );
  if (!yes) return;
  await host.setOn(true);
  if (!context.mounted) return;
  toast(context, host.state == HostState.up ? 'The relay on this device is running' : host.problem ?? 'It couldn\'t start', tone: host.state == HostState.up ? GlacierToastTone.neutral : GlacierToastTone.danger);
}

/// What switching it off does: this app back to its relay before where it uses this one, everyone on it seeing it
/// gone, and what its folder keeps.
List<String> hostOffWords(RelayHosting host) => [
      if (host.inUse) 'This app goes back to ${relayInUseWords(host.usedBefore.isEmpty ? Net.defaultHub : host.usedBefore)} first.',
      whenItStopsWords,
      keptWords,
    ];

Future<void> askToStopHosting(BuildContext context, RelayHosting host) async {
  var yes = false;
  await showChoices(
    context,
    title: 'Stop hosting the relay on this device?',
    header: _words(context, hostOffWords(host)),
    choices: [Choice('Stop hosting', Lucide.hardDrive, () => yes = true, danger: true)],
  );
  if (!yes) return;
  await host.setOn(false);
  if (context.mounted) toast(context, 'The relay on this device is off');
}

/// Asks before this app moves onto it, saying what it means for the account's other devices and its friends.
Future<void> askToUseHere(BuildContext context, RelayHosting host, Net net) async {
  var yes = false;
  final viaHost = Uri.tryParse(host.via)?.host ?? host.via;
  await showChoices(
    context,
    title: 'Use the relay on this device for this app?',
    header: _words(context, [movingWords(net.hubUrl), moveHereWords(viaHost)]),
    choices: [Choice('Use it', Lucide.check, () => yes = true)],
  );
  if (!yes) return;
  final problem = await host.useHere();
  if (!context.mounted) return;
  toast(context, problem ?? 'This app uses the relay on this device', tone: problem == null ? GlacierToastTone.neutral : GlacierToastTone.danger);
}

Widget _words(BuildContext context, List<String> paragraphs) {
  final t = context.tokens;
  return Padding(
    padding: EdgeInsetsDirectional.fromSTEB(t.space(4), 0, t.space(4), t.space(2)),
    child: Text(paragraphs.join('\n\n'), key: const ValueKey('host-words'), style: pageText(t, t.fontSize('sm'), color: t.color('app-ink-2'), height: 1.4)),
  );
}

/// A relay's address as a QR code holding the link that opens it in the app ([relayLink]), to be scanned from this
/// screen.
void showRelayCode(BuildContext context, String address) {
  final t = context.tokens;
  showChoices(
    context,
    header: Padding(
      padding: EdgeInsets.all(t.space(4)),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        QrView(key: const ValueKey('host-code'), data: relayLink(address), size: t.lenOf('15rem'), label: 'This relay, as a QR code'),
        SizedBox(height: t.space(3)),
        Text(address, textAlign: TextAlign.center, style: pageText(t, t.fontSize('xs'), color: t.color('app-ink-3'))),
        Text('Scan to use this relay in Uplink', style: pageText(t, t.fontSize('sm'), color: t.color('app-ink-3'))),
      ]),
    ),
    choices: const [],
  );
}

/// The relay picker's "Use this relay?" (Settings › Routes' address field, and a relay's link opened): what moving
/// means, what someone who hosts it sees where it runs in an app ([joinHostedWords]), and its pass phrase asked for
/// where it asks one. The person's yes, and the phrase they gave.
Future<({bool yes, String? pass})> decideRelay(BuildContext context, String url, RelayCheck check, {String? from}) async {
  var yes = false;
  // A relay hosted from an app is moved to only while it talks to other relays: its hello says so only while its
  // public relay lets it stay (relay/lib/federation.dart, card).
  final usable = !check.hosted || (check.relay?.fed ?? false);
  final pass = TextEditingController();
  final t = context.tokens;
  await showChoices(
    context,
    title: 'Use ${relayInUseWords(url).replaceFirst('Your own relay: ', '')}?',
    header: Padding(
      padding: EdgeInsetsDirectional.fromSTEB(t.space(4), 0, t.space(4), t.space(2)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        Text([movingWords(from ?? Net.instance.hubUrl), if (check.hosted) joinHostedWords, if (url.startsWith('ws://')) lanSeenWords, if (!usable) hostedNotLinkedWords, relayLimitsWords].join('\n\n'), key: const ValueKey('relay-words'), style: pageText(t, t.fontSize('sm'), color: t.color('app-ink-2'), height: 1.4)),
        if (check.asksPass) ...[
          SizedBox(height: t.space(3)),
          GlacierInput(key: const ValueKey('relay-pass'), controller: pass, type: GlacierInputType.password, placeholder: 'Its pass phrase'.t, ariaLabel: 'The relay\'s pass phrase', autoCorrect: false, size: GlacierFieldSize.md),
        ],
      ]),
    ),
    choices: [if (usable) Choice('Use this relay', Lucide.check, () => yes = true, hint: check.asksPass ? 'It asks for a pass phrase: whoever runs it can give it to you.' : 'It answered as an Uplink relay.')],
  );
  final phrase = pass.text.trim();
  pass.dispose();
  return (yes: yes, pass: phrase.isEmpty ? null : phrase);
}

/// Asked before a relay's link is followed at all: the app connects to the address only on a yes.
Future<bool> checkFirst(BuildContext context, String url) async {
  var yes = false;
  await showChoices(
    context,
    title: 'Check this relay?',
    header: _words(context, [checkFirstWords(url)]),
    choices: [Choice('Check it', Lucide.check, () => yes = true)],
  );
  return yes;
}

/// A relay's link was opened (`ghostmsg://relay?a=…`, from a host's QR code or a shared link): asked first, then used.
Future<void> askToUseRelay(BuildContext context, String link) async {
  final address = relayFromLink(link);
  if (address == null) return toast(context, 'That relay link isn\'t complete. Ask for it again.', tone: GlacierToastTone.danger);
  final r = await Net.instance.useRelay(address, askFirst: (url) => checkFirst(context, url), decide: (url, check) => decideRelay(context, url, check));
  if (!context.mounted || r.declined) return;
  toast(context, r.problem ?? 'Using ${relayInUseWords(Net.instance.hubUrl)}', tone: r.problem == null ? GlacierToastTone.neutral : GlacierToastTone.danger);
}

/// Its port on the local network, changed.
class RelayHostPortBox extends StatefulWidget {
  const RelayHostPortBox({super.key, required this.host});
  final RelayHosting host;

  @override
  State<RelayHostPortBox> createState() => _RelayHostPortBoxState();
}

class _RelayHostPortBoxState extends State<RelayHostPortBox> {
  late final _port = TextEditingController(text: widget.host.port == 0 ? '' : '${widget.host.port}');
  String? _problem;

  @override
  void dispose() {
    _port.dispose();
    super.dispose();
  }

  Future<void> _use() async {
    final n = int.tryParse(_port.text.trim());
    final problem = n == null ? 'A port is a number from 1024 to 65535.' : await widget.host.setPort(n);
    if (!mounted) return;
    setState(() => _problem = problem);
    if (problem == null) toast(context, 'Devices on this network use port $n now');
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      GlacierInput(key: const ValueKey('host-port-field'), controller: _port, type: GlacierInputType.number, placeholder: '7787'.t, ariaLabel: 'The port devices on this network use', size: GlacierFieldSize.md, onSubmitted: (_) => _use()),
      if (_problem != null) Padding(padding: EdgeInsets.only(top: t.space(2)), child: Text(_problem!, key: const ValueKey('host-port-problem'), style: pageText(t, t.fontSize('sm'), color: t.color('app-danger')))),
      SizedBox(height: t.space(2)),
      SettingRow(key: const ValueKey('host-port'), icon: const AppIcon(Lucide.check, size: 18), label: 'Use this port', hint: const Tr('Anyone on it now signs in again at the new one.'), onPress: _use),
    ]);
  }
}

/// Its pass phrase, set, changed or taken away.
class RelayHostPassBox extends StatefulWidget {
  const RelayHostPassBox({super.key, required this.host});
  final RelayHosting host;

  @override
  State<RelayHostPassBox> createState() => _RelayHostPassBoxState();
}

class _RelayHostPassBoxState extends State<RelayHostPassBox> {
  final _pass = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _pass.dispose();
    super.dispose();
  }

  Future<void> _set(String? phrase) async {
    if (_busy) return;
    setState(() => _busy = true);
    await widget.host.setPass(phrase);
    if (!mounted) return;
    _pass.clear();
    setState(() => _busy = false);
    toast(context, phrase == null ? 'It asks for no pass phrase now' : 'It asks for the pass phrase now: everyone on it signs in again with it');
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      GlacierInput(key: const ValueKey('host-pass-field'), controller: _pass, type: GlacierInputType.password, placeholder: widget.host.hasPass ? 'A new pass phrase' : 'A long pass phrase', ariaLabel: 'The relay\'s pass phrase', autoCorrect: false, size: GlacierFieldSize.md, onSubmitted: (v) => v.trim().isEmpty ? null : _set(v)),
      SizedBox(height: t.space(2)),
      SettingRow(key: const ValueKey('host-pass-set'), icon: const AppIcon(Lucide.keyRound, size: 18), label: widget.host.hasPass ? 'Change the pass phrase' : 'Ask for this pass phrase', hint: const Tr('Give it to whoever you let use it. Everyone on it signs in again.'), disabled: _busy, onPress: () => _pass.text.trim().isEmpty ? null : _set(_pass.text)),
      if (widget.host.hasPass) SettingRow(key: const ValueKey('host-pass-clear'), icon: const AppIcon(Lucide.lock, size: 18), label: 'Ask for no pass phrase', disabled: _busy, onPress: () => _set(null)),
    ]);
  }
}

/// The public relay it stays linked to, chosen: Uplink's own unless the person names another.
class RelayHostViaBox extends StatefulWidget {
  const RelayHostViaBox({super.key, required this.host});
  final RelayHosting host;

  @override
  State<RelayHostViaBox> createState() => _RelayHostViaBoxState();
}

class _RelayHostViaBoxState extends State<RelayHostViaBox> {
  late final _via = TextEditingController(text: widget.host.via == Net.defaultHub ? '' : widget.host.via);
  String? _problem;

  @override
  void dispose() {
    _via.dispose();
    super.dispose();
  }

  Future<void> _use() async {
    final problem = await widget.host.setVia(_via.text);
    if (!mounted) return;
    setState(() => _problem = problem);
    if (problem == null) toast(context, 'It stays linked to ${Uri.tryParse(widget.host.via)?.host ?? widget.host.via} now');
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      Text(viaChoiceWords, style: pageText(t, t.fontSize('sm'), color: t.color('app-ink-2'))),
      SizedBox(height: t.space(2)),
      GlacierInput(key: const ValueKey('host-via-field'), controller: _via, placeholder: 'gogho.st'.t, ariaLabel: 'The public relay it stays linked to', inputMode: TextInputType.url, autoCorrect: false, size: GlacierFieldSize.md, onSubmitted: (_) => _use()),
      if (_problem != null) Padding(padding: EdgeInsets.only(top: t.space(2)), child: Text(_problem!, key: const ValueKey('host-via-problem'), style: pageText(t, t.fontSize('sm'), color: t.color('app-danger')))),
      SizedBox(height: t.space(2)),
      SettingRow(key: const ValueKey('host-via-use'), icon: const AppIcon(Lucide.globe, size: 18), label: 'Stay linked to this relay', hint: const Tr('Empty: Uplink\'s own.'), onPress: _use),
    ]);
  }
}
