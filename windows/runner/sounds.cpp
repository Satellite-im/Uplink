// The app's interface sounds on Windows (lib/sounds.dart): a sound's WAV, already at the loudness wanted, played
// from memory, once or over and over (ringing). PlaySound plays one sound at a time: a new one takes the place of
// the one before, which for these short sounds is not heard.
#include "sounds.h"

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <windows.h>
#include <mmsystem.h>

#include <memory>
#include <vector>

namespace {

std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> g_channel;
// PlaySound reads the sound from this memory while it plays: kept until the next one.
std::vector<uint8_t> g_playing;

}  // namespace

// The "ghost/sound" channel: play (a WAV's bytes, once or looped) and stop.
void RegisterSounds(flutter::BinaryMessenger* messenger) {
  g_channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(messenger, "ghost/sound", &flutter::StandardMethodCodec::GetInstance());
  g_channel->SetMethodCallHandler([](const flutter::MethodCall<flutter::EncodableValue>& call, std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
    if (call.method_name() == "play") {
      bool loop = false;
      const std::vector<uint8_t>* bytes = nullptr;
      if (const auto* args = std::get_if<flutter::EncodableMap>(call.arguments())) {
        auto b = args->find(flutter::EncodableValue("bytes"));
        if (b != args->end()) bytes = std::get_if<std::vector<uint8_t>>(&b->second);
        auto l = args->find(flutter::EncodableValue("loop"));
        if (l != args->end()) {
          if (const auto* v = std::get_if<bool>(&l->second)) loop = *v;
        }
      }
      if (bytes && !bytes->empty()) {
        // The one playing is stopped before its memory is written over.
        PlaySoundW(nullptr, nullptr, 0);
        g_playing = *bytes;
        PlaySoundW(reinterpret_cast<LPCWSTR>(g_playing.data()), nullptr, SND_MEMORY | SND_ASYNC | SND_NODEFAULT | (loop ? SND_LOOP : 0));
      }
      result->Success();
      return;
    }
    if (call.method_name() == "stop") {
      PlaySoundW(nullptr, nullptr, 0);
      result->Success();
      return;
    }
    result->NotImplemented();
  });
}
