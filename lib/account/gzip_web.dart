import 'package:archive/archive.dart' show GZipDecoderWeb, GZipEncoderWeb;

/// gzip in a browser (lib/account/gzip.dart), with the two calls the backup makes of `dart:io`'s.
const gzip = PlainGzip();

/// package:archive's gzip written in Dart: its `…Web` classes by name, which are that on every device (its plain
/// GZipEncoder would be `dart:io`'s again wherever a test runs, and so no test of what a browser does).
class PlainGzip {
  const PlainGzip();

  /// At zlib's usual level, 6, as `dart:io`'s is.
  List<int> encode(List<int> bytes) => const GZipEncoderWeb().encodeBytes(bytes);

  /// Throws where [bytes] aren't a whole gzip of what they say: the checksum and the length at its end are looked at,
  /// as `dart:io`'s looks at them, and one cut short is refused too (`dart:io`'s hands back what it could read of
  /// that). A backup is unpacked only after its seal has shown it whole, so the difference is never met.
  List<int> decode(List<int> bytes) => const GZipDecoderWeb().decodeBytes(bytes, verify: true);
}
