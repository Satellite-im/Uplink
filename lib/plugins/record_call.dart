/// Record call: a call recorded to one MP4, its first track everyone together and then a track of each voice, named
/// for them (Matt, 2026-11-19: "I'd like to have a "record call" plugin where it records the call to an MP4 with
/// multiple named audio tracks"). The work is lib/voice/recorder.dart's; this puts it in a call's menu.
///
/// A plugin a whole circle can hold: in a circle's spaces it is there when the circle's owner or an admin has turned
/// it on (Circle settings › Plugins), for everyone in the circle; elsewhere when it is added here. Whatever is on,
/// everyone in a call being recorded is told and asked (lib/ui/recording_ui.dart), and only voices whose own device
/// said yes are in it.
///
/// **In the space's header** (Matt, 2026-11-19: "add icons in the compose window or header depending on what makes
/// sense for plugins like the recording plugin"): Record, and Stop in red while recording, beside the space's settings
/// while this device is in its call; the call's menu still has them and Recordings.
///
/// **Saved to the circle** ("allow for changing settings like save location (expect saving to have at least one file
/// space in a circle we'll save to a folder in a given space within the circle)"): a recording made in a circle's space
/// goes up into a folder of one of the circle's Files spaces, as well as staying on the device. Which space and which
/// folder are the circle's choice (Circle settings › Plugins › Record call, kept with the plugin in the manifest:
/// `space`, `folder`); until it chooses, the first Files space and a folder named Recordings. With no Files space, or
/// no right to add files there, it stays on the device and says why.
///
/// **With video** (GMFB-42: "capture the webcams and screenshares in the call, not just the audio tracks"; Matt,
/// 2026-11-23: "One composed video"): on a Mac or a Windows PC the recording can have the call's cameras and shared screens in it as
/// one track of video (lib/voice/recording_video.dart). Whether it does is chosen as it starts ([startChoices]): with
/// video where the device can, or the voices alone. Everyone is asked once, about both.
library;

import 'dart:io';

import '../art/app_icon.dart';
import '../art/lucide.g.dart';
import '../circles/circles.dart';
import '../files/files_store.dart';
import '../net/file_seal.dart';
import '../ui/recording_ui.dart';
import '../voice/recorder.dart';
import '../voice/voice.dart';
import 'plugin.dart';

/// Where a circle's recordings go: one of its Files spaces, and a folder in it.
typedef RecordSaveTo = ({CircleSpace space, VoiceChannel channel, String folder});

class RecordCallPlugin extends GhostPlugin {
  const RecordCallPlugin();

  /// The folder a circle's recordings go into until it names one.
  static const defaultFolder = 'Recordings';

  /// Where [c]'s recordings go: the Files space and folder it chose, else its first Files space and [defaultFolder];
  /// null where it has no Files space.
  static RecordSaveTo? saveToIn(Circle c) {
    final files = [for (final s in c.spaces) if (s.kind == SpaceKind.files) s];
    if (files.isEmpty) return null;
    final choices = c.manifest.plugins['recordcall'] ?? const <String, Object?>{};
    final chosen = files.where((s) => s.seed == choices['space']).firstOrNull ?? files.first;
    return (space: chosen, channel: c.channelOf(chosen), folder: SpaceFile.cleanFolder(choices['folder']) ?? defaultFolder);
  }

  /// Puts [r] into its circle's Files space, where it was made in a circle's space; says where it went, or why it
  /// stayed on this device; null outside a circle.
  static String? saveInCircle(Recording r) {
    final circle = Circles.instance.all.where((c) => c.spaces.any((s) => s.seed == r.seed)).firstOrNull;
    if (circle == null) return null;
    final to = saveToIn(circle);
    if (to == null) return 'Kept on this device: ${circle.name} has no Files space to save it in.';
    final files = FilesStore.instance;
    if (!files.canUpload(to.channel)) return 'Kept on this device: you can\'t add files to ${to.space.name}.';
    final why = tooBigFor(files.of(to.channel).info, File(r.path).existsSync() ? File(r.path).lengthSync() : 0, to.space.name);
    if (why != null) return why;
    files.upload(to.channel, [r.path], folder: to.folder);
    return 'Saving to ${to.space.name} › ${to.folder}';
  }

  /// Why a recording of [size] bytes can't go into the Files space named [space], as far as is known of it ([info]:
  /// the most one file may be, and the room left); null where it can, or nothing is known yet. A recording with video
  /// is big, about half a gigabyte for half an hour (GMFB-42): said as the recording stops, in the same words that say
  /// where it went, rather than left as an upload that failed in a list nobody is looking at.
  static String? tooBigFor(FilesInfo? info, int size, String space) {
    if (info == null || size <= 0) return null;
    final sealed = FileSeal.sealedSize(size);
    if (info.maxFile > 0 && sealed > info.maxFile) return 'Kept on this device: at ${fileSize(size)} it is too big for $space, where a file can be up to ${fileSize(info.maxFile)}.';
    if (info.quota > 0 && info.used + sealed > info.quota) return 'Kept on this device: $space has no room left for its ${fileSize(size)}.';
    return null;
  }

  /// The ways to start a recording, the one a plain press gives first (GMFB-42; Matt, 2026-11-23): where the device
  /// can take video ([video]: CallRecorder.videoSupported, a Mac), with it, or the voices alone; elsewhere the one
  /// way there has always been.
  static List<({String label, LucideIcon icon, bool video})> startChoices({required bool video}) => video
      ? const [(label: 'Record voice and video', icon: Lucide.circleDot, video: true), (label: 'Record voice only', icon: Lucide.mic, video: false)]
      : const [(label: 'Record this call', icon: Lucide.circleDot, video: false)];

