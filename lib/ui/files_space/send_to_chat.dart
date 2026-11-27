/// A file from My files sent into a chat (GMFB-37, @matt: "A private file drive for each account, not tied to any
/// space"; done looks like "Send a file from the drive into any chat").
///
/// It goes the way a file picked on this device goes into a space's chat (HangoutRoom.sendFiles): brought down from
/// the drive where it isn't here yet, then sealed again under the space's own seed and sent up into the space's own
/// storage, with a message that carries it. Nothing of the drive is shared: not its seed, its key or its list. A file
/// may be as big as the relay takes in the space it goes to (FilesInfo.maxFile).
///
/// Which chats: every space this device may write and send files in, its own and each circle's; and each friend by
/// username on this app's relay, whose chat has carried files since 0.12.29 (lib/friends/file_card.dart). To a friend
/// it goes as the + in their chat sends one (lib/ui/thread.dart, _sendFilesToFriend): sealed again under a key of its
/// own into the account's "sent to friends" space, and the friend is sent the card that says where it is. The drive's
/// own copy can't be pointed at instead: a card names its space by seed, and the drive's seed opens the whole drive;
/// and the relay has no way to copy a sealed file from one space to another, so it is brought down and sent up.
/// Not a conversation by text, whose pictures go as the phone's picture messages do, nor another network's.
library;

import 'dart:async';
import 'dart:io' show File;

import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../../art/lucide.g.dart';
import '../../art/lucide_more.dart';
import '../../circles/circles.dart';
import '../../files/files_store.dart';
import '../../friends/buddies.dart';
import '../../friends/file_card.dart';
import '../../friends/friends.dart';
import '../../me/me.dart';
import '../../platform_info.dart';
import '../../sms.dart';
import '../../standalone/chats.dart';
import '../../voice/channels.dart';
import '../../voice/hangout.dart';
import '../../voice/voice.dart';
import '../common.dart';
import '../space_chat_files.dart' show spaceMayAttach;
import '../../l10n/words.dart';

/// The spaces whose chat a file can be sent to from here: every space with a chat (not a group's call) that this
/// device's circle roles let it write and send files in; its own first, then each circle's by the circle's name.
List<VoiceChannel> chatsForFiles({Iterable<VoiceChannel>? from, Circles? circles}) {
  final cs = circles ?? Circles.instance;
  final spaces = [
    for (final c in from ?? Voice.instance.channels)
      if (c.hangout && cs.allows(c, CirclePerm.write) && cs.allows(c, CirclePerm.files)) c,
  ];
  String key(VoiceChannel c) => c.circle == null ? '' : '1${(cs.circleOf(c)?.name ?? '').toLowerCase()}\u0000${c.circle}';
  final order = {for (final (i, c) in spaces.indexed) c.seed: i};
  spaces.sort((a, b) {
    final k = key(a).compareTo(key(b));
    return k != 0 ? k : order[a.seed]!.compareTo(order[b.seed]!);
  });
  return spaces;
}

/// Sends the file at [path] into [room]'s chat, sealed up through [uploads]: null once the message has gone, else why
/// it didn't (it then waits in that chat with its Try again, where it got as far as being shown there).
Future<String?> sendPathToRoom(HangoutRoom room, String path, ChatUploads uploads, {Circles? circles}) async {
  final name = room.channel.name;
  if (!spaceMayAttach(room, circles: circles)) return room.putOut ?? 'Your role in $name can\'t send files.';
  final o = room.sendFiles([(path: path, owned: false)], uploads);
  if (o == null) return 'It couldn\'t be read to send.';
  final done = Completer<String?>();
  void watch() {
    if (done.isCompleted) return;
    if (!room.outgoing.contains(o)) {
      done.complete(null);
    } else if (o.failed) {
      done.complete('${o.error ?? o.files.first.error ?? 'It didn\'t go.'} It waits in $name\'s chat, with Try again.');
    }
  }

  room.addListener(watch);
  watch();
  try {
    return await done.future;
  } finally {
    room.removeListener(watch);
  }
}

/// The friends by username a file can be sent to from here (GMFB-37, "Send a file from the drive into any chat"): one
/// of each, on this app's relay (their app asks its own relay for the file, and a file is kept on the sender's), by
/// the name shown. None on a computer that only shows its phone's conversations, which leaves the sending to the phone.
List<Buddy> friendsForFiles({Iterable<Buddy>? from, bool Function(Buddy)? elsewhere, bool? ownNetwork}) {
  if (!(ownNetwork ?? Sms.ownNetwork)) return const [];
  final away = elsewhere ?? Buddies.instance.elsewhere;
  final friends = [for (final b in Buddies.onePerUsername([...(from ?? Buddies.instance.friends)])) if (b.state == 'yes' && !away(b)) b];
  final order = {for (final (i, b) in friends.indexed) b.username: i};
  friends.sort((a, b) {
    final k = a.shown.toLowerCase().compareTo(b.shown.toLowerCase());
    return k != 0 ? k : order[a.username]!.compareTo(order[b.username]!);
  });
  return friends;
}

