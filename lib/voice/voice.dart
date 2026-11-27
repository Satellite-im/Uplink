import 'dart:async';
import 'dart:math' as math;
import '../names.dart';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' show MediaStream;

import '../net/crypto.dart';
import '../net/hub_carrier.dart';
import '../sounds.dart';
import '../invites/link_relay.dart';

/// What a space is for (Matt, 2026-11-17: "each space should be able to act as a chat and a voice chat, or just a
/// texting space. Additionally add full functionality for filesharing in a space when the space is designated a Files
/// Space"). Every space has its chat room; only a [voice] one has a call, so a [text] or [files] one never shows Join
/// and never asks the relay who is in a call room it does not have.
///
/// Carried as `k` wherever a space goes (its JSON, its link, the invite, the phone and computer in step), left out for
/// [voice], so a space from before kinds is a voice one and an older build reading a newer space just sees a voice
/// space.
enum SpaceKind {
  voice('Chat and voice', 'Talk any time, with a chat beside it'),
  text('Texting', 'A chat, no voice'),
  files('Files', 'Share files, with a chat beside them'),

  /// A call you walk around in (lib/voice/open_space.dart): everyone has a place on a floor seen from above, and is
  /// heard louder or quieter by how near they are. A build from before this kind takes it for a voice space where it
  /// stands alone (everyone heard, nobody placed) and for a chat in a circle ([of], CircleSpace.fromJson).
  open('Open space', 'Walk around, and hear who is near you');

  const SpaceKind(this.label, this.hint);
  final String label;
  final String hint;

  /// Its word on the wire: `voice`, `text`, `files`, `open`.
  String get wire => name;

  bool get hasVoice => this == voice || this == open;

  /// From its word; voice for anything else (missing, or a kind from a newer build).
  static SpaceKind of(Object? wire) {
    for (final k in values) {
      if (k.name == wire) return k;
    }
    return voice;
  }
}

/// Voice and video channels (Matt, 2026-11-14: "I'd like to be able to jump in audio chats like discord has always
/// open voice channels that you can jump in and out at any time and you can see who's connected and also toggle
/// video on and off, also allow for group chat video and voice calls to hop in the voice and video channel at any time
/// with the option to call the group. This will be our fist step towards a discord style server please make sure we
/// stream at lossless quality").
///
/// **A channel** is a room on the relay server's hub, named and opened by a seed only its members hold: a group's
/// is made from the group's id (16 random bytes the members alone were given), one you make has a seed of its own,
/// given to the friends you share it with. From the seed come the room's name, its token (to join or look at it) and
/// the key what is said in it is sealed with ([VoiceChannel]). The hub sees that some installs are in a room, never
/// who they are or what they say.
///
/// **Who is connected** is shown without joining: the hub is asked to say who is in each channel ([VoiceRoute.look]).
/// Names come from the members themselves, sealed, as they join ([VoiceSession]).
///
/// **The sound and picture** go between the phones directly (WebRTC; lib/voice/rtc.dart), each to each: the hub
/// carries only how to connect. Sound is Opus at its highest: 48 kHz, stereo, 510 kb/s, no discontinuous
/// transmission ([highestOpus]); video is sent at up to 1080p and 12 Mb/s, holding resolution over frame rate.
/// That is as close to lossless as a live call carries: Opus at 510 kb/s is beyond what people hear as different
/// from the source, and no browser or phone engine sends uncompressed sound or picture.
@immutable
class VoiceChannel {
  const VoiceChannel({required this.seed, required this.name, this.group, this.mine = false, this.owner = '', this.discord, this.kind = SpaceKind.voice, this.circle});

  /// 32 bytes in hex: everything else comes from it.
  final String seed;
  final String name;

  /// The group whose channel this is; null for one made by someone.
  final String? group;

  /// Made on this phone.
  final bool mine;

  /// Bridged to a Discord voice channel (lib/voice/discord.dart, messaging/discord/): `<guild>/<channel>`. The bridge
  /// is a member of the space and carries its sound and chat to and from Discord, so it is not end-to-end encrypted.
  final String? discord;

  /// The public key (33 bytes in hex) of the install that made it: the hangout's owner, who decides its roles
  /// (lib/voice/roles.dart). Empty for a group's channel and for hangouts made before roles.
  final String owner;

  /// What it is for: chat and voice, texting, or files ([SpaceKind]). A group's channel is always voice.
  final SpaceKind kind;

  /// The circle it is a space of (its seed, lib/circles/circle.dart), or null for a space of its own. A circle's spaces
  /// are listed in the circle, not in Messages; this is not kept in the space's JSON, since the circle's list of spaces
  /// is what says which are its.
  final String? circle;

  /// Whether it has a call: a [SpaceKind.voice] space, or a group's channel.
  bool get hasVoice => kind.hasVoice;

  // The call's room on the hub, the token that lets one join or look at it, and the key what is said there is sealed
  // with: each derived from the seed under its own label, so none gives away another.
  //
  // Each is worked out once for a seed and kept ([_derived]): they were derived afresh at every asking, a hash in pure
  // Dart each time, and a list of spaces asks for `room` for every row it draws and a call for every message it
  // sends (walking an open space spent a twentieth of its time deriving the same room: docs/performance-audit.md,
  // "Calls").
  Uint8List get _seed => NetCrypto.unhex(seed);
  static final Map<String, Uint8List> _derived = {};
  static final Map<String, String> _derivedHex = {};
  Uint8List _derive(String label) => _derived['$label|$seed'] ??= NetCrypto.derive(_seed, label);
  String _hexOf(String label, {int? first}) => _derivedHex['$label|$seed'] ??= NetCrypto.hex(first == null ? _derive(label) : _derive(label).sublist(0, first));
  String get room => _hexOf('voice room', first: 16);
  String get token => _hexOf('voice token');

  /// A copy each time: whoever asks may keep or change theirs.
  Uint8List get key => Uint8List.fromList(_derive('voice key'));

  /// The hangout's chat room: a room of its own beside the call's, which anyone looking at the hangout is in, so the
  /// chat and the roles reach people who are not in the call (lib/voice/hangout.dart).
  String get chatRoom => _hexOf('hangout room', first: 16);
  String get chatToken => _hexOf('hangout token');

  /// A group's channel, from the group's id.
  factory VoiceChannel.ofGroup(String groupId, String name) =>
      VoiceChannel(seed: NetCrypto.hex(NetCrypto.sha256(utf8.encode('ghost-voice group|$groupId'))), name: name, group: groupId);

  /// A new channel of this phone's.
  factory VoiceChannel.make(String name, {String owner = '', SpaceKind kind = SpaceKind.voice}) => VoiceChannel(seed: NetCrypto.hex(NetCrypto.randomBytes(32)), name: name, mine: true, owner: owner, kind: kind);

  /// A hangout (not a group's channel): it has a chat and roles.
  bool get hangout => group == null;

  VoiceChannel copyWith({bool? mine, String? name, SpaceKind? kind}) =>
      VoiceChannel(seed: seed, name: name ?? this.name, group: group, mine: mine ?? this.mine, owner: owner, discord: discord, kind: kind ?? this.kind, circle: circle);

  /// As kept and shared: the seed, the name, and `m`, `o` and `k` only where they aren't the usual. The group, the
  /// Discord bridge and the circle are not carried.
  Map<String, Object> toJson() => {'s': seed, 'n': name, if (mine) 'm': 1, if (owner.isNotEmpty) 'o': owner, if (kind != SpaceKind.voice) 'k': kind.wire};

  /// A link anyone can open in a browser to hop in, as a guest or signed up (site/join; Matt, 2026-11-14: "Make the
  /// voice hangouts possible to share via a link so people can join to talk anonymously or sign up through the
  /// browser similar to a zoom meeting"). The seed is in the part after the #, which a browser never sends to any
  /// server, so the link opens the channel and the relay still can't read it. Whoever has it is in, as with a
  /// meeting link.
  ///
  /// The owner's key follows the name, so the browser knows whose roles to believe; a texting or Files space ends with
  /// its kind (`.text`, `.files`), which can't be taken for a name or a key, so the page knows not to offer voice.
  ///
  /// Made while the app uses a relay other than Uplink's own, it ends with that relay's host after an `@`
  /// (lib/invites/link_relay.dart; GMFB-25).
  String get link => LinkRelay.mark('https://gogho.st/join/#$seed.${base64Url.encode(utf8.encode(name)).replaceAll('=', '')}${owner.isEmpty ? '' : '.$owner'}${kind == SpaceKind.voice ? '' : '.${kind.wire}'}');

