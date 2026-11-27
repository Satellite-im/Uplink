import 'package:flutter/services.dart' show Clipboard, ClipboardData, TextCapitalization;
import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../art/app_icon.dart';
import '../art/lucide.g.dart';
import '../kit/settings_type.dart';
import '../ui/common.dart';
import '../inbox/curl_sync.dart';
import 'google_signin.dart';
import '../kit/semantic_colors.dart';

/// Setting up Google Messages, start to end, in one place (Matt, 2026-11-15: "Please make setting up google messages a
/// onboarding flow that is all in one place. It should also needs to if possible prompt to open the link incognito"):
/// sign in to Google in a private window, copy that request, paste it here, tap the emoji Google Messages shows on the
/// phone. The same on a computer (lib/desktop/ui/desk_settings.dart) and on the phone (lib/ui/gm_web_screen.dart),
/// whose helpers pair the same way (sidecar/gmessages `pair_google`).
class GoogleSignInFlow extends StatefulWidget {
  const GoogleSignInFlow({super.key, required this.onPair, this.onOpenPrivate, this.emoji, this.problem, this.onPhone = false, this.synced});

  /// The Google sign-in the browser extension synced to this account (GMFB-10, @kevin: "Getting rcs is annoying due to
  /// the workaround we are using so maybe making a chrome extension to automate is a better solution"): it does steps
  /// 1 to 3 in a private window of its own. Read from CurlSync where not given (a test gives its own).
  final Future<({Map<String, String> cookies, int at})?> Function()? synced;

  /// Hands the cookies to the helper; an error's words, or null once it is asked.
  final Future<String?> Function(Map<String, String> cookies) onPair;

  /// Opens [googleSignInUrl] in a private window of a browser on this computer; false where none could be.
  final Future<bool> Function()? onOpenPrivate;

  /// The emoji to tap in Google Messages, once the helper has it.
  final String? emoji;

  /// Why the last try failed, from the helper.
  final String? problem;

  /// On the phone: the browser steps are done on a computer.
  final bool onPhone;

  @override
  State<GoogleSignInFlow> createState() => _GoogleSignInFlowState();
}

class _GoogleSignInFlowState extends State<GoogleSignInFlow> {
  final _pasted = TextEditingController();

  /// What is wrong with what was pasted, or why the helper would not pair.
  String? _error;

  /// The helper has the cookies and has not answered yet.
  bool _asking = false;

  /// The sign-in page was opened, or its link copied: the paste step is the current one from then.
  bool _opened = false;

  /// The extension's synced Google sign-in, once read; null where there is none.
  ({Map<String, String> cookies, int at})? _synced;

  @override
  void initState() {
    super.initState();
    (widget.synced ?? () => CurlSync.instance.entryOf('gmessages'))().then((e) {
      final usable = e != null && googleCookiesMissing(e.cookies).isEmpty;
      if (mounted && usable) setState(() => _synced = e);
    });
  }

  /// Pairs with the Google cookies the account's other devices synced, in place of signing in here.
  Future<void> _pairSynced() async {
    final e = _synced;
    if (e == null) return;
    setState(() {
      _error = null;
      _asking = true;
    });
    final why = await widget.onPair(e.cookies);
    if (mounted) {
      setState(() {
        _asking = false;
        _error = why == null ? null : '$why The sign-in may have ended: set up Google Messages again in the extension, or do the steps below.';
      });
    }
  }

  @override
  void dispose() {
    _pasted.dispose();
    super.dispose();
  }

  /// Reads the cookies out of what was pasted and hands them to the helper; says which are missing where some are.
  Future<void> _pair() async {
    final cookies = googleCookiesIn(_pasted.text);
    final missing = googleCookiesMissing(cookies);
    if (missing.isNotEmpty) {
      setState(() => _error = cookies.isEmpty
          ? 'That doesn\'t look like the copied request. Copy it again with Copy as cURL, and paste all of it.'
          : 'It\'s missing ${missing.join(', ')}. Make sure you copied the "config" request, signed in, and pasted all of it.');
      return;
    }
    setState(() {
      _error = null;
      _asking = true;
    });
    final why = await widget.onPair(cookies);
    if (mounted) {
      setState(() {
        _asking = false;
        _error = why;
      });
    }
  }

