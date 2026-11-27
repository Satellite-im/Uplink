import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart' show Clipboard, ClipboardData, TextCapitalization;
import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../account/account.dart';
import '../art/app_icon.dart';
import '../art/lucide.g.dart';
import '../friends/buddies.dart';
import '../kit/settings_kit.dart';
import '../kit/settings_type.dart';
import '../me/identity.dart';
import '../me/me.dart';
import '../sms.dart';
import 'common.dart';
import '../kit/semantic_colors.dart';
import '../l10n/words.dart';

// An account's key as the world can know it (GMFB-33; lib/me/identity.dart): its did:key on the profile, with Copy and
// Share, and statements signed with it, and checked. Vouches are lib/ui/vouches_ui.dart's.

Widget _icon(LucideIcon icon) => AppIcon(icon, size: 18);

/// What a did:key is, in a line, under it.
const didWords = 'Your account key, written as a did:key: who you are on the network, the same on every device. Anyone can check something you sign against it with standard tools, without asking us.';

/// The same, on a friend's card.
String theirDidWords(String name) => '$name\'s account key, as a did:key. A statement signed by it is theirs.';

/// Whose a checked statement is, in words: yours, a friend's, or an account this app doesn't know; or why it doesn't
/// check out.
String proofOwnerWords(ProofCheck c, {Uint8List? mine, Iterable<Buddy> friends = const []}) {
  if (!c.good) return c.problem;
  final key = c.key!;
  bool same(List<int> a, List<int> b) => a.length == b.length && [for (var i = 0; i < a.length; i++) a[i] == b[i]].every((x) => x);
  if (mine != null && same(mine, key)) return 'Signed by you.';
  for (final b in friends) {
    try {
      if (same(base64Decode(b.key), key)) return 'Signed by ${b.shown == bareName(b.username) ? '@${b.username}' : '${b.shown} (@${b.username})'}, your friend.';
    } catch (_) {}
  }
  return 'Signed by an account you don\'t have as a friend: ${Did.short(c.did)}. The signature is that account\'s; who holds it, this can\'t say.';
}

/// This account's name and key, as the routes know them; null where they can't be asked yet.
typedef IdentityOf = Future<({String id, Uint8List key})?> Function();
typedef SignWith = Future<Uint8List> Function(List<int> message);

Future<({String id, Uint8List key})?> _phoneIdentity() async {
  try {
    return await Sms.instance.netIdentity();
  } catch (_) {
    return null;
  }
}

/// Profile › Your account key: the did:key, copied or shared; the account's 0x address where it has one; signing a
/// statement and checking one.
class AccountKeySection extends StatefulWidget {
  const AccountKeySection({super.key, this.identity, this.sign, this.address});
  final IdentityOf? identity;
  final SignWith? sign;

  /// The account's 0x address, where this device is signed in to one; Account.instance's where not given.
  final String? address;

  @override
  State<AccountKeySection> createState() => _AccountKeySectionState();
}

class _AccountKeySectionState extends State<AccountKeySection> {
  late final Future<({String id, Uint8List key})?> _me = (widget.identity ?? _phoneIdentity)();

  @override
  Widget build(BuildContext context) => FutureBuilder(
        future: _me,
        builder: (context, snap) {
          final me = snap.data;
          final did = me == null ? null : Did.ofKey(me.key);
          final address = widget.address ?? Account.instance.address;
          return PaneSection(
            title: 'Your account key',
            description: const Text(didWords),
            children: [
              SettingRow(
                key: const ValueKey('did-copy'),
                icon: _icon(Lucide.keyRound),
                label: did == null ? (snap.connectionState == ConnectionState.done ? 'Not made yet' : 'Reading…') : Did.short(did),
                hint: did == null ? null : const Tr('Copy'),
                disabled: did == null,
                onPress: did == null
                    ? null
                    : () {
                        unawaited(Clipboard.setData(ClipboardData(text: did)));
                        toast(context, 'Copied your account key');
                      },
              ),
              SettingRow(key: const ValueKey('did-share'), icon: _icon(Lucide.share2), label: 'Share it', disabled: did == null, onPress: did == null ? null : () => Sms.instance.shareText('My Uplink account key', did)),
              if (address != null)
                SettingRow(
                  key: const ValueKey('did-address'),
                  icon: _icon(Lucide.atSign),
                  label: '${address.substring(0, 8)}…${address.substring(address.length - 6)}',
                  hint: const Tr('Your account\'s address, made from your recovery words. Copy'),
                  onPress: () {
                    unawaited(Clipboard.setData(ClipboardData(text: address)));
                    toast(context, 'Copied your account\'s address');
                  },
                ),
              SettingRow(
                key: const ValueKey('proof-sign'),
                icon: _icon(Lucide.penLine),
                label: 'Sign a statement',
                hint: const Tr('Words to paste anywhere, which show they came from this account'),
                disabled: me == null,
                onPress: me == null ? null : () => push<void>(context, (_) => SignStatementScreen(publicKey: me.key, sign: widget.sign ?? Sms.instance.netSign)),
              ),
              SettingRow(
                key: const ValueKey('proof-check'),
                icon: _icon(Lucide.shieldCheck),
                label: 'Check a statement',
                hint: const Tr('Paste one to see whose it is'),
                onPress: () => push<void>(context, (_) => CheckStatementScreen(mine: me?.key)),
              ),
            ],
          );
        },
      );
}