  /// The space a [link] (or just its part after the #) is; null where it is not one, a circle's among them. An open
  /// space's ends `.open` ([link]) and is read as one; before 0.12.21 it was refused as no link at all, as builds from
  /// then still refuse it.
  static VoiceChannel? fromLink(String link) {
    link = LinkRelay.split(link).link;
    final hash = link.contains('#') ? link.substring(link.indexOf('#') + 1) : link;
    final m = RegExp(r'^([0-9a-f]{64})(?:\.([A-Za-z0-9_-]*))?(?:\.(0[23][0-9a-f]{64}))?(?:\.(voice|text|files|open))?$').firstMatch(hash);
    if (m == null) return null;
    var name = 'Space';
    try {
      final b = m.group(2) ?? '';
      if (b.isNotEmpty) name = utf8.decode(base64Url.decode(base64Url.normalize(b)));
    } catch (_) {}
    return VoiceChannel(seed: m.group(1)!, name: name.isEmpty ? 'Space' : name, owner: m.group(3) ?? '', kind: SpaceKind.of(m.group(4)));
  }

  /// A space from its JSON; null where the seed or name is missing. An owner that isn't a compressed public key is
  /// dropped.
  static VoiceChannel? fromJson(Object? j) {
    if (j is! Map || j['s'] is! String || (j['s'] as String).length != 64 || j['n'] is! String) return null;
    final owner = j['o'] is String && RegExp(r'^0[23][0-9a-f]{64}$').hasMatch(j['o'] as String) ? j['o'] as String : '';
    return VoiceChannel(seed: j['s'] as String, name: j['n'] as String, mine: j['m'] == 1, owner: owner, kind: SpaceKind.of(j['k']));
  }
}

/// What a voice channel stands on: the hub's rooms. The app's is the hub carrier ([HubVoiceRoute]); a test gives
/// one that passes packets between sessions.
abstract class VoiceRoute {
  /// This device's id on the hub.
  String get me;

  /// Joins [room]; the ids of those already in it.
  Future<List<String>> join(String room, String token);
  void leave(String room);
  void send(String room, Uint8List bytes);

  /// Asks to be told who is in [room] without joining it ([looks]), until [unlook].
  void look(String room, String token);
  void unlook(String room);
  Stream<RoomEvent> get events;
  Stream<({String room, String from, Uint8List bytes})> get packets;
  Stream<({String room, List<String> members})> get looks;
}

/// A route that knows read-only rooms (relay/lib/hub.dart): joined with what binds the room to its circle owner's key and
/// the circle's admin list (`ro`), and told when that list changes. The hub's route is one; a test's may be.
abstract class ReadOnlyRoute {
  Future<List<String>> joinReadOnly(String room, String token, Map<String, Object?> ro);
  void anchor(String room, Map<String, Object?> grants);
}

/// A route with reactions as packets of their own (relay/lib/hub.dart toRoomReaction): anyone in a room may send one,
/// even where only some may post (a read-only space), and nothing but a reaction is taken from one.
abstract class ReactionRoute {
  /// Whether the relay takes them now; where not, a reaction goes as an ordinary kept packet.
  bool get takesReactions;
  void sendReaction(String room, Uint8List bytes);
  Stream<({String room, String from, Uint8List bytes})> get reactionPackets;
}

/// The app's route: every call passed straight to the relay's hub through its carrier.
class HubVoiceRoute implements VoiceRoute, ReadOnlyRoute, ReactionRoute {
  HubVoiceRoute(this.hub);
  final HubCarrier hub;
  @override
  String get me => hub.signer.id;
  @override
  Future<List<String>> join(String room, String token) => hub.join(room, token);
  @override
  Future<List<String>> joinReadOnly(String room, String token, Map<String, Object?> ro) => hub.join(room, token, ro: ro);
  @override
  void anchor(String room, Map<String, Object?> grants) => hub.anchorRoom(room, grants);
  @override
  bool get takesReactions => hub.takesReactions;
  @override
  void sendReaction(String room, Uint8List bytes) => hub.sendReaction(room, bytes);
  @override
  Stream<({String room, String from, Uint8List bytes})> get reactionPackets => hub.roomReactions;
  @override
  void leave(String room) => hub.leave(room);
  @override
  void send(String room, Uint8List bytes) => hub.sendRoom(room, bytes);

  /// Sends [bytes] to the room and has the hub keep them for whoever joins later (HubCarrier.sendRoom's keep).
  void sendKept(String room, Uint8List bytes) => hub.sendRoom(room, bytes, keep: true);
  @override
  void look(String room, String token) => hub.look(room, token);
  @override
  void unlook(String room) => hub.unlook(room);
  @override
  Stream<RoomEvent> get events => hub.roomEvents;
  @override
  Stream<({String room, String from, Uint8List bytes})> get packets => hub.roomPackets;
  @override
  Stream<({String room, List<String> members})> get looks => hub.looks;
}

/// One other person's connection in a call: what WebRTC needs said between the two, said through the channel.
abstract class VoicePeer {
  /// This side's offer, as SDP.
  Future<String> makeOffer();

  /// Takes their offer; this side's answer, as SDP.
  Future<String> takeOffer(String sdp);
  Future<void> takeAnswer(String sdp);
  Future<void> addCandidate(Map<String, dynamic> candidate);
  Future<void> close();
}

/// Media whose connections say when they fail, and can be made to go through the relay alone (lib/voice/rtc.dart).
///
/// Matt, 2026-11-21: "Sometimes calls are not negotiating in voice chats and I can't connect to another person, if p2p
/// fails please connect over voice through the relay", then "Try to negotiate over the relay first". Where the hub
/// handed out a relay (relay/lib/turn.dart), a connection starts through it alone ([relayOnly]): that connects
/// wherever the relay itself can be reached, whatever the routers between the two. Where that fails ([onFailed]: no
/// way through, or not connected in time), the side that offered starts over once trying every path at once (direct,
/// and the relay too) (VoiceSession._failed). With no relay handed out it is the other way round: every path first,
/// then the relay alone if one has been handed out since.
abstract class FallbackMedia implements VoiceMedia {
  /// The connection to [id], made anew: [onCandidate] is told each way to connect it finds, to pass on to them.
  VoicePeer peerWith(String id, {required void Function(Map<String, dynamic> candidate) onCandidate, required void Function() onFailed, bool relayOnly = false});

  /// Whether a relay for calls was handed out (no point starting over through it otherwise).
  bool get hasRelay;
}

/// Media that can share this device's screen in a call (GMFB-27; lib/voice/rtc.dart). Apart from [VoiceMedia] so the
/// stand-ins in tests need not.
abstract class ScreenMedia {
  /// This device can capture its screen: a computer, or Android.
  bool get screenSupported;

  /// What can be shared on a computer: each screen and window, with a picture of it. Empty on a phone, where the
  /// system asks what to share itself.
  Future<List<ScreenSource>> screenSources();

  /// Starts sharing [source] (a screen or window from [screenSources]; the system's choice on a phone), or stops.
  /// [onEnded] is told if it stops from outside the app. False when nothing was started.
  Future<bool> setScreen(bool on, {String? source, void Function()? onEnded});

  /// The screen this device is sending while it shares, for its own preview.
  ValueListenable<MediaStream?> get localScreen;
}

/// The sound of what this device shares (GMFB-63), and the connections that send it: one to each viewer who asked
/// (lib/voice/screen_sound.dart says how it is asked for and by whom).
abstract class ShareSoundSource {
  /// A connection to [id], made anew, and its offer; null where it could not be made.
  Future<String?> offer(String id, {required List<Map<String, Object>> servers, required bool relayOnly});
  Future<bool> answer(String id, String sdp);
  Future<void> candidate(String id, Map<String, dynamic> c);
  Future<void> close(String id);

  /// Ends all of it: no connection left. The sound itself is the share's, and ends with it.
  Future<void> end();

  void Function(String id, Map<String, dynamic> candidate)? onCandidate;

  /// How a connection stands: `connected`, `failed`, `closed`, or anything between.
  void Function(String id, String state)? onState;
}

