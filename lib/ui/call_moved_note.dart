import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../art/app_icon.dart';
import '../art/lucide_more.dart';
import '../voice/channels.dart';
import 'common.dart';
import '../l10n/words.dart';

/// Over every page, at the top, while a call this device was in has gone to another of the person's devices (GMFB-50,
/// Kevin: "If you are on your pc talking in a call and switch to your phone a "would you like to reconnect"
/// notification could be nice. Maybe a sticky toast notification?"): a toast's pill that stays, with Bring it back
/// here and a cross. It is not one of the toast provider's own, which the next toast would replace; it stands at the
/// top so the two never lie on each other. What it shows and when it goes is [MovedAway]'s (lib/voice/channels.dart):
/// this only draws it. Wrapped round the pages inside the app's [GlacierToastProvider], on the phone and the computer.
class CallMovedNote extends StatelessWidget {
  const CallMovedNote({super.key, required this.child, this.note});
  final Widget child;

  /// Given for a test or a picture; the app's own otherwise.
  final MovedAway? note;

  @override
  Widget build(BuildContext context) {
    final note = this.note ?? Voice.instance.movedAway;
    return Stack(fit: StackFit.passthrough, alignment: AlignmentDirectional.topStart, children: [
      child,
      ValueListenableBuilder<MovedCall?>(
        valueListenable: note,
        builder: (context, moved, _) {
          if (moved == null) return const SizedBox.shrink();
          final t = context.tokens;
          return PositionedDirectional(
            start: t.space(4),
            end: t.space(4),
            top: t.space(2) + (MediaQuery.maybeViewPaddingOf(context)?.top ?? 0),
            child: Align(
              alignment: Alignment.topCenter,
              heightFactor: 1,
              child: IntrinsicWidth(
                child: GlacierToast(
                  key: const ValueKey('call-moved-note'),
                  icon: const AppIcon(LucideMore.phoneCall, size: 16, wash: false),
                  message: const Tr('This call moved to another of your devices'),
                  action: GlacierToastAction(
                    label: 'Bring it back here',
                    onPress: () async {
                      try {
                        await note.bringBack();
                      } catch (e) {
                        if (context.mounted) toast(context, 'Couldn\'t join: $e', tone: GlacierToastTone.danger);
                      }
                    },
                  ),
                  onDismiss: note.dismiss,
                ),
              ),
            ),
          );
        },
      ),
    ]);
  }
}
