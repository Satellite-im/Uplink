// Every frame of Spotify's sound as it was captured, made into chunks of the music without loss (native/voicefx
// music_pack.h) as each is full: what MusicTee and LosslessSend are on the Mac. On the capturing thread alone, but for
// [Set]. Nothing of Windows in it, so tool/spotify/feed_check.cpp tries it anywhere.
#ifndef RUNNER_MUSIC_TEE_H_
#define RUNNER_MUSIC_TEE_H_

#include <algorithm>
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <functional>
#include <vector>

#include "music_pack.h"

class MusicTee {
 public:
  // Told each chunk, on the thread that writes.
  explicit MusicTee(std::function<void(std::vector<uint8_t>)> made) : made_(std::move(made)), block_(MUSIC_PACK_FRAMES * 2), packed_(MUSIC_CHUNK_ROOM) {}

  // Whether chunks are made. From any thread.
  void Set(bool on) { on_ = on; }

  // Takes [frames] frames of interleaved stereo; null is that much silence.
  void Write(const int16_t* from, size_t frames) {
    if (!on_) {
      // Counted all the same: the numbers are of the sound and not of what was sent.
      at_ += held_ + frames;
      held_ = 0;
      return;
    }
    while (frames > 0) {
      const size_t n = (std::min)(frames, static_cast<size_t>(MUSIC_PACK_FRAMES) - held_);
      if (from) {
        std::memcpy(block_.data() + held_ * 2, from, n * 2 * sizeof(int16_t));
        from += n * 2;
      } else {
        std::memset(block_.data() + held_ * 2, 0, n * 2 * sizeof(int16_t));
      }
      held_ += n;
      frames -= n;
      if (held_ < MUSIC_PACK_FRAMES) return;
      const int bytes = music_chunk(block_.data(), MUSIC_PACK_FRAMES, at_, packed_.data());
      at_ += held_;
      held_ = 0;
      if (bytes > 0 && made_) made_(std::vector<uint8_t>(packed_.begin(), packed_.begin() + bytes));
    }
  }

 private:
  std::function<void(std::vector<uint8_t>)> made_;
  std::vector<int16_t> block_;
  std::vector<uint8_t> packed_;
  std::atomic<bool> on_{false};
  uint64_t at_ = 0;
  size_t held_ = 0;
};

#endif
