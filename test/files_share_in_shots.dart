// The "Add … to" sheet drawn in every look (test/themes_test.dart), over the conversations as a share from another app
// brings it up, and the hint over a Mac's window while files are dragged onto it with no Files space showing. Matt,
// 2026-11-17: "Finish the missing pieces that went unfinished" (of Circles and Files spaces, released in 0.9.2).
import 'package:flutter/widgets.dart';
import 'package:ghost_messaging/circles/circle.dart';
import 'package:ghost_messaging/ui/files_space/share_in.dart';
import 'package:ghost_messaging/ui/shell.dart';
import 'package:ghost_messaging/voice/voice.dart';

import 'themes_test.dart' show ThemeScreen;

const _ownSeed = '6161616161616161616161616161616161616161616161616161616161616161';
const _owlsSeed = '6262626262626262626262626262626262626262626262626262626262626262';
const _bookSeed = '6363636363636363636363636363636363636363636363636363636363636363';
const _spaces = [
  VoiceChannel(seed: _ownSeed, name: 'Hand-ins', kind: SpaceKind.files),
  VoiceChannel(seed: '6464646464646464646464646464646464646464646464646464646464646464', name: 'Drop box', kind: SpaceKind.files, circle: _bookSeed),
  VoiceChannel(seed: '6565656565656565656565656565656565656565656565656565656565656565', name: 'Photos', kind: SpaceKind.files, circle: _owlsSeed),
];
final _owls = Circle(seed: _owlsSeed, owner: '', manifest: CircleManifest(owner: '', version: 1, name: 'Night Owls', hue: 'indigo', icon: 'sparkles'));
final _book = Circle(seed: _bookSeed, owner: '', manifest: CircleManifest(owner: '', version: 1, name: 'Book Club', hue: 'amber', icon: 'book'));

const _files = [
  IncomingFile(source: 'content://shots/1', name: 'Sunset at the pier.jpg', size: 3200000, mime: 'image/jpeg'),
  IncomingFile(source: 'content://shots/2', name: 'Q3 report.pdf', size: 2100000, mime: 'application/pdf'),
  IncomingFile(source: 'content://shots/3', name: 'budget 2027.xlsx', size: 84000),
  IncomingFile(source: 'content://shots/4', name: 'voice note.m4a', size: 1400000),
];

/// The list, with the sheet brought up over it once it is drawn.
class _SharedOver extends StatefulWidget {
  const _SharedOver();
  @override
  State<_SharedOver> createState() => _SharedOverState();
}

class _SharedOverState extends State<_SharedOver> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      showAddToSheet(context, files: _files, spaces: _spaces, onChoose: (_) {}, circleOf: (c) => switch (c.circle) { _owlsSeed => _owls, _bookSeed => _book, _ => null });
    });
  }

  @override
  Widget build(BuildContext context) => const AppShell();
}

final shareInThemeScreens = <ThemeScreen>[
  ThemeScreen('files-share-in', () => const _SharedOver()),
  ThemeScreen('files-drop-hint', () => const Stack(fit: StackFit.expand, children: [AppShell(), IncomingDropHint()]), size: ThemeScreen.wide),
];
