import 'package:flutter/widgets.dart';

import 'retro_button.dart';

/// Dial-Up's Send: a raised button with the word on it, bold, and the dark frame the era put round the button Enter
/// presses, standing where the app's round arrow does (the design: "a raised RetroButton 'Send' (bold, 72px wide
/// minimum) at the right"). Off while there is nothing to send, as the arrow is. [label] is 'Save' while a message is
/// edited. An IconTap(filled: true) (lib/ui/common.dart) draws as this under Dial-Up, so Send, Save edit and a voice
/// message's Send become it without the screens knowing; a screen may use it directly too.
class DialupSendButton extends StatelessWidget {
  const DialupSendButton({super.key, required this.onPressed, this.label = 'Send', this.semanticLabel});

  final VoidCallback? onPressed;
  final String label;

  /// Said by a screen reader; the [label] when null.
  final String? semanticLabel;

  /// The word for a button read aloud as [label]: "Send" for any sending ("Send voice message"), else its first word
  /// ("Save edit" is "Save"), so the face stays one short word.
  static String wordFor(String label) => label.startsWith('Send') ? 'Send' : label.split(' ').first;

  // 40 high, as the composer's other buttons are, so it stands level with the 44 high box beside it.
  @override
  Widget build(BuildContext context) => RetroButton(onPressed: onPressed, label: label, semanticLabel: semanticLabel ?? label, primary: true, bold: true, faceHeight: 40, minFaceWidth: 72);
}
