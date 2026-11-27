/// What the window is showing, named in its title bar (Matt, 2026-11-24: "show the active circle or conversation name
/// in the titlebar where the "ghost messaging" title is"): the circle that is open, else the conversation that is
/// open, else the app's own name. A page says what it is by standing under a [WindowTitle]; the title bar
/// (lib/desktop/ui/desk_title_bar.dart) reads [WindowTitle.now]. Nothing reads it on a phone, which has no title bar.
library;

import 'package:flutter/widgets.dart';

/// [child] is the page of the circle or conversation called [name]: while it is on the screen the window is named
/// for it. A circle's list ([circle]) names the window before any conversation open beside it, and only while it is
/// the list shown (under Settings it is not what the window is showing); a conversation names it for as long as its
/// page is there, whatever is opened over it (its own settings are still that conversation's).
class WindowTitle extends StatefulWidget {
  const WindowTitle({super.key, required this.name, this.circle = false, required this.child});
  final String name;
  final bool circle;
  final Widget child;

  /// What the title bar says with nothing open.
  static const app = 'Uplink';

  /// The open circle's name, else the open conversation's; null with neither. Changes after the frame in which a
  /// page came or went, never during one.
  static final ValueNotifier<String?> now = ValueNotifier<String?>(null);

  /// Every page naming the window, the newest last.
  static final List<_WindowTitleState> _named = [];
  static bool _due = false;

  static String? _pick() {
    String? of(bool circle) {
      for (final s in _named.reversed) {
        if (s.widget.circle != circle || !s._shown) continue;
        final name = s.widget.name.trim();
        if (name.isNotEmpty) return name;
      }
      return null;
    }

    return of(true) ?? of(false);
  }

  /// A page came, went or changed its name. Worked out once the frame is drawn: this is told while pages are being
  /// built and thrown away, when the title bar may not be built again.
  static void _changed() {
    if (_due) return;
    _due = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _due = false;
      now.value = _pick();
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  State<WindowTitle> createState() => _WindowTitleState();
}

class _WindowTitleState extends State<WindowTitle> {
  /// Whether its page is the one on top where it stands. Asked of a circle's list alone.
  bool _shown = true;

  @override
  void initState() {
    super.initState();
    WindowTitle._named.add(this);
    WindowTitle._changed();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!widget.circle) return;
    final shown = ModalRoute.of(context)?.isCurrent ?? true;
    if (shown == _shown) return;
    _shown = shown;
    WindowTitle._changed();
  }

  @override
  void didUpdateWidget(WindowTitle old) {
    super.didUpdateWidget(old);
    if (old.name != widget.name || old.circle != widget.circle) WindowTitle._changed();
  }

  @override
  void dispose() {
    WindowTitle._named.remove(this);
    WindowTitle._changed();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