  /// Opens the sign-in page in a private window; where no browser could be, its link is put on the clipboard.
  Future<void> _open() async {
    final ok = await widget.onOpenPrivate!.call();
    if (!mounted) return;
    setState(() => _opened = true);
    if (!ok) {
      await Clipboard.setData(const ClipboardData(text: googleSignInUrl));
      if (mounted) toast(context, 'No browser could be opened privately: the link is copied. Open a private window and paste it.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final emoji = widget.emoji;
    Widget card(int n, String title, List<Widget> body, {bool current = false}) => Container(
          margin: EdgeInsets.only(bottom: t.space(3)),
          padding: EdgeInsets.all(t.space(4)),
          decoration: BoxDecoration(
            color: t.color('app-paper-2'),
            borderRadius: BorderRadius.circular(t.radius('lg')),
            border: Border.all(color: current ? t.color('app-ink') : t.color('app-rule'), width: current ? 1.5 : 1),
          ),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              width: t.lenOf('1.6rem'),
              height: t.lenOf('1.6rem'),
              margin: EdgeInsetsDirectional.only(end: t.space(3)),
              decoration: BoxDecoration(shape: BoxShape.circle, color: current ? t.color('app-ink') : t.color('app-paper-3')),
              alignment: Alignment.center,
              child: Text('$n', style: pageText(t, t.fontSize('xs'), weight: 'bold', color: current ? t.color('app-paper') : t.color('app-ink-3'))),
            ),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: pageText(t, t.fontSize('md'), weight: 'semibold', color: t.color('app-ink'))),
              SizedBox(height: t.space(1)),
              ...body,
            ])),
          ]),
        );
    Widget text(String s, {bool small = false}) => Padding(
          padding: EdgeInsets.only(bottom: t.space(2)),
          child: Text(s, style: pageText(t, small ? t.fontSize('xs') : t.fontSize('sm'), color: small ? t.color('app-ink-3') : t.color('app-ink-2'), height: 1.45)),
        );
    Widget button(String label, VoidCallback? onPressed, {bool filled = false}) => GlacierPressable(
          onPressed: onPressed,
          semanticLabel: label,
          builder: (context, state) => Container(
            padding: EdgeInsets.symmetric(horizontal: t.space(4), vertical: t.space(2)),
            decoration: BoxDecoration(
              color: filled ? t.color('app-ink').withValues(alpha: onPressed == null ? 0.4 : (state.pressed ? 0.85 : 1)) : (state.pressed ? t.color('app-paper-3') : const Color(0x00000000)),
              borderRadius: BorderRadius.circular(t.radius('full')),
              border: filled ? null : Border.all(color: t.color('app-ink-3')),
            ),
            child: Text(label, style: pageText(t, t.fontSize('sm'), weight: 'semibold', color: filled ? t.color('app-paper') : t.color('app-ink'))),
          ),
        );

    // The emoji: the last step, alone.
    if (emoji != null) {
      return Container(
        padding: EdgeInsets.all(t.space(6)),
        decoration: BoxDecoration(color: t.color('app-paper-2'), borderRadius: BorderRadius.circular(t.radius('xl'))),
        child: Column(children: [
          Text('On your phone', style: pageText(t, t.fontSize('sm'), weight: 'semibold', color: t.color('app-ink-3'))),
          SizedBox(height: t.space(2)),
          Text('Google Messages asks you to tap an emoji. Tap this one:', textAlign: TextAlign.center, style: pageText(t, t.fontSize('md'), color: t.color('app-ink'))),
          SizedBox(height: t.space(4)),
          Text(emoji, style: TextStyle(fontSize: t.lenOf('5rem'))),
          SizedBox(height: t.space(3)),
          text('If nothing shows on the phone, open Google Messages: the question is waiting there.', small: true),
        ]),
      );
    }

    final pasting = _opened || _pasted.text.isNotEmpty;
    final synced = _synced;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      // The browser extension's sign-in, where it has synced one (GMFB-10); else where to get it.
      Container(
        key: const ValueKey('gm-synced'),
        margin: EdgeInsets.only(bottom: t.space(3)),
        padding: EdgeInsets.all(t.space(4)),
        decoration: BoxDecoration(
          color: t.color('app-paper-2'),
          borderRadius: BorderRadius.circular(t.radius('lg')),
          border: Border.all(color: synced != null ? t.color('app-ink') : t.color('app-rule'), width: synced != null ? 1.5 : 1),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(synced != null ? 'Your browser has signed in for you' : 'Or let your browser do steps 1 to 3', style: pageText(t, t.fontSize('md'), weight: 'semibold', color: t.color('app-ink'))),
          SizedBox(height: t.space(1)),
          if (synced != null) ...[
            text('The Uplink keys extension signed in to Google in a private window and synced it to your account. Pair with it, then tap the emoji on your phone.'),
            Row(children: [
              button(_asking ? 'Asking Google…' : 'Use the Google sign-in from your browser', _asking ? null : _pairSynced, filled: true),
            ]),
          ] else
            text('The Uplink keys extension for Chrome signs in to Google in a private window and hands the sign-in to all your devices: add it from gogho.st/docs/browser-extension, open it, and choose Set up Google Messages. This page then has a button for it.', small: true),
        ]),
      ),
      if (widget.onPhone)
        text('Google only lets this be done in a computer\'s browser (it needs the browser\'s developer tools). Do steps 1 and 2 on a computer, then get the copied text to this phone (email or a note to yourself) and paste it in step 3. Or simpler: pair Uplink on your computer instead (Settings › Google Messages there).'),
      card(1, 'Sign in to Google in a private window', [
        text('Open this link in a private (incognito) window and sign in with the Google account Google Messages on your phone uses. A private window keeps the browser from changing the sign-in afterwards. Don\'t go anywhere else in that window.'),
        if (widget.onOpenPrivate != null) ...[
          Wrap(spacing: t.space(2), runSpacing: t.space(2), children: [
            button('Open in a private window', _open, filled: !pasting),
            button('Copy the link', () async {
              await Clipboard.setData(const ClipboardData(text: googleSignInUrl));
              if (context.mounted) toast(context, 'Copied. Paste it in a private window.');
              setState(() => _opened = true);
            }),
          ]),
        ] else
          Wrap(spacing: t.space(2), children: [
            button('Copy the link', () async {
              await Clipboard.setData(const ClipboardData(text: googleSignInUrl));
              if (context.mounted) toast(context, 'Copied');
              setState(() => _opened = true);
            }, filled: !pasting),
          ]),
        SizedBox(height: t.space(2)),
        text('Firefox works best (Ctrl+Shift+P, ⇧⌘P on a Mac). Chrome and Edge: Ctrl+Shift+N (⇧⌘N). Safari: File › New Private Window. If Google refuses a sign-in from Chrome, use Firefox: Chrome can lock a sign-in to itself.', small: true),
      ], current: !pasting),
      card(2, 'Copy the sign-in', [
        text('Once it shows a page of text (messages.google.com/web/config): open the developer tools (F12, or ⌥⌘I on a Mac), choose Network, and reload the page. Right-click the request named "config", then Copy › Copy as cURL (on Windows, "Copy as cURL (bash)").'),
        text('Safari: turn on Settings › Advanced › Show features for web developers first, then Develop › Show Web Inspector › Network.', small: true),
      ], current: pasting && _pasted.text.isEmpty),
      card(3, 'Paste it here', [
        GlacierInput(
          controller: _pasted,
          placeholder: "curl 'https://messages.google.com/web/config' …",
          ariaLabel: 'The copied request',
          autoCorrect: false,
          autoCapitalize: TextCapitalization.none,
          size: GlacierFieldSize.md,
          onChange: (_) => setState(() => _error = null),
          onSubmitted: (_) => _pair(),
        ),
        SizedBox(height: t.space(3)),
        Row(children: [
          button(_asking ? 'Asking Google…' : 'Pair', _asking || _pasted.text.trim().isEmpty ? null : _pair, filled: true),
          SizedBox(width: t.space(3)),
          Expanded(child: Text('Then close the private window. Don\'t sign out in it.', style: pageText(t, t.fontSize('xs'), color: t.color('app-ink-3')))),
        ]),
        if (_error != null || widget.problem != null)
          Padding(
            padding: EdgeInsets.only(top: t.space(3)),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Padding(padding: EdgeInsetsDirectional.only(end: t.space(2), top: 2), child: AppIcon(Lucide.triangleAlert, size: 16, color: t.danger)),
              Expanded(child: Text(_error ?? widget.problem!, style: pageText(t, t.fontSize('sm'), color: t.danger, height: 1.4))),
            ]),
          ),
      ], current: _pasted.text.isNotEmpty),
      card(4, 'Tap the emoji on your phone', [
        text('Google Messages on your phone asks you to choose an emoji. Uplink shows here which one.'),
      ]),
    ]);
  }
}