/// Media that can send what the computer plays with its shared screen (GMFB-63; lib/voice/screen_sound.dart). Apart
/// from [ScreenMedia] so the stand-ins in tests, and the builds from before it, need not.
abstract class ScreenSoundMedia {
  /// Whether this device can: a PC, and a Mac from macOS 14.4.
  Future<bool> screenSoundSupported();

  /// Whether the next share is to take the computer's sound too. Set before [ScreenMedia.setScreen] starts one.
  set screenWithSound(bool on);

  /// The sound of the share there is, and the connections that send it; null while it shares none.
  ShareSoundSource? get screenSound;
}

/// A screen or window that can be shared, as a computer lists them.
@immutable
class ScreenSource {
  const ScreenSource({required this.id, required this.name, required this.window, this.thumbnail});
  final String id;
  final String name;

  /// A window, not a whole screen.
  final bool window;

  /// A JPEG of it, where the system gave one.
  final Uint8List? thumbnail;
}

/// Media whose camera can be turned to the other side of a phone (GMFB-57, Kevin: "Add a button to flip camera on
/// mobile versions"; lib/voice/rtc.dart). Apart from [VoiceMedia] so the stand-ins in tests need not.
abstract class CameraMedia {
  /// This device has a front and a back camera to change between: an Android phone or an iPhone.
  bool get canFlipCamera;

  /// The camera is, or will next be, the one on the back: what it sees is not drawn mirrored. Kept while video is off,
  /// so turning video on again in the same call opens the camera it was.
  bool get backCamera;

  /// Changes to the other camera. The picture each connection sends stays the one it is, so nothing is asked of them.
  Future<void> flipCamera();
}

/// This device's microphone and camera, and the connections to the others (lib/voice/rtc.dart).
abstract class VoiceMedia {
  /// How loud each one is now, 0 to 1: `me` for this device's microphone, and each other member by id. What the
  /// call's faces ripple with while someone talks.
  ValueListenable<Map<String, double>> get levels;
  Future<void> start();
  Future<void> stop();
  set muted(bool on);
  set deafened(bool on);
  Future<void> setVideo(bool on);

  /// How loud [id] is played on this device, 0 to 2 (1 as they send it), and whether they are silenced for this
  /// device alone (Matt, 2026-11-15: "press and hold on a user to habe options like muting changing volume levels for
  /// that user").
  void setPeerVolume(String id, double volume);
  void setPeerMuted(String id, bool muted);
  VoicePeer peer(String id, {required void Function(Map<String, dynamic> candidate) onCandidate});
}

/// How far coming into a call has got ([VoiceSession.join], Voice.join): its chat's room being opened, the microphone
/// being started, the call's own room being joined on the relay server, and in.
enum JoinStep { room, microphone, relay, done }

/// Someone in a Discord voice channel a space is bridged to, as the bridge says (voice room message 'dc').
@immutable
class DiscordPerson {
  const DiscordPerson({required this.id, required this.name, this.speaking = false, this.muted = false, this.deafened = false, this.bot = false});
  final String id;
  final String name;
  final bool speaking, muted, deafened, bot;

  static DiscordPerson? fromJson(Object? j) {
    if (j is! Map || j['id'] is! String || j['name'] is! String) return null;
    return DiscordPerson(id: j['id'] as String, name: j['name'] as String, speaking: j['speaking'] == true, muted: j['muted'] == true, deafened: j['deafened'] == true, bot: j['bot'] == true);
  }
}

/// Someone in the call, as they said they are.
@immutable
class VoiceMember {
  const VoiceMember(this.id, {this.name = '', this.muted = false, this.video = false, this.screen = false, this.guest = false, this.username, this.notices = false, this.recording, this.agreed = const {}, this.declined = const {}, this.captions = false, this.hand = false, this.recordsVideo = false, this.pictured = const {}});
  final String id;
  final String name;

  /// Listening on a stage, they raised their hand to speak ('h' in their 'me', GMFB-29).
  final bool hand;

  /// Their app shows that a call is being recorded and asks before their voice is in it ('rs' in their 'me'). One that
  /// doesn't (an older build, the browser page, the Discord bridge) is never recorded: it can't have agreed.
  final bool notices;

  /// The recording they are making of this call, by its id; null while they make none ('r').
  final String? recording;

  /// The recordings of this call they said their voice may be in ('ry'), and those they said it may not ('rn').
  final Set<String> agreed, declined;

  /// The recording they are making takes the call's pictures too, cameras and shared screens ('rv' beside 'r';
  /// GMFB-42: "capture the webcams and screenshares in the call, not just the audio tracks").
  final bool recordsVideo;

  /// The recordings they said their picture may be in as well as their voice ('rp'): only ever ones they were asked
  /// about as "voice and video". A build from before GMFB-42 asked about the voice alone and says no 'rp', so its
  /// person is never in the picture.
  final Set<String> pictured;

  /// Whether their picture may be in the recording [id]: they said yes to voice and video, and haven't taken it back.
  bool picturedIn(String id) => pictured.contains(id) && agreed.contains(id) && !declined.contains(id);

  /// They want the call's words as captions ('cw'): each device that can then writes out its own voice.
  final bool captions;

  /// Their username on Uplink, where they have one and said it: to add them as a friend.
  final String? username;
  final bool muted;
  final bool video;

  /// What their picture shows is their screen, not their camera ('s' in their 'me', GMFB-27): drawn whole and large,
  /// never cropped or mirrored. [video] is said too while they share, so an older build still shows the picture.
  final bool screen;

  /// Joined from a browser by the link, with no username: a guest.
  final bool guest;
  VoiceMember copyWith({String? name, bool? muted, bool? video, bool? screen, bool? guest, String? username, bool? hand}) =>
      VoiceMember(id, name: name ?? this.name, muted: muted ?? this.muted, video: video ?? this.video, screen: screen ?? this.screen, guest: guest ?? this.guest, username: username ?? this.username, notices: notices, recording: recording, agreed: agreed, declined: declined, captions: captions, hand: hand ?? this.hand, recordsVideo: recordsVideo, pictured: pictured);

  /// With the recording and caption fields replaced whole (anything not given goes back to none).
  VoiceMember withRecording({required bool notices, String? recording, Set<String> agreed = const {}, Set<String> declined = const {}, bool captions = false, bool recordsVideo = false, Set<String> pictured = const {}}) =>
      VoiceMember(id, name: name, muted: muted, video: video, screen: screen, guest: guest, username: username, notices: notices, recording: recording, agreed: agreed, declined: declined, captions: captions, hand: hand, recordsVideo: recordsVideo && recording != null, pictured: pictured);
}

/// Media that can say how its connection to someone stands, so a call can mend one that broke ([VoiceSession] looks
/// every few seconds). lib/voice/rtc.dart's is one; a test's may be.
abstract class LinkedMedia {
  /// true: through. false: not through yet, or lost and trying by itself. null: no connection, or one that failed.
  bool? linkUp(String id);
}

/// Media that can play each person at a gain for where they stand in an open space, under their own volume
/// (lib/voice/open_space.dart). lib/voice/rtc.dart's is one; a test's may be.
abstract class PlacedMedia {
  /// 0 to 1; 1 takes it away.
  void setPlaceGain(String id, double gain);
}

/// Someone's sound as it arrives on this device: the received track carrying it, and a mark of the connection it came
/// on. A connection made again brings a track with the same id (the id is their microphone's), so the mark is what
/// says it is a new one.
typedef VoiceSound = ({String track, int link});

/// Media that can say which track each other member's sound arrives on, for a recording to tap
/// (lib/voice/recorder.dart; GMFB-52). lib/voice/rtc.dart's is one; a test's may be.
abstract class SoundMedia {
  /// Each other member's sound by their id, while there is a connection that has brought one.
  ValueListenable<Map<String, VoiceSound>> get sounds;
}

/// Media that can say which track each picture in the call is on, for a recording that takes video to draw
/// (lib/voice/recording_video.dart; GMFB-42). lib/voice/rtc.dart's is one; a test's may be.
abstract class PictureMedia {
  /// Each other member's picture by their id, their camera or their screen: the received track and its connection's
  /// mark, as [SoundMedia.sounds] says their sound. There from when their connection brings one, whether or not they
  /// are sending anything on it.
  Map<String, VoiceSound> get pictures;

  /// What this device sends as its picture now: its screen while it shares, else its camera while video is on; null
  /// while it sends none.
  ({String track, bool screen})? get ownPicture;

  /// Tells when [pictures] or [ownPicture] may have changed.
  Listenable get pictureChanges;
}

