import 'linux_dialogs.dart';
import 'dart:async';
import 'dart:io';
import '../platform_info.dart';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';

import 'desk_player.dart';
import 'desk_voice.dart' show m4aMillis, isOgg, oggMillis;
import 'linux_voice.dart';
import 'link/link.dart';
import '../sms.dart' show Sms;

/// What the computer is called in the app's words: "Mac", or "PC" on Windows.
/// A page in a browser (Sms.browser) is none of those: "browser".
String get computerWord => Sms.browser ? 'browser' : PlatformInfo.isWindows ? 'PC' : PlatformInfo.isIOS ? 'iPhone' : PlatformInfo.isLinux ? 'computer' : 'Mac';

/// What the desktop app is for, in its name: "the Mac", or "Windows".
String get desktopName => Sms.browser ? 'a browser' : PlatformInfo.isWindows ? 'Windows' : PlatformInfo.isIOS ? 'the iPhone' : PlatformInfo.isLinux ? 'Linux' : 'the Mac';

/// What the app asks of the system it runs on, over the "ghost_desktop/system" channel (on a Mac and an iPhone,
/// DeskChannels.swift): opening a link, the computer's name, the Keychain, and recording and playing voice
/// messages. Each answers quietly (null, false, nothing) where the system has no such thing.
class MacPlatform {
  /// Opens a web address in this device's own browser, and says whether it could (Matt, 2026-11-20: "when clicking sign
  /// up with discord it says "no browser could be opened""): `open` on a Mac, `explorer` on Windows, the iPhone's own
  /// browser through iOS (DeskChannels.swift). Only http and https addresses with a host, handed over alone.
  static Future<bool> openLink(String url) async {
    // Exactly as given: an address with a space before it is refused rather than tidied (test/desk_link_test.dart).
    final uri = Uri.tryParse(url);
    if (uri == null || url != url.trim() || (uri.scheme != 'http' && uri.scheme != 'https') || uri.host.isEmpty) return false;
    if (PlatformInfo.isIOS) {
      try {
        return await _system.invokeMethod<bool>('openLink', {'url': uri.toString()}) ?? false;
      } catch (_) {
        return false;
      }
    }
    final opener = PlatformInfo.isMacOS ? 'open' : PlatformInfo.isWindows ? 'explorer' : 'xdg-open';
    try {
      // Windows' explorer answers 1 even when it opened the address.
      return (await Process.run(opener, [uri.toString()])).exitCode == 0 || PlatformInfo.isWindows;
    } catch (_) {
      return false;
    }
  }

  MacPlatform._();
  static const _system = MethodChannel('ghost_desktop/system');

  /// "Matt's MacBook Pro", or the host's name where macOS will not say.
  static Future<String> computerName() async {
    try {
      final name = await _system.invokeMethod<String>('name');
      if (name != null && name.trim().isNotEmpty) return name.trim();
    } catch (_) {}
    return PlatformInfo.localHostname.replaceAll(RegExp(r'\.local\.?$'), '').replaceAll('-', ' ');
  }

  /// The Keychain: what is kept under [account], or null; and [value] kept there, true where the Keychain took it.
  static Future<String?> keyRead(String account) async {
    try {
      return await _system.invokeMethod<String>('keyRead', {'account': account});
    } catch (_) {
      return null;
    }
  }

  static Future<bool> keyWrite(String account, String value) async {
    try {
      return await _system.invokeMethod<bool>('keyWrite', {'account': account, 'value': value}) ?? false;
    } catch (_) {
      return false;
    }
  }

  // --- the message field's own (macos/Runner/DeskChannels.swift, DeskSound.swift) --------------------------------

  /// The Mac's panel for choosing pictures: the paths chosen, none where it was put away.
  static Future<List<String>> pickPictures({int most = 5}) async {
    // Linux: the desktop's own chooser (lib/desktop/linux_dialogs.dart).
    if (PlatformInfo.isLinux) return linuxPick(most: most, pictures: true);
    try {
      return [for (final p in (await _system.invokeMethod<List>('pickPictures', {'most': most})) ?? const []) '$p'];
    } catch (_) {
      return const [];
    }
  }

