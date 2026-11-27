/// Heavy work done aside, so the screen keeps moving while it is: `Isolate.run` wherever there are isolates
/// (aside_io.dart). A browser has none, and there `Isolate.run` throws before it has begun; so there the same work is
/// done in place, in its turn (aside_web.dart), and the page waits for it.
///
/// Everything in lib/ that would call `Isolate.run` calls [runAside] (test/aside_test.dart reads the files to see).
/// What is handed to it is what could be handed to another isolate: a function of what it is given and nothing else,
/// since in a browser it runs among the app's own objects and on a phone among copies.
library;

export 'aside_io.dart' if (dart.library.js_interop) 'aside_web.dart';
