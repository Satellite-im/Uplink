import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import 'accent.dart';
import 'app_state.dart';
import 'app_lock/app_lock.dart';
import 'backgrounds.dart';
import 'kit/settings_css.dart';
import 'kit/settings_type.dart' show pageText;
import 'main.dart' show GhostMessagingApp;
import 'sms.dart';
import 'sounds.dart';
import 'ui/common.dart' show PaneRoot;
import 'ui/thread.dart';

/// A conversation's bubble on the side of the screen (GMFB-8, from @kevin: "It would be nice to have message bubbles
/// that just sit on the side of the screen like google messages and facebook messenger"; Matt asked for it to be
/// built). Android opens it from the conversation's notification (android Bubbles.kt, BubbleActivity.kt) in an engine
/// of its own, at `bubbleMain` (lib/main.dart) with the conversation's thread.
///
/// It is the app's own conversation page in the app's look and with the person's choices, and nothing around it: none
/// of the app's background work (the relay, friends, spaces, Signal and Telegram) is started here, since the app's own
/// engine already does it beside this one.

/// The conversation a bubble was opened on: its thread, the first argument; null where there is none to show.
int? bubbleThread(List<String> args) {
  if (args.isEmpty) return null;
  final thread = int.tryParse(args.first.trim());
  // -1 is "the list", never a conversation (android Notifier.incoming). Bridged conversations are below it.
  return thread == null || thread == -1 ? null : thread;
}

/// The bubble's own start, in place of the app's (lib/main.dart): loads the look and the person's choices and shows
/// the one conversation [args] names.
Future<void> runBubble(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  final state = AppState();
  // The stylesheets, the person's choices and the wallpaper's colours, as the app asks for them (lib/main.dart).
  final loaded = await Future.wait<Object?>([
    AccentSheets.load(),
    state.load(),
    PhonePalette.load(),
  ]);
  final accents = loaded[0]! as AccentSheets;
  installSettingsStyles(accents.base);
  // The app's lock (GMFB-46, lib/app_lock): a bubble opens locked too where a PIN is set, and is unlocked by itself.
  await AppLock.start(state, tell: false);
  // What changed (a message in, one read in the app) and the choices changing, told to this engine too (android
  // MainActivity.configureBubble).
  Sms.instance.listen();
  Sms.instance.prefsChanged.stream.listen((_) => state.reload());
  // A message sent from the bubble sounds as one sent in the app does.
  Sounds.instance.start(state);
  runApp(GhostMessagingApp(sheet: accents.base, state: state, accents: accents, home: BubbleConversation(thread: bubbleThread(args))));
}

/// The bubble's one page: the conversation, with no way back to a list that is not there (PaneRoot), and a button
/// into the whole app on the same conversation.
class BubbleConversation extends StatelessWidget {
  const BubbleConversation({super.key, required this.thread, this.openInApp});
  final int? thread;

  /// Opens the whole app on [thread]; Android's, by default (android MainActivity "openInApp").
  final void Function(int thread)? openInApp;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final thread = this.thread;
    if (thread == null) {
      return ColoredBox(
        color: t.color('glacier-bg'),
        child: Center(child: Text('This conversation couldn\'t be opened.', style: pageText(t, t.fontSize('sm'), color: t.color('app-ink-3')))),
      );
    }
    return PaneRoot(
      isBeside: true,
      child: ThreadScreen(
        key: ValueKey('bubble-$thread'),
        thread: thread,
        // Its people are read by the page itself as it opens.
        people: const [],
        onExpand: () {
          final open = openInApp;
          if (open != null) {
            open(thread);
          } else {
            unawaited(Sms.instance.openInApp(thread));
          }
        },
      ),
    );
  }
}
