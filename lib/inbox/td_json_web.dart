import 'td_json.dart' show TdTransport;

/// TDLib in a browser (lib/inbox/td_json.dart): there is none, so [start] finds no library, and Telegram's page says
/// it "isn't in this build of the app" (lib/inbox/telegram.dart), as it does in any build that left TDLib out.
/// Nothing makes one of these.
abstract final class TdJson implements TdTransport {
  /// A new TDLib client, or null where the library is not in this build: always null here.
  static Future<TdJson?> start() async => null;
}
