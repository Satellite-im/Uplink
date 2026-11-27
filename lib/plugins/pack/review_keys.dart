/// The trust this build ships with for the Marketplace (Matt, 2026-11-20: "I'd like to be able to verify them for the
/// store through a review process"): whose approvals it believes, and the withdrawals and retirements it carries itself.
library;

/// The review keys this build trusts: base64 of each 33-byte compressed P-256 public key whose approvals a store pack
/// must carry (lib/plugins/pack/review.dart). Matt's hub key, and any other device's he reviews from. Changing this list
/// is an app release: an approval by a key that is not here does not verify, at install or at any later load.
// Matt's Fold (2026-11-20), hub id a4bbad8bc42293e4. The key came from the relay, but it was held to the id his phone
// shows (Settings › Routes › This phone, "a4bbad8b c42293e4", read by Matt): the first 8 bytes of the key's sha256.
// The relay can't make that match without finding a second key with the same 64 bits.
const List<String> marketReviewKeys = ['AzE0uewhHTdq8W8BJkINLSjycyYrv3vW1IUYd8x+e8lP'];

/// Withdrawals this build carries itself (PackRevocation.toJson() maps), merged at load with what the relay says, each
/// verified as any other: a relay that withholds them can't keep a withdrawn plugin running on a new build.
const List<Map<String, Object>> shippedRevocations = [];

/// Review keys retired by their own signature (PackRetirement.toJson() maps), merged the same way.
const List<Map<String, Object>> shippedRetirements = [];