/// How long a call waits before it mends a connection ([VoiceSession]'s `mend`): short in a test.
@immutable
class MendTimes {
  const MendTimes({this.every = const Duration(seconds: 2), this.first = const Duration(seconds: 3), this.second = const Duration(seconds: 10), this.finding = const Duration(seconds: 15)});

  /// How often every connection is looked at.
  final Duration every;

  /// How long the one of two with the lower id leaves a missing connection before offering a new one, and how long the
  /// other does: the first has the first go, so the two don't offer each other at once; the second is for when the
  /// first never does (an older build, which only starts over once).
  final Duration first, second;

  /// How long a connection may be finding its way (or have lost it) before it is let go of and made again.
  final Duration finding;
}

/// Being in one channel: joined on the hub, a connection to each member, and what each says of themselves.
///
/// Who connects to whom: whoever comes in makes an offer to each who is already there; those there answer. So two
/// never offer each other at once. What is said (offers, answers, ways to connect, and each member's name, muted
/// and video) is sealed with the channel's key and sent to the room, naming who it is for where it is for one.
///
/// **Mending** (Matt, 2026-11-23: "add better reconnect logic to calls it seems like they can get hung up if one person
/// leaves or a new person joins everyone needs to re connect"). A call used to be set up once, as each came in, and
/// never again: a connection that broke later, an answer that never arrived, or this device's own connection to the
/// relay dropping for a moment (everyone else is told it went and lets go of it, and it was never offered to again)
/// left people in the call who could not hear each other until they left and came back. Now:
/// - Back in the room after the relay was lost ([_back]): every connection is made again, as on coming in.
/// - Every few seconds each member is looked at ([_mend]): where there is no working connection, one of the two
///   offers a new one (the lower id first, the other if it never does), again and again, further apart each time.
/// - Two offers that cross are settled by id, the higher's standing (0.12.19 let the lower's stand; against it the higher
///   gives way after a moment), not left to fail both ways. Which side mends first after a break (the lower id) is a
///   separate choice, kept as 0.12.19 has it, so against 0.12.19 the same side goes first and the two don't cross.
/// - What one member says is acted on in the order it was said, so a way to connect never overtakes its offer.
/// Nothing new is said on the wire: a fresh offer is marked `a`, which every build since the relay fallback takes.
class VoiceSession extends ChangeNotifier {
  VoiceSession({required this.channel, required this.route, required this.media, required this.name, this.username, this.kbps = 510, this.stereo = true, this.mend = const MendTimes()});

  /// How patiently connections are mended.
  final MendTimes mend;

  /// Opus as the settings ask (lib/voice/voice_settings.dart).
  final int kbps;
  final bool stereo;

  /// This device's username, said to the others so they can add it as a friend.
  final String? username;

  final VoiceChannel channel;
  final VoiceRoute route;
  final VoiceMedia media;

  /// This device's name, as the others see it.
  final String name;

  final Map<String, VoiceMember> members = {};

  /// Where the space is bridged to Discord: everyone in the Discord voice channel, as the bridge last said ('dc'), and
  /// the bridge's own id (a member, not shown as a person).
  List<DiscordPerson> discordPeople = const [];
  String? bridgeId;

  /// The Discord people's talking as levels (`dc:<id>`), for their faces to ripple as everyone's do.
  final ValueNotifier<Map<String, double>> discordLevels = ValueNotifier(const {});

  /// Who is not answered at all (a hangout's banned: lib/voice/hangout.dart).
  bool Function(String id)? refuse;

  /// Whether [id] (or this device, as [me]) listens on a stage (GMFB-29: HangoutRoom.listens): two who both listen
  /// have nothing to send each other, so they make no connection, and a stage holds many more listeners than a call
  /// where everyone connects to everyone. Null: everyone connects, as in any call.
  bool Function(String id)? listens;

  /// This device's hand raised, listening on a stage ([raiseHand]).
  bool hand = false;

  /// Raises or lowers this device's hand: said to everyone in the call, for whoever manages the stage.
  void raiseHand(bool on) {
    if (hand == on) return;
    hand = on;
    _sayState();
    notifyListeners();
  }

  /// Whether this device and [id] connect: unless both listen on a stage.
  bool _links(String id) {
    final l = listens;
    return l == null || !(l(route.me) && l(id));
  }

  /// The stage changed (someone brought up to speak, or sent back to listen): connections that are now wanted are made
  /// (the lower id offers, so two never offer each other at once), and those between two who both listen let go.
  ///
  /// Only those held apart by the stage ([_withheld]) are offered to here. Anyone else is offered to by whoever came
  /// into the call later ([join]): Voice asks this on every change in a space's call, so someone who had just come in,
  /// before their offer arrived, was offered to here as well whenever this side's id was the lower, and the two offers
  /// crossed. Whatever still has no connection after that is [_mendAll]'s.
  void relink() {
    if (!joined) return;
    for (final id in members.keys.toList()) {
      if (!_links(id)) {
        _withheld.add(id);
        // Nothing waits between two who no longer connect: neither an offer of theirs kept nor an answer to this one's.
        _dropKept(id);
        _awaiting.remove(id);
        _awaitingAgain.remove(id);
        if (_peers.containsKey(id)) {
          _offered.remove(id);
          unawaited(_peers.remove(id)?.close());
        }
      } else if (_withheld.contains(id)) {
        if (_peers.containsKey(id)) {
          _withheld.remove(id);
        } else if (route.me.compareTo(id) < 0) {
          _withheld.remove(id);
          unawaited(_offer(id));
        }
      }
    }
  }

  /// Those in the call this device has made no connection with because both listen on a stage ([_links]): when one is
  /// brought up to speak, [relink] connects them.
  final Set<String> _withheld = {};

  /// This device may not unmute (muted for everyone, or its role may not speak), or turn on video.
  bool locked = false, videoLocked = false;
  final Map<String, VoicePeer> _peers = {};
  final List<StreamSubscription<Object?>> _subs = [];
  bool muted = false, deafened = false, video = false, joined = false;

  /// This device is sharing its screen (GMFB-27): the picture it sends is the screen, in the camera's place.
  bool screen = false;

  /// And the computer's sound with it (GMFB-63; lib/voice/screen_sound.dart): said in 'me' as 'sa' beside 's'. Who
  /// else in the call says so of their own share is [sharingSound].
  bool screenSound = false;
  final Set<String> sharingSound = {};

  /// Told what someone said of a share's sound ('ss', lib/voice/screen_sound.dart).
  void Function(String from, Map<String, dynamic> what)? onShareSound;

  /// Says [what] of a share's sound to the one person it names (`to`).
  void sayShareSound(Map<String, Object?> what) => _say({'t': 'ss', ...what});

  /// When this device came into the call.
  DateTime? since;

  /// Told when another device of this identity came into the call and took it over ([join]); without it the session
  /// just leaves.
  Future<void> Function()? onMovedAway;
  bool _moving = false;

  /// This join's own mark, said with 'moved', offers and answers: so of two devices of one identity the one that came
  /// in later stays, and an answer meant for the other is never taken here.
  final String _join = NetCrypto.hex(NetCrypto.randomBytes(8));

  /// The join each other member's last offer came from ('j'): a new one is another of their devices, or them again.
  final Map<String, Object?> _offerJoin = {};

  // --- recording (Matt, 2026-11-19: "a "record call" plugin where it records the call to an MP4 with multiple named
  // audio tracks") ---------------------------------------------------------------------------------------------------
  // Said in 'me', which every build reads only the fields it knows of: 'rs' this build shows recording and asks, 'r'
  // the recording this device makes, 'ry' and 'rn' the recordings this device's person let their voice be in, or not.
  // A voice is in a recording only once its own device said yes: lib/voice/recorder.dart taps nobody else.

  /// The recording this device is making, by its id; null while none.
  String? recording;

  /// The recordings of this call this device's person said yes to, and no to.
  final Set<String> agreed = {}, declined = {};

  /// The recordings being made of this call by others, by their id, with who makes each.
  Map<String, String> get recordingsByOthers => {for (final m in members.values) if (m.recording != null) m.recording!: m.id};

  /// Recordings being made by others that this device's person hasn't answered yet.
  List<String> get unanswered => [for (final r in recordingsByOthers.keys) if (!agreed.contains(r) && !declined.contains(r)) r];

