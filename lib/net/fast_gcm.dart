/// AES-GCM for everything the app seals (messages, backups, a Files space's files), in two halves that give the same
/// bytes. Where Dart's integers are 64 bits (a phone, a computer) it is the fast one, whose GHASH works on two 64-bit
/// halves (fast_gcm_64.dart). A browser's integers are JavaScript's numbers: `<<`, `>>>` and `^` keep 32 bits of them,
/// so that code would run there and give wrong tags, with nothing to say so. There it is pointycastle's own GCM
/// (fast_gcm_web.dart), slower and right. test/fast_gcm_test.dart holds each to the other, to pointycastle and to the
/// GCM paper's own answers.
library;

export 'fast_gcm_64.dart' if (dart.library.js_interop) 'fast_gcm_web.dart';
