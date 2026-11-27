import 'package:media_kit/media_kit.dart' as mk;

/// Sets mpv's [name] to [value] on [player], where libmpv is what plays it (lib/voice/mpv_property.dart).
Future<void> setMpvProperty(mk.Player player, String name, String value) async {
  final native = player.platform;
  if (native is mk.NativePlayer) await native.setProperty(name, value);
}