  // Pictures (GMFB-42): 'rv' beside 'r' says the recording takes cameras and shared screens too, and 'rp' lists the
  // recordings this device's person said yes to as "voice and video". Two new fields, not a wider meaning for 'ry':
  // a build from before this asked "Include your voice?" and its yes must never put a face in a file.

  /// Whether the recording this device is making takes pictures too. Set with [setRecording], for its whole length.
  bool recordingVideo = false;

  /// The recordings this device's person said their picture may be in as well as their voice.
  final Set<String> pictured = {};

  /// Whether the recording [id] takes pictures too: this device's own, or another member's that says so.
  bool takesVideo(String id) => recording == id ? recordingVideo : members.values.any((m) => m.recording == id && m.recordsVideo);

  /// Says this device is recording ([id]) or has stopped (null); [video]: it takes pictures as well as voices.
  void setRecording(String? id, {bool video = false}) {
    recording = id;
    recordingVideo = id != null && video;
    _sayState();
    notifyListeners();
  }

  // --- captions (Matt, 2026-11-19: "Live captions") ------------------------------------------------------------------
  // Each device writes out its own voice, where anyone in the call wants captions ('cw' in their state), and says the
  // words in the call's room ('cap': the words, and whether the line is done). An older build ignores both.

  /// This device's person wants the call's words shown.
  bool wantsCaptions = false;

  /// Whether anyone in the call wants captions: then this device writes out its own voice.
  bool get anyoneWantsCaptions => wantsCaptions || members.values.any((m) => m.captions);

  /// Told each caption said in the call: who, the words, and whether the line is done.
  void Function(String from, String words, bool done)? onCaption;

  /// Turns captions on or off for this device's person, and says so to the call.
  void setWantsCaptions(bool on) {
    wantsCaptions = on;
    _sayState();
    notifyListeners();
  }

  /// Told what someone watching a file together with the call did ('wt', lib/voice/watch_together.dart).
  void Function(String from, Map<String, dynamic> what)? onWatch;

  /// Says [what] of watching together to the call.
  void sayWatch(Map<String, Object?> what) => _say({'t': 'wt', ...what});

  /// Told a soundboard's sound someone in the call played ('sb', lib/voice/soundboard.dart): who, and its id.
  void Function(String from, String sound)? onSound;

  /// Says to the call that this device played the soundboard's sound [sound], for each device to play its own copy.
  void saySound(String sound) => _say({'t': 'sb', 's': sound});

  /// Told what someone said of the music played to the call ('mu', lib/voice/spotify.dart).
  void Function(String from, Map<String, dynamic> what)? onMusic;

  /// Says [what] of the music: to the call, or to the one person it names (`to`).
  void sayMusic(Map<String, Object?> what) => _say({'t': 'mu', ...what});

  /// Told what someone said of an open space's floor ('os': where they stand; 'osg': its groups;
  /// lib/voice/open_space.dart).
  void Function(String from, Map<String, dynamic> what)? onPlace;

  /// Says [what] of an open space's floor to the call.
  void sayPlace(Map<String, Object?> what) => _say(what);

  /// Says [words] of this device's voice to the call; [done]: the line is finished.
  void sayCaption(String words, {required bool done}) => _say({'t': 'cap', 'x': words.length > 600 ? words.substring(words.length - 600) : words, 'f': done});

  /// Answers whether this device's voice may be in the recording [id]; its picture too where the recording takes
  /// pictures, since that is what was then asked ("voice and video", lib/ui/recording_ui.dart).
  void answerRecording(String id, bool yes) {
    (yes ? agreed : declined).add(id);
    (yes ? declined : agreed).remove(id);
    yes && takesVideo(id) ? pictured.add(id) : pictured.remove(id);
    _sayState();
    notifyListeners();
  }

  /// How far coming into the call has got ([join]): what the screens say is being waited for while it is connecting
  /// (lib/voice/call_wait.dart).
  JoinStep step = JoinStep.room;

  /// Comes into the call: starts the microphone (and camera), joins the room on the hub, and offers a connection to
  /// everyone already there. Throws where the relay doesn't answer within 15 seconds.
  Future<void> join({bool withVideo = false}) async {
    video = withVideo;
    _gone = false;
    _step(JoinStep.microphone);
    await media.start();
    // Left while the microphone was starting (Leave pressed on "Connecting…", which is on the screen from the first
    // moment): the call is not come into after all, and the microphone that has just started is let go of. Coming in
    // went on regardless, and left this device in the call with nothing on the screen saying so.
    if (_gone) {
      await media.stop();
      return;
    }
    if (withVideo) await media.setVideo(true);
    _step(JoinStep.relay);
    _subs.add(route.packets.where((p) => p.room == channel.room).listen((p) => _heard(p.from, p.bytes)));
    _subs.add(route.events.where((e) => e.room == channel.room).listen(_event));
    // A call is joined now or said to have failed: a room asked for before the relay server is up waits for it
    // (HubCarrier.join), and a call should not.
    final there = await route.join(channel.room, channel.token).timeout(const Duration(seconds: 15), onTimeout: () => throw StateError('the relay server did not answer'));
    // Left while the relay server was answering: out of the room it has just been let into, and nothing kept.
    if (_gone) {
      route.leave(channel.room);
      for (final s in _subs) {
        await s.cancel();
      }
      _subs.clear();
      await media.stop();
      return;
    }
    joined = true;
    step = JoinStep.done;
    since = DateTime.now();
    Sounds.instance.play(UiSound.hangoutJoin);
    // This identity is in the call on this device now ('moved'): another of its devices already in it (a phone and its
    // computer, or two computers signed in to one account, are one identity: Voice.separateKey) leaves, as Discord does
    // when one joins from elsewhere, and everyone else lets go of any connection they had with this identity, so the
    // offers below make new ones. Said on every join: the relay never names one's own identity among those here, and to
    // whoever had no such connection it means nothing. Two devices answering the same offers would have broken the call.
    _say({'t': 'moved', 'at': since!.millisecondsSinceEpoch, 'j': _join});
    for (final id in there) {
      if (id == route.me || (refuse?.call(id) ?? false)) continue;
      members[id] = VoiceMember(id);
    }
    _sayState();
    for (final id in members.keys.toList()) {
      // On a stage, two who both listen make no connection (GMFB-29).
      _links(id) ? unawaited(_offer(id)) : _withheld.add(id);
    }
    _mendTimer?.cancel();
    _mendTimer = Timer.periodic(mend.every, (_) => _mendAll());
    notifyListeners();
  }

  /// Left ([leave]): what [join] looks at after each wait, to stop coming into a call that was left meanwhile.
  bool _gone = false;

  void _step(JoinStep to) {
    if (step == to) return;
    step = to;
    notifyListeners();
  }

  /// Goes out of the call: leaves the room, closes every connection and stops the microphone and camera. Safe to call
  /// when not joined.
  Future<void> leave() async {
    // Whatever of coming in is still under way stops where it is ([join]).
    _gone = true;
    if (joined) Sounds.instance.play(UiSound.hangoutLeave);
    if (joined) route.leave(channel.room);
    joined = false;
    _mendTimer?.cancel();
    _mendTimer = null;
    _lost = false;
    _awaiting.clear();
    _unwell.clear();
    _tries.clear();
    _said.clear();
    _awaitingAgain.clear();
    for (final id in _kept.keys.toList()) {
      _dropKept(id);
    }
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    for (final p in _peers.values) {
      await p.close();
    }
    _peers.clear();
    _offered.clear();
    _retried.clear();
    _relayed.clear();
    _withheld.clear();
    members.clear();
    sharingSound.clear();
    screenSound = false;
    await media.stop();
    notifyListeners();
  }

  /// [quiet]: no sound for it, as push to talk's own pressing and letting go are (lib/keys.dart).
  void setMuted(bool on, {bool quiet = false}) {
    if (!on && locked) return;
    if (on != muted && !quiet) Sounds.instance.play(on ? UiSound.mute : UiSound.unmute);
    muted = on;
    media.muted = on || deafened;
    _sayState();
    notifyListeners();
  }

  /// Deafened: nobody is heard, and the microphone is off too for as long as it lasts (the mute choice is kept).
  void setDeafened(bool on) {
    if (on != deafened) Sounds.instance.play(on ? UiSound.deafen : UiSound.undeafen);
    deafened = on;
    media.deafened = on;
    media.muted = muted || on;
    _sayState();
    notifyListeners();
  }

