import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../art/app_icon.dart';
import '../art/lucide.g.dart';
import '../inbox/inbox.dart';
import '../inbox/people.dart' show Reach;
import '../kit/settings_type.dart';
import '../sms.dart';
import 'common.dart';
import 'dialup/dialup.dart';
import 'inbox_ui.dart' show inboxMark;
import 'person_reach.dart' show openReach;
import 'shell.dart';
import 'thread.dart';

/// A new message: who it is to (contacts as they are typed, or a number), then the conversation with them.
///
/// What is typed also finds people on the networks signed in (GMFB-61, Matt, Android 0.12.25: "I'd like to be able to
/// lookup contacts from connected platforms to start new chats for example slack or telegram"): each under the
/// phone's own, named with its network and its mark, and a press opens the chat with them there
/// ([InboxNetwork.findPeople], [InboxNetwork.chatWith]). Only while nobody is chosen: a text to several people has no
/// place for someone on another network.
class ComposeScreen extends StatefulWidget {
  const ComposeScreen({super.key, this.addresses = const [], this.body});
  final List<String> addresses;
  final String? body;

  @override
  State<ComposeScreen> createState() => _ComposeScreenState();
}

class _ComposeScreenState extends State<ComposeScreen> {
  final List<Person> _to = [];
  final _field = TextEditingController();
  final _focus = FocusNode();
  // The contacts found for what is typed, as the phone answers them.
  List<Map<String, String?>> _matches = const [];
  // The people found on the networks signed in, a network after another, and the searches begun: an answer to an
  // older one is dropped.
  List<InboxContact> _onNetworks = const [];
  int _asked = 0;
  Timer? _debounce;

  /// The most people shown from one network: the list is the phone's first.
  static const _mostEach = 6;

  @override
  void initState() {
    super.initState();
    for (final a in widget.addresses) {
      _to.add(Person(address: a));
      Sms.instance.contact(a).then((p) { if (mounted) setState(() => _to[_to.indexWhere((x) => x.address == a)] = p); });
    }
    _search('');
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _field.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// Looks contacts up for [q], once typing has paused for 120 ms: the phone's, and each network's people.
  void _search(String q) {
    _debounce?.cancel();
    final asked = ++_asked;
    _debounce = Timer(const Duration(milliseconds: 120), () async {
      unawaited(_searchNetworks(q, asked));
      final found = await Sms.instance.searchContacts(q);
      if (mounted) setState(() => _matches = found);
    });
  }

  /// The people [q] finds on every network signed in, each asked on its own: one that fails or is slow holds up
  /// nobody else's. Nobody for nothing typed.
  Future<void> _searchNetworks(String q, int asked) async {
    final networks = q.trim().isEmpty ? const <InboxNetwork>[] : Inbox.instance.ready;
    final found = await Future.wait([
      for (final n in networks)
        n.findPeople(q).timeout(const Duration(seconds: 8)).then((list) => list.take(_mostEach).toList(), onError: (Object _) => const <InboxContact>[]),
    ]);
    if (mounted && asked == _asked) setState(() => _onNetworks = [for (final list in found) ...list]);
  }

  /// The chat with [c] on its network, made there where there is none yet (lib/ui/person_reach.dart).
  void _openOn(InboxContact c) => unawaited(openReach(context, c.name, Reach.on(c)));

  /// What is typed can be written to as it stands: a phone number (three or more digits and their punctuation) or an
  /// email address.
  bool get _typedNumber {
    final q = _field.text.trim();
    return RegExp(r'^[+()\-\s0-9.]{3,}$').hasMatch(q) || RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(q);
  }

  /// Adds [p] to who it is to (once), and clears the field for the next.
  void _add(Person p) {
    if (!_to.any((x) => x.address == p.address)) setState(() => _to.add(p));
    _field.clear();
    _search('');
    _focus.requestFocus();
  }

  /// On to the conversation with the people chosen (a number still in the field among them), carrying the draft.
  Future<void> _next() async {
    if (_typedNumber) _add(Person(address: _field.text.trim()));
    if (_to.isEmpty) return;
    final addresses = _to.map((p) => p.address).toList();
    final thread = await Sms.instance.threadFor(addresses);
    if (!mounted) return;
    // In the app's frame the conversation takes this page's place in the pane, and the list marks it.
    final shell = AppShell.maybeOf(context);
    if (shell != null) return shell.openThread(thread, List.of(_to), draft: widget.body);
    Navigator.of(context).pushReplacement(PageRouteBuilder<void>(
      transitionDuration: const Duration(milliseconds: 200),
      pageBuilder: (context, _, _) => ThreadScreen(thread: thread, people: List.of(_to), draft: widget.body),
      transitionsBuilder: (context, a, _, child) => FadeTransition(opacity: a, child: child),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final gutter = t.space(4);
    final ready = _to.isNotEmpty || _typedNumber;
    // Dial-Up: Next is one of the era's raised buttons on the title bar, and the field a white box sunk into the page.
    final dialup = isBevelChrome(t);
    return GhostPage(
      title: 'New message',
      actions: [
        if (dialup)
          RetroButton(onPressed: ready ? _next : null, label: 'Next', faceHeight: 32, minFaceWidth: 64)
        else
        Padding(
          padding: EdgeInsetsDirectional.only(end: t.space(2)),
          child: GlacierPressable(
            onPressed: ready ? _next : null,
            builder: (context, state) => Container(
              padding: EdgeInsets.symmetric(horizontal: t.space(4), vertical: t.space(2)),
              decoration: BoxDecoration(color: t.color(ready ? 'app-ink' : 'app-paper-3'), borderRadius: BorderRadius.circular(t.lenOf('1.2rem'))),
              child: Text('Next', style: pageText(t, t.fontSize('sm'), weight: 'semibold', color: t.color(ready ? 'app-paper' : 'app-ink-3'))),
            ),
          ),
        ),
      ],
      body: _face(dialup, Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: EdgeInsetsDirectional.fromSTEB(gutter, 0, gutter, t.space(2)),
          child: Wrap(
            spacing: t.space(2),
            runSpacing: t.space(2),
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              for (final p in _to)
                GlacierPressable(
                  onPressed: () => setState(() => _to.remove(p)),
                  semanticLabel: 'Remove ${p.label}',
                  builder: (context, state) => Container(
                    padding: EdgeInsetsDirectional.fromSTEB(t.space(1), t.space(1), t.space(3), t.space(1)),
                    decoration: BoxDecoration(color: t.color(state.pressed ? 'app-paper-3' : 'app-paper-2'), borderRadius: BorderRadius.circular(dialup ? 0 : t.lenOf('1rem'))),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Avatar(people: [p], size: t.lenOf('1.5rem')),
                      SizedBox(width: t.space(2)),
                      Text(p.label, style: pageText(t, t.fontSize('sm'), weight: 'medium')),
                      SizedBox(width: t.space(1)),
                      AppIcon(Lucide.x, size: 14, color: t.color('app-ink-3'), wash: false),
                    ]),
                  ),
                ),
            ],
          ),
        ),
        Padding(
          padding: EdgeInsetsDirectional.fromSTEB(gutter, 0, gutter, t.space(2)),
          child: _well(dialup, GlacierInput(
            controller: _field,
            focusNode: _focus,
            autoFocus: true,
            placeholder: _to.isEmpty ? 'Name or number' : 'Add someone else',
            ariaLabel: 'To',
            size: GlacierFieldSize.md,
            inputMode: TextInputType.text,
            enterKeyHint: TextInputAction.next,
            autoCorrect: false,
            onChange: (v) { setState(() {}); _search(v); },
            onSubmitted: (_) => _typedNumber ? _add(Person(address: _field.text.trim())) : _next(),
          )),
        ),
        Expanded(
          child: _results(dialup, _typedNumber || _matches.isNotEmpty || (_to.isEmpty && _onNetworks.isNotEmpty), gutter, ListView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: EdgeInsets.only(bottom: t.space(4)),
            children: [
              if (_typedNumber)
                _ContactRow(
                  person: Person(address: _field.text.trim()),
                  line: 'Send to ${_field.text.trim()}',
                  onPress: () => _add(Person(address: _field.text.trim())),
                ),
              for (final c in _matches)
                _ContactRow(
                  person: Person(address: c['address'] ?? '', name: c['name'], photo: c['photo']),
                  line: [c['label'], c['address']].where((s) => s != null && s.isNotEmpty).join(' · '),
                  onPress: () => _add(Person(address: c['address'] ?? '', name: c['name'], photo: c['photo'])),
                ),
              // People on the networks signed in (GMFB-61), while nobody is chosen yet.
              if (_to.isEmpty)
                for (final c in _onNetworks)
                  if (Inbox.instance.named(c.network) case final n?)
                    _ContactRow(
                      key: ValueKey('on-${c.network}-${c.id}'),
                      // Named by their id there, so their presence is found (Avatar), as Contacts does.
                      person: Person(address: '${c.network}:${c.id}', name: c.name, photo: c.avatar),
                      line: [n.name, c.handle ?? c.number].where((s) => s != null && s.isNotEmpty).join(' · '),
                      mark: inboxMark(n, size: 18),
                      onPress: () => _openOn(c),
                    ),
            ],
          )),
        ),
      ])),
    );
  }
}

