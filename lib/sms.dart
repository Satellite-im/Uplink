import 'platform_info.dart';
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'desktop/linux_voice.dart' show LinuxVoice;
import 'files/file_kinds.dart';
import 'kept_lists.dart';
import 'package:flutter/services.dart';

/// A person in a conversation: their number (or email address, for an MMS) and what the phone's contacts know of them.
class Person {
  const Person({required this.address, this.name, this.photo});
  final String address;
  final String? name;
  final String? photo;

  /// What they are called on the screen: their name in the contacts, else the number.
  String get label => (name != null && name!.isNotEmpty) ? name! : address;

  factory Person.from(Map m) => Person(address: (m['address'] as String?) ?? '', name: m['name'] as String?, photo: m['photo'] as String?);
}

/// One conversation as the list shows it, read from the map the native side (or the link to the phone) answers with.
class Conversation {
  const Conversation({
    required this.id,
    required this.date,
    required this.people,
    required this.snippet,
    required this.unread,
    required this.error,
    required this.archived,
    this.pinned = false,
    this.name,
    this.groupId,
    this.muted = false,
    this.blocked = false,
    this.draft,
    this.encrypted = false,
    this.heard,
  });
  /// Android's thread id.
  final int id;

  /// When the newest message in it was written.
  final DateTime date;
  final List<Person> people;

  /// The line under the title in the list.
  final String snippet;
  final bool unread;

  /// Something in it was not sent.
  final bool error;
  final bool archived;
  final bool pinned;
  final bool muted;

  /// This conversation with its archive or its pin changed, or read: what the list shows at once, before Android
  /// answers.
  Conversation copyWith({bool? archived, bool? pinned, bool? unread}) => Conversation(
        id: id,
        date: date,
        people: people,
        snippet: snippet,
        unread: unread ?? this.unread,
        error: error,
        archived: archived ?? this.archived,
        pinned: pinned ?? this.pinned,
        name: name,
        groupId: groupId,
        muted: muted,
        blocked: blocked,
        draft: draft,
        encrypted: encrypted,
        heard: heard,
      );

  /// What someone not in the contacts last sent here, where it is not the newest message (your reply may be): what
  /// the list sorts the conversation by (lib/plugins). Null for a contact, a group, or where nothing came in.
  final String? heard;

  /// The one person of the conversation is on Android's blocked list.
  final bool blocked;

  /// What was typed here and not sent.
  final String? draft;

  /// Encryption is on with the one person of the conversation.
  final bool encrypted;

  /// A name given to the conversation on this phone (android Store.threadName): a group's. Null where none was.
  final String? name;

  /// The group of friends this conversation is (lib/friends/groups.dart), by its id; null for any other.
  final String? groupId;

  /// What the conversation is called: its name where it was given one, else its people.
  String get title => name ?? peopleTitle(people);

  /// A conversation by its people: the one person, or a group's first names.
  static String peopleTitle(List<Person> people) => people.isEmpty ? 'Unknown' : people.map((p) => people.length > 1 ? p.label.split(' ').first : p.label).join(', ');
  /// More than one other person, or a group of friends (which may have no one else in it yet).
  bool get group => people.length > 1 || groupId != null;

  factory Conversation.from(Map m) => Conversation(
        id: (m['id'] as num).toInt(),
        date: DateTime.fromMillisecondsSinceEpoch((m['date'] as num).toInt()),
        people: [for (final p in (m['people'] as List? ?? const [])) Person.from(p as Map)],
        snippet: (m['snippet'] as String?) ?? '',
        unread: m['unread'] == true,
        error: m['error'] == true,
        archived: m['archived'] == true,
        pinned: m['pinned'] == true,
        name: m['name'] as String?,
        groupId: m['group'] as String?,
        muted: m['muted'] == true,
        blocked: m['blocked'] == true,
        draft: m['draft'] as String?,
        encrypted: m['encrypted'] == true,
        heard: (m['heard'] as String?)?.trim().isEmpty ?? true ? null : m['heard'] as String,
      );
}

/// A part of a picture message that is not its words: a picture, a video, a sound, a file.
class Attachment {
  const Attachment({required this.id, required this.type, this.name});

  /// The part's id, which [Sms.part] fetches its bytes by.
  final int id;

  /// Its MIME type.
  final String type;
  final String? name;

  /// Its type says nothing of what it is (none, or "octet-stream", as a file sent from a folder often is): its name's
  /// ending is asked instead (GMFB-60: a sound.ogg and a photo.heic that came so were each a file's row).
  bool get _untyped => type.isEmpty || type.endsWith('/octet-stream');

  /// A picture: drawn as one, or as a file's row where this device can't read it (lib/ui/thread.dart).
  bool get isImage => type.startsWith('image/') || (_untyped && FileKind.drawsAsPicture(name ?? ''));

  /// Sound: a voice message (android Voice.kt records them) or a sound's file, drawn with a player.
  bool get isAudio => type.startsWith('audio/') || type == 'application/ogg' || type == 'application/x-ogg' || (_untyped && _sounds.contains(FileKind.endingOf(name ?? '')));

  /// The endings an untyped file is taken as sound by: the common ones, Ogg's among them (.ogg, .oga, .opus).
  static const _sounds = {'ogg', 'oga', 'opus', 'mp3', 'm4a', 'aac', 'wav', 'flac'};

  /// A video: drawn as a picture of where it starts, with a button that plays it (lib/ui/video.dart).
  bool get isVideo => type.startsWith('video/');

  /// The ending a file of this kind goes by, for a player that tells the kind by it: the name's own where it has a
  /// plain one, else the kind's.
  String get ending {
    final dot = (name ?? '').lastIndexOf('.');
    final named = dot < 0 ? '' : name!.substring(dot + 1).toLowerCase();
    if (RegExp(r'^[a-z0-9]{2,4}$').hasMatch(named)) return named;
    return switch (type) {
      'video/3gpp' || 'audio/3gpp' => '3gp',
      'video/quicktime' => 'mov',
      'video/webm' => 'webm',
      'audio/amr' => 'amr',
      _ => type.startsWith('audio/') ? 'm4a' : 'mp4',
    };
  }

  /// One of Uplink's stickers (android Sender.sendSticker names them so): drawn small, on the page.
  bool get isSticker => isImage && (name ?? '').split('/').last.startsWith('ghost-sticker');
}

/// A lot of conversations, and the row of Android's list the next lot starts at: null at the end.
class ConversationPage {
  const ConversationPage(this.items, this.next, {this.floor});
  final List<Conversation> items;
  final int? next;

  /// Where more follow: the date every conversation newer than which is in this lot or one before it. A first lot also
  /// holds older ones (the pinned, the newest unread), so the oldest of its conversations does not say. Null at the
  /// end, and from a phone whose build does not say it.
  final DateTime? floor;
}

/// What is shown of [fresh] laid over [old]: a conversation read again replaces the one held, and all of them stand
/// newest first. [only], where given, are the conversations still there: any other has gone.
List<Conversation> mergeConversations(List<Conversation>? old, List<Conversation> fresh, {Set<int>? only}) {
  final byId = <int, Conversation>{for (final c in old ?? const <Conversation>[]) c.id: c, for (final c in fresh) c.id: c};
  final all = [for (final c in byId.values) if (only == null || only.contains(c.id)) c];
  all.sort((a, b) {
    final byDate = b.date.compareTo(a.date);
    return byDate != 0 ? byDate : b.id.compareTo(a.id);
  });
  return all;
}

/// sending, sent, delivered, failed, received, and for a picture message the carrier has announced that is not here:
/// downloading (being brought down now), pending_download (it could not be: the conversation offers to try again).
class Message {
  const Message({
    required this.id,
    required this.kind,
    required this.address,
    required this.body,
    required this.date,
    required this.outgoing,
    required this.state,
    this.attachments = const [],
    this.edited = false,
    this.original,
    this.encrypted = false,
    this.notice,
    this.why,
    this.missing,
    this.via,
    this.read = true,
    this.reactions = const [],
  });

  /// Reactions on it as the network keeps them (Google Messages' connection: each emoji, not who): drawn under it with
  /// those folded from reaction texts, each emoji once ([foldReactions]).
  final List<String> reactions;

  /// Whether it had been read when it was read from the phone: an incoming one not yet looked at is false. Where the
  /// phone does not say (an older one), it is taken as read, so nothing is marked new that is not.
  final bool read;
  final int id;

  /// Which of the phone's stores it is in: 'sms', 'mms' or 'rcs'. An id is unique only within its kind, see [key].
  final String kind;

  /// Who it is from, or to.
  final String address;
  final String body;
  final DateTime date;
  final bool outgoing;
  final String state;
  final List<Attachment> attachments;

  /// Changed on this phone after it was sent ([Sms.editMessage]); [original] is what it first said.
  final bool edited;
  final String? original;

  /// It travelled sealed by Uplink's own encryption and was opened here.
  final bool encrypted;

  /// Not words to show in a bubble: 'key' (it carried an encryption key) or 'undecryptable' (sealed, and the key to
  /// open it is not here).
  final String? notice;

  /// Why it was not sent, where it was not and the phone knows (a picture message: android/.../MmsWhy.kt).
  final String? why;

  /// What a message of Google Messages' carried that this phone could not get (its notification said "Photo" and
  /// nothing more): "Picture", "Video", "Voice message", "Picture message" or "Attachment"; null for the rest.
  final String? missing;

  /// 'net' where it came or went by the app's routes, between friends, not as a text (lib/friends/friends.dart).
  final String? via;

  /// What the message is known by across the kinds.
  String get key => '$kind:$id';

  factory Message.from(Map m) => Message(
        id: (m['id'] as num).toInt(),
        kind: m['kind'] as String,
        address: (m['address'] as String?) ?? '',
        body: (m['body'] as String?) ?? '',
        date: DateTime.fromMillisecondsSinceEpoch((m['date'] as num).toInt()),
        outgoing: m['outgoing'] == true,
        state: (m['state'] as String?) ?? 'sent',
        attachments: [
          for (final p in (m['parts'] as List? ?? const []))
            Attachment(id: ((p as Map)['id'] as num).toInt(), type: (p['type'] as String?) ?? '', name: p['name'] as String?),
        ],
        edited: m['edited'] == true,
        original: m['original'] as String?,
        encrypted: m['encrypted'] == true,
        notice: m['notice'] as String?,
        why: m['why'] as String?,
        missing: m['missing'] as String?,
        via: m['via'] as String?,
        read: m['read'] != false,
        reactions: [for (final r in (m['reactions'] as List? ?? const [])) '$r'],
      );
}

/// What stands between this phone and picture messages (android/.../MmsDiag.kt), and how the last ones went.
class MmsStatus {
  const MmsStatus({this.dataOn, this.carrier, this.sim = true, this.allowed, this.maxBytes, this.lastSend, this.lastDownload, this.waiting = 0});

  /// Mobile data is on: picture messages go over it, even on Wi-Fi. Null where Android would not say.
  final bool? dataOn;
  final String? carrier;
  final bool sim;

  /// The carrier's settings on this phone allow picture messages. Null where Android would not say.
  final bool? allowed;
  final int? maxBytes;
  final MmsAttempt? lastSend;
  final MmsAttempt? lastDownload;

