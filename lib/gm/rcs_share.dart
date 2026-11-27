import '../app_state.dart';
import '../sms.dart';

/// How RCS stands on the phone, told to its paired computers (GMFB-11, @kevin: "Syncing the rcs setting between
/// connected devices would be really cool"). A computer paired with the phone already shows the phone's RCS chats
/// (through the phone's own Google Messages web session, android GmWeb.kt); what it didn't know was that, so its
/// Google Messages settings asked it to be set up again. Now it asks the phone (`rcs` on the desk link, android
/// DeskSession.kt → DartAsk) and says "on through your phone" instead.
class RcsState {
  const RcsState({this.webPaired = false, this.webConnected = false, this.setUp = false, this.rcsOn = false, this.phone = ''});

  /// The phone holds a Google Messages web session (every conversation, RCS among them, comes through it).
  final bool webPaired;
  final bool webConnected;

  /// The phone finished RCS setup (lib/ui/rcs_setup.dart `rcs_setup`), and said RCS chats are on in Google Messages.
  final bool setUp;
  final bool rcsOn;

  /// The phone's number as Google Messages has it.
  final String phone;

  /// RCS reaches this computer through the phone: nothing to set up here.
  bool get throughPhone => webPaired;

  Map<String, Object?> toJson() => {'webPaired': webPaired, 'webConnected': webConnected, 'setUp': setUp, 'rcsOn': rcsOn, 'phone': phone};

  factory RcsState.fromJson(Map<Object?, Object?> j) => RcsState(
        webPaired: j['webPaired'] == true,
        webConnected: j['webConnected'] == true,
        setUp: j['setUp'] == true,
        rcsOn: j['rcsOn'] == true,
        phone: j['phone'] is String ? j['phone'] as String : '',
      );
}

/// The two ends of that asking: the phone's answer, and a computer's question.
class RcsShare {
  RcsShare._();

  /// On the phone: what a paired computer is told ([RcsState]), from the phone's Google Messages web session and its
  /// RCS setup.
  static Future<Object?> answer(AppState app) async {
    final web = await Sms.instance.gmWebState().catchError((_) => const <String, Object?>{});
    return RcsState(
      webPaired: web['paired'] == true,
      webConnected: web['connected'] == true,
      setUp: app.flag('rcs_setup', fallback: false),
      rcsOn: app.flag('rcs_on_chosen', fallback: false),
      phone: web['phone'] is String ? web['phone'] as String : '',
    ).toJson();
  }

  /// On a computer: how RCS stands on its phone; null where the phone can't say (not reachable, or too old).
  static Future<RcsState?> ofPhone() async {
    try {
      return RcsState.fromJson(await Sms.instance.rcsOfPhone());
    } catch (_) {
      return null;
    }
  }
}