Widget _well(bool dialup, Widget field) => dialup ? DialupWell(child: field) : field;

/// Dial-Up's page is the window's silver face, with white only in its wells, as every other Dial-Up page has it: this
/// one was plain white to the bottom edge under its sunken field.
Widget _face(bool dialup, Widget body) => dialup ? Builder(builder: (context) => ColoredBox(color: DialupColors.of(context.tokens).chrome, child: body)) : body;

/// The people found, in a white well sunk into Dial-Up's face (as the Chat List's rows are) while there are any.
Widget _results(bool dialup, bool any, double gutter, Widget list) =>
    dialup && any ? Padding(padding: EdgeInsetsDirectional.fromSTEB(gutter, 0, gutter, gutter), child: Sunken(child: list)) : list;

/// One person found: their face, their name, and [line] under it.
class _ContactRow extends StatelessWidget {
  const _ContactRow({super.key, required this.person, required this.line, required this.onPress, this.mark});
  final Person person;
  final String line;
  final VoidCallback onPress;

  /// The mark of the network they are on, at the row's end, for someone found there.
  final Widget? mark;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return GlacierPressable(
      onPressed: onPress,
      builder: (context, state) => ColoredBox(
        color: state.pressed ? t.color('app-paper-2') : const Color(0x00000000),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: t.space(4), vertical: t.space(2) + 2),
          child: Row(children: [
            Avatar(people: [person], size: t.lenOf('2.5rem')),
            SizedBox(width: t.space(3)),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(person.name ?? person.address, maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('md'), weight: 'medium')),
                if (person.name != null || line.isNotEmpty)
                  Text(line, maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('sm'), color: t.color('app-ink-3'))),
              ]),
            ),
            if (mark != null) ...[SizedBox(width: t.space(2)), mark!],
          ]),
        ),
      ),
    );
  }
}
