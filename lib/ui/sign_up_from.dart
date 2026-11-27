/// Signing up from an account someone already has (Matt, 2026-11-19: "add a sign up with discord sign up with telegram
/// or signal option where it pre populates your connection, loads your picture and username and status as well as
/// other details during signup so users don't need to fill everything in manually").
///
/// - **Discord**: signed in in the browser through the relay server (relay/lib/handles.dart, OAuth), which links the
///   account as Settings › Me does and hands back what Discord said of it: its username, name and picture.
/// - **Telegram** and **Signal**: connected here as Settings › Networks connects them (Telegram's sign-in, Signal's
///   linked-device code), and their own profile read from them: name, username, picture, and the bio or About line as
///   a status.
///
/// What comes back fills in the form (lib/standalone/welcome.dart, lib/ui/profile.dart): nothing is claimed or sent to
/// friends until the person presses Continue.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../art/lucide.g.dart';
import '../inbox/inbox.dart';
import '../inbox/signal.dart';
import '../inbox/telegram.dart';
import '../kit/semantic_colors.dart';
import '../kit/settings_kit.dart';
import '../kit/settings_type.dart';
import '../me/me.dart';
import '../sms.dart';
import '../me/picture_make.dart';
import 'common.dart';
import 'inbox_ui.dart' show SignalLinkScreen, TelegramSignInScreen, inboxMark;
import 'me.dart' show NetworkMark;
import 'profile_card.dart' show ProfileFace;
import '../l10n/words.dart';

/// What an account someone has said of them, for a new profile.
@immutable
class SignUpProfile {
  const SignUpProfile({required this.from, this.name = '', this.username = '', this.status = '', this.bio = '', this.picture});

  /// "Discord", "Telegram" or "Signal".
  final String from;
  final String name;

  /// Tidied to what an Uplink username may be ('' where it can't be one).
  final String username;
  final String status;
  final String bio;

  /// The picture as a profile keeps it (Me.setPicture), or null.
  final ProfilePicture? picture;

  bool get isEmpty => name.isEmpty && username.isEmpty && status.isEmpty && picture == null;
}

/// [handle] as an Uplink username: lower case, letters, numbers, dots and underscores; '' where it can't be made one.
String usernameFrom(String handle) {
  final t = tidyHandle(handle).replaceAll(RegExp(r'[^a-z0-9._]'), '');
  final cut = t.length > 20 ? t.substring(0, 20) : t;
  return Me.goodUsername(cut) ? cut : '';
}

/// [status] cut to what a profile's status holds (Me.statusMost).
String statusFrom(String status) {
  final s = status.replaceAll(RegExp(r'\s+'), ' ').trim();
  return s.length <= Me.statusMost ? s : '${s.substring(0, Me.statusMost - 1).trimRight()}…';
}

/// For a test: what brings a picture's bytes down from an address.
@visibleForTesting
Future<Uint8List?> Function(String url) fetchPicture = _fetch;

/// The bytes at [url], over https only; null where it can't be had, takes too long, or is over 8 MB.
Future<Uint8List?> _fetch(String url) async {
  final u = Uri.tryParse(url);
  if (u == null || u.scheme != 'https') return null;
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  try {
    final req = await client.getUrl(u);
    final res = await req.close().timeout(const Duration(seconds: 20));
    if (res.statusCode != 200) return null;
    final b = BytesBuilder(copy: false);
    await for (final chunk in res.timeout(const Duration(seconds: 20))) {
      b.add(chunk);
      // A profile picture is small; anything this large is not one.
      if (b.length > 8 * 1024 * 1024) return null;
    }
    return b.takeBytes();
  } catch (_) {
    return null;
  } finally {
    client.close(force: true);
  }
}

/// A picture, from a file on this device or an address, as a profile keeps it; null where there is none to be had.
Future<ProfilePicture?> profilePictureFrom({String? path, String? url}) async {
  Uint8List? bytes;
  try {
    if (path != null && path.isNotEmpty && File(path).existsSync()) bytes = await File(path).readAsBytes();
  } catch (_) {}
  if (bytes == null && url != null && url.isNotEmpty) bytes = await fetchPicture(url);
  if (bytes == null || bytes.isEmpty) return null;
  try {
    return await profilePictureOf(bytes);
  } catch (_) {
    return null;
  }
}

/// What [p] (a network's own profile of the account signed in there) gives a new profile.
Future<SignUpProfile> signUpFromInbox(String from, InboxProfile p) async {
  final status = [p.status, if (from == 'Signal') p.bio].where((x) => x.trim().isNotEmpty).join(' ');
  return SignUpProfile(
    from: from,
    name: p.name.trim(),
    username: usernameFrom(p.username),
    // Signal's About line is its status; Telegram's bio is the nearest it has to one.
    status: statusFrom(from == 'Signal' ? status : (p.bio.isNotEmpty ? p.bio : p.status)),
    bio: from == 'Telegram' ? p.bio.trim() : '',
    picture: await profilePictureFrom(path: p.avatar),
  );
}

/// What Discord's sign-in gave: its username, and its name and picture where it said them.
Future<SignUpProfile> signUpFromDiscord(String handle, Map<String, String> about) async => SignUpProfile(
      from: 'Discord',
      name: (about['name'] ?? '').trim(),
      username: usernameFrom(handle),
      picture: await profilePictureFrom(url: about['picture']),
    );

