import 'browser.dart';

/// Where there is no browser (a phone, a computer, a test that has not put its own in): nothing here can be asked.
Browser browser() => const _NoBrowser();

/// A [Browser] whose every member throws [UnsupportedError]: nothing outside a page should be asking.
class _NoBrowser implements Browser {
  const _NoBrowser();

  static Never _none() => throw UnsupportedError('This is not a page in a browser.');

  @override
  Uri get address => _none();
  @override
  String get name => _none();
  @override
  String? get unfit => 'This is not a page in a browser.';
  @override
  Future<BrowserStore> openStore() => _none();
  @override
  Future<bool> keep() => _none();
  @override
  Future<TabHold?> holdTab({required Future<void> Function() onAsked, void Function()? onTaken}) => _none();
  @override
  Future<TabHold> takeTab({required Future<void> Function() onAsked, void Function()? onTaken}) => _none();
  @override
  void reload({String? note}) => _none();
  @override
  String? takeNote() => _none();
  @override
  bool openTab(String url) => _none();
  @override
  void onVisible(void Function() then) => _none();
}
