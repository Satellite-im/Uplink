/// The device's own translation as the plugins' text rules are handed it ([TextHost]): the phone's ML Kit models
/// (android/.../Translate.kt), asked through lib/sms.dart; on a computer, or an iPhone paired with a phone, the paired
/// phone's, across the link. An iPhone on its own has none yet (Matt, 2026-11-17: "add a translate plugin which can
/// automatically translate texts when detected from another language").
library;

import 'dart:ui' show PlatformDispatcher;

import '../sms.dart';
import 'plugin.dart';
import 'translate.dart' show languageAliases;

class DeviceTextHost implements TextHost {
  const DeviceTextHost();

  /// The language this device is set to: on the phone the phone's, on a computer the computer's, so each reads its
  /// texts in its own.
  @override
  String get language {
    final code = PlatformDispatcher.instance.locale.languageCode.toLowerCase();
    // Norwegian's "nb", Filipino's "fil" and the like, as the models name them ([languageAliases]).
    return code.isEmpty || code == 'und' ? 'en' : (languageAliases[code] ?? code);
  }

  @override
  bool get canTranslate => !Sms.standalone;

  @override
  Future<DeviceTranslation> translate(String text, {required String to, List<String> known = const [], bool fetch = true, bool wifiOnly = true}) async =>
      DeviceTranslation.from(await Sms.instance.translate(text, to: to, known: known, fetch: fetch, wifiOnly: wifiOnly));

  @override
  Future<List<DeviceLanguage>> languages() async => [
        for (final l in await Sms.instance.translateLanguages())
          if (l['tag'] is String) DeviceLanguage(l['tag'] as String, downloaded: l['downloaded'] == true, fetching: l['fetching'] == true),
      ];

  @override
  Future<bool> model(String tag, {bool delete = false, bool wifiOnly = true}) => Sms.instance.translateModel(tag, delete: delete, wifiOnly: wifiOnly);
}
