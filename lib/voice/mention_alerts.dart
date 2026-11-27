import 'package:flutter/foundation.dart';

import '../circles/circles.dart';
import 'hangout.dart';
import 'voice.dart';

/// One notification for a mention in a space.
@immutable
class MentionAlert {
  const MentionAlert({required this.key, required this.where, required this.title, required this.body});

  /// `space:<seed>`: the notification's own name, and what a press on it opens (lib/main.dart).
  final String key;

  /// The circle's name, or "Spaces" for a space of one's own: shown under the title.
  final String where;

  /// "Maya in #plans".
  final String title;
  final String body;
}

/// A notification when someone mentions you in a space (Matt, 2026-11-19: "Add mentions support to spaces and circles
/// with the @user prefix"), until then the only thing a space's chat notified of.
///
/// Told of each message a space's chat takes in (HangoutRoom.onFresh, set by Voice): one from someone else that
/// mentions this device, newer than it last read that space, is notified, unless the space is the one on the screen
/// while the app is in front, or Settings › Notifications › Mentions in spaces is off. The space read takes it away.
/// A notification is the phone's (Sms.notifyInbox does nothing on a computer).
class MentionAlerts {
  MentionAlerts({required this.notify, required this.cancel, required this.inFront, required this.on});

  final void Function(MentionAlert alert) notify;
  final void Function(String key) cancel;

  /// Whether Uplink is on the screen.
  final bool Function() inFront;

  /// Whether mentions are to be notified (the person's choice).
  final bool Function() on;

  /// The space whose chat is on the screen, by its seed (set by its page, lib/ui/hangout_screen.dart): not notified
  /// while Uplink is in front.
  static String? showing;

  /// The app's own, once watching (lib/main.dart).
  static MentionAlerts? instance;

  /// The notification's name for [c].
  static String keyOf(VoiceChannel c) => 'space:${c.seed}';

  /// [fresh] came into [room]'s chat; [readAt] is when its space was last read (ms).
  void heard(HangoutRoom room, List<HangoutMessage> fresh, {required int readAt, String Function(String id)? nameOf}) {
    if (!on()) return;
    final c = room.channel;
    if (showing == c.seed && inFront()) return;
    final mine = [for (final m in fresh) if (m.from != room.me && m.at > readAt && room.mentionsMe(m)) m];
    if (mine.isEmpty) return;
    final m = mine.reduce((a, b) => a.at >= b.at ? a : b);
    final who = m.name.isNotEmpty ? m.name : (nameOf?.call(m.from) ?? 'Someone');
    final circle = Circles.instance.circleOf(c);
    notify(MentionAlert(
      key: keyOf(c),
      where: circle?.name ?? 'Spaces',
      title: '$who in #${c.name}',
      body: m.text.isNotEmpty ? m.text : (m.what.isNotEmpty ? m.what : 'Mentioned you'),
    ));
  }

  /// [c] was read: its notification goes.
  void read(VoiceChannel c) => cancel(keyOf(c));
}
