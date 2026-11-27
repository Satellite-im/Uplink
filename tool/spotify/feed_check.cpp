// Checks the PC's music feed (windows/runner/music_feed.h), what makes chunks of it without loss (music_tee.h) and what
// waits to be played of those (music_ring.h) on any computer, without a sound: cc -c native/voicefx/music_pack.c
// -Inative/voicefx/include -o build/spotify/music_pack.o && c++ -std=c++17 -Inative/voicefx/include -Inative/voicefx/test
// tool/spotify/feed_check.cpp build/spotify/music_pack.o -o build/spotify/feed-check && build/spotify/feed-check
#include "../../windows/runner/music_feed.h"
#include "../../windows/runner/music_ring.h"
#include "../../windows/runner/music_tee.h"

#include <cstdio>
#include <thread>

#include "music_unpack.h"

static int wrong = 0;
static void check(bool ok, const char* what) {
  if (!ok) {
    std::printf("FAIL: %s\n", what);
    wrong++;
  }
}

// Frames numbered from [from]: left is the number, right is its negative.
static std::vector<int16_t> block(int from, size_t frames) {
  std::vector<int16_t> b(frames * 2);
  for (size_t i = 0; i < frames; i++) {
    b[i * 2] = static_cast<int16_t>((from + static_cast<int>(i)) % 30000 + 1);
    b[i * 2 + 1] = static_cast<int16_t>(-b[i * 2]);
  }
  return b;
}

