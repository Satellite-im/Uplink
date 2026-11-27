import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/api/api.dart';
import 'package:ghost_messaging/api/methods.dart';
import 'package:ghost_messaging/app_state.dart';

/// The docs' API reference and the Postman collection are made from docs-src/api/app-methods.json
/// (tool/build-docs.mjs), which is what the app's own registry says of itself (`api.describe`). This holds the file to
/// the registry, so a method added or changed in lib/api/methods.dart can't be left out of the docs.
///
///     UPDATE_API_DOCS=1 flutter test test/api_reference_test.dart   # writes the file; then node tool/build-docs.mjs
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('docs-src/api/app-methods.json is what the registry says of itself', () {
    // No phone underneath: what the app keeps there goes nowhere.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('ghost_messaging/sms'), (_) async => null);
    if (Api.instance.method('app.info') == null) Api.instance.registerAll(appMethods(AppState()));
    final described = Api.instance.describe();
    // Other tests in the same run register methods of their own (test.echo): they are not the app's.
    described['methods'] = [
      for (final m in described['methods'] as List)
        if (!(m as Map)['name'].toString().startsWith('test.')) m,
    ];
    final made = '${const JsonEncoder.withIndent('  ').convert(jsonSafe(described))}\n';
    final file = File('docs-src/api/app-methods.json');
    if (Platform.environment['UPDATE_API_DOCS'] == '1') {
      file.writeAsStringSync(made);
      return;
    }
    expect(file.existsSync() ? file.readAsStringSync() : '', made, reason: 'Run: UPDATE_API_DOCS=1 flutter test test/api_reference_test.dart && node tool/build-docs.mjs');
  });
}