  Future<void> setVideo(bool on) async {
    if (on && videoLocked) return;
    video = on;
    await media.setVideo(on);
    _sayState();
    notifyListeners();
  }

  /// The camera this device sends is the one on its back (GMFB-57): its own preview is then not mirrored.
  bool get backCamera => media is CameraMedia && (media as CameraMedia).backCamera;

  /// Whether the Flip camera button is shown (GMFB-57): on a phone, while video is on and the screen is not being
  /// shared in its place.
  bool get canFlipCamera => video && !screen && media is CameraMedia && (media as CameraMedia).canFlipCamera;

  /// Changes between the front and the back camera (GMFB-57). Does nothing where it can't: a computer, video off, the
  /// screen shared. Nothing is said to the others: they are sent the same picture as before, from the other camera.
  Future<void> flipCamera() async {
    if (!canFlipCamera) return;
    try {
      await (media as CameraMedia).flipCamera();
    } catch (_) {
      // The camera would not change (one camera, or the system said no): the call goes on with the one it has.
    }
    notifyListeners();
  }

  /// Whether this device can share its screen at all: a computer or Android, with media that can capture one.
  bool get canShareScreen => media is ScreenMedia && (media as ScreenMedia).screenSupported;

  /// Shares this device's screen, or the window [source] on a computer (ScreenMedia.screenSources), or stops. Sent in
  /// the camera's place, so turning it on or off asks nothing of the connections; the camera comes back when it
  /// stops, if video is on. Held by the same rule as video (a role that may not show video may not share). False when
  /// it did not start: the person said no to the system's question, or there is nothing to capture.
  ///
  /// [sound]: with what the computer plays too, where this device can take it ([ScreenSoundMedia]); [screenSound]
  /// says whether it then is.
  Future<bool> setScreen(bool on, {String? source, bool sound = false}) async {
    final m = media is ScreenMedia ? media as ScreenMedia : null;
    if (m == null) return false;
    if (on && videoLocked) return false;
    if (!on && !screen) return true;
    final withSound = media is ScreenSoundMedia ? media as ScreenSoundMedia : null;
    withSound?.screenWithSound = on && sound;
    final started = await m.setScreen(on, source: source, onEnded: () {
      // Stopped from outside the app (the system's own Stop sharing, the window closed).
      if (!screen) return;
      screen = false;
      screenSound = false;
      _sayState();
      notifyListeners();
    });
    screen = on && started;
    screenSound = screen && withSound?.screenSound != null;
    _sayState();
    notifyListeners();
    return started;
  }

  void _event(RoomEvent e) {
    // The relay was lost: nothing can be said or heard in the room until it is back, which the carrier sees to by
    // itself, joining the room again and saying who is in it then.
    if (e.closed) {
      // Not lost but taken: this device's place on the relay went to another connection of the same device, a second
      // window of the app (GMFB-47). The two take each other's place turn about, so mending would bring this one back
      // into the call every few seconds, offering everyone a new connection each time. It goes, as when another device
      // takes the call over ('moved'), and stays out until its person joins again.
      if (e.replaced) {
        if (joined && !_moving) {
          _moving = true;
          unawaited(_movedAway());
        }
        return;
      }
      if (joined && !_lost) {
        _lost = true;
        notifyListeners();
      }
      return;
    }
    if (e.members != null) {
      if (joined && _lost) _back(e.members!);
      return;
    }
    // Another device of this identity is not someone else in the call.
    if (e.came == route.me || e.went == route.me) return;
    if (e.came != null) {
      if (refuse?.call(e.came!) ?? false) return;
      // They offer: they came in.
      if (!members.containsKey(e.came!)) {
        Sounds.instance.stopLoop(UiSound.ringOut);
        Sounds.instance.play(UiSound.someoneJoined);
      }
      members[e.came!] = VoiceMember(e.came!);
      // An offer of this device's still unanswered was to them as they were before: theirs is the one to answer now.
      _awaiting.remove(e.came);
      // They offer, unless the two of them both listen on a stage.
      if (!_links(e.came!)) _withheld.add(e.came!);
      _sayState();
    } else if (e.went != null) {
      final was = members.remove(e.went) != null;
      _forget(e.went!);
      unawaited(_peers.remove(e.went)?.close());
      // The last of the others gone: the call is over, said so; anyone else going is someone leaving.
      if (was) Sounds.instance.play(members.isEmpty ? UiSound.callEnded : UiSound.someoneLeft);
    }
    notifyListeners();
  }

  /// Everything remembered of the tries to connect to [id].
  void _forget(String id) {
    _offered.remove(id);
    _awaitingAgain.remove(id);
    _dropKept(id);
    _withheld.remove(id);
    _retried.remove(id);
    _relayed.remove(id);
    _awaiting.remove(id);
    _unwell.remove(id);
    _tries.remove(id);
    _offerJoin.remove(id);
  }

  // --- mending (the class's own words say why) -------------------------------------------------------------------------

  /// The relay is lost and this device is out of the room until it is back ([_back]).
  bool get reconnecting => _lost;
  bool _lost = false;
  Timer? _mendTimer;

  /// Offers of this device's not answered yet, with when each was made.
  final Map<String, DateTime> _awaiting = {};

  /// Since when there has been no working connection to each member, and how many times one was made again.
  final Map<String, DateTime> _unwell = {};
  final Map<String, int> _tries = {};

  /// What each member said, waiting its turn ([_heard]).
  final Map<String, Future<void>> _said = {};

  /// Those of [_awaiting] whose offer was marked again (`a`): a mending offer, which crosses another only with theirs.
  final Set<String> _awaitingAgain = {};

  /// An offer that crossed this device's own and was let wait, the higher id's standing ([_act], `offer`): the latest
  /// from each, the ways to connect said after it, and when this side gives way if its own is still not answered.
  final Map<String, Map<String, dynamic>> _kept = {};
  final Map<String, List<Map<String, dynamic>>> _keptIce = {};
  final Map<String, Timer> _keptUntil = {};

  /// The most ways to connect held with a kept offer from one sender.
  static const _keptIceMost = 64;

  void _dropKept(String id) {
    _kept.remove(id);
    _keptIce.remove(id);
    _keptUntil.remove(id)?.cancel();
  }

  /// Keeps [m], an offer from [from] crossing this device's own, for [_giveWay].
  void _keep(String from, Map<String, dynamic> m) {
    _kept[from] = m;
    _keptIce[from] = [];
    _keptUntil[from] ??= Timer(mend.first ~/ 2, () => _giveWay(from));
  }

  /// The offer kept from [from] while this device's own crossed it: where this one's is still not answered (0.12.19 and
  /// 0.12.18 let the higher id's go unanswered too, from the other side), it is given up and theirs answered, with the
  /// ways to connect they said after it. In turn with everything else they said ([_said]).
  void _giveWay(String from) {
    _keptUntil.remove(from);
    final turn = (_said[from] ?? Future<void>.value()).then((_) async {
      final offer = _kept.remove(from);
      final ice = _keptIce.remove(from) ?? const [];
      if (offer == null || !joined || _moving || !_awaiting.containsKey(from) || !_links(from)) return;
      _awaiting.remove(from);
      _awaitingAgain.remove(from);
      await _peers.remove(from)?.close();
      await _act(from, {...offer, 'a': 1});
      for (final c in ice) {
        try {
          await _act(from, c);
        } catch (_) {}
      }
    }).catchError((Object e) => debugPrint('voice: the offer kept from $from not taken: $e'));
    _said[from] = turn;
  }

  /// Back in the room after the relay was lost, with [there] in it now. While this device was gone everyone else was
  /// told it went and let go of their connection to it, so each is made again, as on coming in; whoever left meanwhile
  /// is let go of. (After the relay itself restarts everyone comes back in turn, each offering to those back before.)
  void _back(List<String> there) {
    _lost = false;
    final now = {for (final id in there) if (id != route.me && !(refuse?.call(id) ?? false)) id};
    for (final id in members.keys.toList()) {
      if (now.contains(id)) continue;
      members.remove(id);
      _forget(id);
      unawaited(_peers.remove(id)?.close());
    }
    for (final id in now) {
      members.putIfAbsent(id, () => VoiceMember(id));
    }
    _sayState();
    for (final id in members.keys.toList()) {
      if (!_links(id)) continue;
      _forget(id);
      unawaited(_peers.remove(id)?.close());
      unawaited(_offer(id, again: true));
    }
    notifyListeners();
  }

