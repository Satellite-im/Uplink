/// Who reads what the app is spending (lib/perf/cpu_reading.dart): the system's own calls, or nobody in a browser.
library;

export 'cpu_source_io.dart' if (dart.library.js_interop) 'cpu_source_web.dart';
