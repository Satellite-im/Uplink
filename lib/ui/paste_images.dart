import 'dart:async';
import '../platform_info.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../desktop/platform.dart';

/// A picture pasted into a message field on a computer (Matt, 2026-11-16: "add the ability to paste images into the
/// chatbar on desktop"; 2026-11-20: "pasting a screenshot into the compose bar isn't adding attachements"): a screenshot,
/// a picture copied from a page, an image file copied in the Finder. It goes to [onImage] as a file, as one chosen with
/// the picker would; words on the clipboard are pasted as ever.
///
/// - Mac: the Edit menu's Paste holds ⌘V and macOS hands a menu's key to the menu before the app, so a key binding here
///   never saw it. The window looks at ⌘V itself (macos/Runner/MainFlutterWindow.swift) while a field wrapped in this
///   has the cursor, and sends the picture over "ghost_desktop/paste"; this gives it to the field that has the cursor.
/// - Windows and Linux: Ctrl+V reaches the app, so it is caught here, the picture asked for (clipboard.cpp), and the
///   words pasted where there is none.
/// - A phone: nothing (its keyboard's own picture insert is another matter).
///
/// Every message field uses it: a conversation of texts, a network's chat, a space's chat.
class PasteImages extends StatefulWidget {
  const PasteImages({super.key, required this.focusNode, required this.onImage, this.enabled = true, required this.child});

  /// The field's own focus: a picture goes to the field the cursor is in.
  final FocusNode focusNode;

  /// A picture pasted: its path.
  final void Function(String path) onImage;

  /// Whether it takes a picture now (false while it holds as many as it may, or is being edited): words still paste.
  final bool enabled;
  final Widget child;

  static const _channel = MethodChannel('ghost_desktop/paste');
  static final _fields = <_PasteImagesState>[];
  static bool _listening = false;
  static bool _told = false;

  static bool get _mac => !kIsWeb && PlatformInfo.isMacOS;
  static bool get _otherDesktop => !kIsWeb && (PlatformInfo.isWindows || PlatformInfo.isLinux);

  /// The Mac window told whether a field that takes pictures has the cursor, once a change.
  static void _tell() {
    if (!_mac) return;
    final on = _fields.any((f) => f._takes);
    if (on == _told) return;
    _told = on;
    unawaited(_channel.invokeMethod('target', {'on': on}).catchError((_) => null));
  }

  static void _listen() {
    if (!_mac || _listening) return;
    _listening = true;
    _channel.setMethodCallHandler((call) async {
      final path = call.arguments is Map ? (call.arguments as Map)['path'] : null;
      if (call.method != 'image' || path is! String) return null;
      _fields.where((f) => f._takes).lastOrNull?.widget.onImage(path);
      return null;
    });
  }

  /// For a test: as the Mac window would, a picture pasted at [path] into the field that has the cursor.
  @visibleForTesting
  static bool pastedForTest(String path) {
    final f = _fields.where((f) => f._takes).lastOrNull;
    f?.widget.onImage(path);
    return f != null;
  }

  @override
  State<PasteImages> createState() => _PasteImagesState();
}

class _PasteImagesState extends State<PasteImages> {
  bool get _takes => widget.enabled && widget.focusNode.hasFocus;

  @override
  void initState() {
    super.initState();
    PasteImages._fields.add(this);
    PasteImages._listen();
    widget.focusNode.addListener(PasteImages._tell);
    PasteImages._tell();
  }

  @override
  void didUpdateWidget(PasteImages old) {
    super.didUpdateWidget(old);
    if (old.focusNode != widget.focusNode) {
      old.focusNode.removeListener(PasteImages._tell);
      widget.focusNode.addListener(PasteImages._tell);
    }
    PasteImages._tell();
  }

  @override
  void dispose() {
    widget.focusNode.removeListener(PasteImages._tell);
    PasteImages._fields.remove(this);
    PasteImages._tell();
    super.dispose();
  }

  /// The paste keys: a picture on the clipboard goes to [PasteImages.onImage]; anything else is pasted as words.
  Future<void> _paste() async {
    final picture = widget.enabled ? await MacPlatform.pasteImage() : null;
    if (!mounted) return;
    if (picture != null) {
      widget.onImage(picture);
      return;
    }
    final at = widget.focusNode.context;
    if (at != null && at.mounted) Actions.maybeInvoke(at, const PasteTextIntent(SelectionChangedCause.keyboard));
  }

  @override
  Widget build(BuildContext context) {
    if (!PasteImages._mac && !PasteImages._otherDesktop) return widget.child;
    // The paste keys caught here too on a Mac, where they reach the app at all (its window takes a picture's ⌘V first
    // and lets words through, so this pastes words there, or a picture should the window ever pass one on).
    return Shortcuts(
      shortcuts: {SingleActivator(LogicalKeyboardKey.keyV, meta: PasteImages._mac, control: !PasteImages._mac): const _PastePicture()},
      child: Actions(actions: {_PastePicture: CallbackAction<_PastePicture>(onInvoke: (_) => _paste())}, child: widget.child),
    );
  }
}

/// The paste keys pressed in a field that takes pictures.
class _PastePicture extends Intent {
  const _PastePicture();
}
