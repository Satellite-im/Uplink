// What waits to be played of a circle's music without loss, on Windows (music_sink.cpp; the Mac's is MusicRing in
// macos/Runner/MusicSink.swift): written by the app, read on the sound thread. Nothing of Windows in it, so
// tool/spotify/feed_check.cpp tries it anywhere.
#ifndef RUNNER_MUSIC_RING_H_
#define RUNNER_MUSIC_RING_H_

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <mutex>
#include <vector>

class MusicRing {
 public:
  static constexpr int kRate = 48000;
  // Three seconds: lib/voice/spotify_lossless.dart never has more than two waiting.
  static constexpr size_t kCapacity = kRate * 3;

  struct Now {
    size_t waiting;
    int dry;
  };

  // Takes 16-bit samples, interleaved, low byte first: the frames that wait now, and how often it has run out.
  Now Write(const uint8_t* data, size_t bytes) {
    std::lock_guard<std::mutex> hold(lock_);
    const size_t frames = (std::min)(bytes / 4, kCapacity - count_);
    size_t at = (head_ + count_) % kCapacity;
    for (size_t i = 0; i < frames; i++) {
      ring_[at * 2] = static_cast<int16_t>(data[i * 4] | (data[i * 4 + 1] << 8));
      ring_[at * 2 + 1] = static_cast<int16_t>(data[i * 4 + 2] | (data[i * 4 + 3] << 8));
      if (++at == kCapacity) at = 0;
    }
    count_ += frames;
    if (frames > 0) running_ = true;
    return {count_, dry_};
  }

  void Clear() {
    std::lock_guard<std::mutex> hold(lock_);
    head_ = count_ = 0;
    running_ = false;
  }

  void Set(float to) {
    std::lock_guard<std::mutex> hold(lock_);
    toward_ = (std::max)(0.0f, (std::min)(4.0f, to));
  }

  // The next [frames], interleaved; silence for what is not there. The loudness moves from silent to as loud as can be
  // in 30 ms, so it never clicks; at 1 the samples are what they were.
  void Read(int16_t* out, size_t frames) {
    std::lock_guard<std::mutex> hold(lock_);
    constexpr float kStep = 1.0f / (0.03f * kRate);
    const size_t n = (std::min)(frames, count_);
    for (size_t i = 0; i < n; i++) {
      if (gain_ < toward_) gain_ = (std::min)(toward_, gain_ + kStep);
      if (gain_ > toward_) gain_ = (std::max)(toward_, gain_ - kStep);
      for (size_t c = 0; c < 2; c++) {
        const float v = static_cast<float>(ring_[head_ * 2 + c]) * gain_;
        out[i * 2 + c] = static_cast<int16_t>((std::max)(-32768.0f, (std::min)(32767.0f, v)));
      }
      if (++head_ == kCapacity) head_ = 0;
    }
    count_ -= n;
    std::fill(out + n * 2, out + frames * 2, int16_t{0});
    if (n < frames) {
      if (running_) dry_++;
      running_ = false;
      gain_ = toward_;
    }
  }

 private:
  std::mutex lock_;
  std::vector<int16_t> ring_ = std::vector<int16_t>(kCapacity * 2, 0);
  size_t head_ = 0, count_ = 0;
  int dry_ = 0;
  bool running_ = false;
  float gain_ = 0, toward_ = 0;
};

#endif
