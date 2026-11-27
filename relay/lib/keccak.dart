/// Keccak-256 as Ethereum has it (the original padding, 0x01, not SHA3-256's 0x06), with Dart's own 64-bit integers and
/// nothing fetched, for accounts.dart: an account's address is the last 20 bytes of the Keccak-256 of its public key,
/// and what it signs is hashed with it (EIP-191). The app hashes with pointycastle; test/account_crypto_test.dart in the
/// app holds the two to the same bytes. Runs on the Dart VM (64-bit ints), which is where the relay runs.
library;

// Bytes taken in per round of the permutation: 1600 bits of state less twice the 256-bit digest, in bytes.
const _rate = 136;

// The 24 round constants, and each lane's rotation (indexed x + 5y), as the Keccak specification gives them.

final List<int> _rc = [
  0x0000000000000001, 0x0000000000008082, 0x800000000000808a, 0x8000000080008000, 0x000000000000808b, 0x0000000080000001,
  0x8000000080008081, 0x8000000000008009, 0x000000000000008a, 0x0000000000000088, 0x0000000080008009, 0x000000008000000a,
  0x000000008000808b, 0x800000000000008b, 0x8000000000008089, 0x8000000000008003, 0x8000000000008002, 0x8000000000000080,
  0x000000000000800a, 0x800000008000000a, 0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008,
];

const _rot = [0, 1, 62, 28, 27, 36, 44, 6, 55, 20, 3, 10, 43, 25, 39, 41, 45, 15, 21, 8, 18, 2, 61, 56, 14];

int _rotl(int x, int n) => n == 0 ? x : (x << n) | (x >>> (64 - n));

/// Keccak-f[1600] on the 25 lanes of [a], in place: 24 rounds of theta, rho and pi, chi, iota.
void _permute(List<int> a) {
  final c = List<int>.filled(5, 0), b = List<int>.filled(25, 0);
  for (var round = 0; round < 24; round++) {
    for (var x = 0; x < 5; x++) {
      c[x] = a[x] ^ a[x + 5] ^ a[x + 10] ^ a[x + 15] ^ a[x + 20];
    }
    for (var x = 0; x < 5; x++) {
      final d = c[(x + 4) % 5] ^ _rotl(c[(x + 1) % 5], 1);
      for (var y = 0; y < 25; y += 5) {
        a[y + x] ^= d;
      }
    }
    for (var x = 0; x < 5; x++) {
      for (var y = 0; y < 5; y++) {
        b[y + 5 * ((2 * x + 3 * y) % 5)] = _rotl(a[x + 5 * y], _rot[x + 5 * y]);
      }
    }
    for (var y = 0; y < 25; y += 5) {
      for (var x = 0; x < 5; x++) {
        a[y + x] = b[y + x] ^ (~b[y + (x + 1) % 5] & b[y + (x + 2) % 5]);
      }
    }
    a[0] ^= _rc[round];
  }
}

/// The 32-byte Keccak-256 of [data].
List<int> keccak256(List<int> data) {
  final state = List<int>.filled(25, 0);
  final padded = [...data, 0x01];
  while (padded.length % _rate != 0) {
    padded.add(0);
  }
  padded[padded.length - 1] |= 0x80;
  for (var off = 0; off < padded.length; off += _rate) {
    for (var i = 0; i < _rate ~/ 8; i++) {
      var lane = 0;
      for (var j = 7; j >= 0; j--) {
        lane = (lane << 8) | (padded[off + i * 8 + j] & 0xff);
      }
      state[i] ^= lane;
    }
    _permute(state);
  }
  return [for (var i = 0; i < 32; i++) (state[i ~/ 8] >>> (8 * (i % 8))) & 0xff];
}
