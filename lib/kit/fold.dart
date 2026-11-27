/// Lower-cased with curly quotes made straight, for matching words (Ghost Keyboard's settings_search.dart `fold`).
String fold(String text) => text.toLowerCase().replaceAll(_singles, "'").replaceAll(_doubles, '"');

// Made once: a search folds every conversation's words at every key pressed.
final RegExp _singles = RegExp('[‘’]'), _doubles = RegExp('[“”]');
