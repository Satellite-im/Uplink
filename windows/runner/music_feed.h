// The music waiting to be sent to a call, on Windows (spotify_sound.cpp; the Mac's is MusicFeed in
// macos/Runner/MusicLink.swift): written as Spotify plays it, read 10 ms at a time. Reading gets silence where there is
// none, and starts again only once a little is waiting, so a late block is one gap and not a stutter. Nothing of Windows
// in it, so tool/spotify/feed_check.cpp tries it anywhere.
#ifndef RUNNER_MUSIC_FEED_H_
#define RUNNER_MUSIC_FEED_H_

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <mutex>
#include <vector>

class MusicFeed {
 public:
  static constexpr int kRate = 48000;
  static constexpr size_t kChannels = 2;
  // What is sent at a time: 10 ms.
  static constexpr size_t kFrames = 480;

  // How much waits before reading starts, and the most that may wait: past it the oldest goes, so the music a listener
  // hears never falls behind by more. Loopback comes in bursts (the plugin's own capturer found gaps of 20 to 80 ms), so
  // a little more waits here than on the Mac.
  explicit MusicFeed(size_t prime_ms = 100, size_t most_ms = 300)
      : prime_(kRate * prime_ms / 1000), most_(kRate * most_ms / 1000), ring_(most_ * kChannels, 0) {}

  // Takes [frames] frames of interleaved stereo; null is that much silence.
  void Write(const int16_t* from, size_t frames) {
    std::lock_guard<std::mutex> hold(lock_);
    // More than there is room for: its newest part.
    const size_t n = std::min(frames, most_);
    if (from) from += (frames - n) * kChannels;
    if (count_ + n > most_) {
      const size_t over = count_ + n - most_;
      head_ = (head_ + over) % most_;
      count_ -= over;
    }
    size_t at = (head_ + count_) % most_;
    for (size_t i = 0; i < n; i++) {
      ring_[at * 2] = from ? from[i * 2] : int16_t{0};
      ring_[at * 2 + 1] = from ? from[i * 2 + 1] : int16_t{0};
      if (++at == most_) at = 0;
    }
    count_ += n;
  }

  // Fills [into] with [frames] frames; silence for what is not there.
  void Read(int16_t* into, size_t frames) {
    std::lock_guard<std::mutex> hold(lock_);
    if (!primed_ && count_ >= prime_) primed_ = true;
    const size_t n = primed_ ? std::min(frames, count_) : 0;
    for (size_t i = 0; i < n; i++) {
      into[i * 2] = ring_[head_ * 2];
      into[i * 2 + 1] = ring_[head_ * 2 + 1];
      if (++head_ == most_) head_ = 0;
    }
    count_ -= n;
    if (n < frames) {
      std::memset(into + n * kChannels, 0, (frames - n) * kChannels * sizeof(int16_t));
      primed_ = false;
    }
  }

  // Forgets what is waiting.
  void Clear() {
    std::lock_guard<std::mutex> hold(lock_);
    head_ = count_ = 0;
    primed_ = false;
  }

 private:
  const size_t prime_, most_;
  std::vector<int16_t> ring_;
  size_t head_ = 0, count_ = 0;
  bool primed_ = false;
  std::mutex lock_;
};

#endif