/// A box to write several lines in, as Add handles has.
class _Words extends StatefulWidget {
  const _Words({required this.controller, required this.placeholder, this.readOnly = false, this.fieldKey});
  final TextEditingController controller;
  final String placeholder;
  final bool readOnly;
  final Key? fieldKey;

  @override
  State<_Words> createState() => _WordsState();
}

class _WordsState extends State<_Words> {
  final _focus = FocusNode();

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final ink = pageText(t, t.fontSize('md'), color: t.color('app-ink'), height: 1.4);
    return SettingRowBox(
      child: GestureDetector(
        onTap: _focus.requestFocus,
        child: Container(
          constraints: BoxConstraints(minHeight: t.lenOf('6rem')),
          padding: EdgeInsets.all(t.space(3)),
          decoration: BoxDecoration(color: t.color('app-paper-3'), borderRadius: BorderRadius.circular(t.radius('md'))),
          child: ListenableBuilder(
            listenable: widget.controller,
            builder: (context, _) => Stack(children: [
              if (widget.controller.text.isEmpty) IgnorePointer(child: Text(widget.placeholder, style: ink.copyWith(color: t.color('app-ink-3')))),
              EditableText(
                key: widget.fieldKey,
                controller: widget.controller,
                focusNode: _focus,
                readOnly: widget.readOnly,
                style: ink,
                cursorColor: t.color('app-ink'),
                backgroundCursorColor: t.color('app-ink-3'),
                selectionColor: t.textSelection,
                minLines: 3,
                maxLines: 14,
                keyboardType: TextInputType.multiline,
                autocorrect: false,
                enableSuggestions: false,
                textCapitalization: TextCapitalization.sentences,
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// Signing a statement: the words (up to 280 characters), then the block to paste anywhere.
class SignStatementScreen extends StatefulWidget {
  const SignStatementScreen({super.key, required this.publicKey, required this.sign, this.now});
  final Uint8List publicKey;
  final SignWith sign;
  final DateTime Function()? now;

  @override
  State<SignStatementScreen> createState() => _SignStatementScreenState();
}

class _SignStatementScreenState extends State<SignStatementScreen> {
  late final _words = TextEditingController(text: Me.instance.username == null ? 'This is my Uplink account.' : 'I am @${Me.instance.username} on Uplink');
  final _block = TextEditingController();
  String? _problem;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _words.addListener(() {
      if (_block.text.isNotEmpty) _block.clear();
      setState(() => _problem = null);
    });
  }

  @override
  void dispose() {
    _words.dispose();
    _block.dispose();
    super.dispose();
  }

  Future<void> _sign() async {
    final why = Proof.refuse(_words.text);
    if (why != null) return setState(() => _problem = why);
    setState(() => _busy = true);
    try {
      final block = await Proof.make(_words.text, publicKey: widget.publicKey, sign: widget.sign, now: widget.now?.call());
      if (mounted) setState(() => _block.text = block);
    } catch (e) {
      if (mounted) setState(() => _problem = 'It couldn\'t be signed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final left = Proof.most - Proof.tidy(_words.text).runes.length;
    final block = _block.text;
    return GhostPage(
      title: 'Sign a statement',
      body: SettingsPaneScope(
        finder: SettingsFinder(),
        child: ListView(
          padding: EdgeInsetsDirectional.fromSTEB(t.space(4), t.space(2), t.space(4), t.space(8) + MediaQuery.paddingOf(context).bottom),
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          children: [
            PaneSection(
              title: 'What you say',
              description: const Tr('Say which account elsewhere is yours, and paste the signed block there: in a bio, a post or a page. It shows the words came from this account, and when.'),
              footer: Text(_problem ?? (left >= 0 ? '$left characters left' : '${-left} too many'), style: TextStyle(color: _problem != null || left < 0 ? t.danger : t.color('app-ink-3'))),
              children: [
                _Words(controller: _words, placeholder: 'I am @maya on Uplink'.t, fieldKey: const ValueKey('proof-words')),
                SettingRow(key: const ValueKey('proof-make'), icon: _icon(Lucide.penLine), label: _busy ? 'Signing…' : 'Sign it', disabled: _busy || left < 0, onPress: _sign),
              ],
            ),
            if (block.isNotEmpty) ...[
              SizedBox(height: t.space(6)),
              PaneSection(
                title: 'Your signed statement',
                description: const Tr('Paste all of it, from the first line to the last. Anyone can check it in Uplink, or with standard tools: the page "How accounts work" says how.'),
                children: [
                  _Words(controller: _block, placeholder: ''.t, readOnly: true, fieldKey: const ValueKey('proof-block')),
                  SettingRow(
                    key: const ValueKey('proof-copy'),
                    icon: _icon(Lucide.copy),
                    label: 'Copy it',
                    onPress: () {
                      unawaited(Clipboard.setData(ClipboardData(text: block)));
                      toast(context, 'Copied your signed statement');
                    },
                  ),
                  SettingRow(icon: _icon(Lucide.share2), label: 'Share it', onPress: () => Sms.instance.shareText('A statement signed by my Uplink account', block)),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Checking a statement: a pasted block, and whose it is (this account's, a friend's, someone else's) or why it isn't.
class CheckStatementScreen extends StatefulWidget {
  const CheckStatementScreen({super.key, this.mine, this.buddies});

  /// This account's key, to say a statement is yours.
  final Uint8List? mine;
  final Buddies? buddies;

  @override
  State<CheckStatementScreen> createState() => _CheckStatementScreenState();
}

class _CheckStatementScreenState extends State<CheckStatementScreen> {
  final _pasted = TextEditingController();
  ProofCheck? _result;

  @override
  void initState() {
    super.initState();
    _pasted.addListener(() {
      if (_result != null) setState(() => _result = null);
    });
  }

  @override
  void dispose() {
    _pasted.dispose();
    super.dispose();
  }

  Future<void> _paste() async {
    final got = await Clipboard.getData(Clipboard.kTextPlain);
    if (got?.text != null) _pasted.text = got!.text!;
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final r = _result;
    final friends = (widget.buddies ?? Buddies.instance).friends;
    return GhostPage(
      title: 'Check a statement',
      body: SettingsPaneScope(
        finder: SettingsFinder(),
        child: ListView(
          padding: EdgeInsetsDirectional.fromSTEB(t.space(4), t.space(2), t.space(4), t.space(8) + MediaQuery.paddingOf(context).bottom),
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          children: [
            PaneSection(
              title: 'The statement',
              description: const Tr('Paste a signed statement, from its BEGIN line to its END line. Nothing is sent anywhere to check it.'),
              children: [
                _Words(controller: _pasted, placeholder: Proof.begin, fieldKey: const ValueKey('check-words')),
                SettingRow(icon: _icon(Lucide.clipboardPaste), label: 'Paste', onPress: () => unawaited(_paste())),
                SettingRow(key: const ValueKey('check-go'), icon: _icon(Lucide.shieldCheck), label: 'Check it', onPress: () => setState(() => _result = Proof.check(_pasted.text))),
              ],
            ),
            if (r != null) ...[
              SizedBox(height: t.space(6)),
              PaneSection(
                title: r.good ? 'It checks out' : 'It doesn\'t check out',
                children: [
                  SettingRow(
                    key: const ValueKey('check-result'),
                    icon: _icon(r.good ? Lucide.circleCheck : Lucide.x),
                    label: proofOwnerWords(r, mine: widget.mine, friends: friends),
                    hint: r.good ? Text('“${r.statement}”${r.signed == null ? '' : ', signed ${listWhen(r.signed!.toLocal())}'}') : null,
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
