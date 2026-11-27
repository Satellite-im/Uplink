/// Settings › API (Matt, 2026-11-17: "expose it all through a API section of the settings that shows up when developer
/// mode is enabled it should serve as a complete list of documentation for the API as well as test areas"): turning
/// the API on, on this phone and through the relay, with what a client needs to reach it; the last calls made; and
/// every method, each with a page of its own that documents it and runs it.
library;

import 'package:flutter/services.dart' show Clipboard, ClipboardData, TextCapitalization;
import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../api/api.dart';
import '../api/remote.dart';
import '../api/server.dart';
import '../app_state.dart';
import '../art/app_icon.dart';
import '../art/lucide.g.dart';
import '../kit/settings_kit.dart';
import '../kit/semantic_colors.dart';
import '../kit/settings_type.dart';
import 'common.dart';
import 'computers.dart' show PairButton;
import 'settings.dart' show SettingsModel;
import '../l10n/words.dart';

Widget _icon(LucideIcon icon) => AppIcon(icon, size: 18);

/// The headings the methods are listed under, by the group each method names; a group not here shows its own name.
const _groupNames = {
  'api': 'The API itself',
  'app': 'The app',
  'conversations': 'Conversations of texts',
  'messages': 'Sending',
  'contacts': 'Contacts',
  'presence': 'Presence',
  'plugins': 'Plugins',
  'filters': 'Filters',
  'networks': 'Telegram, Signal and other networks',
  'friends': 'Friends by username',
  'net': 'Routes and the relay server',
  'ui': 'The screen',
};

void _copy(BuildContext context, String text, String said) {
  Clipboard.setData(ClipboardData(text: text));
  toast(context, said);
}