  /// Picture messages announced and not yet fetched.
  final int waiting;

  factory MmsStatus.from(Map m) => MmsStatus(
        dataOn: m['dataOn'] as bool?,
        carrier: m['carrier'] as String?,
        sim: m['sim'] != false,
        allowed: m['allowed'] as bool?,
        maxBytes: (m['maxBytes'] as num?)?.toInt(),
        lastSend: m['lastSend'] == null ? null : MmsAttempt.from(m['lastSend'] as Map),
        lastDownload: m['lastDownload'] == null ? null : MmsAttempt.from(m['lastDownload'] as Map),
        waiting: (m['waiting'] as num?)?.toInt() ?? 0,
      );

  /// What would stop one going, in a line; null where nothing is seen to.
  String? get obstacle => !sim
      ? 'There is no SIM for texts'
      : allowed == false
          ? 'The carrier has picture messaging switched off for this SIM'
          : dataOn == false
              ? 'Mobile data is off. Picture messages need it, even on Wi-Fi'
              : null;

  /// All of it as text, to copy and send to whoever is helping.
  String report(String version) => [
        'Uplink $version, picture messages',
        'Carrier: ${carrier ?? 'not said'}',
        'SIM for texts: ${sim ? 'yes' : 'none'}',
        'Mobile data: ${dataOn == null ? 'not said' : (dataOn! ? 'on' : 'off')}',
        'Allowed by the carrier\'s settings: ${allowed == null ? 'not said' : (allowed! ? 'yes' : 'no')}',
        'Largest message: ${maxBytes == null ? 'not said' : '${maxBytes! ~/ 1024} KB'}',
        'Last sent: ${lastSend == null ? 'none yet' : lastSend!.line}',
        'Last fetched: ${lastDownload == null ? 'none yet' : lastDownload!.line}',
        'Waiting to be fetched: $waiting',
      ].join('\n');
}

/// How one picture message went: sent or fetched, or why not.
class MmsAttempt {
  const MmsAttempt({required this.at, required this.ok, required this.detail});
  final DateTime at;
  final bool ok;
  final String detail;
  factory MmsAttempt.from(Map m) => MmsAttempt(at: DateTime.fromMillisecondsSinceEpoch((m['at'] as num).toInt()), ok: m['ok'] == true, detail: (m['detail'] as String?) ?? '');
  /// The attempt in a line, with its time to the minute.
  String get line => '${ok ? 'worked' : 'failed'}: $detail (${at.toIso8601String().substring(0, 16).replaceFirst('T', ' ')})';
}

/// One of Google Messages' notification channels, as it was when a notification last came on it (android GmBridge):
/// its "Incoming messages", or a conversation's own, which overrides that one.
class GmChannel {
  const GmChannel({required this.id, required this.name, required this.loud, required this.popup, this.conversation, this.title});
  final String id;
  final String name;

  /// Makes a sound (importance Default or more); [popup] also shows over the screen (High).
  final bool loud;
  final bool popup;
  final String? conversation;

  /// The conversation's title where the channel is one conversation's.
  final String? title;

  factory GmChannel.from(Map m) => GmChannel(
        id: '${m['id']}',
        name: '${m['name'] ?? m['id']}',
        loud: m['loud'] == true,
        popup: m['popup'] == true,
        conversation: m['conversation'] as String?,
        title: m['title'] as String?,
      );

  /// How it reads in a list: a conversation's by the conversation.
  String get label => conversation != null ? (title ?? name) : name;
}

/// What the phone lets the app do: whether it is the default texting app, and the permissions it has been given
/// (the contacts, notifications, the phone).
class SmsStatus {
  const SmsStatus({required this.isDefault, required this.contacts, required this.notifications, required this.phone, this.gmInstalled = false, this.bridge = false, this.sms = false, this.gmDefault = false, this.bubbles, this.battery});

  /// Whether Android lets the app run while the phone sleeps (android Reach.kt, GMFB-28): a friend's call can ring
  /// then. Null where that is not known or not a question (a build from before it, a computer).
  final bool? battery;
  final bool isDefault;
  final bool contacts;
  final bool notifications;
  final bool phone;

  /// Beside Google Messages (android GmBridge.kt): whether it is on the phone, whether Uplink may read its
  /// notifications, and whether Uplink may read the SMS database and send texts without being the default.
  final bool gmInstalled;
  final bool bridge;
  final bool sms;

  /// Google Messages is the default SMS app now (RCS works only there).
  final bool gmDefault;

  /// Android's own setting for the app's conversation bubbles (android Bubbles.kt, GMFB-8): 'all', 'selected' (the
  /// conversations the person chose), 'none', or null where the phone has none (before Android 11, or a computer).
  final String? bubbles;

  /// Uplink beside Google Messages, not the default: its RCS chats come through its notifications.
  bool get beside => !isDefault && bridge && sms;

  /// The app can run: the default, or beside Google Messages.
  bool get usable => isDefault || beside;

  factory SmsStatus.from(Map m) => SmsStatus(
        isDefault: m['isDefault'] == true,
        contacts: m['contacts'] == true,
        notifications: m['notifications'] == true,
        phone: m['phone'] == true,
        gmInstalled: m['gmInstalled'] == true,
        bridge: m['bridge'] == true,
        sms: m['sms'] == true,
        gmDefault: m['gmDefault'] == true,
        bubbles: m['bubbles'] is String ? m['bubbles'] as String : null,
        battery: m['battery'] is bool ? m['battery'] as bool : null,
      );
}

/// Where Uplink's own encryption stands with one person (android/.../E2e.kt): none, offered (your key sent,
/// theirs awaited), pending (theirs here, your yes awaited), on.
class E2eState {
  const E2eState({this.address = '', this.state = 'none', this.verified = false, this.changed = false, this.safety, this.person, this.hasGhost = false, this.declined = false, this.plain = 0, this.friend = '', this.id, this.otherIds = const []});
  final String address;
  final String state;
  final bool verified;

  /// Their install's name: the id the key held for them makes (android E2e.state), 32 hex digits; null where no key
  /// of theirs is held, or the record came from somewhere that does not say. Who is a friend to the direct route, who
  /// sent a friend's words and where they are sent are decided by this, never by an address (lib/net/net.dart,
  /// lib/friends/friends.dart). For a friend by username, the install their username stands for (UsernameChats.states).
  final String? id;

  /// For a friend by username, their other installs that are friends here too, by name: one that came again with a
  /// new key, kept beside the newest (Buddies.onePerUsername). What comes sealed from one of them is theirs as well;
  /// what is sent goes to [id] alone. Empty for a number.
  final List<String> otherIds;

  /// The same record with [friend] changed, and everything else as it is.
  E2eState withFriend(String friend) => E2eState(address: address, state: state, verified: verified, changed: changed, safety: safety, person: person, hasGhost: hasGhost, declined: declined, plain: plain, friend: friend, id: id, otherIds: otherIds);

  /// A different key arrived from someone already exchanged with.
  final bool changed;

  /// Thirty digits, the same on both phones when nobody is in the middle.
  final String? safety;
  final Person? person;

  /// They are known to have Uplink: a text only the app writes has come from them (its invisible hello,
  /// a key, a background).
  final bool hasGhost;

  /// The person here turned encryption off with them: it is not offered again.
  final bool declined;

  /// How many texts have come from them without encryption while it is on, and not been put away (android
  /// E2e.arrived): they may have turned it off or changed phones, and then cannot read what goes to them sealed.
  final int plain;

  /// Their texts are coming plain though encryption is on: the conversation says so, with a way to turn it off.
  bool get plainWarning => on && plain > 0;

  bool get on => state == 'on';

  /// Where being friends with them stands (lib/friends/friends.dart): '' (not), 'want' (this phone means to ask
  /// once keys are exchanged), 'asked' (it asked), 'invited' (they asked), 'yes' (both said so).
  final String friend;
  bool get isFriend => on && friend == 'yes';

  /// Both phones have the app and nothing has been exchanged yet: the conversation offers encryption.
  bool get offerable => state == 'none' && hasGhost && !declined;

  factory E2eState.from(Map m) => E2eState(
        address: (m['address'] as String?) ?? '',
        state: (m['state'] as String?) ?? 'none',
        verified: m['verified'] == true,
        changed: m['changed'] == true,
        safety: m['safety'] as String?,
        person: m['person'] == null ? null : Person.from(m['person'] as Map),
        hasGhost: m['hasGhost'] == true,
        declined: m['declined'] == true,
        plain: (m['plain'] as num?)?.toInt() ?? 0,
        friend: (m['friend'] as String?) ?? '',
        id: _isId(m['id']) ? m['id'] as String : null,
        otherIds: [for (final x in (m['others'] is List ? m['others'] as List : const [])) if (_isId(x)) x as String],
      );

  /// Whether [x] is an Uplink id: 32 hex digits.
  static bool _isId(Object? x) => x is String && RegExp(r'^[0-9a-f]{32}$').hasMatch(x);
}

/// Coming from another texting app (android/.../Arriving.kt): what can be seen of the app being left and of Android's
/// own store of texts. Android tells no app whether RCS is on for a number, so that is never among it.
class Arriving {
  const Arriving({this.old, this.oldLabel, this.oldInstalled = false, this.oldHasRcs = false, this.texts, this.recentTexts, this.pictures, this.lastReceived, this.samsungChats, this.sideloaded = false, this.android = 0});

  /// The app being left, by its package and its name; null where none is known.
  final String? old;
  final String? oldLabel;
  final bool oldInstalled;

  /// It is one that keeps RCS chats of its own (Google Messages, Samsung Messages).
  final bool oldHasRcs;

  /// How many texts Android's store holds, how many of them are of the last thirty days, and how many picture
  /// messages; null until this app holds the SMS role.
  final int? texts;
  final int? recentTexts;
  final int? pictures;
  final DateTime? lastReceived;

  /// RCS chats Samsung Messages keeps, where its store will say how many.
  final int? samsungChats;

  /// This copy was installed from a file, not by a store: Android may refuse it the SMS role or a permission until
  /// "Allow restricted settings" is chosen on its page.
  final bool sideloaded;
  final int android;

  String get app => oldLabel ?? 'your old texting app';

  /// RCS is worth talking about: the app being left keeps RCS chats, and is still on the phone.
  bool get rcsLikely => oldHasRcs && oldInstalled;

  factory Arriving.from(Map m) => Arriving(
        old: m['old'] as String?,
        oldLabel: m['oldLabel'] as String?,
        oldInstalled: m['oldInstalled'] == true,
        oldHasRcs: m['oldHasRcs'] == true,
        texts: (m['texts'] as num?)?.toInt(),
        recentTexts: (m['recentTexts'] as num?)?.toInt(),
        pictures: (m['pictures'] as num?)?.toInt(),
        lastReceived: m['lastReceived'] == null ? null : DateTime.fromMillisecondsSinceEpoch((m['lastReceived'] as num).toInt()),
        samsungChats: (m['samsungChats'] as num?)?.toInt(),
        sideloaded: m['sideloaded'] == true,
        android: (m['android'] as num?)?.toInt() ?? 0,
      );
}