  /// How the connection to [id] stands: true through, false finding its way, null none or failed. Media that can't say
  /// counts a connection there is as through.
  bool? _up(String id) {
    if (!_peers.containsKey(id)) return null;
    final m = media;
    return m is LinkedMedia ? (m as LinkedMedia).linkUp(id) : true;
  }

  /// Looks at every member ([MendTimes.every]): where this device should be connected to one and is not, and has
  /// waited its turn, the connection is let go of and offered anew.
  void _mendAll() {
    if (!joined || _moving || _lost) return;
    final now = DateTime.now();
    _unwell.removeWhere((id, _) => !members.containsKey(id));
    for (final id in members.keys.toList()) {
      if (!_links(id) || (refuse?.call(id) ?? false)) {
        _unwell.remove(id);
        continue;
      }
      final up = _up(id);
      if (up == true) {
        // Through: the next time it breaks is a first time again.
        _unwell.remove(id);
        _tries.remove(id);
        _retried.remove(id);
        _awaiting.remove(id);
        continue;
      }
      final waited = now.difference(_unwell[id] ??= now);
      final tries = _tries[id] ?? 0;
      // The lower id has the first go; each try waits twice as long as the one before, up to eight times.
      final turn = (route.me.compareTo(id) < 0 ? mend.first : mend.second) * (1 << math.min(tries, 3));
      // One still finding its way is given its time first.
      if (waited < (up == false ? mend.finding + turn : turn)) continue;
      _tries[id] = tries + 1;
      _unwell[id] = now;
      _awaiting.remove(id);
      unawaited(_peers.remove(id)?.close());
      // Through the relay alone and through every path, turn about.
      final m = media;
      unawaited(_offer(id, relayOnly: m is FallbackMedia && m.hasRelay && tries.isEven, again: true));
    }
  }

  /// The connection to [id]: the one there is, or one made now whose candidates are said to them (`ice`).
  VoicePeer _peerFor(String id, {bool relayOnly = false}) {
    final had = _peers[id];
    if (had != null) return had;
    void cand(Map<String, dynamic> c) => _say({'t': 'ice', 'to': id, 'c': c});
    final m = media;
    late final VoicePeer made;
    made = m is FallbackMedia ? m.peerWith(id, onCandidate: cand, onFailed: () => _failed(id, made), relayOnly: relayOnly) : media.peer(id, onCandidate: cand);
    return _peers[id] = made;
  }

  /// Those this device offered to, and those it has started over with through the relay alone ([_failed]).
  final Set<String> _offered = {}, _retried = {};

  /// The connection to [id] found no way through ([FallbackMedia]). The side that offered starts over once, the other
  /// way: through every path where the first try was the relay alone, through the relay alone where it was every path
  /// (and a relay has been handed out since). The offer is marked `a` (again) so the other side lets go of its failed
  /// connection first, and `r` where it is the relay alone; the other side waits for it. A second failure is left as it
  /// is: they show in the call without sound, as before.
  void _failed(String id, VoicePeer which) {
    if (!joined || !identical(_peers[id], which)) return;
    if (!_offered.contains(id) || _retried.contains(id) || !members.containsKey(id)) return;
    final m = media;
    if (m is! FallbackMedia) return;
    final wasRelay = _relayed.contains(id);
    if (!wasRelay && !m.hasRelay) return;
    _retried.add(id);
    _peers.remove(id);
    unawaited(which.close());
    unawaited(_offer(id, relayOnly: !wasRelay, again: true));
  }

  /// Those whose connection this device offered through the relay alone.
  final Set<String> _relayed = {};

  /// An offer to [id]: through the relay alone first where there is one (Matt, 2026-11-21: "Try to negotiate over the
  /// relay first"), [relayOnly] said for a second try.
  Future<void> _offer(String id, {bool? relayOnly, bool again = false}) async {
    _offered.add(id);
    _awaiting[id] = DateTime.now();
    again ? _awaitingAgain.add(id) : _awaitingAgain.remove(id);
    final m = media;
    final relay = relayOnly ?? (m is FallbackMedia && m.hasRelay);
    relay ? _relayed.add(id) : _relayed.remove(id);
    final sdp = await _peerFor(id, relayOnly: relay).makeOffer();
    _say({'t': 'offer', 'to': id, 'sdp': highestOpus(sdp, kbps: kbps, stereo: stereo), 'j': _join, if (relay) 'r': 1, if (again) 'a': 1});
  }

  /// Says this device's state to the call ('me'): its name, muted (deafened counts), video, and the recording and
  /// caption fields above.
  void _sayState() => _say({
        't': 'me',
        'n': name,
        'm': muted || deafened,
        // Video is said while the screen is shared, so a build that knows nothing of sharing shows the picture.
        'v': video || screen,
        if (screen) 's': 1,
        if (screen && screenSound) 'sa': 1,
        if (username != null) 'u': username,
        'rs': 1,
        if (recording != null) 'r': recording,
        if (recording != null && recordingVideo) 'rv': 1,
        if (agreed.isNotEmpty) 'ry': [...agreed],
        if (declined.isNotEmpty) 'rn': [...declined],
        if (pictured.isNotEmpty) 'rp': [...pictured],
        if (wantsCaptions) 'cw': 1,
        if (hand) 'h': 1,
      });

  /// Sends [what] to the room, sealed with the channel's key. Nothing is sent before joining or after leaving.
  void _say(Map<String, Object?> what) {
    if (!joined) return;
    try {
      route.send(channel.room, NetCrypto.seal(channel.key, utf8.encode(jsonEncode(what))));
    } catch (_) {}
  }

  /// A packet from the room: opened with the channel's key (anything that doesn't open is dropped) and acted on by its
  /// kind `t`.
  Future<void> _heard(String from, Uint8List bytes) async {
    final clear = NetCrypto.open(channel.key, bytes);
    if (clear == null) return;
    Map<String, dynamic> m;
    try {
      m = (jsonDecode(utf8.decode(clear)) as Map).cast<String, dynamic>();
    } catch (_) {
      return;
    }
    // Said by another device of this identity: it took the call over ([join]), so this one goes. Nothing else it says is
    // for this device (an offer it makes is to the others, never to itself).
    if (from == route.me) {
      // Only for a join later than this one (two coming in at once: the later stays, and the earlier hears it).
      final at = (m['at'] as num?)?.toInt() ?? 0, mine = since?.millisecondsSinceEpoch ?? 0;
      final later = at > mine || (at == mine && '${m['j'] ?? ''}'.compareTo(_join) > 0);
      if (m['t'] == 'moved' && joined && !_moving && later) {
        _moving = true;
        unawaited(_movedAway());
      }
      return;
    }
    // Going, for the device that took over: what the others answer it is not for this one.
    if (_moving) return;
    final to = m['to'];
    if (to != null && to != route.me) return;
    if (refuse?.call(from) ?? false) {
      members.remove(from);
      unawaited(_peers.remove(from)?.close());
      return;
    }
    // One member's words are acted on in the order they were said: taking an offer waits on WebRTC, and a way to
    // connect said right behind it must not get in first. What goes wrong with one is no reason to drop the next.
    final turn = (_said[from] ?? Future<void>.value()).then((_) => _act(from, m)).catchError((Object e) => debugPrint('voice: ${m['t']} from $from not taken: $e'));
    _said[from] = turn;
    return turn;
  }