/// Settings › API's sections: serving on this phone, serving through the relay, the recent calls, and every method
/// by group.
List<Widget> apiPane(BuildContext context, SettingsModel m) {
  final app = m.app;
  final t = context.tokens;
  final localOn = ApiServer.on(app);
  final remoteOn = ApiRemote.on(app);
  final methods = Api.instance.methods;
  return [
    PaneSection(
      title: 'On this phone',
      description: const Tr('The API over HTTP, served by the app. From a computer over USB: adb forward tcp:8765 tcp:8765, then http://127.0.0.1:8765. Every request carries the token.'),
      children: [
        SettingRow(
          icon: _icon(Lucide.terminal),
          label: 'Serve the API',
          hint: ValueListenableBuilder<List<String>?>(
            valueListenable: ApiServer.instance.addresses,
            builder: (context, at, _) => ValueListenableBuilder<String?>(
              valueListenable: ApiServer.instance.problem,
              builder: (context, problem, _) => Text(problem ?? (at == null ? 'Off' : 'At ${at.join(', ')}')),
            ),
          ),
          control: GlacierSwitch(
            checked: localOn,
            ariaLabel: 'Serve the API',
            onCheckedChange: (on) {
              app.setFlag('api_local', on);
              ApiServer.instance.apply(app);
            },
          ),
        ),
        SettingRow(
          icon: _icon(Lucide.wifi),
          label: 'Allow from Wi-Fi',
          hint: const Tr('Served on the phone\'s address on your network too, for anyone on it who has the token.'),
          control: GlacierSwitch(
            checked: ApiServer.lan(app),
            disabled: !localOn,
            ariaLabel: 'Allow from Wi-Fi',
            onCheckedChange: localOn
                ? (on) {
                    app.setFlag('api_lan', on);
                    ApiServer.instance.apply(app);
                  }
                : null,
          ),
        ),
        if (localOn) ...[
          SettingRow(icon: _icon(Lucide.keyRound), label: 'Copy the token', hint: const Tr('Authorization: Bearer <token>'), onPress: () => _copy(context, ApiServer.token(app), 'Token copied')),
          SettingRow(
            icon: _icon(Lucide.copy),
            label: 'Copy an example',
            hint: const Tr('A curl command that calls app.info.'),
            onPress: () => _copy(context, 'curl -s -X POST -H "Authorization: Bearer ${ApiServer.token(app)}" http://127.0.0.1:${ApiServer.port(app)}/api/app.info', 'Example copied'),
          ),
          SettingRow(icon: _icon(Lucide.refreshCw), label: 'Make a new token', hint: const Tr('Whoever has the old one is shut out.'), onPress: () {
            ApiServer.newToken(app);
            toast(context, 'New token made');
          }),
        ],
      ],
    ),
    PaneSection(
      title: 'From anywhere',
      description: const Tr('The API through the relay server, from any network. Requests and answers are sealed with the connection string\'s key: the relay passes them and cannot read them. The app has to be running.'),
      children: [
        SettingRow(
          icon: _icon(Lucide.globe),
          label: 'Through the relay',
          hint: ValueListenableBuilder<String>(
            valueListenable: ApiRemote.instance.state,
            builder: (context, s, _) => Text(switch (s) {
              'off' => 'Off',
              'connecting' => 'Connecting to the relay…',
              'waiting' => 'Ready: waiting for a client',
              'connected' => 'A client is connected',
              _ => s,
            }),
          ),
          control: GlacierSwitch(
            checked: remoteOn,
            ariaLabel: 'Through the relay',
            onCheckedChange: (on) {
              app.setFlag('api_remote', on);
              ApiRemote.instance.apply(app);
            },
          ),
        ),
        if (remoteOn) ...[
          SettingRow(icon: _icon(Lucide.keyRound), label: 'Copy the connection string', hint: const Tr('ghostapi1:… Whoever has it can call the API: keep it as you would a password.'), onPress: () => _copy(context, ApiRemote.connection(app), 'Connection string copied')),
          SettingRow(
            icon: _icon(Lucide.copy),
            label: 'Copy an example',
            hint: const Tr('Calls app.info with tool/ghost-api.mjs, from the repository.'),
            onPress: () => _copy(context, 'node messaging/tool/ghost-api.mjs --remote ${ApiRemote.connection(app)} app.info', 'Example copied'),
          ),
          SettingRow(icon: _icon(Lucide.refreshCw), label: 'Make a new connection string', hint: const Tr('The old one stops working at once.'), onPress: () {
            ApiRemote.newConnection(app);
            ApiRemote.instance.apply(app);
            toast(context, 'New connection string made');
          }),
        ],
      ],
    ),
    ValueListenableBuilder<List<ApiCall>>(
      valueListenable: Api.instance.calls,
      builder: (context, calls, _) => calls.isEmpty
          ? const SizedBox.shrink()
          : PaneSection(
              title: 'Recent calls',
              children: [
                for (final c in calls.take(8))
                  SettingRow(
                    icon: AppIcon(c.ok ? Lucide.check : Lucide.circleAlert, size: 18, color: c.ok ? null : t.danger),
                    label: c.method,
                    hint: Text('${c.via} · ${c.ms} ms · ${clock(c.at)}${c.error == null ? '' : ' · ${c.error}'}', maxLines: 2, overflow: TextOverflow.ellipsis),
                  ),
              ],
            ),
    ),
    PaneSection(
      title: 'Methods',
      description: Text('${methods.length} methods. Each opens to what it takes and answers, with a place to try it. Those marked ⚠ change or remove something.'),
      children: const [],
    ),
    for (final g in Api.instance.groups)
      PaneSection(
        title: _groupNames[g] ?? g,
        children: [
          for (final x in methods.where((x) => x.group == g))
            SettingRow(
              label: '${x.name}${x.danger ? '  ⚠' : ''}',
              hint: Text(x.summary, maxLines: 2, overflow: TextOverflow.ellipsis),
              onPress: () => push<void>(context, (_) => ApiMethodPage(method: x, app: app)),
            ),
        ],
      ),
  ];
}

/// One method: what it does, what it takes and answers, and a place to call it with parameters typed as JSON.
class ApiMethodPage extends StatefulWidget {
  const ApiMethodPage({super.key, required this.method, required this.app});
  final ApiMethod method;
  final AppState app;

  @override
  State<ApiMethodPage> createState() => _ApiMethodPageState();
}