/// Where the app's own update stands: idle, disabled, checking, upToDate, available, downloading, ready, installing,
/// failed.
class UpdateState {
  const UpdateState({this.phase = 'idle', this.current = '', this.available, this.progress, this.error, this.auto = true, this.canInstall = true, this.source = ''});
  final String phase;
  final String current;
  final String? available;
  final double? progress;
  final String? error;
  final bool auto;
  final bool canInstall;
  final String source;

  factory UpdateState.from(Map m) => UpdateState(
        phase: (m['phase'] as String?) ?? 'idle',
        current: (m['current'] as String?) ?? '',
        available: m['available'] as String?,
        progress: (m['progress'] as num?)?.toDouble(),
        error: m['error'] as String?,
        auto: m['auto'] != false,
        canInstall: m['canInstall'] != false,
        source: (m['source'] as String?) ?? '',
      );
}

/// What a notification or another app asked to open.
class OpenRequest {
  const OpenRequest({this.thread, this.addresses = const [], this.body, this.computers = false, this.pairing, this.inbox, this.circle, this.add, this.relay});
  final int? thread;

  /// A chat on Signal or Telegram (`network:chat`), from its notification (lib/inbox/alerts.dart).
  final String? inbox;
  final List<String> addresses;
  final String? body;

  /// The "Paired with …" notification was tapped: Settings › Computers.
  final bool computers;

  /// A computer's pairing link was opened (the phone's camera read its QR code): the pairing page, with it.
  final String? pairing;

  /// A circle's invite link was opened (https://gogho.st/join/#c.…): its invite, to Join or put off
  /// (lib/ui/circles/circle_invite_card.dart).
  final String? circle;

  /// Someone's add-me link was opened (https://gogho.st/add/maya; lib/friends/add_link.dart): asked whether to send
  /// them a friend request.
  final String? add;

  /// A relay's link was opened (`ghostmsg://relay?a=…`, from the QR code of a relay hosted from someone's app;
  /// lib/relay_host): asked whether to use it.
  final String? relay;
  factory OpenRequest.from(Map m) => OpenRequest(
        thread: (m['thread'] as num?)?.toInt(),
        addresses: [for (final a in (m['addresses'] as List? ?? const [])) a as String],
        body: m['body'] as String?,
        computers: m['desk'] == true,
        pairing: m['pair'] as String?,
        inbox: m['inbox'] as String?,
        circle: m['circle'] as String?,
        add: m['add'] as String?,
        relay: m['relay'] as String?,
      );
}

/// A computer this phone is paired with (android/.../Desk.kt, docs/desktop.md).
class Computer {
  const Computer({required this.id, required this.name, this.mode = 'both', this.relay = '', this.since, this.seen, this.via});
  final String id;
  final String name;

  /// How the two connect: both (the local network first, the relay when that fails), local, relay.
  final String mode;
  final String relay;
  final DateTime? since;
  final DateTime? seen;

  /// How it is connected now: local, relay, or null when it is not.
  final String? via;

  factory Computer.from(Map m) => Computer(
        id: (m['id'] as String?) ?? '',
        name: (m['name'] as String?) ?? 'A computer',
        mode: (m['mode'] as String?) ?? 'both',
        relay: (m['relay'] as String?) ?? '',
        since: (m['since'] as num?) == null || m['since'] == 0 ? null : DateTime.fromMillisecondsSinceEpoch((m['since'] as num).toInt()),
        seen: (m['seen'] as num?) == null || m['seen'] == 0 ? null : DateTime.fromMillisecondsSinceEpoch((m['seen'] as num).toInt()),
        via: m['via'] as String?,
      );
}

/// A pairing with a computer while it is being made: none, waiting (for the computer to connect), code (both show
/// six digits to compare), done, failed.
class PairingState {
  const PairingState({this.phase = 'none', this.name = '', this.mode = 'both', this.offered = 'both', this.relay = '', this.code, this.mine = false, this.theirs = false, this.error});
  final String phase;
  final String name;

  /// How the two will connect, chosen here; [offered] is what the computer chose, and how it is reached to pair.
  final String mode;
  final String offered;
  final String relay;
  final String? code;

  /// "They match" was said here, and on the computer.
  final bool mine;
  final bool theirs;
  final String? error;

  factory PairingState.from(Map m) => PairingState(
        phase: (m['phase'] as String?) ?? 'none',
        name: (m['name'] as String?) ?? '',
        mode: (m['mode'] as String?) ?? 'both',
        offered: (m['offered'] as String?) ?? 'both',
        relay: (m['relay'] as String?) ?? '',
        code: m['code'] as String?,
        mine: m['mine'] == true,
        theirs: m['theirs'] == true,
        error: m['error'] as String?,
      );
}

/// Where the screens' calls go. On the phone, Android's channel. On the Mac (lib/desktop), the link to the phone:
/// the same calls by the same names, answered by the phone, so the conversations are drawn by the same screens.
abstract class SmsCalls {
  Future<T?> invokeMethod<T>(String method, [dynamic arguments]);
}

/// Calls on a paired computer that answer the app's own network here, not on the phone (lib/desktop/own_calls.dart).
abstract class OwnNetworkCalls {}

/// Calls answered on the Android phone itself, though not straight by its channel: what keeps the phone's friends by
/// username in Dart in front of it (lib/standalone/overlay.dart). [Sms.remote] stays false behind one.
abstract class PhoneSide {}

/// Calls that reach the phone from somewhere else (a computer's link) and say what the phone at their other end can
/// do: an older Uplink there does less. [caps] names what it does beyond the first few (android
/// DeskCalls.CAPS), so a screen offers only what will work ([Sms.can]).
abstract class CapableCalls {
  Set<String> get caps;
}

/// The calls on the phone itself: straight to the native side by its method channel.
class _ChannelCalls implements SmsCalls {
  const _ChannelCalls();
  static const _channel = MethodChannel('ghost_messaging/sms');

  @override
  Future<T?> invokeMethod<T>(String method, [dynamic arguments]) => _channel.invokeMethod<T>(method, arguments);
}

/// A video in a message, as the conversation draws it before it is played: a picture of where it starts (null where
/// none can be made of it) and how long it runs.
class VideoPreview {
  const VideoPreview({this.picture, this.length = Duration.zero, this.width = 0, this.height = 0, this.videoWidth = 0, this.videoHeight = 0, this.bytes = 0});
  final Uint8List? picture;
  final Duration length;

  /// The picture's size, in pixels.
  final int width;
  final int height;

  /// The video as it arrived: its own size as it plays, in pixels, and its file's in bytes; 0 where not known.
  final int videoWidth;
  final int videoHeight;
  final int bytes;

  /// How large it came, in words: "320 × 240 · 0.9 MB". Null where nothing is known of it.
  String? get facts {
    final parts = [
      if (videoWidth > 0 && videoHeight > 0) '$videoWidth × $videoHeight',
      if (bytes > 0) bytes >= 1000 * 1000 ? '${(bytes / (1000 * 1000)).toStringAsFixed(1)} MB' : '${(bytes / 1000).ceil()} KB',
    ];
    return parts.isEmpty ? null : parts.join(' · ');
  }

  /// It came small: under 480 pixels the short way, which is what a phone makes of a video to send it as a picture
  /// message (a carrier takes about a megabyte). One filmed and sent whole is 720 or more.
  bool get small => videoWidth > 0 && videoHeight > 0 && (videoWidth < videoHeight ? videoWidth : videoHeight) < 480;

  /// Nothing is known of it: not a picture, not its length.
  bool get empty => picture == null && length == Duration.zero;

  factory VideoPreview.from(Map? m) => VideoPreview(
        picture: m?['picture'] as Uint8List?,
        length: Duration(milliseconds: (m?['millis'] as num?)?.toInt() ?? 0),
        width: (m?['width'] as num?)?.toInt() ?? 0,
        height: (m?['height'] as num?)?.toInt() ?? 0,
        videoWidth: (m?['videoWidth'] as num?)?.toInt() ?? 0,
        videoHeight: (m?['videoHeight'] as num?)?.toInt() ?? 0,
        bytes: (m?['bytes'] as num?)?.toInt() ?? 0,
      );
}

/// Where the voice message being played has got to (android/.../Voice.kt): its part, and whether it is playing now.
class VoicePlayback {
  const VoicePlayback({required this.part, required this.position, required this.length, required this.playing});
  /// The attachment's id; -1 where none is.
  final int part;
  final Duration position;
  final Duration length;
  final bool playing;

  factory VoicePlayback.from(Map m) => VoicePlayback(
        part: (m['part'] as num?)?.toInt() ?? -1,
        position: Duration(milliseconds: (m['position'] as num?)?.toInt() ?? 0),
        length: Duration(milliseconds: (m['duration'] as num?)?.toInt() ?? 0),
        playing: m['playing'] == true,
      );
}

/// The native side (android/.../MainActivity.kt): Android's SMS database, sending, the SMS role.
class Sms {
  Sms._();
  static final Sms instance = Sms._();

  static SmsCalls _calls = const _ChannelCalls();
  static const _events = EventChannel('ghost_messaging/events');

  /// The Mac sets this to its link to the phone before anything is drawn (lib/desktop/remote.dart).
  static set calls(SmsCalls calls) => _calls = calls;

  /// These screens are not on the Android phone: no texts here, so what only the phone can do is not offered. True on
  /// a computer and on an iPhone, paired or not.
  static bool get remote => !(_calls is _ChannelCalls || _calls is PhoneSide);

  /// The calls as they are answered now: the phone's channel, or what stands in front of it (lib/standalone).
  // ignore: unnecessary_getters_setters
  static SmsCalls get calls => _calls;

  /// An iPhone of its own (lib/standalone; Matt, 2026-11-15: "roll a version of the app that works without sms"):
  /// no phone to ask, so the routes, the relay server's directory, friends by username and calls run here, as they do
  /// on the phone. Set before anything is drawn.
  static bool standalone = false;

  /// An Android phone that passed texts by in the walkthrough and is not (yet) the texting app (Matt, 2026-11-20:
  /// "rework the onboarding on mobile so that SMS is not required"): Android is asked for no conversations, which it
  /// would refuse without the texting app's permissions; friends' chats, circles and the networks go on as ever.
  static bool textsOff = false;

  /// What these screens ask of is a paired Android phone (a computer, or an iPhone paired with one): the routes,
  /// the directory and calls are the phone's, asked across the link.
  static bool get paired => remote && !standalone;

  /// Whether the app's own network (the routes, friends by username, the directory) runs here, under this install's
  /// identity: the phone, an iPhone of its own, a computer of its own, and a computer paired with a phone that has
  /// taken the phone's identity for its friends and circles (lib/desktop/own_calls.dart; Matt, 2026-11-18: "I want
  /// desktop to be able to run standalone for internal friends and circles ... even if the desktop is linked").
  static bool get ownNetwork => !paired || _calls is OwnNetworkCalls;

  /// A paired computer whose Settings › Me and friends are the phone's, asked across the link: one that has not taken
  /// on the phone's identity for its own network.
  static bool get followsPhone => paired && !ownNetwork;

