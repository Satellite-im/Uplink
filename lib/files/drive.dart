import '../me/me.dart';
import '../net/crypto.dart';
import '../net/hub_carrier.dart' show KeysSigner, NetSigner;
import '../voice/voice.dart' show SpaceKind, VoiceChannel;

/// My files: a private drive for each Uplink account, tied to no space or circle (GMFB-37, @matt: "A private file drive
/// for each account, not tied to any space").
///
/// It is a Files space like any other to the relay (relay/lib/files.dart) and to the store (FilesStore): the same
/// sealed chunks, folders, log and streaming. What makes it the account's is where its seed comes from, and who signs:
///
/// - **Its seed** is made from the key the account's devices seal copies to each other with (Me.mineKey, itself made
///   from the recovery words), under words of its own. Every device signed in to the account makes the same seed, so
///   the same room, token and files key (FileSeal), and opens the same drive; nothing is sent between them for it, and
///   the relay, which never has the words, can read none of it.
/// - **Its signer** is a key pair made from the seed, not the install's own hub key. The relay lets a blob be finished
///   and removed only by the key that started it or by the space's owner, and each device may have a hub key of its
///   own (a browser, a computer before it took on the phone's identity), so a file one device added could not be
///   removed from another. With one key made from the seed, every device of the account is the same writer and the
///   drive's owner, and a relay from before this needs nothing new.
/// - **A drive is known by its owner**: a Files space whose owner is the key its own seed makes ([signerOf]). That is
///   all a kept upload (queue.json keeps the seed and the owner) needs to go on signing as the drive after a restart.
///
/// Its room is the relay's for any one space (FilesInfo.quota), and since an account has one drive, that is what one
/// account may keep. The relay lets a space go that nobody has opened for ninety days (FilesConfig.idleDays), so the
/// app looks at the drive once a run ([FilesStore.touch]).
class Drive {
  Drive._();

  /// What it is called everywhere it is shown.
  static const name = 'My files';

  /// The drive's seed (64 hex digits) for the account whose devices share [mineKey].
  static String seedOf(List<int> mineKey) => NetCrypto.hex(NetCrypto.derive(mineKey, 'my files seed'));

  /// The key pair every device of the account writes to the drive of [seed] with. A private key is a number from 1 to
  /// one under the curve's order: the 32 bytes made from the seed are brought into that range, never refused.
  static NetKeys keysOf(String seed) {
    final raw = BigInt.parse(NetCrypto.hex(NetCrypto.derive(NetCrypto.unhex(seed), 'my files signer')), radix: 16);
    final d = raw % (NetCrypto.curve.n - BigInt.one) + BigInt.one;
    return NetKeys.fromScalar(NetCrypto.unhex(d.toRadixString(16).padLeft(64, '0')));
  }

  /// The drive as a Files space, for the account whose devices share [mineKey]: owned by the key its seed makes.
  static VoiceChannel channelOf(List<int> mineKey) {
    final seed = seedOf(mineKey);
    return VoiceChannel(seed: seed, name: name, mine: true, owner: NetCrypto.hex(keysOf(seed).public), kind: SpaceKind.files);
  }

  // What each Files space with an owner was found to be, by seed and owner: making the key pair is a multiplication on
  // the curve, done once a space a run.
  static final Map<String, NetSigner?> _signers = {};

  /// What signs for [c] where it is a drive (its owner is the key its seed makes); null for any other space.
  static NetSigner? signerOf(VoiceChannel c) {
    if (c.kind != SpaceKind.files || c.owner.isEmpty || c.circle != null || c.group != null) return null;
    return _signers.putIfAbsent('${c.seed}:${c.owner}', () {
      final keys = keysOf(c.seed);
      return NetCrypto.hex(keys.public) == c.owner ? KeysSigner(keys) : null;
    });
  }

  /// Whether [c] is an account's drive.
  static bool isDrive(VoiceChannel c) => signerOf(c) != null;

  /// This account's drive; null where no Uplink account is signed in to on this device.
  static Future<VoiceChannel?> mine() async {
    final key = await Me.instance.mineKey();
    return key == null ? null : channelOf(key);
  }
}
