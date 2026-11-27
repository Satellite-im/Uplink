// The sound of the Spotify app on this PC, and of nothing else, as a track of flutter_webrtc's own, while a call is
// played its music (lib/voice/spotify_app.dart WindowsMusic; Matt, 2026-11-25: "also make sure this works on windows").
#ifndef RUNNER_SPOTIFY_SOUND_H_
#define RUNNER_SPOTIFY_SOUND_H_

#include <windows.h>

#include <atomic>
#include <functional>
#include <memory>
#include <string>
#include <thread>
#include <vector>

#include "music_feed.h"
#include "music_tee.h"

// Spotify's own process: the Spotify.exe of this Windows session whose parent is not a Spotify.exe (its helpers are
// under it), the desktop app's or the Microsoft Store's. An open handle to it, so that its number can't come to be
// another process's while the handle is held. Null where Spotify is not running.
HANDLE OpenSpotify(DWORD* pid);

// Takes Spotify's sound and gives it to a track. Made, begun and ended on the app's own thread.
class SpotifySound {
 public:
  // [quit] is told, on the capturing thread, when a Spotify that was being heard has gone; [chunk] each chunk of the music
  // without loss, on the same thread, while [Pack] has it made.
  SpotifySound(std::function<void()> quit, std::function<void(std::vector<uint8_t>)> chunk);
  ~SpotifySound();

  // Makes the track and begins: the track's id, or empty where it can't be (Windows before 10 version 2004, or no
  // WebRTC). The sound processing asked for is the microphone's own ([echo], [noise], [gain]): WebRTC keeps one set of it
  // for every track a device sends, and this track's sound goes through none of it.
  std::string Begin(bool echo, bool noise, bool gain);

  // Ends both threads, lets go of every handle, and takes the track away. Safe to call twice.
  void End();

  // The loudest it has been since last asked, 0 to 1.
  float Level();

  // Whether chunks of it are made too, for those who have it without loss (music_tee.h).
  void Pack(bool on) { tee_.Set(on); }

 private:
  struct Track;

  // Finds Spotify and hears it until it goes, again and again: [capture_].
  void Capture();
  // Hears the process [pid], open as [process], until it goes or [stop_]. False where its sound can't be taken.
  bool Hear(DWORD pid, HANDLE process);
  // Hands the track 10 ms of it every 10 ms, silence where there is none: [feeder_]. The one thread that does.
  void Feed();

  std::function<void()> quit_;
  std::unique_ptr<Track> track_;
  std::shared_ptr<MusicFeed> feed_ = std::make_shared<MusicFeed>();
  MusicTee tee_;
  std::thread capture_, feeder_;
  // Set to end both threads (a manual-reset event).
  HANDLE stop_ = nullptr;
  std::atomic<float> peak_{0.0f};
};

// The rate this PC's own sound runs at, frames a second; 0 where it can't be told. Below 44,100 (a Bluetooth headset whose
// microphone is in use) what Spotify plays may be taken at no more. Waits on the device: not for the app's thread.
double SpeakerRate();

// Whether this Windows can hear one program by itself: Windows 10 version 2004 (build 19041).
bool CanHearOneProgram();

#endif
