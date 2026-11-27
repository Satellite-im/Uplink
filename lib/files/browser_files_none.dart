import 'package:flutter/foundation.dart';

import 'file_source.dart';

/// Not in a browser: a phone or a computer picks, takes drops and saves through FilePlatform (browser_files.dart).
class BrowserFiles {
  BrowserFiles._();
  static Future<List<FileSource>> pick() async => const [];
  static Stream<List<FileSource>> get dropped => const Stream.empty();
  static final ValueNotifier<bool> over = ValueNotifier(false);
  static void dropTarget(bool on) {}
  static void save(String url, String name) {}
}