  /// Whether a voice message can be recorded here to go as a file (a network's chat, a space, a friend): the phone
  /// itself, and the computers and the iPhone with a recorder of their own (DeskSound.swift on the Mac and the iPhone,
  /// windows/runner/desk_sound.cpp on Windows; GMFB-32). Linux where the desktop has a program that records
  /// (pw-record, parecord, arecord or ffmpeg: lib/desktop/linux_voice.dart); with none, no microphone is offered.
  static bool get canRecordVoice => !remote || PlatformInfo.isMacOS || PlatformInfo.isWindows || PlatformInfo.isIOS || (PlatformInfo.isLinux && LinuxVoice.instance.available);

  /// A computer's window rather than a phone's screen: the sizes a window is read at (smaller bubbles and dock).
  static bool get computer => remote && (PlatformInfo.isMacOS || PlatformInfo.isWindows || PlatformInfo.isLinux || browserWide);

  /// A page in a browser (lib/web; Matt: "the full web client"): a device of its own ([standalone]) that has no folder
  /// to keep files in, no helper programs, nothing native behind the app's channels and, in this first version, no
  /// calls unless its build has them. Screens leave out what would need one of those ([callsHere], and each place that asks this). Set before
  /// anything is drawn; false on every phone and computer.
  static bool browser = false;

  /// What a page in a browser is called in the account's list of devices (lib/web/browser.dart: "Browser · Safari ·
  /// Mac"), said by lib/web/app.dart as it starts. A page can't learn the computer's name, and is none of the five
  /// platforms.
  static String browserName = 'Browser';

  /// Whether a voice or video call can be made or joined here: on every phone and computer; in a browser where its
  /// build has them ([browserCalls]), through the page's own WebRTC (lib/voice/call_sound.dart plays what arrives).
  static bool get callsHere => !browser || browserCalls;

  /// Calls in a browser (GMFB-30, GMFB-51): lib/web/app.dart sets this as the page starts, on in every build unless it
  /// left them out (`tool/build-web.mjs --no-calls`, which says `--dart-define=GHOST_WEB_CALLS=false`). Off, a browser
  /// offers no way into a call.
  static bool browserCalls = false;

  /// Files spaces in a browser (GMFB-30; docs/OPEN_NETWORK.md part 6): lib/web/app.dart sets this as the page starts,
  /// on in every build unless it left them out (`tool/build-web.mjs --no-files`, which says
  /// `--dart-define=GHOST_WEB_FILES=false`). Off, a browser offers no Files space.
  static bool browserFiles = false;

  /// Whether a circle's Files spaces open here: on every phone and computer, and in a browser whose build has them.
  static bool get filesHere => !browser || browserFiles;

  /// A page in a browser whose window is wide enough to be laid out as a computer's (lib/web/app.dart, which says so as
  /// the window is sized): read at a computer's sizes then, and at a phone's in a narrow one. False everywhere else.
  static bool browserWide = false;

  /// Whether [what] can be done from here: anything on the phone itself; on a computer, what the phone it is paired
  /// with says it does for one (`deleteMessage`, `editMessage`, `sendPictures`, `sendVoice`, `sendSticker`, …).
  static bool can(String what) {
    final calls = _calls;
    // The phone itself, straight by its channel or behind what keeps its friends by username (lib/standalone/overlay.dart):
    // everything. Missing the second hid Add an attachment, Stickers and the microphone on every Android phone from
    // 71d8d197e (Matt, 2026-11-15: "Im missing the button to send picture and videos to people").
    if (calls is _ChannelCalls || calls is PhoneSide) return true;
    return calls is CapableCalls && (calls as CapableCalls).caps.contains(what);
  }

  /// The conversation that changed, each time one does (-1: some conversation, which is not known).
  final changes = StreamController<int>.broadcast();

  /// A conversation marked read from here, once the phone has done it: the list reads its row again
  /// (lib/conversation_feed.dart). Not said on [changes], which an open conversation answers by reading itself and
  /// marking itself read again; and beside Google Messages the phone says nothing of a conversation read, since
  /// Android's own database is not written.
  final reads = StreamController<int>.broadcast();

  /// Something outside the app asked for a conversation to be opened, while the app was running.
  final opens = StreamController<OpenRequest>.broadcast();

  /// Where the app's own update stands, each time it moves (android/.../Updater.kt).
  final updates = StreamController<UpdateState>.broadcast();

  /// The call notification's Leave was pressed (android CallService.kt).
  final leaveCall = StreamController<void>.broadcast();

  /// Answer or Decline pressed on a friend's call's notification (android IncomingCall.kt, GMFB-28): "answer", "decline".
  final ringAction = StreamController<String>.broadcast();

  /// A call in a space began or ended: on the phone, its service keeps it going with the screen locked.
  /// [screen]: the screen is being shared (GMFB-27), which Android 14 asks a service of its own kind for.
  Future<void> callStarted(String name, {bool video = false, bool screen = false}) async {
    if (remote) return;
    try {
      await _calls.invokeMethod('callStarted', {'name': name, 'video': video, 'screen': screen});
    } catch (_) {}
  }

  Future<void> callEnded() async {
    if (remote) return;
    try {
      await _calls.invokeMethod('callEnded');
    } catch (_) {}
  }

  /// A friend calling (lib/voice/friend_calls.dart, GMFB-28): on the phone, a call's notification, full screen while
  /// the phone is locked or the app is out of sight, until [ringEnded].
  Future<void> ringIncoming(String from, {bool video = false}) async {
    if (remote || !PlatformInfo.isAndroid) return;
    try {
      await _calls.invokeMethod('ringIncoming', {'from': from, 'video': video});
    } catch (_) {}
  }

  /// The ringing [ringIncoming] began is over, however it ended: the phone is told, so its notification goes.
  Future<void> ringEnded() async {
    if (remote || !PlatformInfo.isAndroid) return;
    try {
      await _calls.invokeMethod('ringEnded');
    } catch (_) {}
  }

  /// A line in the conversation with a friend by username ([address], `@name`) about a call: missed, declined, no
  /// answer (GMFB-28). [out]: a call this side made.
  Future<void> callNote(String address, String words, int at, {required bool out}) =>
      _calls.invokeMethod('callNote', {'address': address, 'body': words, 'at': at, 'out': out});

  /// A new message on Signal or Telegram (lib/inbox/alerts.dart): a notification that opens the chat.
  Future<void> notifyInbox(String key, {required String network, required String title, required String body, bool group = false}) async {
    if (remote || !PlatformInfo.isAndroid) return;
    try {
      await _calls.invokeMethod('notifyInbox', {'key': key, 'network': network, 'title': title, 'body': body, 'group': group});
    } catch (_) {}
  }

  /// Takes the notification [notifyInbox] put up under [key] away.
  Future<void> cancelInbox(String key) async {
    if (remote || !PlatformInfo.isAndroid) return;
    try {
      await _calls.invokeMethod('cancelInbox', {'key': key});
    } catch (_) {}
  }

  /// The networks signed in ([names]), and whether a friend's call is to ring while the app is closed ([calls]): Android
  /// keeps Uplink running while there is either, and stops when there is neither (android NetworksService.kt;
  /// lib/keep_running.dart).
  Future<void> keepNetworks(List<String> names, {bool calls = false}) async {
    if (remote || !PlatformInfo.isAndroid) return;
    try {
      await _calls.invokeMethod('keepNetworks', {'names': names, 'calls': calls});
    } catch (_) {}
  }

  /// Android's own question whether the app may run while the phone sleeps (android Reach.kt, GMFB-28).
  Future<void> askBattery() async {
    if (remote || !PlatformInfo.isAndroid) return;
    try {
      await _calls.invokeMethod('askBattery');
    } catch (_) {}
  }

  /// The person's choices were changed from Android's side (a chat background someone shared): read them again.
  final prefsChanged = StreamController<void>.broadcast();

  /// Something about the computers paired with this phone changed: one connected, a pairing moved on.
  final computersChanged = StreamController<void>.broadcast();

  /// Where the voice message being played has got to, a few times a second while one plays.
  final voice = StreamController<VoicePlayback>.broadcast();

  /// The recording under way is as long as a message may be ([voiceFull]), or was thrown away because the app left
  /// the screen ([voiceStopped]).
  final voiceFull = StreamController<void>.broadcast();
  final voiceStopped = StreamController<void>.broadcast();

  /// A data text for the app's routes came (android/.../NetSms.kt): the number it came from, and its bytes.
  final netSms = StreamController<({String address, Uint8List bytes})>.broadcast();

  /// Files shared into the app from another (their content addresses): added to a Files space the person picks.
  final sharedIn = StreamController<List<String>>.broadcast();
  StreamSubscription<dynamic>? _sub;

  /// Starts hearing the native side's events, once, and passes each on by its 'type' to the stream of its kind above.
  void listen() {
    _sub ??= _events.receiveBroadcastStream().listen((e) {
      final m = e as Map;
      if (m['type'] == 'changed') changes.add((m['thread'] as num?)?.toInt() ?? -1);
      if (m['type'] == 'open') opens.add(OpenRequest.from(m));
      if (m['type'] == 'update') updates.add(UpdateState.from(m));
      if (m['type'] == 'prefs') prefsChanged.add(null);
      if (m['type'] == 'leaveCall') leaveCall.add(null);
      if (m['type'] == 'ringAction' && m['do'] is String) ringAction.add(m['do'] as String);
      if (m['type'] == 'desk') computersChanged.add(null);
      if (m['type'] == 'voice') voice.add(VoicePlayback.from(m));
      if (m['type'] == 'voiceFull') voiceFull.add(null);
      if (m['type'] == 'voiceStopped') voiceStopped.add(null);
      if (m['type'] == 'netSms') netSms.add((address: m['address'] as String, bytes: m['bytes'] as Uint8List));
      if (m['type'] == 'sharedFiles') sharedIn.add([for (final u in (m['uris'] as List? ?? const [])) u as String]);
    });
  }

  // --- the app's routes (lib/net; android/.../Net.kt, NetSms.kt) -------------------------------------------------------

  /// Who this phone is to the others: its name and its public key.
  Future<({String id, Uint8List key})> netIdentity() async {
    final m = await _calls.invokeMethod('netIdentity') as Map;
    return (id: m['id'] as String, key: base64Decode(m['key'] as String));
  }

  /// Everyone the routes can reach (the people encryption is on with): their name, their number, and the key
  /// packets to and from them are sealed with.
  Future<List<({String id, String address, Uint8List key})>> netPeers() async {
    final list = await _calls.invokeMethod('netPeers') as List? ?? const [];
    return [for (final p in list.cast<Map>()) (id: p['id'] as String, address: p['address'] as String, key: p['key'] as Uint8List)];
  }

  /// Friends by username (lib/friends/buddies.dart): the list, kept where the phone works out each one's sealing key
  /// (android Buddies.kt). Nothing on a computer, which speaks through its phone.
  Future<void> buddiesKeep(String json) async {
    if (!ownNetwork) return;
    await _calls.invokeMethod('buddiesKeep', {'json': json});
  }

