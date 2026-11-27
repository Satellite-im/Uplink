import 'dart:async';

import 'package:flutter/widgets.dart';

import '../friends/buddies.dart';
import '../inbox/people.dart' show Someone;
import '../invites/text_invites.dart';
import '../sms.dart';
import '../voice/channels.dart';
import '../voice/voice.dart';
import 'invite_people.dart';
import 'shell.dart';

/// The words an invite to [c] goes with, by a text or the share sheet.
String spaceInviteWords(VoiceChannel c) => 'Join me in ${c.name} on Uplink: ${c.link}';

/// Inviting people into a space, from wherever invite is offered (Matt, 2026-11-16: "make a way to invite friends from
/// the app into spaces and invite people into spaces through the app"): the sheet lib/ui/invite_people.dart draws for
/// spaces and circles alike (Matt, 2026-11-17: "when adding people to the space we should have a suggested list of our
/// contacts to add if they're not on ghost yet it should send them a text ... sort the list by friends on ghost
/// first"). Friends on Uplink are sent the space at once (Voice.share: it shows on their phone as an invite);
/// contacts chosen are texted the link from this phone, asked first; anyone else by a text already written, the link
/// copied, its QR code, or the system's share sheet.
///
/// [send], [compose], [buddies], [inSpace] (who is in it, by id), [contacts], [texts] and [canText] are for a test;
/// the app's own otherwise ([compose] opens a new text with the words written, through the phone on a computer, or
/// the share sheet where there is no shell). A group's channel is its members' alone: nothing is raised for one.
Future<void> showSpaceInvite(
  BuildContext context,
  VoiceChannel channel, {
  Future<List<Buddy>> Function(VoiceChannel channel, List<Buddy> friends)? send,
  void Function(String words)? compose,
  Buddies? buddies,
  Set<String>? inSpace,
  Future<List<Someone>> Function()? contacts,
  TextInvites? texts,
  bool? canText,
}) {
  if (channel.group != null) return Future.value();
  // The shell stands under the outermost navigator the sheet is raised on: found here, before.
  final shell = AppShell.maybeOf(context);
  final write = compose ?? (shell == null ? (String words) => unawaited(Sms.instance.shareText(channel.name, words)) : (String words) => shell.compose(body: words));
  return showInvitePeople(
    context,
    InviteTarget.space(channel, send: send ?? Voice.instance.share, inside: () => inSpace ?? _inSpace(channel), words: spaceInviteWords(channel)),
    buddies: buddies,
    contacts: contacts,
    texts: texts,
    compose: write,
    canText: canText,
  );
}

/// Who is in [channel] now, by id: in the call here, or as the hub says.
Set<String> _inSpace(VoiceChannel channel) {
  final v = Voice.instance;
  final s = v.session;
  if (s != null && s.channel.room == channel.room) return s.members.keys.toSet();
  return v.inChannel(channel).toSet();
}
