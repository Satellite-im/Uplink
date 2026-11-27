/// Sending souls to a friend from a chat with them, and the card that says so (GMFB-39, "Payments between friends";
/// Matt, 2026-11-23: "Tip souls in a chat"). What is sent, how it is carried and when a card is true are
/// lib/souls/souls_send.dart; here are the page souls are sent from and the card as it is drawn.
///
/// The words everywhere are souls and nothing else: they are the app's points, a thank-you, and are never said as
/// anything that could be bought, sold or owed.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart' show FilteringTextInputFormatter, HapticFeedback, TextCapitalization, TextInputType;
import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../app_state.dart';
import '../art/app_icon.dart';
import '../art/lucide.g.dart';
import '../kit/settings_kit.dart';
import '../kit/settings_type.dart';
import '../me/me.dart';
import '../souls/souls_send.dart';
import 'common.dart';
import 'souls.dart' show SoulFlame, soulsCount;
import '../l10n/words.dart';

/// The page souls are sent from: how many, a few words to go with them if wanted, and Send, which asks once more
/// before anything goes. [to] is the friend's Uplink id and [name] what they are called here; [write] sends the card's
/// words into the conversation (true where they went). Closes once the souls are sent.
///
/// [api] and [receipts] are for a test; the app's own otherwise.
class SendSoulsScreen extends StatefulWidget {
  const SendSoulsScreen({super.key, required this.to, required this.name, required this.write, this.api, this.receipts});
  final String to;
  final String name;
  final Future<bool> Function(String words) write;
  final SoulsApi? api;
  final SoulsReceipts? receipts;

  @override
  State<SendSoulsScreen> createState() => _SendSoulsScreenState();
}

class _SendSoulsScreenState extends State<SendSoulsScreen> {
  final _amount = TextEditingController();
  final _note = TextEditingController();
  bool _sending = false;

  /// Why the last try didn't go, under Send until something is changed.
  String? _problem;

  /// This sending's name at the relay, and what it was made for. Kept while the number and the friend are the same, so
  /// pressing Send again after an answer was lost asks for the same sending, which the relay does once.
  String? _id;
  int? _idFor;

  @override
  void initState() {
    super.initState();
    _amount.addListener(_changed);
    _note.addListener(_changed);
    Me.instance.addListener(_changed);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    Me.instance.removeListener(_changed);
    _amount.dispose();
    _note.dispose();
    super.dispose();
  }

  int get _have => Me.instance.souls;
  int? get _n => int.tryParse(_amount.text.trim());

  /// Why Send can't be pressed yet, in words under it; null where it can.
  String? get _why {
    final n = _n;
    if (_have < 1) return 'You have no souls to send yet.';
    if (n == null || n < 1) return 'Say how many souls to send.';
    if (n > soulsAtOnce) return 'Up to $soulsAtOnce souls at a time.';
    if (n > _have) return 'You have ${soulsWords(_have)}.';
    return null;
  }

  void _ask() {
    final n = _n;
    if (_why != null || n == null || _sending) return;
    // Asked once more, with the number and the name: souls sent are the friend's from then on.
    showChoices(context, title: 'Send ${soulsWords(n)} to ${widget.name}? They can\'t be taken back.', choices: [
      Choice('Send ${soulsWords(n)}', Lucide.flame, () => unawaited(_send(n))),
    ]);
  }