  /// The list [buddiesKeep] kept, as JSON; an empty list on a computer that speaks through its phone.
  Future<String> buddiesKept() async {
    if (!ownNetwork) return '[]';
    return await _calls.invokeMethod<String>('buddiesKept') ?? '[]';
  }

  /// This phone's signature over [message], r then s.
  Future<Uint8List> netSign(List<int> message) async => (await _calls.invokeMethod('netSign', {'message': Uint8List.fromList(message)})) as Uint8List;

  // --- an Uplink account (lib/account; Matt, 2026-11-17: "We need to have a way to login to existing accounts") ----------

  /// This install's identity's private key, 32 bytes, for an account's sealed backup: an account made on an install
  /// that had its own key keeps that key, and a new device signing in gets it back. Asked only to seal it.
  Future<Uint8List> identityExport() async => Uint8List.fromList(((await _calls.invokeMethod('identityExport')) as List).cast<int>());

  /// Makes [scalar] (32 bytes, whose public key is [public]) this install's identity, in place of the one it had: a
  /// device signing in to an account. Everything sealed to the old key ends with it (as resetting encryption does);
  /// the app is restarted straight after ([restartApp]) so nothing goes on as the old one.
  Future<void> identityImport(List<int> scalar, List<int> public) => _calls.invokeMethod('identityImport', {'scalar': Uint8List.fromList(scalar), 'public': Uint8List.fromList(public)});

  /// Keeps [value] under [name] where the install keeps its keys (Android's Keystore-sealed vault, the Keychain), never
  /// in the preferences; an empty value forgets it.
  Future<void> secretKeep(String name, String value) => _calls.invokeMethod('secretKeep', {'name': name, 'value': value});

  /// What [secretKeep] kept under [name]; null where nothing is.
  Future<String?> secretRead(String name) => _calls.invokeMethod<String>('secretRead', {'name': name});

  /// Starts the app again from nothing, with every choice written first; false where it cannot (an iPhone), and the
  /// person is asked to.
  Future<bool> restartApp() async {
    await prefsWritten();
    return (await _calls.invokeMethod<bool>('restartApp')) ?? false;
  }