class _ApiMethodPageState extends State<ApiMethodPage> {
  late final _params = TextEditingController(text: _start());
  String? _result;
  bool _ok = true;
  bool _running = false;

  /// What the parameters field starts with: the method's example, or its required parameters' examples, on one line.
  String _start() {
    final m = widget.method;
    final ex = m.example ?? {for (final p in m.params) if (p.required && p.example != null) p.name: p.example};
    return prettyJson(ex).replaceAll('\n', ' ').replaceAll(RegExp(r'\s+'), ' ');
  }

  @override
  void dispose() {
    _params.dispose();
    super.dispose();
  }

  /// Calls the method with the JSON typed and shows its answer or its refusal. A method that changes or removes
  /// something is asked about first.
  Future<void> _run() async {
    Map<String, Object?> params;
    try {
      final text = _params.text.trim();
      final v = text.isEmpty ? const <String, Object?>{} : (jsonDecodeObject(text));
      params = v;
    } catch (_) {
      setState(() {
        _ok = false;
        _result = 'The parameters are not a JSON object.';
      });
      return;
    }
    if (widget.method.danger) {
      var go = false;
      await showChoices(context, title: '${widget.method.name} changes or removes something. Run it?', choices: [Choice('Run it', Lucide.play, () => go = true, danger: true)]);
      if (!go) return;
    }
    setState(() => _running = true);
    try {
      final r = await Api.instance.call(widget.method.name, params);
      if (!mounted) return;
      setState(() {
        _ok = true;
        _result = prettyJson(r);
      });
    } on ApiError catch (e) {
      if (!mounted) return;
      setState(() {
        _ok = false;
        _result = '${e.code}: ${e.message}';
      });
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final m = widget.method;
    final mono = pageText(t, t.fontSize('sm'), mono: true);
    return GhostPage(
      title: m.name,
      body: ListView(
        padding: EdgeInsetsDirectional.fromSTEB(t.space(4), t.space(2), t.space(4), t.space(8)),
        children: [
          Text(m.summary, style: pageText(t, t.fontSize('md'))),
          if (m.danger) Padding(padding: EdgeInsets.only(top: t.space(2)), child: Text('⚠ It changes or removes something; you are asked before it runs here.', style: pageText(t, t.fontSize('sm'), color: t.danger))),
          SizedBox(height: t.space(4)),
          PaneSection(
            title: 'Parameters',
            children: [
              if (m.params.isEmpty) const SettingRow(label: 'None'),
              for (final p in m.params)
                SettingRow(
                  label: '${p.name}${p.required ? '' : ' (optional)'}',
                  hint: Text('${p.type} · ${p.doc}${p.example == null ? '' : '  e.g. ${prettyJson(p.example).replaceAll('\n', ' ')}'}'),
                ),
            ],
          ),
          PaneSection(title: 'Answers', children: [SettingRowBox(child: Text(m.returns, style: mono))]),
          PaneSection(
            title: 'Call it',
            footer: Text('Over HTTP: POST /api/${m.name} with these parameters as the body. Through the relay: {"method": "${m.name}", "params": {...}}.'),
            children: [
              SettingRowBox(
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  GlacierInput(controller: _params, ariaLabel: 'Parameters as JSON', placeholder: '{}'.t, autoCorrect: false, autoCapitalize: TextCapitalization.none, size: GlacierFieldSize.md),
                  SizedBox(height: t.space(2)),
                  PairButton(label: _running ? 'Running…' : 'Run ${m.name}', icon: Lucide.play, onPressed: _running ? null : _run),
                ]),
              ),
              if (_result != null)
                SettingRowBox(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Text(_ok ? 'Answer' : 'Refused', style: pageText(t, t.fontSize('xs'), weight: 'semibold', color: _ok ? t.color('app-ink-3') : t.danger)),
                    SizedBox(height: t.space(1)),
                    Text(_result!, style: mono),
                    SizedBox(height: t.space(2)),
                    PairButton(label: 'Copy the answer', icon: Lucide.copy, quiet: true, onPressed: () => _copy(context, _result!, 'Answer copied')),
                  ]),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