  Future<void> _send(int n) async {
    if (_sending) return;
    if (_id == null || _idFor != n) {
      _id = SoulsCard.newId();
      _idFor = n;
    }
    setState(() {
      _sending = true;
      _problem = null;
    });
    try {
      final done = await sendSoulsCard(api: widget.api ?? SoulsApi.live(), to: widget.to, souls: n, id: _id!, note: _note.text, write: widget.write, receipts: widget.receipts);
      Me.instance.soulsNow(done.n);
      HapticFeedback.lightImpact();
      if (!mounted) return;
      // The souls went and the message that says so didn't: said as it is, so nobody sends them a second time.
      toast(context, done.written ? 'Sent ${soulsWords(n)} to ${widget.name}' : '${widget.name} got ${soulsWords(n)}, but the card couldn\'t be put in the chat. Tell them yourself.');
      Navigator.of(context).pop();
    } on SoulsSendError catch (e) {
      if (!mounted) return;
      setState(() {
        _sending = false;
        // Not known to have gone or not: the same sending is asked for again, which can't send twice.
        _problem = e.code == 'unreachable' ? '${e.message} Send again: nothing is sent twice.' : e.message;
        if (e.code != 'unreachable') _id = null;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _sending = false;
        _problem = 'That didn\'t work. Nothing was sent.';
        _id = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final gap = SizedBox(height: t.space(5));
    final n = _n;
    final why = _why;
    return GhostPage(
      title: 'Send souls',
      body: SettingsPaneScope(
        finder: SettingsFinder(),
        child: LayoutBuilder(builder: (context, box) {
          final side = math.max(t.space(4), (box.maxWidth - 640) / 2);
          return ListView(padding: EdgeInsetsDirectional.fromSTEB(side, t.space(2), side, t.space(8) + MediaQuery.paddingOf(context).bottom), children: [
            Padding(
              padding: EdgeInsets.symmetric(vertical: t.space(3)),
              child: Row(children: [
                const SoulFlame(size: 22),
                SizedBox(width: t.space(2)),
                Expanded(
                  child: Text(
                    'You have ${soulsCount(_have)} ${_have == 1 ? 'soul' : 'souls'}. Send some to ${widget.name} to say thanks.',
                    key: const ValueKey('send-souls-have'),
                    style: pageText(t, t.fontSize('md'), color: t.color('app-ink-2'), height: 1.4),
                  ),
                ),
              ]),
            ),
            PaneSection(title: 'How many', children: [
              SettingRowBox(
                child: GlacierInput(
                  key: const ValueKey('send-souls-amount'),
                  controller: _amount,
                  placeholder: 'Up to $soulsAtOnce',
                  ariaLabel: 'How many souls',
                  autoFocus: true,
                  inputMode: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  maxLength: 3,
                  disabled: _sending,
                ),
              ),
            ]),
            gap,
            PaneSection(title: 'A note, if you like', children: [
              SettingRowBox(
                child: GlacierInput(
                  key: const ValueKey('send-souls-note'),
                  controller: _note,
                  placeholder: 'Thanks for the help'.t,
                  ariaLabel: 'A note',
                  autoCapitalize: TextCapitalization.sentences,
                  maxLength: soulsNoteMost,
                  disabled: _sending,
                ),
              ),
            ]),
            gap,
            PaneSection(children: [
              SettingRow(
                key: const ValueKey('send-souls-send'),
                icon: AppIcon(Lucide.flame, size: 18),
                label: _sending ? 'Sending…' : (why == null && n != null ? 'Send ${soulsWords(n)} to ${widget.name}' : 'Send'),
                hint: Text(_problem ?? why ?? 'A card in the chat tells ${widget.name}.', key: const ValueKey('send-souls-hint')),
                disabled: why != null || _sending,
                onPress: why == null && !_sending ? _ask : null,
              ),
            ]),
          ]);
        }),
      ),
    );
  }
}

/// What a souls card says, by where it stands: its headline, and the line under it (null for none). [mine]: this
/// account wrote the message. [repeat]: the same receipt is on a message further up, so this one says nothing new.
({String title, String? line}) soulsCardWords(SoulsCard card, SoulsCardState state, {required bool mine, required String name, bool repeat = false}) {
  final n = soulsWords(card.souls);
  if (repeat) return (title: 'Souls card, repeated', line: 'The same $n as the card above. Nothing more was sent.');
  return switch (state) {
    SoulsCardState.confirmed => (title: mine ? 'You sent $name $n' : '$name sent you $n', line: card.note.isEmpty ? null : card.note),
    SoulsCardState.unknown => (title: mine ? '$n to $name' : '$n from $name', line: 'Not confirmed yet. Checking with the relay.'),
    SoulsCardState.refused => (title: 'Not confirmed', line: mine ? 'This says you sent $n, but the relay has no record of it.' : 'This says $name sent you $n, but the relay has no record of it.'),
  };
}

/// A message that is a souls card ([SoulsCard.of]), drawn as one: the flame, who sent how many to whom, and the note.
/// It says souls were sent only once the relay's receipt agrees ([SoulsReceipts]): from the one who wrote the message
/// ([from], an Uplink id) to the other ([to]). Until then it says it isn't confirmed, and where the relay knows of no
/// such sending it says that.
///
/// [line] draws it as one line of words instead (Dial-Up's transcript). [api] and [receipts] are for a test.
class SoulsSentCard extends StatefulWidget {
  const SoulsSentCard({super.key, required this.card, required this.mine, required this.name, required this.from, required this.to, this.repeat = false, this.maxWidth = 320, this.onLongPress, this.line, this.api, this.receipts});
  final SoulsCard card;
  final bool mine;
  final String name;
  final String from;
  final String to;
  final bool repeat;
  final double maxWidth;
  final VoidCallback? onLongPress;
  final Widget Function(String words)? line;
  final SoulsApi? api;
  final SoulsReceipts? receipts;

  @override
  State<SoulsSentCard> createState() => _SoulsSentCardState();
}

class _SoulsSentCardState extends State<SoulsSentCard> {
  SoulsReceipts get _receipts => widget.receipts ?? SoulsReceipts.instance;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _check());
  }

  @override
  void didUpdateWidget(SoulsSentCard old) {
    super.didUpdateWidget(old);
    if (old.card.id != widget.card.id || old.from != widget.from || old.to != widget.to) _check();
  }

  /// Asks the relay about this card where that isn't known. One that came and is found true: the count is asked for
  /// again, so the souls page says what the card does.
  Future<void> _check() async {
    if (!mounted || widget.repeat) return;
    final app = AppState.maybeOf(context);
    if (app != null && widget.receipts == null) _receipts.attach(app);
    final was = _receipts.stateOf(widget.card, from: widget.from, to: widget.to);
    if (was != SoulsCardState.unknown) return;
    final now = await _receipts.check(widget.card, from: widget.from, to: widget.to, api: widget.api);
    if (now && !widget.mine) Me.instance.askSouls();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return ListenableBuilder(
      listenable: _receipts,
      builder: (context, _) {
        final state = _receipts.stateOf(widget.card, from: widget.from, to: widget.to);
        final words = soulsCardWords(widget.card, state, mine: widget.mine, name: widget.name, repeat: widget.repeat);
        final draw = widget.line;
        if (draw != null) return draw(words.line == null ? '${words.title}.' : '${words.title}. ${words.line}');
        final real = state == SoulsCardState.confirmed && !widget.repeat;
        final box = Container(
          key: ValueKey('souls-card-${widget.card.id}'),
          constraints: BoxConstraints(maxWidth: math.min(widget.maxWidth, t.lenOf('22rem'))),
          padding: EdgeInsets.all(t.space(3)),
          decoration: BoxDecoration(color: t.color('app-paper-2'), borderRadius: BorderRadius.circular(t.radius('lg')), border: Border.all(color: t.color('app-rule'))),
          child: Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child: real ? const SoulFlame(size: 20) : AppIcon(Lucide.flame, size: 20, color: t.color('app-ink-3')),
            ),
            SizedBox(width: t.space(2)),
            Flexible(
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(words.title, style: pageText(t, t.fontSize('md'), weight: 'semibold', color: t.color(real ? 'app-ink' : 'app-ink-2'), height: 1.3)),
                if (words.line != null) ...[
                  SizedBox(height: t.space(1)),
                  Text(words.line!, style: pageText(t, t.fontSize('sm'), color: t.color(real ? 'app-ink-2' : 'app-ink-3'), height: 1.4)),
                ],
              ]),
            ),
          ]),
        );
        return Semantics(
          label: words.line == null ? words.title : '${words.title}. ${words.line}',
          excludeSemantics: true,
          child: GestureDetector(behavior: HitTestBehavior.opaque, onLongPress: widget.onLongPress, child: box),
        );
      },
    );
  }
}