  /// Lets go of this install's identity where it has one to go back to: a computer paired with a phone forgets the
  /// phone's identity it took on, and takes it on again from the phone as it starts (lib/desktop/own_calls.dart), so
  /// signing out of an account there leaves it the same you as the phone. False everywhere else, where signing out
  /// makes a new identity instead; and never asked of the phone across a link.
  Future<bool> identityForget() async {
    if (followsPhone) return false;
    try {
      return (await _calls.invokeMethod<bool>('identityForget')) ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Everything a device of its own keeps deleted (lib/standalone: an iPhone, a computer with no phone, a page in a
  /// browser): its conversations and choices, who it is, every secret; with [note] ('signed-out', 'removed') kept to be
  /// said as it starts again. Asked only where [standalone] (lib/account/account.dart).
  Future<void> wipeHere(String? note) => _calls.invokeMethod('wipeHere', {'note': note});

  // --- groups of friends (lib/friends/groups.dart, android Groups.kt) ------------------------------------------------

  /// The groups this phone is in, each as android Groups.view gives it.
  Future<List<Map>> groups() async => ((await _calls.invokeMethod('groups')) as List? ?? const []).cast<Map>();

  /// The group a conversation is, or null.
  Future<Map?> groupOf(int thread) async => (await _calls.invokeMethod('groupOf', {'thread': thread})) as Map?;

  /// A new group of this phone's making, out of people encryption is on with: its state, as JSON, not kept yet.
  Future<String> groupDraft(String id, String name, List<String> addresses) async => (await _calls.invokeMethod('groupDraft', {'id': id, 'name': name, 'addresses': addresses})) as String;

  /// A person encryption is on with, as a member of a group: JSON.
  Future<String> groupMember(String address) async => (await _calls.invokeMethod('groupMember', {'address': address})) as String;

  /// Keeps a group as it now is ([state]: JSON); answers it as [groups] gives one.
  Future<Map> groupSave(String state) async => (await _calls.invokeMethod('groupSave', {'state': state})) as Map;
  Future<void> groupForget(String id) => _calls.invokeMethod('groupForget', {'id': id});

  /// What is written in a group, kept in its conversation: going (its row), what became of it, come, and a line
  /// about the group itself.
  Future<int> groupTextOut(String id, String body) async => ((await _calls.invokeMethod('groupTextOut', {'id': id, 'body': body})) as num).toInt();
  Future<void> groupTextState(int row, String state) => _calls.invokeMethod('groupTextState', {'row': row, 'state': state});
  Future<void> groupTextIn(String id, String from, String body, int at) => _calls.invokeMethod('groupTextIn', {'id': id, 'from': from, 'body': body, 'at': at});
  Future<void> groupNote(String id, String body) => _calls.invokeMethod('groupNote', {'id': id, 'body': body});

  // --- friends (lib/friends/friends.dart, android Friends.kt) --------------------------------------------------------

  /// Says where being friends with [address] stands, on their encryption record.
  Future<void> friendSet(String address, String state) => _calls.invokeMethod('friendSet', {'address': address, 'state': state});

  /// Keeps [body], on its way to [address] by the routes, with the phone's messages; its row, for [netTextState].
  Future<int> netTextOut(String address, String body, {int? at}) async => ((await _calls.invokeMethod('netTextOut', {'address': address, 'body': body, 'at': ?at})) as num).toInt();

  /// What became of a row from [netTextOut]: 'sent', 'delivered' or 'failed'.
  Future<void> netTextState(int id, String state) => _calls.invokeMethod('netTextState', {'id': id, 'state': state});

  /// Takes a row from [netTextOut] back: no route could take it, and it goes as a text instead.
  Future<void> netTextDrop(int id) => _calls.invokeMethod('netTextDrop', {'id': id});

  /// Keeps [body], which came from [address] by the routes, as a text that arrived is kept, and says so as one is.
  Future<void> netTextIn(String address, String body, int at) => _calls.invokeMethod('netTextIn', {'address': address, 'body': body, 'at': at});

  /// The conversations with friends by username kept here, for a new device of the account (GMFB-53;
  /// lib/standalone/chats.dart history): `{a: address, r: [[words, when, 1 where ours], …]}` each.
  Future<List<Map>> netHistory() async => ((await _calls.invokeMethod('netHistory')) as List? ?? const []).cast<Map>();

  /// Messages of [address]'s conversation another device of the account held, kept here once each: how many were new.
  Future<int> netHistoryKeep(String address, List<List<Object>> rows) async => ((await _calls.invokeMethod('netHistoryKeep', {'address': address, 'rows': rows})) as num?)?.toInt() ?? 0;

  /// Data texts (android NetSms.kt): whether this phone can send them, and one sent to [address] carrying [bytes].
  Future<bool> netSmsAvailable() async => await _calls.invokeMethod<bool>('netSmsAvailable') ?? false;
  Future<void> netSmsSend(String address, Uint8List bytes) => _calls.invokeMethod('netSmsSend', {'address': address, 'bytes': bytes});

  /// The data texts that came while the app's screens were not there, oldest first; handed over once.
  Future<List<({String address, Uint8List bytes})>> netSmsDrain() async {
    final list = await _calls.invokeMethod('netSmsDrain') as List? ?? const [];
    return [for (final m in list.cast<Map>()) (address: m['address'] as String, bytes: m['bytes'] as Uint8List)];
  }

  /// What the phone lets the app do now, and Android asked to make it the default texting app.
  Future<SmsStatus> status() async => SmsStatus.from(await _calls.invokeMethod('status') as Map);
  Future<bool> requestDefault() async => await _calls.invokeMethod<bool>('requestDefault') ?? false;

  /// Beside Google Messages: Android's page for notification access, opened at Uplink (android GmBridge.kt).
  Future<void> openBridgeAccess() => _calls.invokeMethod<bool>('bridgeAccess');

  /// Opens Google Messages, or its Play Store page where it is not on the phone.
  Future<void> openGm() => _calls.invokeMethod<bool>('openGm');

  /// Google Messages' notification channels as Uplink last saw them (android GmBridge.channelList), loudest first.
  Future<List<GmChannel>> gmChannels() async =>
      [for (final c in ((await _calls.invokeMethod<List>('gmChannels')) ?? const [])) GmChannel.from(c as Map)];

  /// The on-phone Google Messages connection (android GmWeb.kt): how it stands, pairing (a QR code to show on another
  /// screen) and unpairing.
  Future<Map<String, Object?>> gmWebState() async => ((await _calls.invokeMethod<Map>('gmWebState')) ?? const {}).cast<String, Object?>();
  Future<Map<String, Object?>> gmWebPair() async => ((await _calls.invokeMethod<Map>('gmWebPair')) ?? const {}).cast<String, Object?>();
  /// Pairs the phone's connection by Google account, from a signed-in browser's cookies (lib/gm/google_signin.dart).
  Future<Map<String, Object?>> gmWebPairGoogle(Map<String, String> cookies) async =>
      ((await _calls.invokeMethod<Map>('gmWebPairGoogle', {'cookies': cookies})) ?? const {}).cast<String, Object?>();
  Future<Map<String, Object?>> gmWebUnpair() async => ((await _calls.invokeMethod<Map>('gmWebUnpair')) ?? const {}).cast<String, Object?>();

  /// Android's settings for one of Google Messages' channels.
  Future<void> openGmChannel(GmChannel c) => _calls.invokeMethod<bool>('openGmChannel', {'id': c.id, 'conversation': c.conversation});

  /// Android's notification settings for Google Messages, to make them silent (Uplink then shows its own).
  Future<void> openGmNotifications() => _calls.invokeMethod<bool>('openGmNotifications');

  /// Beside Google Messages: reading the SMS database and sending texts, asked for.
  Future<SmsStatus> requestSms() async => SmsStatus.from((await _calls.invokeMethod<Map>('requestSms')) ?? const {});
  Future<SmsStatus> requestPermissions() async => SmsStatus.from(await _calls.invokeMethod('requestPermissions') as Map);

  /// What the app was opened to show (a notification pressed, something shared into it), or null. Requests that
  /// come while it runs arrive on [opens].
  Future<OpenRequest?> openRequest() async {
    final m = await _calls.invokeMethod('openRequest');
    return m == null ? null : OpenRequest.from(m as Map);
  }

  Future<List<Conversation>> conversations() async =>
      [for (final c in (await _calls.invokeMethod<List>('conversations')) ?? const []) Conversation.from(c as Map)];

  /// Conversations, the newest first, a lot at a time (Matt, 2026-11-13: "see if we can load by most recent first so
  /// that things are faster"): [limit] of them from the [offset]th row of Android's list. [pinned] adds what heads
  /// the screen however old it is, for the first lot: the pinned ones, and the newest few unread ones (android
  /// Store.conversationsPage). [archived]: the archived ones alone, all at once.
  Future<ConversationPage> conversationsPage({int limit = 0, int offset = 0, bool pinned = false, bool archived = false}) async {
    final answer = (await _calls.invokeMethod<Map>('conversationsPage', {'limit': limit, 'offset': offset, 'pinned': pinned, 'archived': archived})) ?? const {};
    final floor = (answer['floor'] as num?)?.toInt();
    return ConversationPage(
      [for (final c in (answer['items'] as List?) ?? const []) Conversation.from(c as Map)],
      (answer['next'] as num?)?.toInt(),
      floor: floor == null ? null : DateTime.fromMillisecondsSinceEpoch(floor),
    );
  }

  /// One conversation as the list has it, or null where it is gone.
  Future<Conversation?> conversation(int thread) async {
    final c = await _calls.invokeMethod<Map>('conversation', {'thread': thread});
    return c == null ? null : Conversation.from(c);
  }

  /// How many conversations are archived.
  Future<int> archivedCount() async => ((await _calls.invokeMethod('archivedCount')) as num?)?.toInt() ?? 0;

  /// The newest [limit] messages of a conversation.
  Future<List<Message>> messages(int thread, {int limit = 300}) async =>
      [for (final m in (await _calls.invokeMethod<List>('messages', {'thread': thread, 'limit': limit})) ?? const []) Message.from(m as Map)];

  Future<List<Person>> people(int thread) async =>
      [for (final p in (await _calls.invokeMethod<List>('people', {'thread': thread})) ?? const []) Person.from(p as Map)];

  /// The conversation with exactly these people, made where there is none.
  Future<int> threadFor(List<String> addresses) async => ((await _calls.invokeMethod('threadFor', {'addresses': addresses})) as num).toInt();

  /// Sends [body] to [addresses], with [attachments] (content addresses) as a picture message; answers the
  /// conversation it went into.
  Future<int> send(List<String> addresses, String body, {List<String> attachments = const []}) async =>
      ((await _calls.invokeMethod('send', {'addresses': addresses, 'body': body, 'attachments': attachments})) as num).toInt();

  /// Sends one of the app's stickers (lib/stickers.dart) as a picture message: [picture] is its bytes, [name] its
  /// pack and number.
  Future<int> sendSticker(List<String> addresses, Uint8List picture, String name) async =>
      ((await _calls.invokeMethod('sendSticker', {'addresses': addresses, 'picture': picture, 'name': name})) as num).toInt();

  /// Sends a picture message that did not go again, with its own pictures (android Sender.resendMms). [body]: other
  /// words for it, where it was edited first.
  Future<void> resendMms(int id, {String? body}) => _calls.invokeMethod('resendMms', {'id': id, 'body': body});

  /// A line for the app's own log (Settings › Developer; android DevLog.kt). Never a message's words.
  void devLog(String tag, String line) {
    _calls.invokeMethod('devLog', {'tag': tag, 'line': line}).catchError((_) {});
  }

  /// The log's lines, the newest last, and the whole report as text.
  Future<(List<String>, String)> devLogRead(String version) async {
    final m = (await _calls.invokeMethod<Map>('devLogRead', {'version': version})) ?? const {};
    return ([for (final l in (m['lines'] as List?) ?? const []) l as String], (m['report'] as String?) ?? '');
  }

  Future<void> devLogClear() => _calls.invokeMethod('devLogClear');

  /// Hands [text] to Android's share sheet: an email, a note, another app.
  Future<void> shareText(String subject, String text) => _calls.invokeMethod('shareText', {'subject': subject, 'text': text});

  /// Whether picture messages can go from this phone, and how the last ones went.
  Future<MmsStatus> mmsStatus() async => MmsStatus.from((await _calls.invokeMethod<Map>('mmsStatus')) ?? const {});

  /// Asks again for the picture messages announced and never fetched; answers how many.
  Future<int> mmsRetry() async => ((await _calls.invokeMethod('mmsRetry')) as num?)?.toInt() ?? 0;

  Future<void> markRead(int thread) async {
    await _calls.invokeMethod('markRead', {'thread': thread});
    reads.add(thread);
  }

  /// Takes away the notification shown for [thread] and leaves the conversation as it is: unread, and not muted, so
  /// the next text notifies as ever (MainActivity's cancelChat, Notifier.cancel; a computer's own calls take it too).
  Future<void> cancelNotification(int thread) => _calls.invokeMethod('cancelChat', {'thread': thread});

  /// Tries again to bring down a picture message that could not be ([Message.state] `pending_download`).
  Future<void> retryDownload(Message m) => _calls.invokeMethod('retryDownload', {'id': m.id});
  // Deleted beside Google Messages, a conversation or text may be one Uplink only leaves out: that list is kept on the
  // account too (lib/kept_lists.dart).
  Future<void> deleteThread(int thread) => _calls.invokeMethod('deleteThread', {'thread': thread}).then((_) => KeptLists.instance.changed());
  Future<void> deleteThreads(List<int> threads) => _calls.invokeMethod('deleteThreads', {'threads': threads}).then((_) => KeptLists.instance.changed());

  /// Coming from another texting app: what can be seen (null where Android will not say), and the ways out.
  Future<Arriving> arriving() async {
    final m = await _calls.invokeMethod('arriving');
    return m is Map ? Arriving.from(m) : const Arriving();
  }

  /// Opens a web address in the browser: a link pressed in a message (lib/links.dart). On a computer, its own
  /// browser. True where something took it.
  Future<bool> openLink(String address) async => await _calls.invokeMethod<bool>('openLink', {'url': address}) ?? false;

  /// Open, in turn: the old app's settings (RCS chats is in them), Android's page for this app (⋮ › Allow restricted
  /// settings), Android's Default apps, and Google's page that turns RCS off for a number with a code it texts.
  Future<void> openOldApp() => _calls.invokeMethod('openOldApp');
  Future<void> openAppInfo() => _calls.invokeMethod('openAppInfo');
  Future<void> openDefaultApps() => _calls.invokeMethod('openDefaultApps');
  Future<void> openRcsOff() => _calls.invokeMethod('openRcsOff');
  Future<void> deleteMessage(Message m) => _calls.invokeMethod('deleteMessage', {'kind': m.kind, 'id': m.id}).then((_) => KeptLists.instance.changed());
  Future<void> editMessage(Message m, String body) => _calls.invokeMethod('editMessage', {'kind': m.kind, 'id': m.id, 'body': body});
  Future<void> archive(int thread, bool archived) => _calls.invokeMethod('archive', {'thread': thread, 'archived': archived});
  /// Gives the conversation a name on this phone, or takes it away with an empty one: a group's.
  Future<void> setThreadName(int thread, String name) => _calls.invokeMethod('threadName', {'thread': thread, 'name': name});

  /// Whether [thread] is an RCS group Google Messages knows: its name is then everyone's, renamed through Google
  /// Messages (GmWeb.renameGroup). False anywhere else, and where nothing answers.
  Future<bool> isRcsGroup(int thread) async {
    try {
      return await _calls.invokeMethod<bool>('rcsGroup', {'thread': thread}) ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<void> threadFlag(String name, int thread, bool on) => _calls.invokeMethod('threadFlag', {'name': name, 'thread': thread, 'on': on});
  Future<String?> draft(int thread) => _calls.invokeMethod<String>('draft', {'thread': thread});
  Future<void> setDraft(int thread, String text) => _calls.invokeMethod('setDraft', {'thread': thread, 'text': text});
  Future<void> setBlocked(String address, bool blocked) => _calls.invokeMethod('setBlocked', {'address': address, 'blocked': blocked});

  Future<E2eState> e2e(String address) async => E2eState.from((await _calls.invokeMethod('e2e', {'address': address})) as Map);
  Future<E2eState> e2eOffer(String address) async => E2eState.from((await _calls.invokeMethod('e2eOffer', {'address': address})) as Map);
  Future<void> e2eOff(String address) => _calls.invokeMethod('e2eOff', {'address': address});

  /// Puts away the warning that [address]'s texts are coming without encryption; the next plain one brings it back.
  Future<void> e2ePlainSeen(String address) => _calls.invokeMethod('e2ePlainSeen', {'address': address});
  Future<void> e2eVerify(String address, bool verified) => _calls.invokeMethod('e2eVerify', {'address': address, 'verified': verified});
  Future<void> e2eReset() => _calls.invokeMethod('e2eReset');
  Future<String?> e2eMine() => _calls.invokeMethod<String>('e2eMine');
  Future<List<E2eState>> e2eList() async => [for (final m in (await _calls.invokeMethod<List>('e2eList')) ?? const []) E2eState.from(m as Map)];
  Future<List<Person>> blockedNumbers() async => [for (final m in (await _calls.invokeMethod<List>('blockedNumbers')) ?? const []) Person.from(m as Map)];
  Future<void> notificationSettings() => _calls.invokeMethod('notificationSettings');

  /// Android's own page for the app's bubbles, which decides which conversations may bubble (Settings ›
  /// Notifications › Bubbles; android Bubbles.kt).
  Future<void> bubbleSettings() => _calls.invokeMethod('bubbleSettings');

  /// From a conversation's bubble (lib/bubble.dart): the whole app, opened on [thread].
  Future<void> openInApp(int thread) => _calls.invokeMethod('openInApp', {'thread': thread});

  /// Opens the calendar's new event with [title] at [begin] filled in (lib/plugins/actions.dart); false where the
  /// phone has no calendar to take it, or on a computer.
  Future<bool> addEvent({required String title, required DateTime begin, bool allDay = false, String notes = ''}) async {
    if (remote) return false;
    try {
      return (await _calls.invokeMethod<bool>('addEvent', {'title': title, 'begin': begin.millisecondsSinceEpoch, 'allDay': allDay, 'notes': notes})) ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Brings [thread] back as a notification at [at] (android/.../Reminders.kt); false where it could not be set, or on
  /// a computer.
  Future<bool> remind({required int thread, required String title, required String body, required DateTime at}) async {
    if (remote) return false;
    try {
      return (await _calls.invokeMethod<bool>('remind', {'thread': thread, 'title': title, 'body': body, 'at': at.millisecondsSinceEpoch})) ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Android's new contact with [address] filled in; false where nothing could take it, or on a computer.
  Future<bool> addContact(String address) async {
    if (remote) return false;
    try {
      return (await _calls.invokeMethod<bool>('addContact', {'address': address})) ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Opens the map at [place] (an address as written); false where nothing could, or on a computer.
  Future<bool> openMap(String place) async {
    if (remote) return false;
    try {
      return (await _calls.invokeMethod<bool>('openMap', {'place': place})) ?? false;
    } catch (_) {
      return false;
    }
  }

  /// The phone's dialler with [number] in it.
  Future<void> dial(String number) async {
    if (remote) return;
    try {
      await _calls.invokeMethod('dial', {'address': number});
    } catch (_) {}
  }

  /// Where the phone's own model for summaries stands (android/.../Summaries.kt): "available", "downloading",
  /// "downloadable" or "unavailable". A computer has none of its own.
  Future<String> summaryStatus() async {
    if (remote) return 'unavailable';
    try {
      return (await _calls.invokeMethod<String>('summaryStatus')) ?? 'unavailable';
    } catch (_) {
      return 'unavailable';
    }
  }

  /// Asks for the model where the phone can have it and has not yet; where it stands after.
  Future<String> summaryPrepare() async {
    if (remote) return 'unavailable';
    try {
      return (await _calls.invokeMethod<String>('summaryPrepare')) ?? 'unavailable';
    } catch (_) {
      return 'unavailable';
    }
  }

  /// One line on what [conversation] (a line a text, `<name>: <words>`) says, by the phone's own model; null where it
  /// cannot say.
  Future<String?> summarize(String conversation) async {
    if (remote) return null;
    try {
      return await _calls.invokeMethod<String>('summarize', {'text': conversation});
    } catch (_) {
      return null;
    }
  }

  /// Up to three replies to the newest of [messages] (`{mine, who, text, at}`, oldest first) by the small model inside
  /// the app (android/.../SmartReplies.kt); empty where it has none.
  Future<List<String>> smartReplies(List<Object?> messages) async {
    if (remote) return const [];
    try {
      return ((await _calls.invokeMethod<List<Object?>>('smartReplies', {'messages': messages})) ?? const []).whereType<String>().toList();
    } catch (_) {
      return const [];
    }
  }

  /// [text] translated into [to] on the phone (android/.../Translate.kt), for the Translate plugin
  /// (lib/plugins/translate.dart; Matt, 2026-11-17: "add a translate plugin which can automatically translate texts when
  /// detected from another language"): `{state, text, from}`, as Translate.kt answers. On a computer, or an iPhone
  /// paired with a phone, the paired phone is asked over the link (lib/desktop/remote.dart); an iPhone on its own has
  /// no translation yet ('unavailable'). Never throws: a bubble must never break over it.
  Future<Map<String, Object?>> translate(String text, {required String to, List<String> known = const [], bool fetch = true, bool wifiOnly = true}) async {
    if (standalone) return const {'state': 'unavailable'};
    try {
      final got = await _calls.invokeMethod<Map>('translate', {'text': text, 'to': to, 'known': known, 'fetch': fetch, 'wifiOnly': wifiOnly});
      return got == null ? const {'state': 'failed'} : got.cast<String, Object?>();
    } catch (_) {
      return const {'state': 'failed'};
    }
  }

  /// Every language the phone can translate, `{tag, downloaded, fetching}` each; none where it cannot.
  Future<List<Map<String, Object?>>> translateLanguages() async {
    if (standalone) return const [];
    try {
      return [for (final l in (await _calls.invokeMethod<List>('translateLanguages')) ?? const []) (l as Map).cast<String, Object?>()];
    } catch (_) {
      return const [];
    }
  }

  /// Fetches a language's model for translation, or deletes it ([delete]) to give its room back.
  Future<bool> translateModel(String tag, {bool delete = false, bool wifiOnly = true}) async {
    if (standalone) return false;
    try {
      return (await _calls.invokeMethod<bool>('translateModel', {'tag': tag, 'action': delete ? 'delete' : 'fetch', 'wifiOnly': wifiOnly})) ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Android's page for the "Paired with…" notification alone, where the person can turn it off.
  Future<void> deskNotificationSettings() => _calls.invokeMethod('deskNotificationSettings');

  /// The app's own update (android Updater.kt): where it stands, a look for a newer version (installed too, where
  /// asked), the one fetched installed.
  Future<UpdateState> update() async => UpdateState.from((await _calls.invokeMethod('update')) as Map);
  Future<void> updateCheck({bool install = false}) => _calls.invokeMethod('updateCheck', {'install': install});
  Future<void> updateInstall() => _calls.invokeMethod('updateInstall');
  Future<void> updateBackground() => _calls.invokeMethod('updateBackground');

  /// A page opened: a look for a newer version, which Android makes no oftener than every five minutes.
  Future<void> updateOnPage() => _calls.invokeMethod('updatePage');
  Future<void> setAutoUpdate(bool on) => _calls.invokeMethod('setAutoUpdate', {'on': on});
  Future<void> allowInstalls() => _calls.invokeMethod('allowInstalls');
  Future<void> setOpenThread(int? thread) => _calls.invokeMethod('setOpenThread', {'thread': thread ?? -1});

  Future<List<Map<String, String?>>> searchContacts(String query) async => [
        for (final c in (await _calls.invokeMethod<List>('searchContacts', {'query': query})) ?? const [])
          {for (final e in (c as Map).entries) e.key as String: e.value as String?},
      ];

  Future<Person> contact(String address) async => Person.from(await _calls.invokeMethod('contact', {'address': address}) as Map);

  final _photos = <String, Future<Uint8List?>>{};
  Future<Uint8List?> photo(String uri) => _photos[uri] ??= _calls.invokeMethod<Uint8List>('photo', {'uri': uri});

  /// A picture's bytes, kept while it is among the last [_partsKept] asked for: a long conversation's pictures are
  /// read again when scrolled back to, where they once stayed in memory for as long as the app ran.
  final _parts = <int, Future<Uint8List?>>{};
  static const _partsKept = 40;
  Future<Uint8List?> part(int id) {
    final had = _parts.remove(id);
    // An empty file is not there yet either: a picture you send is written as a part first and its bytes after, and
    // read in between it came back empty, was kept, and the message drew as nothing but "Delivered" for as long as
    // the app was open (Matt, 2026-11-19: "when I'm sending pictures and voice messages sometimes I don't see my
    // outbound messages just the delivered tag").
    final bytes = had ?? _calls.invokeMethod<Uint8List>('part', {'id': id}).then((b) => b == null || b.isEmpty ? null : b);
    _parts[id] = bytes;
    while (_parts.length > _partsKept) {
      _parts.remove(_parts.keys.first);
    }
    // Not there yet is not kept: a picture you sent can be asked for before its file is (Google Messages tells of the
    // message before the phone has kept its copy), and was then blank for as long as the app was open (Matt,
    // 2026-11-16: "the preview of the image I sent never loads").
    bytes.then((b) {
      if (b == null && identical(_parts[id], bytes)) _parts.remove(id);
    }, onError: (_) {
      if (identical(_parts[id], bytes)) _parts.remove(id);
    });
    return bytes;
  }

  /// A picture held here before the phone has it: a message drawn while it is sending (lib/ui/thread.dart).
  void holdPart(int id, Future<Uint8List?> bytes) => _parts[id] = bytes;

  // --- voice messages (android/.../Voice.kt) -------------------------------------------------------------------

  /// Starts recording a voice message with the phone's microphone, asking Android for it the first time. Answers the
  /// most seconds one may run (the carrier's limit on a message decides), or null where the microphone was refused.
  /// [file]: one that goes as a file ([finishVoice]: a network's chat, a space, a friend), which no carrier holds; a
  /// computer then records it with its own microphone and needs no phone (lib/desktop/desk_voice.dart, GMFB-32).
  Future<int?> startVoice({bool file = false}) async {
    final m = await _calls.invokeMethod('voiceStart', file ? const {'file': true} : null) as Map?;
    if (m == null || m['ok'] != true) return null;
    return (m['seconds'] as num?)?.toInt() ?? 60;
  }

  /// How loud the microphone hears it right now, 0 to 1.
  Future<double> voiceLevel() async => ((await _calls.invokeMethod('voiceLevel')) as num?)?.toDouble() ?? 0;

  /// Throws the recording away.
  Future<void> cancelVoice() => _calls.invokeMethod('voiceCancel');

  /// Ends the recording and sends it to [addresses] as a picture message with the sound in it. The conversation.
  Future<int> sendVoice(List<String> addresses) async =>
      (((await _calls.invokeMethod('voiceSend', {'addresses': addresses})) as Map)['thread'] as num).toInt();

  /// Plays the sound in a message's part [part] (or goes on with it, where it was paused); [voice] says how far.
  Future<void> playVoice(int part) => _calls.invokeMethod('voicePlay', {'part': part});
  Future<void> pauseVoice() => _calls.invokeMethod('voicePause');

  /// Stops whatever is playing: leaving the conversation.
  Future<void> stopVoice() => _calls.invokeMethod('voiceStop');

  final _voiceLengths = <int, Future<Duration>>{};

  /// How long the sound in part [part] runs; zero where it cannot be read.
  Future<Duration> voiceLength(int part) => _voiceLengths[part] ??= () async {
        try {
          return Duration(milliseconds: ((await _calls.invokeMethod('voiceLength', {'part': part})) as num?)?.toInt() ?? 0);
        } catch (_) {
          return Duration.zero;
        }
      }();

  // --- videos (android/.../Video.kt; on a Mac macos/Runner/DeskVideo.swift) -------------------------------------

  final _videoPreviews = <int, Future<VideoPreview>>{};
  static const _videoPreviewsKept = 40;

  /// A picture of where the video [a] starts and how long it runs, kept while it is among the last few asked for.
  /// One that could not be had (the phone out of a computer's reach) is asked for again the next time.
  Future<VideoPreview> videoPreview(Attachment a) {
    final had = _videoPreviews.remove(a.id);
    final preview = had ??
        () async {
          try {
            return VideoPreview.from(await _calls.invokeMethod<Map>('videoPreview', {'part': a.id, 'type': a.type, 'ending': a.ending}));
          } catch (_) {
            return const VideoPreview();
          }
        }();
    _videoPreviews[a.id] = preview;
    preview.then((p) {
      if (p.empty && identical(_videoPreviews[a.id], preview)) _videoPreviews.remove(a.id);
    });
    while (_videoPreviews.length > _videoPreviewsKept) {
      _videoPreviews.remove(_videoPreviews.keys.first);
    }
    return preview;
  }

  /// The video [a] as a file the app's own player opens (lib/ui/video_screen.dart): on the phone android Video.kt's
  /// videoFile; on a computer a copy of the phone's bytes (lib/desktop/remote.dart videoCopy). Null where it can't be had.
  Future<String?> videoFile(Attachment a) => _calls.invokeMethod<String>('videoFile', {'part': a.id, 'ending': a.ending});

  /// Opens the computer's own panel of emoji, which types what is chosen where the cursor is. A phone's keyboard has
  /// its own, so this is a computer's alone ([remote]).
  Future<void> emojiPanel() => _calls.invokeMethod('emoji');

  /// The conversations (with when each was deleted) and texts deleted beside Google Messages that Android kept: Uplink's
  /// own lists, kept on the account too (lib/kept_lists.dart). Nothing on a computer.
  Future<Map<String, Object?>> hiddenLists() async {
    if (remote) return const {};
    try {
      return ((await _calls.invokeMethod<Map>('hiddenLists')) ?? const {}).cast<String, Object?>();
    } catch (_) {
      return const {};
    }
  }

  /// Joins [threads] and [msgs] from the account into those lists; true where any was new.
  Future<bool> addHiddenLists(Map<String, int> threads, List<String> msgs) async {
    if (remote) return false;
    try {
      return (await _calls.invokeMethod<bool>('addHiddenLists', {'threads': threads, 'msgs': msgs})) ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Any files, pictures and videos among them (a Telegram chat's +): their content addresses on the phone, paths on a
  /// computer.
  Future<List<String>> pickFiles() async => [for (final u in (await _calls.invokeMethod<List>('pickFiles')) ?? const []) u as String];

  /// A picked file's path on this device: a phone's content address copied into the app's cache, a path as it is.
  Future<String> cacheCopy(String picked) async => picked.startsWith('content:') ? (await _calls.invokeMethod<String>('cacheCopy', {'uri': picked}))! : picked;

  /// Ends the recording and gives its file, for a network's chat to send.
  Future<String> finishVoice() async => ((await _calls.invokeMethod('voiceFinish')) as Map)['path'] as String;

  /// Opens a file in whichever app reads its kind.
  Future<void> openFile(String path, {String? name}) => _calls.invokeMethod('openFile', {'path': path, 'name': name});

  Future<List<String>> pickImages() async => [for (final u in (await _calls.invokeMethod<List>('pickImages')) ?? const []) u as String];

  // --- a Files space's files on the phone (lib/files/file_platform.dart; android MainActivity "keepFile" and the rest) --

  /// A picked or shared file (its content address) copied into the app's own folder, to go up from there even after
  /// the app was closed: its path, name and size.
  Future<({String path, String name, int size})> keepFile(String uri) async {
    final m = (await _calls.invokeMethod<Map>('keepFile', {'uri': uri}))!;
    return (path: m['path'] as String, name: m['name'] as String, size: (m['size'] as num).toInt());
  }

  /// Asks where to save the file at [path] (as [name]) and copies it there; false where the person put the page away.
  Future<bool> saveFile(String path, String name, String mime) async => await _calls.invokeMethod<bool>('saveFile', {'path': path, 'name': name, 'mime': mime}) ?? false;

  /// Shares the file at [path] with another app.
  Future<void> shareFile(String path, String name, String mime) => _calls.invokeMethod('shareFile', {'path': path, 'name': name, 'mime': mime});

  /// Files another app shared into this one before anything listened for them ([sharedIn] has the ones after).
  Future<List<String>> sharedFiles() async => [for (final u in (await _calls.invokeMethod<List>('sharedFiles')) ?? const []) u as String];

  /// What files shared in are, asked of the app that shares them without copying them (android MainActivity
  /// "describeFiles"): each one's address, name, size (-1 where the app doesn't say) and type. Addresses this app would
  /// not copy (its own, a file:// one) are left out. Matt, 2026-11-17: "Finish the missing pieces that went unfinished".
  Future<List<({String uri, String name, int size, String mime})>> describeFiles(List<String> uris) async => [
        for (final m in (await _calls.invokeMethod<List>('describeFiles', {'uris': uris})) ?? const [])
          if (m is Map)
            (
              uri: '${m['uri']}',
              name: '${m['name'] ?? 'file'}',
              size: (m['size'] as num?)?.toInt() ?? -1,
              mime: '${m['mime'] ?? 'application/octet-stream'}',
            ),
      ];

  Future<String?> ownNumber() => _calls.invokeMethod<String>('ownNumber');

  /// On a computer: what the phone's Telegram is asked (its status, approving this computer's login link: lib/inbox/
  /// telegram.dart answerComputer; android DartAsk "telegram").
  Future<Map<String, dynamic>> telegram(Map<String, Object?> what) async =>
      Map<String, dynamic>.from((await _calls.invokeMethod<Map>('telegram', {'what': what})) ?? const {});

  /// On a computer: the networks' sign-ins its phone holds or can read of the account's (lib/inbox/curl_sync.dart
  /// forComputer; android DartAsk "signins"), for a computer that can't open what the account keeps itself.
  Future<Map<Object?, Object?>> signInsOfPhone() async => (await _calls.invokeMethod<Map>('signins', {'what': const <String, Object?>{}})) ?? const {};

  /// On a computer: how RCS stands on its phone (lib/gm/rcs_share.dart; android DartAsk "rcs").
  Future<Map<Object?, Object?>> rcsOfPhone() async => (await _calls.invokeMethod<Map>('rcs', {'what': const <String, Object?>{}})) ?? const {};

  Future<Map<String, dynamic>> voiceSync(Map<String, Object?> what) async =>
      Map<String, dynamic>.from((await _calls.invokeMethod<Map>('voice', {'what': what})) ?? const {});

  /// On a paired computer: the phone's identity, friends by username and conversations with them, handed over so the
  /// computer has friends and circles of its own (android DeskCalls "handover"; lib/friends/handover.dart).
  Future<Map<String, dynamic>> handover(Map<String, Object?> what) async =>
      Map<String, dynamic>.from((await _calls.invokeMethod<Map>('handover', {'what': what})) ?? const {});

  /// On a paired computer: friends by username, asked of the phone (android DeskCalls "buddies", answered by the
  /// phone's [Buddies.forComputer]).
  Future<Map<String, dynamic>> buddies(Map<String, Object?> what) async =>
      Map<String, dynamic>.from((await _calls.invokeMethod<Map>('buddies', {'what': what})) ?? const {});

  /// On a paired computer: one of Settings › Me's asks, done by the phone (the 'me' call: android DeskCalls "me",
  /// answered by the phone's [Me.forComputer]). Matt, 2026-11-14: "on desktop the phone number reads as unknown and is
  /// not proxying the verification process".
  Future<Map<String, dynamic>> me(Map<String, Object?> what) async =>
      Map<String, dynamic>.from((await _calls.invokeMethod<Map>('me', {'what': what})) ?? const {});

  /// On the phone: answers what Android asks the app's Dart side by [method] (android DartAsk.kt: what a paired
  /// computer asks that only Dart knows). An error's words, from a [MeError] or another, reach the computer.
  static void answer(String method, Future<Object?> Function(Map<String, Object?> args) work) {
    _answers[method] = work;
    _ChannelCalls._channel.setMethodCallHandler((call) async {
      final w = _answers[call.method];
      if (w == null) throw MissingPluginException();
      try {
        return await w(Map<String, Object?>.from((call.arguments as Map?) ?? const {}));
      } catch (e) {
        throw PlatformException(code: 'failed', message: '$e');
      }
    });
  }

  /// What answers each method Android asks of Dart, as [answer] was given them.
  static final Map<String, Future<Object?> Function(Map<String, Object?>)> _answers = {};
  Future<void> setOwnNumber(String number) => _calls.invokeMethod('setOwnNumber', {'number': number});

  /// The colours Android takes from the wallpaper (Material You), by name ("accent1_100"…); null before Android 12.
  Future<Map<String, int>?> systemPalette() async {
    final m = await _calls.invokeMethod<Map>('systemPalette');
    return m == null ? null : {for (final e in m.entries) e.key as String: (e.value as num).toInt()};
  }

  /// A copy of the picture at [uri] kept by the app as a chat background, [name] saying whose ("all", or a
  /// conversation's number); the copy's path, or null when the picture could not be read.
  Future<String?> importBackground(String uri, String name) => _calls.invokeMethod<String>('importBackground', {'uri': uri, 'name': name});
  Future<void> deleteBackground(String name) => _calls.invokeMethod('deleteBackground', {'name': name});

  /// Whether Ghost Keyboard is on this phone, signed as it should be (android/.../Codes.kt): sign-in codes are
  /// offered to it and to nothing else.
  Future<bool> keyboardHere() async => await _calls.invokeMethod<bool>('keyboardHere') ?? false;

  /// Whether everyone in [addresses] is known to have Uplink (android/.../Backgrounds.kt): a text only the
  /// app writes has come from each of them.
  Future<bool> ghostPeers(List<String> addresses) async => await _calls.invokeMethod<bool>('ghostPeers', {'addresses': addresses}) ?? false;

  /// Sends [thread]'s background ([raw], as the choice is kept) to its people as a text their copy of the app wears.
  Future<void> shareBackground(List<String> addresses, int thread, String raw) => _calls.invokeMethod('shareBackground', {'addresses': addresses, 'thread': thread, 'raw': raw});

  // --- paired computers (android/.../Desk.kt) ---------------------------------------------------------------------------

  /// The computers paired with this phone, and where a pairing under way stands.
  Future<List<Computer>> computers() async => [for (final m in (await _calls.invokeMethod<List>('deskList')) ?? const []) Computer.from(m as Map)];
  Future<PairingState> pairing() async => PairingState.from((await _calls.invokeMethod('deskState')) as Map);

  /// The name of the computer a pairing code is from, before anything is done with it. Throws when it is not one.
  Future<String> pairingCodeName(String code) async => (((await _calls.invokeMethod('deskPeek', {'code': code})) as Map)['name'] as String?) ?? 'A computer';

  /// The camera, looking for a computer's QR code: its words, or null when the screen was left (or `denied`, when
  /// the camera was refused).
  Future<({String? text, bool denied})> scanPairingCode() async {
    final m = (await _calls.invokeMethod('deskScan')) as Map;
    return (text: m['text'] as String?, denied: m['denied'] == true);
  }

  /// Starts pairing with the computer whose code this is. Throws when it is not a code of ours.
  Future<PairingState> beginPairing(String code, {String? mode}) async => PairingState.from((await _calls.invokeMethod('deskBegin', {'code': code, 'mode': mode})) as Map);
  Future<PairingState> setPairingMode(String mode) async => PairingState.from((await _calls.invokeMethod('deskPendingMode', {'mode': mode})) as Map);
  Future<void> confirmPairing() => _calls.invokeMethod('deskConfirm');
  Future<void> cancelPairing() => _calls.invokeMethod('deskCancel');
  Future<void> pairingShown() => _calls.invokeMethod('deskDone');
  Future<void> unpairComputer(String id) => _calls.invokeMethod('deskUnpair', {'id': id});
  Future<void> setComputerMode(String id, String mode) => _calls.invokeMethod('deskSetMode', {'id': id, 'mode': mode});

  /// Where this phone listens on the local network (`192.168.1.20:47811`), for a computer that cannot find it.
  Future<List<String>> phoneAddresses() async => [for (final a in (await _calls.invokeMethod<List>('deskAddresses')) ?? const []) '$a'];

  /// Whether Android lets the app use the network in deep sleep (its battery setting is "Unrestricted").
  Future<bool> unrestrictedBattery() async => await _calls.invokeMethod<bool>('deskUnrestricted') ?? false;

  /// Whether timings are being written to Android's log (`adb shell setprop log.tag.GhostPerf VERBOSE`).
  Future<bool> perfOn() async => await _calls.invokeMethod<bool>('perfOn') ?? false;

  /// The person's choices, each a string under its key: all of them read, and one kept.
  Future<Map<String, String>> prefs() async => {for (final e in ((await _calls.invokeMethod<Map>('prefs')) ?? const {}).entries) e.key as String: e.value as String};
  Future<void> setPref(String key, String value) {
    final going = _calls.invokeMethod('setPref', {'key': key, 'value': value}).then<void>((_) {});
    _prefsGoing.add(going);
    unawaited(going.catchError((_) {}).whenComplete(() => _prefsGoing.remove(going)));
    return going;
  }

  /// The choices on their way to being kept ([setPref]), each until it is written.
  final Set<Future<void>> _prefsGoing = {};

  /// Once every choice asked to be kept so far is written: before the app starts again ([restartApp]), so what was
  /// changed just before is not lost with it (2026-11-19: a computer signing in to an account came back signed out, the
  /// account's last choices still being written as the app closed).
  Future<void> prefsWritten() => Future.wait([for (final f in [..._prefsGoing]) f.catchError((_) {})]);

  @visibleForTesting
  void dispose() => _sub?.cancel();
}
