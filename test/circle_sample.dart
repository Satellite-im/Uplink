/// A made-up circle with something going on in it, for the tests' pictures of a circle's list: a texting space with
/// new messages, a voice space with three talking, two Files spaces under a heading (one with files counted), and
/// quieter ones. Nothing in it is real or sent anywhere.
library;

import 'package:flutter/widgets.dart';
import 'package:ghost_messaging/circles/circle.dart';
import 'package:ghost_messaging/ui/circles/circle_view.dart';
import 'package:ghost_messaging/voice/voice.dart';

final sampleCircle = Circle(
  seed: '5' * 64,
  owner: '',
  manifest: CircleManifest(owner: '', version: 1, name: 'Night Owls', hue: 'indigo', icon: 'sparkles', spaces: const [
    CircleSpace(seed: '5151515151515151515151515151515151515151515151515151515151515151', name: 'General', kind: SpaceKind.text),
    CircleSpace(seed: '5252525252525252525252525252525252525252525252525252525252525252', name: 'Lounge', order: 1),
    CircleSpace(seed: '5353535353535353535353535353535353535353535353535353535353535353', name: 'Announcements', kind: SpaceKind.text, order: 2),
    CircleSpace(seed: '5454545454545454545454545454545454545454545454545454545454545454', name: 'Study room', order: 3, section: 'Rooms'),
    CircleSpace(seed: '5555555555555555555555555555555555555555555555555555555555555556', name: 'Movie night', order: 4, section: 'Rooms'),
    CircleSpace(seed: '5656565656565656565656565656565656565656565656565656565656565656', name: 'Drop box', kind: SpaceKind.files, order: 5, section: 'Sharing'),
    CircleSpace(seed: '5757575757575757575757575757575757575757575757575757575757575757', name: 'Photos', kind: SpaceKind.files, order: 6, section: 'Sharing'),
  ]),
);

/// The sample circle as its list draws it. [onOpen] and the rest do nothing unless given.
CircleView sampleCircleView({
  bool wide = false,
  String? selected,
  bool canEdit = true,
  void Function(CircleSpaceView space)? onOpen,
  void Function(CircleSpaceView space)? onSpaceMenu,
  void Function({String? section})? onNewSpace,
  VoidCallback? onBack,
  Circle? circle,
}) {
  final night = DateTime(2026, 11, 17, 21, 40);
  DateTime ago(int minutes) => night.subtract(Duration(minutes: minutes));
  const said = {
    'General': ('Maya: Popcorn is on me', 2),
    'Lounge': ('Sam: Mic check, can you hear me?', 6),
    'Announcements': ('You: Movie night moves to Friday', 180),
    'Movie night': ('Theo: Vote for the film by tonight', 40),
    'Drop box': ('Sam: Added flashcards.zip', 11),
  };
  const unread = {'General': 3, 'Movie night': 1, 'Drop box': 2};
  const talking = {'Lounge': ['Maya', 'Theo', 'Sam']};
  const files = {'Drop box': 12, 'Photos': 48};
  final c = circle ?? sampleCircle;
  return CircleView(
    circle: c,
    spaces: [
      for (final s in c.spaces)
        CircleSpaceView(
          space: s,
          channel: c.channelOf(s),
          unread: unread[s.name] ?? 0,
          lastMessage: said[s.name]?.$1,
          lastAt: said[s.name] == null ? null : ago(said[s.name]!.$2),
          inVoice: talking[s.name] ?? const [],
          files: files[s.name],
        ),
    ],
    selected: selected,
    wide: wide,
    canEdit: canEdit,
    online: 5,
    onOpen: onOpen ?? (_) {},
    onSpaceMenu: onSpaceMenu,
    onNewSpace: onNewSpace ?? ({String? section}) {},
    onSettings: () {},
    onInvite: () {},
    onBack: onBack ?? () {},
    onMenu: () {},
  );
}
