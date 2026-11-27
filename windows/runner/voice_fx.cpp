// What is done to the microphone before Opus, on Windows (lib/voice/voice_fx.dart; Matt, 2026-11-15: "build in like
// krisp noise supression or other fancy noise suppression tools, add a volume slider for input ... with
// overboosting"): RNNoise, DeepFilterNet where the build made it, and the gain, from native/voicefx, set as
// the capture post-processing of flutter_webrtc's own WebRTC. flutter_webrtc's DLL hands out its instance
// (FlutterWebRTCPluginSharedInstance), and its audio_processing() is libwebrtc's RTCAudioProcessing, whose
// CustomProcessing gets each 10 ms block: floats on the 16-bit scale, as on Android and the Mac.
#include "voice_fx.h"
#include "call_recorder.h"

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <windows.h>

#include <memory>
#include <string>
#include <thread>
#include <vector>
#include <cstring>

#include "flutter_webrtc.h"
#include "flutter_webrtc/flutter_web_r_t_c_plugin.h"
#include "rtc_audio_processing.h"

extern "C" {
#include "voicefx.h"
}

namespace {

// What libwebrtc calls with each block of the microphone, on its audio thread; it owns the one VoiceFx.
class Processor : public libwebrtc::RTCAudioProcessing::CustomProcessing {
 public:
  Processor() : fx_(voicefx_create()) {}

  void Initialize(int sample_rate_hz, int num_channels) override {}

  // A block is 10 ms, so the rate is a hundred times its frames.
  void Process(int num_bands, int num_frames, int buffer_size, float* buffer) override {
    voicefx_process(fx_, buffer, num_frames, num_frames * 100);
    // A call being recorded takes this device's voice as it is sent (call_recorder.cpp).
    CallRecorderMic(buffer, num_frames, num_frames * 100);
  }

  void Reset(int new_rate) override {}

  void Release() override {}

  VoiceFx* fx() { return fx_; }

 private:
  VoiceFx* fx_;
};

Processor* g_processor = nullptr;
bool g_attached = false;
std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> g_channel;

// Into flutter_webrtc's capture post-processing, once; false while flutter_webrtc has no audio processing to give.
bool Attach() {
  if (g_attached) return true;
  auto* webrtc = FlutterWebRTCPluginSharedInstance();
  if (!webrtc) return false;
  flutter_webrtc_plugin::FlutterWebRTCBase* base = webrtc;
  auto processing = base->audio_processing();
  if (!processing) return false;
  processing->SetCapturePostProcessing(g_processor);
  g_attached = true;
  return true;
}

}  // namespace

// The "ghost/voicefx" channel: modes (what this build can do) and configure (the mode and the gain, 1 for as it is).
void RegisterVoiceFx(flutter::BinaryMessenger* messenger) {
  if (!g_processor) {
    g_processor = new Processor();
    // DeepFilterNet, where this build has it: its model is built in, made ready once, off this thread. A build
    // without it answers 0 and offers RNNoise alone.
    std::thread([fx = g_processor->fx()] { voicefx_deepfilter_model(fx, ""); }).detach();
  }
  g_channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(messenger, "ghost/voicefx", &flutter::StandardMethodCodec::GetInstance());
  g_channel->SetMethodCallHandler([](const flutter::MethodCall<flutter::EncodableValue>& call, std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
    if (call.method_name() == "modes") {
      int bits = voicefx_modes(g_processor->fx());
      flutter::EncodableList modes;
      if (bits & (1 << VOICEFX_RNNOISE)) modes.push_back(flutter::EncodableValue("rnnoise"));
      if (bits & (1 << VOICEFX_DEEPFILTER)) modes.push_back(flutter::EncodableValue("deepfilter"));
      modes.push_back(flutter::EncodableValue("live"));
      modes.push_back(flutter::EncodableValue("effects"));
      result->Success(flutter::EncodableValue(modes));
      return;
    }
    // Live voice changing (lib/voice/live_changer.dart): what was said, taken; the changed voice, fed.
    const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
    auto arg = [&](const char* name) -> const flutter::EncodableValue* {
      if (!args) return nullptr;
      auto it = args->find(flutter::EncodableValue(name));
      return it == args->end() ? nullptr : &it->second;
    };
    auto number = [&](const char* name, int fallback) {
      const auto* v = arg(name);
      if (!v) return fallback;
      if (const auto* i = std::get_if<int32_t>(v)) return static_cast<int>(*i);
      if (const auto* l = std::get_if<int64_t>(v)) return static_cast<int>(*l);
      return fallback;
    };
    // A voice effect made here as it is said (lib/voice/live_changer.dart, native/voicefx voicefx_effect).
    if (call.method_name() == "effect") {
      const auto* v = arg("name");
      const auto* name = v ? std::get_if<std::string>(v) : nullptr;
      const std::string n = name ? *name : std::string();
      voicefx_effect(g_processor->fx(), voicefx_effect_id(n.c_str()));
      result->Success(flutter::EncodableValue(Attach()));
      return;
    }
    if (call.method_name() == "live") {
      const auto* on = arg("on");
      const auto* b = on ? std::get_if<bool>(on) : nullptr;
      voicefx_live(g_processor->fx(), b && *b ? 1 : 0);
      result->Success(flutter::EncodableValue(Attach()));
      return;
    }
    if (call.method_name() == "take") {
      int most = number("most", 32000);
      if (most < 1) most = 1;
      std::vector<int16_t> buf(static_cast<size_t>(most));
      int n = voicefx_take(g_processor->fx(), buf.data(), most);
      const auto* bytes = reinterpret_cast<const uint8_t*>(buf.data());
      result->Success(flutter::EncodableValue(std::vector<uint8_t>(bytes, bytes + n * 2)));
      return;
    }
    if (call.method_name() == "feed") {
      const auto* pcm = arg("pcm");
      const auto* data = pcm ? std::get_if<std::vector<uint8_t>>(pcm) : nullptr;
      if (data && data->size() >= 2) {
        std::vector<int16_t> samples(data->size() / 2);
        memcpy(samples.data(), data->data(), samples.size() * 2);
        voicefx_feed(g_processor->fx(), samples.data(), static_cast<int>(samples.size()), number("rate", 24000));
      }
      result->Success(flutter::EncodableValue(voicefx_queued_ms(g_processor->fx())));
      return;
    }
    if (call.method_name() == "queued") {
      result->Success(flutter::EncodableValue(voicefx_queued_ms(g_processor->fx())));
      return;
    }
    if (call.method_name() == "configure") {
      int mode = VOICEFX_OFF;
      double gain = 1.0;
      if (const auto* given = std::get_if<flutter::EncodableMap>(call.arguments())) {
        auto m = given->find(flutter::EncodableValue("mode"));
        if (m != given->end()) {
          if (const auto* name = std::get_if<std::string>(&m->second)) mode = *name == "rnnoise" ? VOICEFX_RNNOISE : *name == "deepfilter" ? VOICEFX_DEEPFILTER : VOICEFX_OFF;
        }
        auto g = given->find(flutter::EncodableValue("gain"));
        if (g != given->end()) {
          if (const auto* v = std::get_if<double>(&g->second)) gain = *v;
        }
      }
      voicefx_configure(g_processor->fx(), mode, static_cast<float>(gain));
      result->Success(flutter::EncodableValue(Attach()));
      return;
    }
    result->NotImplemented();
  });
}