  /// A picture on the clipboard as a file to send: an image file copied, or a copied picture written out (Mac:
  /// DeskChannels.swift, Windows: clipboard.cpp). Null where there is none. Windows hands a copied picture over as
  /// a BMP, which a phone may not send: it is made a PNG here.
  static Future<String?> pasteImage() async {
    try {
      final path = await _system.invokeMethod<String>('pasteImage');
      if (path == null || !path.toLowerCase().endsWith('.bmp')) return path;
      final codec = await ui.instantiateImageCodec(await File(path).readAsBytes());
      final frame = await codec.getNextFrame();
      final png = await frame.image.toByteData(format: ui.ImageByteFormat.png);
      if (png == null) return null;
      final out = File('${path.substring(0, path.length - 4)}.png');
      await out.writeAsBytes(png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes));
      return out.path;
    } catch (_) {
      return null;
    }
  }

  /// Opens the Mac's own "Emoji & Symbols": what is chosen there is typed where the cursor is.
  static Future<void> emoji() async {
    try {
      await _system.invokeMethod('emoji');
    } catch (_) {}
  }

  /// Starts recording a voice message with the Mac's microphone, which stops itself at [bytes]: `ok`, or `denied`
  /// where macOS was told no, or an `error` in words.
  static Future<Map> voiceStart(int bytes) async {
    // Linux has no recorder in the app: a program the desktop has is run (lib/desktop/linux_voice.dart, GMFB-32),
    // which answers these four as the Mac's and Windows' own do.
    if (PlatformInfo.isLinux) return LinuxVoice.instance.start(bytes);
    try {
      return (await _system.invokeMapMethod<Object?, Object?>('voiceStart', {'bytes': bytes})) ?? const {'ok': false};
    } on MissingPluginException {
      return const {'ok': false, 'error': 'This copy of the app has no recorder'};
    }
  }

  /// How loud it is now (`level`, 0 to 1) and whether the recording is as long as it may be (`full`).
  static Future<Map> voiceLevel() async {
    if (PlatformInfo.isLinux) return LinuxVoice.instance.level();
    try {
      return (await _system.invokeMapMethod<Object?, Object?>('voiceLevel')) ?? const {};
    } catch (_) {
      return const {};
    }
  }

  /// Throws the recording under way away.
  static Future<void> voiceCancel() async {
    if (PlatformInfo.isLinux) return LinuxVoice.instance.cancel();
    try {
      await _system.invokeMethod('voiceCancel');
    } catch (_) {}
  }

  /// Ends the recording: its bytes (AAC in an `.m4a`), or null where there is nothing worth keeping. Windows answers
  /// these four too (windows/runner/desk_sound.cpp, GMFB-32), and says in `voiceStart`'s answer how many `seconds`
  /// fit at its own rate.
  static Future<Uint8List?> voiceStop() async {
    if (PlatformInfo.isLinux) return LinuxVoice.instance.stop();
    try {
      return await _system.invokeMethod<Uint8List>('voiceStop');
    } catch (_) {
      return null;
    }
  }

  /// Windows and Linux play a voice message in Dart, by media_kit ([DeskPlayer], GMFB-32); the Mac and the iPhone
  /// natively (DeskSound.swift).
  static bool get _dartPlayer => PlatformInfo.isWindows || PlatformInfo.isLinux;

  /// The part a Mac is playing in Dart, -1 for none: an Ogg sound (.ogg, .oga, .opus: Vorbis or Opus), which the Mac's
  /// own player refuses ("this Mac can't play this kind of sound") and libmpv, which the Mac's app carries for video,
  /// plays (GMFB-60). An iPhone carries no libmpv and has only its own player.
  static int _oggPart = -1;

  /// Plays a message's sound ([bytes] the first time; null goes on with the one paused). Null, or why it cannot.
  static Future<String?> voicePlay(int part, Uint8List? bytes) async {
    if (_dartPlayer) return DeskPlayer.play(part, bytes);
    if (PlatformInfo.isMacOS && (bytes == null ? _oggPart == part : isOgg(bytes))) {
      // The Mac's own player let go first, so two never sound at once.
      if (_oggPart == -1) await _nativeHalt();
      _oggPart = part;
      final why = await DeskPlayer.play(part, bytes);
      if (why != null) _oggPart = -1;
      return why;
    }
    if (_oggPart != -1) {
      _oggPart = -1;
      await DeskPlayer.halt();
    }
    try {
      return await _system.invokeMethod<String>('voicePlay', {'part': part, 'bytes': bytes});
    } on MissingPluginException {
      return 'this copy of the app has no player';
    }
  }

  static Future<void> _nativeHalt() async {
    try {
      await _system.invokeMethod('voiceHalt');
    } catch (_) {}
  }

  /// Pauses the sound playing, to go on from there; [voiceHalt] stops it for good. [voiceLength] is how long a
  /// sound runs, in milliseconds as the phone gives it, or 0 where that cannot be told.
  static Future<void> voicePause() async {
    if (_dartPlayer || _oggPart != -1) return DeskPlayer.pause();
    try {
      await _system.invokeMethod('voicePause');
    } catch (_) {}
  }

  static Future<void> voiceHalt() async {
    if (_dartPlayer) return DeskPlayer.halt();
    if (_oggPart != -1) {
      _oggPart = -1;
      await DeskPlayer.halt();
    }
    await _nativeHalt();
  }

  static Future<int> voiceLength(Uint8List bytes) async {
    // An Ogg sound says how long it runs in its last page, read here on every computer (no native player reads one).
    if (isOgg(bytes)) return oggMillis(bytes);
    // A WAV, which a Linux computer with no ffmpeg records (lib/desktop/linux_voice.dart), says so in its header.
    if (isWav(bytes)) return wavMillis(bytes);
    // Read from the file itself where no native player is asked: an .m4a says how long it runs.
    if (_dartPlayer) return m4aMillis(bytes);
    try {
      return (await _system.invokeMethod<num>('voiceLength', {'bytes': bytes}))?.toInt() ?? 0;
    } catch (_) {
      return 0;
    }
  }

  /// Where the sound being played has got to, as the Mac says it (DeskSound.swift `heard`): handed to [heard].
  static void listenToVoice(void Function(Map state) heard) {
    _heard = heard;
    DeskPlayer.heard = heard;
    _listen();
  }

  /// Who is told of each: where the sound being played has got to, and the iPhone's push token.
  static void Function(Map state)? _heard;
  static void Function(String? token, bool sandbox)? _pushToken;

  /// One listener for all the native side tells (a channel has room for one): the voice being played, and the
  /// iPhone's push token.
  static void _listen() {
    _system.setMethodCallHandler((call) async {
      final a = call.arguments;
      if (call.method == 'voice' && a is Map) _heard?.call(a);
      if (call.method == 'pushToken' && a is Map) _pushToken?.call(a['token'] as String?, a['sandbox'] != false);
      return null;
    });
  }

  /// An iPhone asks once whether it may show notifications, then for Apple's token for this install (Matt,
  /// 2026-11-16: "Yes, wake-ups"; ios/Runner/DeskChannels.swift `pushRegister`). The token comes later, to
  /// [onToken], whenever iOS gives it (each start, and when it changes); null when Apple would not give one.
  static Future<bool> pushRegister(void Function(String? token, bool sandbox) onToken) async {
    _pushToken = onToken;
    _listen();
    try {
      return await _system.invokeMethod<bool>('pushRegister') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// A picture of where a video starts and how long it runs (macos/Runner/DeskVideo.swift), from its bytes.
  static Future<Map?> videoPreview(int id, Uint8List bytes, String ending) async {
    try {
      return await _system.invokeMapMethod<Object?, Object?>('videoPreview', {'id': id, 'bytes': bytes, 'ext': ending});
    } catch (_) {
      return null;
    }
  }

  static Future<void> keyDelete(String account) async {
    try {
      await _system.invokeMethod<bool>('keyDelete', {'account': account});
    } catch (_) {}
  }
}

/// Phones announcing `_ghostmsg._tcp` on this network, as Bonjour finds them. macOS asks the person once whether the
/// app may look on the local network; refused, nothing is found, and an address can be given by hand.
class BonjourFinder implements PeerFinder {
  static const _system = MethodChannel('ghost_desktop/system');
  static const _found = EventChannel('ghost_desktop/bonjour');

  /// Every address of every phone found, as last told.
  List<Peer> _current = const [];
  StreamSubscription<dynamic>? _sub;
  void Function()? _onChange;

  @override
  List<Peer> get current => _current;

  @override
  set onChange(void Function()? listener) => _onChange = listener;

  @override
  void start() {
    _sub ??= _found.receiveBroadcastStream().listen((list) {
      final next = <Peer>[];
      for (final s in (list as List? ?? const [])) {
        final port = ((s as Map)['port'] as num?)?.toInt() ?? 0;
        // A numeric IPv4 address first: it needs no name looked up, and no interface named.
        final addresses = [for (final a in (s['addresses'] as List? ?? const [])) '$a']..sort((a, b) => (a.contains(':') ? 1 : 0) - (b.contains(':') ? 1 : 0));
        for (final a in addresses) {
          // A link-local IPv6 address (fe80…) cannot be dialled without its interface's name: left out.
          if (port > 0 && !a.startsWith('fe80')) next.add(Peer(a, port));
        }
      }
      _current = next;
      _onChange?.call();
    }, onError: (_) {});
    _system.invokeMethod('browse').catchError((_) {});
  }

  @override
  void stop() {
    _sub?.cancel();
    _sub = null;
    _system.invokeMethod('stopBrowsing').catchError((_) {});
  }
}
