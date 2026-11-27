import 'package:integration_test/integration_test_driver.dart';

/// Lets an integration test run in a profile build, where frames are timed as a person would see them:
/// `flutter drive --driver=test_driver/integration_test.dart --target=integration_test/desk_frames_test.dart -d macos --profile`.
Future<void> main() => integrationDriver();