/// Sends the file at [path] to [friend] as [name], the way the + in their chat does (lib/ui/thread.dart,
/// _sendFilesToFriend): sealed up through [uploads] into the account's "sent to friends" space, then the card that
/// says where it is, as a message. Null once the card has gone, else why it didn't. [mineKey], [send] and [refusal]
/// are the account's and the friends' own where null (a test gives its own).
Future<String?> sendPathToFriend(
  Buddy friend,
  String path,
  ChatUploads uploads, {
  String? name,
  String? byName,
  Future<List<int>?> Function()? mineKey,
  Future<bool> Function(String address, String words)? send,
  String? Function()? refusal,
}) async {
  final key = await (mineKey ?? Me.instance.mineKey)();
  if (key == null) return 'Files to a friend need an Uplink account on this device.';
  final seed = FileCard.seedOf(key);
  final cleaned = SpaceFile.cleanName(name ?? path.split(PlatformInfo.pathSeparator).last.split('/').last);
  final shown = cleaned.isEmpty ? 'File' : cleaned;
  final int size;
  try {
    size = await File(path).length();
  } catch (_) {
    return 'It couldn\'t be read to send.';
  }
  final out = OutgoingFile(path: path, name: shown, size: size, mime: FileKind.mimeOf(shown));
  final SpaceFile up;
  try {
    up = await uploads.uploadForChat(FileCard.channelOf(seed), out, byName: byName ?? Me.instance.username ?? '', thumbMost: FileCard.thumbMost(1), moved: () {});
  } on FilesError catch (e) {
    // Nothing of it waits anywhere to try again: what went up is let go, and sending it again starts over.
    uploads.drop(out);
    return e.message;
  } catch (e) {
    uploads.drop(out);
    return 'It didn\'t go up: $e';
  }
  final card = FileCard(seed: seed, files: [up]);
  if (!await (send ?? Friends.instance.sendText)(UsernameChats.addressOf(friend.username), card.words)) {
    return (refusal ?? () => Friends.instance.lastRefusal)() ?? 'No connection. A friend by username is reached over the internet, through the relay.';
  }
  return null;
}

/// Asks which chat [f] (a file of the drive [from]) goes to, then sends it there, saying how it went.
void sendFileToChat(BuildContext context, VoiceChannel from, SpaceFile f, {required FilesStore store, Iterable<VoiceChannel>? spaces, Iterable<Buddy>? friends}) {
  final toasts = GlacierToast.of(context);
  final to = chatsForFiles(from: spaces);
  final people = friends?.toList() ?? friendsForFiles();
  if (to.isEmpty && people.isEmpty) {
    toast(context, 'There is no space or friend to send it to yet. A file goes into a space\'s chat, or to a friend by username on your relay.');
    return;
  }

  Future<void> sendFriend(Buddy b) async {
    if (store.cached(f) == null) toasts.toast(message: Text('Getting ${f.name}…'));
    try {
      final path = await store.fetch(from, f);
      toasts.toast(message: Text('Sending ${f.name} to ${b.shown}'));
      final why = await sendPathToFriend(b, path, store, name: f.name);
      toasts.toast(message: Text(why ?? '${f.name} sent to ${b.shown}'), tone: why == null ? GlacierToastTone.success : GlacierToastTone.danger);
    } on FilesError catch (e) {
      // -1: stopped by the person as it came down.
      if (e.status != -1) toasts.toast(message: Text(e.message), tone: GlacierToastTone.danger);
    } catch (e) {
      toasts.toast(message: Text('Couldn\'t send it: $e'), tone: GlacierToastTone.danger);
    }
  }

  Future<void> send(VoiceChannel c) async {
    if (store.cached(f) == null) toasts.toast(message: Text('Getting ${f.name}…'));
    HangoutRoom? room;
    try {
      final path = await store.fetch(from, f);
      room = await Voice.instance.hold(c);
      if (room == null) {
        toasts.toast(message: const Tr('Not connected to the relay yet. Try again in a moment.'), tone: GlacierToastTone.danger);
        return;
      }
      toasts.toast(message: Text('Sending ${f.name} to ${c.name}'));
      final why = await sendPathToRoom(room, path, store);
      toasts.toast(message: Text(why ?? '${f.name} sent to ${c.name}'), tone: why == null ? GlacierToastTone.success : GlacierToastTone.danger);
    } on FilesError catch (e) {
      // -1: stopped by the person as it came down.
      if (e.status != -1) toasts.toast(message: Text(e.message), tone: GlacierToastTone.danger);
    } catch (e) {
      toasts.toast(message: Text('Couldn\'t send it: $e'), tone: GlacierToastTone.danger);
    } finally {
      // The room was held only for the sending.
      if (room != null) unawaited(Voice.instance.release(c));
    }
  }

  showChoices(
    context,
    title: 'Send ${f.name} to\n${people.isEmpty ? 'It goes into a space\'s chat, or to a friend by username on your relay.' : 'A space\'s chat, or a friend on your relay. Texts can\'t carry it.'}',
    choices: [
      for (final c in to)
        Choice(c.name, c.kind == SpaceKind.files ? Lucide.folder : LucideMore.messageCircle, () => unawaited(send(c)), hint: Circles.instance.circleOf(c)?.name),
      // Friends by username after the spaces (GMFB-37): their chat carries a file as a card.
      for (final b in people) Choice(b.shown, Lucide.userRound, () => unawaited(sendFriend(b)), hint: '@${bareName(b.username)}'),
    ],
  );
}