  /// Starts a recording, with video where [video], and says how it went: why not, or what everyone is being asked.
  static Future<String> _start(bool video) async {
    final rec = CallRecorder.instance;
    final why = await rec.start(video: video);
    if (why != null) return why;
    if (rec.recordingVideo) return 'Recording voice and video. Everyone is asked whether they may be in it.';
    if (video) return 'Recording voices only: the video couldn\'t be started. Everyone is asked whether their voice may be in it.';
    return 'Recording. Everyone is asked whether their voice may be in it.';
  }

  /// Its notes in a space's chat as cards (Matt, 2026-11-19: "use icons for starting and stopping recording and allow
  /// plugins to render messages like these as cards with iconography and details"): "started" on red, as it is going
  /// on; "stopped" with how long, how many voices and where it went.
  @override
  PluginChatCard? card(PluginChatNote note, {required bool mine}) {
    final by = mine ? 'You' : (note.details['by']?.trim().isNotEmpty ?? false ? note.details['by']!.trim() : 'Someone');
    switch (note.kind) {
      case 'started':
        return PluginChatCard(
          icon: Lucide.circleDot,
          alert: true,
          title: note.details['video'] == '1' ? '$by started recording, with video' : '$by started recording',
          detail: note.details['video'] == '1'
              ? 'Everyone in the call is asked first. Only people who say yes are heard or seen in it.'
              : 'Everyone in the call is asked first. Only voices whose owners say yes are in it.',
        );
      case 'stopped':
        final seconds = int.tryParse(note.details['seconds'] ?? '');
        final voices = int.tryParse(note.details['voices'] ?? '');
        final saved = note.details['savedTo'] ?? '';
        return PluginChatCard(
          icon: Lucide.circleStop,
          title: '$by stopped recording',
          detail: saved,
          facts: [
            if (seconds != null) (Lucide.clock, recordingLength(seconds)),
            if (voices != null && voices > 0) (Lucide.users, voices == 1 ? '1 voice' : '$voices voices'),
            if (note.details['video'] == '1') (Lucide.video, 'MP4, video and a track each') else (Lucide.audioLines, 'MP4, a track each'),
          ],
        );
    }
    return null;
  }

  /// [seconds] as a recording's length: "45 s", "12 min", "1 h 5 min".
  static String recordingLength(int seconds) {
    if (seconds < 60) return '$seconds s';
    final m = (seconds / 60).round();
    if (m < 60) return '$m min';
    return m % 60 == 0 ? '${m ~/ 60} h' : '${m ~/ 60} h ${m % 60} min';
  }

  @override
  String get id => 'recordcall';

  @override
  String get name => 'Record call';

  @override
  String get description => 'Record a call to one file with a track for each voice, named. Only people who say yes are in it.';

  @override
  LucideIcon get icon => Lucide.circleDot;

  @override
  bool get onByDefault => false;

  @override
  String get hue => 'coral';

  @override
  PluginShelf get shelf => PluginShelf.tools;

  @override
  String get tagline => 'A track for each voice, named, in one MP4.';

  @override
  String get pitch => 'Record a call to one MP4: everyone together, then each voice on its own named track.';

  @override
  List<String> get adds => const [
        'Record and Stop in the space\'s header while you\'re in its call',
        'On a Mac, the call\'s cameras and shared screens too, as one video',
        'In a circle, saved into a folder of one of its Files spaces',
        'A red line over the call for everyone while it records',
        'Each person asked first; only those who say yes are in it',
        'Recordings kept on this device, to play, share or send to the space',
      ];

  @override
  List<PluginReach> get reaches => const [
        PluginReach(Lucide.mic, 'The voices in a call, on this device', 'Only of people whose own app said yes, and yours while you record.'),
        PluginReach(Lucide.hardDrive, 'Recordings kept on this device', 'In a circle, also saved to the Files space it chose, sealed for its members. Nothing else is uploaded unless you send it.'),
      ];

  @override
  Set<PluginScope> get scopes => const {PluginScope.device, PluginScope.circle};

  @override
  List<SlotFill> get slots => [
        // In the space's header while in its call: Record, or Stop in red.
        Slots.spaceHeader.fill((place, prefs) {
          if (!CallRecorder.supported || !place.voice || !place.inCall) return const [];
          final rec = CallRecorder.instance;
          if (rec.finishing) return const [];
          return [
            // One button: the first way of starting, with video where the device can. The call's menu has the other.
            if (rec.recording == null)
              for (final c in startChoices(video: CallRecorder.videoSupported).take(1)) PluginAction(label: c.label, icon: c.icon, run: (host) async => host.say(await _start(c.video)))
            else
              PluginAction(label: 'Stop recording', icon: Lucide.circleStop, danger: true, run: (host) async => host.say(_stopped(await rec.stop()))),
          ];
        }),
        Slots.callControls.fill((place, prefs) {
          if (!CallRecorder.supported) return const [];
          final rec = CallRecorder.instance;
          return [
            if (rec.recording == null && !rec.finishing)
              for (final c in startChoices(video: CallRecorder.videoSupported)) PluginAction(label: c.label, icon: c.icon, run: (host) async => host.say(await _start(c.video)))
            else if (rec.recording != null)
              PluginAction(
                label: 'Stop recording',
                icon: Lucide.circleStop,
                danger: true,
                run: (host) async {
                  host.say(_stopped(await rec.stop()));
                },
              ),
            PluginAction(label: 'Recordings', icon: Lucide.audioLines, run: (host) => host.present((_) => const RecordingsScreen())),
          ];
        }),
      ];

  /// What is said when a recording stops: where it went.
  static String _stopped(Recording? r) => r == null ? 'The recording couldn\'t be saved' : (CallRecorder.instance.savedTo ?? 'Recording saved in Recordings');

  @override
  PluginSettingsPage? get settingsPage => null;
}