/// The ways to start from an account that this device and the relay server have: Discord where the server signs in
/// with it, Telegram and Signal where this build has them.
List<String> signUpSources() => [
      if (Me.instance.ways['discord'] == 'signin') 'discord',
      if (Inbox.instance.named('telegram') is Telegram) 'telegram',
      if (Inbox.instance.named('signal') is Signal) 'signal',
    ];

/// Starts from [source]: signs in or connects there, and reads the profile. Null where it was left unfinished.
Future<SignUpProfile?> signUpFrom(BuildContext context, String source) async {
  switch (source) {
    case 'discord':
      final got = await Me.instance.signInWith('discord', Sms.instance.openLink);
      if (got == null) throw MeError('No browser could be opened.');
      return signUpFromDiscord(got.handle, got.about);
    case 'telegram' || 'signal':
      final n = Inbox.instance.named(source);
      if (n == null) return null;
      if (n.state != InboxState.ready) {
        await push<void>(context, (_) => n is Telegram ? TelegramSignInScreen(network: n) : SignalLinkScreen(network: n as Signal));
      }
      if (n.state != InboxState.ready) return null;
      // Signal's profile comes a moment after the link: asked a few times.
      InboxProfile? p;
      for (var i = 0; i < 4 && (p == null || p.name.isEmpty); i++) {
        if (i > 0) await Future<void>.delayed(const Duration(seconds: 2));
        p = await n.ownProfile().catchError((_) => null);
      }
      if (p == null) return SignUpProfile(from: n.name);
      return signUpFromInbox(n.name, p);
  }
  return null;
}

/// "Start from an account you have": a row for each of [signUpSources], which signs in there and hands [onFilled]
/// what it found.
class SignUpFromSection extends StatefulWidget {
  const SignUpFromSection({super.key, required this.onFilled});
  final ValueChanged<SignUpProfile> onFilled;

  @override
  State<SignUpFromSection> createState() => _SignUpFromSectionState();
}

class _SignUpFromSectionState extends State<SignUpFromSection> {
  String? _busy;
  String? _problem;

  /// Signs in to [source] and hands what its profile gave to the form; one at a time, a failure shown in its words.
  Future<void> _start(String source) async {
    if (_busy != null) return;
    setState(() {
      _busy = source;
      _problem = null;
    });
    try {
      final got = await signUpFrom(context, source);
      if (got != null && mounted) widget.onFilled(got);
    } catch (e) {
      if (mounted) setState(() => _problem = e is MeError ? e.message : '$e');
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return ListenableBuilder(
      listenable: Me.instance,
      builder: (context, _) {
        final sources = signUpSources();
        if (sources.isEmpty) return const SizedBox.shrink();
        Widget row(String id) {
          final InboxNetwork? n = id == 'discord' ? null : Inbox.instance.named(id);
          final name = n?.name ?? 'Discord';
          final busy = _busy == id;
          return SettingRow(
            key: ValueKey('sign-up-from-$id'),
            icon: n != null ? inboxMark(n) : NetworkMark(networkOf('discord')),
            label: 'Sign up with $name',
            hint: Text(busy
                ? (id == 'discord' ? 'Finish signing in in your browser…' : 'Reading your $name profile…')
                : id == 'discord'
                    ? 'Your Discord username, name and picture, and Discord linked to your profile'
                    : id == 'telegram'
                        ? 'Your Telegram name, username, picture and bio, and your Telegram chats here'
                        : 'Your Signal name, picture and About, and your Signal chats here'),
            value: busy ? const GhostSpinner(size: 16) : null,
            onPress: _busy == null ? () => _start(id) : null,
          );
        }

        return PaneSection(
          title: 'Start from an account you have',
          description: const Tr('Fills in your username, name, picture and status for you. You can change any of it.'),
          footer: _problem == null ? null : Text(_problem!, style: TextStyle(color: t.danger)),
          children: [for (final id in sources) row(id)],
        );
      },
    );
  }
}

/// What was filled in, shown above the form: the picture, the name and status, where it came from, and a way to undo.
class SignUpFilled extends StatelessWidget {
  const SignUpFilled({super.key, required this.profile, required this.onClear});
  final SignUpProfile profile;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final p = profile;
    final face = ProfileFace(name: p.name.isNotEmpty ? p.name : p.username, picture: p.picture?.sharp, size: t.lenOf('3rem'));
    return PaneSection(
      key: const ValueKey('sign-up-filled'),
      children: [
        SettingRowBox(
          child: Padding(
            padding: EdgeInsets.all(t.space(3)),
            child: Row(children: [
              face,
              SizedBox(width: t.space(3)),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                  Text(p.name.isNotEmpty ? p.name : (p.username.isNotEmpty ? '@${p.username}' : 'From ${p.from}'),
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('md'), weight: 'semibold', color: t.color('app-ink'))),
                  if (p.status.isNotEmpty) Text(p.status, maxLines: 2, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('sm'), color: t.color('app-ink-2'))),
                  Text('From ${p.from}', style: pageText(t, t.fontSize('xs'), color: t.color('app-ink-3'))),
                ]),
              ),
              IconTap(key: const ValueKey('sign-up-filled-clear'), icon: Lucide.x, label: 'Don\'t use this', onPressed: onClear),
            ]),
          ),
        ),
      ],
    );
  }
}