  /// Acts on what [from] said to this device ([_heard] opened it and saw it is for here).
  Future<void> _act(String from, Map<String, dynamic> m) async {
    if (!joined || _moving) return;
    switch (m['t']) {
      case 'dc':
        // The bridge to Discord saying who is in the Discord voice channel, and who is talking there.
        bridgeId = from;
        discordPeople = [for (final p in (m['people'] as List? ?? const [])) ?DiscordPerson.fromJson(p)];
        // The bridge says only who is talking, not how loudly: a talker's level is a fixed half.
        discordLevels.value = {for (final p in discordPeople) 'dc:${p.id}': p.speaking && !p.muted ? 0.5 : 0.0};
        notifyListeners();
      case 'me':
        final had = members[from] ?? VoiceMember(from);
        Set<String> ids(Object? l) => {for (final x in (l is List ? l : const [])) if (x is String) x};
        members[from] = had
            .copyWith(name: bareName('${m['n'] ?? ''}'), muted: m['m'] == true, video: m['v'] == true, screen: m['s'] == 1, guest: m['g'] == true, username: m['u'] is String ? m['u'] as String : null, hand: m['h'] == 1)
            .withRecording(notices: m['rs'] == 1, recording: m['r'] is String ? m['r'] as String : null, agreed: ids(m['ry']), declined: ids(m['rn']), captions: m['cw'] == 1, recordsVideo: m['rv'] == 1, pictured: ids(m['rp']));
        m['s'] == 1 && m['sa'] == 1 ? sharingSound.add(from) : sharingSound.remove(from);
        notifyListeners();
      case 'wt':
        onWatch?.call(from, m);
      case 'sb':
        if (m['s'] is String) onSound?.call(from, m['s'] as String);
      case 'mu':
        onMusic?.call(from, m);
      case 'ss':
        onShareSound?.call(from, m);
      case 'os' || 'osg':
        onPlace?.call(from, m);
      case 'cap':
        if (m['x'] is String) onCaption?.call(from, m['x'] as String, m['f'] == true);
      case 'offer':
        members.putIfAbsent(from, () => VoiceMember(from));
        // An offer from another join of theirs (another device, or the app opened again) is a new connection: the old
        // one goes first, whether or not 'moved' got here (an older build says none).
        final j = m['j'];
        // Both offered at once (each waits on the other's answer): the higher id's offer stands, and the other side
        // gives its own up and answers. Left alone, each tried to take an offer on a connection that had made one,
        // and neither connected. The higher's, because an app from 0.12.18 or before already in a space's call offers
        // back from relink to whoever comes in only where its id is the lower, and gives its own offer up when it
        // finds the newcomer's (the `j` below): the newcomer (a browser, always) keeps its offer and both connect at
        // once. 0.12.19 settles it the other way round (the lower's stands), so against it each would let the other's
        // wait: the higher keeps theirs ([_keep]) and gives way after a moment if its own is still not answered
        // ([_giveWay]). An offer marked again (`a`) is answered at once unless this side's own is a mending offer too:
        // then the two crossed as any two do.
        var crossed = false;
        if ((m['a'] != 1 || _awaitingAgain.contains(from)) && _awaiting.containsKey(from) && _peers.containsKey(from)) {
          if (route.me.compareTo(from) > 0) {
            _keep(from, m);
            return;
          }
          crossed = true;
        }
        _dropKept(from);
        if (_peers.containsKey(from) && j != null && _offerJoin[from] != j) await _peers.remove(from)?.close();
        // A connection that failed is still held here until something takes its place: this does.
        if (_peers.containsKey(from) && _up(from) == null) await _peers.remove(from)?.close();
        // Through the relay alone (the first try where there is one), and started over after no way through was
        // found (_failed, marked a; an older build marks a second try r alone): the failed connection goes.
        // Where both offered at once, this side's own connection is not let go of for a first try.
        final relay = m['r'] == 1;
        final again = crossed || m['a'] == 1 || (relay && !_offered.contains(from));
        // They offered: this side answers, and waits for them to start over if it fails.
        if (!again || crossed) _offered.remove(from);
        if (again) await _peers.remove(from)?.close();
        _awaiting.remove(from);
        _awaitingAgain.remove(from);
        // They are making the connection: this side's count of its own tries starts over.
        _unwell.remove(from);
        _offerJoin[from] = j;
        final answer = await _peerFor(from, relayOnly: relay).takeOffer('${m['sdp']}');
        _say({'t': 'answer', 'to': from, 'sdp': highestOpus(answer, kbps: kbps, stereo: stereo), 'j': ?j});
        // Said again for the newcomer, who may have joined after it was said.
        _sayState();
      case 'moved':
        // They came in on another of their devices: the connection to the one they left goes, and their offer makes a
        // new one.
        _awaiting.remove(from);
        unawaited(_peers.remove(from)?.close());
        notifyListeners();
      case 'answer':
        // One meant for another device of this identity's (its offer's mark, not this one's) is not taken here.
        final j = m['j'];
        if (j != null && j != _join) return;
        // One for an offer since given up (theirs stood, or a new one was made) has nothing waiting for it.
        if (_awaiting.remove(from) == null) return;
        _awaitingAgain.remove(from);
        // Answered: an offer of theirs kept meanwhile is let go, and the ways to connect held with it are this
        // connection's as much as that one's (which of theirs said them isn't said): given to it.
        final held = _keptIce[from] ?? const [];
        _dropKept(from);
        await _peers[from]?.takeAnswer('${m['sdp']}');
        for (final c in held) {
          try {
            await _peers[from]?.addCandidate((c['c'] as Map).cast<String, dynamic>());
          } catch (_) {}
        }
      case 'ice':
        // Said after an offer kept for now ([_keep]): held with it.
        final held = _keptIce[from];
        if (held != null && m['c'] is Map) {
          // A handful is all a connection says; past [_keptIceMost] the rest is not kept.
          if (held.length < _keptIceMost) held.add(m);
          return;
        }
        if (m['c'] is Map) await _peerFor(from).addCandidate((m['c'] as Map).cast<String, dynamic>());
    }
  }

  Future<void> _movedAway() async {
    final told = onMovedAway;
    if (told != null) return told();
    await leave();
  }

  @override
  void dispose() {
    unawaited(leave());
    super.dispose();
  }
}

/// How each copy of this device's picture is sent, by how many others are in the call (tool/voicebench, 2026-11-15:
/// each connection encodes its own copy, so at 1080p for everyone three or more people fell to a frame a second).
/// Alone with one other it is the camera's full 1080p at up to 12 Mb/s; with more, a smaller copy to each, and under
/// load a little resolution goes before the frame rate does. Sound is always Opus at 510 kb/s.
({double scale, int bitrate, String preference}) videoFor(int others) => switch (others) {
      <= 1 => (scale: 1.0, bitrate: 12000000, preference: 'balanced'),
      2 => (scale: 1.5, bitrate: 4000000, preference: 'balanced'),
      3 || 4 => (scale: 2.0, bitrate: 2000000, preference: 'balanced'),
      _ => (scale: 3.0, bitrate: 1000000, preference: 'balanced'),
    };

/// [sdp] with Opus asked for at its highest: full band at 48 kHz, stereo both ways, 510 kb/s, constant bit rate,
/// no discontinuous transmission, with forward error correction kept for lost packets.
String highestOpus(String sdp, {int kbps = 510, bool stereo = true, bool fec = true}) {
  final lines = sdp.split('\r\n');
  final opus = RegExp(r'^a=rtpmap:(\d+) opus/48000', caseSensitive: false);
  final payloads = {for (final l in lines) if (opus.hasMatch(l)) opus.firstMatch(l)!.group(1)!};
  if (payloads.isEmpty) return sdp;
  final want = {'minptime': '10', 'useinbandfec': fec ? '1' : '0', 'stereo': stereo ? '1' : '0', 'sprop-stereo': stereo ? '1' : '0', 'maxaveragebitrate': '${kbps * 1000}', 'maxplaybackrate': '48000', 'cbr': '1', 'usedtx': '0'};
  final out = <String>[];
  final fmtpDone = <String>{};
  // Each Opus payload's fmtp line is rewritten with these on top of what it had; a payload with no fmtp line gets one
  // straight after its rtpmap.
  for (var i = 0; i < lines.length; i++) {
    final l = lines[i];
    final fmtp = RegExp(r'^a=fmtp:(\d+) (.*)$').firstMatch(l);
    if (fmtp != null && payloads.contains(fmtp.group(1))) {
      final params = <String, String>{};
      for (final kv in fmtp.group(2)!.split(';')) {
        final at = kv.indexOf('=');
        if (at > 0) params[kv.substring(0, at).trim()] = kv.substring(at + 1).trim();
      }
      params.addAll(want);
      out.add('a=fmtp:${fmtp.group(1)} ${params.entries.map((e) => '${e.key}=${e.value}').join(';')}');
      fmtpDone.add(fmtp.group(1)!);
      continue;
    }
    out.add(l);
    final rtp = opus.firstMatch(l);
    if (rtp != null && !lines.any((x) => x.startsWith('a=fmtp:${rtp.group(1)} '))) {
      out.add('a=fmtp:${rtp.group(1)} ${want.entries.map((e) => '${e.key}=${e.value}').join(';')}');
      fmtpDone.add(rtp.group(1)!);
    }
  }
  return out.join('\r\n');
}
