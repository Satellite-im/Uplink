import 'package:flutter/widgets.dart';

/// What an iPhone or a computer of its own shows in the app's place where what it keeps couldn't be read as it started
/// (StandaloneCalls.loadAgain): said, and nothing started, so nothing is written over what is there. Drawn with no
/// stylesheet, since it stands before anything is loaded.
class StoreUnreadableNotice extends StatelessWidget {
  const StoreUnreadableNotice({super.key, required this.device});

  /// What this is called in the words: 'iPhone', 'computer'.
  final String device;

  @override
  Widget build(BuildContext context) {
    const ink = Color(0xFFFFFFFF), soft = Color(0xFFB8B8B8);
    const face = TextStyle(fontFamily: 'Inter Variable', decoration: TextDecoration.none, color: ink);
    return Directionality(
      textDirection: TextDirection.ltr,
      child: ColoredBox(
        color: const Color(0xFF000000),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Text('Uplink couldn\'t read what it keeps on this $device just now.', textAlign: TextAlign.center, style: face.copyWith(fontSize: 20, height: 1.35, fontWeight: FontWeight.w600)),
                const SizedBox(height: 10),
                Text('Nothing was changed. Quit it and open it again; if this keeps happening, the $device may be short of space.', textAlign: TextAlign.center, style: face.copyWith(fontSize: 15, height: 1.45, color: soft)),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}