int main() {
  const size_t kF = MusicFeed::kFrames;
  std::vector<int16_t> out(kF * 2, 77);
  {
    MusicFeed f(20, 100);
    f.Read(out.data(), kF);
    check(out[0] == 0 && out[kF * 2 - 1] == 0, "nothing waiting is silence");
    f.Write(block(0, kF).data(), kF);
    f.Read(out.data(), kF);
    check(out[0] == 0, "too little waiting to begin");
    f.Write(block(480, kF).data(), kF);
    f.Read(out.data(), kF);
    check(out[0] == 1 && out[1] == -1, "left first, then right");
    check(out[(kF - 1) * 2] == 480, "in order");
    f.Read(out.data(), kF);
    check(out[0] == 481, "on from there");
    f.Read(out.data(), kF);
    check(out[0] == 0, "run dry is silence");
    f.Write(block(0, kF).data(), kF);
    f.Read(out.data(), kF);
    check(out[0] == 0, "and it waits for a little before it begins again");
  }
  {
    MusicFeed f(20, 100);
    f.Write(block(0, kF * 2).data(), kF * 2);
    f.Read(out.data(), kF);
    f.Write(block(960, 100).data(), 100);
    f.Read(out.data(), kF);
    f.Read(out.data(), kF);
    check(out[0] == 961 && out[99 * 2] == 1060 && out[100 * 2] == 0, "part of a block, then silence");
  }
  {
    // 100 ms is the most: the oldest goes.
    MusicFeed f(20, 100);
    for (int i = 0; i < 50; i++) f.Write(block(i * 480, kF).data(), kF);
    f.Read(out.data(), kF);
    check(out[0] == 40 * 480 + 1, "never more than it may hold behind");
    f.Clear();
    f.Write(block(0, 48000).data(), 48000);
    f.Read(out.data(), kF);
    check(out[0] == 48000 - 4800 - 30000 + 1, "a burst longer than all of it: its newest part");
    f.Clear();
    f.Read(out.data(), kF);
    check(out[0] == 0, "cleared");
    f.Write(nullptr, kF * 3);
    f.Read(out.data(), kF);
    check(out[0] == 0 && out[1] == 0, "a silent block");
  }
  {
    // Written and read by two threads at once, as it is: every frame whole, and in order.
    MusicFeed f(20, 100);
    bool on = true, whole = true;
    std::thread w([&] {
      for (int i = 0; i < 4000; i++) f.Write(block(i * 480, kF).data(), kF);
      on = false;
    });
    for (int i = 0; i < 4000; i++) {
      f.Read(out.data(), kF);
      for (size_t k = 0; k < kF; k++) whole = whole && out[k * 2] == -out[k * 2 + 1];
    }
    w.join();
    check(whole && !on, "two threads at once");
  }
  {
    // Without loss: blocks of odd sizes in, chunks of 40 ms out, numbered on and bit for bit; nothing made while off, and
    // the numbers go on over it.
    std::vector<std::vector<uint8_t>> made;
    MusicTee tee([&](std::vector<uint8_t> c) { made.push_back(std::move(c)); });
    int at = 0;
    auto put = [&](size_t n, bool silent = false) {
      tee.Write(silent ? nullptr : block(at, n).data(), n);
      at += static_cast<int>(n);
    };
    put(5000);
    check(made.empty(), "nothing is made until it is wanted");
    tee.Set(true);
    const int from = at;
    for (int i = 0; i < 400; i++) put(static_cast<size_t>(i * 37 % 1000 + 1));
    check(static_cast<int>(made.size()) == (at - from) / MUSIC_PACK_FRAMES, "a chunk as each is full");
    std::vector<int16_t> back(MUSIC_PACK_MOST * 2);
    for (size_t i = 0; i < made.size(); i++) {
      const auto& c = made[i];
      const int want = from + static_cast<int>(i) * MUSIC_PACK_FRAMES;
      const int said = c[4] | c[5] << 8 | c[6] << 16 | c[7] << 24;
      check(c[0] == 1 && c[1] == 1 && (c[2] | c[3] << 8) == MUSIC_PACK_FRAMES && said == want && static_cast<size_t>((c[10] | c[11] << 8) + 12) == c.size(), "its head");
      check(music_unpack(c.data() + 12, static_cast<int>(c.size()) - 12, back.data(), MUSIC_PACK_MOST) == MUSIC_PACK_FRAMES, "it is read");
      check(std::memcmp(back.data(), block(want, MUSIC_PACK_FRAMES).data(), MUSIC_PACK_FRAMES * 4) == 0, "bit for bit");
    }
    tee.Set(false);
    put(777);
    tee.Set(true);
    const size_t had = made.size();
    const int again = at;
    put(MUSIC_PACK_FRAMES, true);
    check(made.size() == had + 1 && (made.back()[4] | made.back()[5] << 8 | made.back()[6] << 16) == again && made.back().size() < 40, "silence, numbered on from where it was left off");
  }
  {
    // What waits to be played.
    MusicRing r;
    auto give = [&](int from, size_t n) {
      const auto b = block(from, n);
      return r.Write(reinterpret_cast<const uint8_t*>(b.data()), n * 4);
    };
    check(give(0, 4800).waiting == 4800, "counted");
    r.Read(out.data(), kF);
    check(out[0] == 0 && out[kF * 2 - 1] == 0, "silent until it is heard");
    r.Set(1);
    r.Read(out.data(), kF);
    check(out[0] == 0 && out[kF * 2 - 2] > 100 && out[kF * 2 - 2] < 960, "it rises");
    for (int i = 0; i < 3; i++) r.Read(out.data(), kF);
    r.Read(out.data(), kF);
    check(std::memcmp(out.data(), block(2400, kF).data(), kF * 4) == 0, "and then it is bit for bit");
    for (int i = 0; i < 4; i++) r.Read(out.data(), kF);
    check(give(0, 0).dry == 0, "played to the end is not run out");
    r.Read(out.data(), kF);
    check(out[0] == 0 && give(0, 0).dry == 1, "past it is");
    r.Read(out.data(), kF);
    check(give(9, kF).dry == 1, "once");
    r.Read(out.data(), kF);
    check(out[0] == 10, "and begins again as loud as it was");
    for (int i = 0; i < 4; i++) give(0, 48000);
    check(give(0, 1).waiting == MusicRing::kCapacity, "no more than three seconds");
    r.Clear();
    const uint8_t part[3] = {1, 2, 3};
    check(r.Write(part, 3).waiting == 0 && r.Write(part, 0).dry == 1, "forgotten, which is not running out");
  }
  std::printf(wrong ? "%d wrong\n" : "PASS\n", wrong);
  return wrong ? 1 : 0;
}
