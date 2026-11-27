// Runs windows/runner/call_video.cpp's own work on a Mac, over the stand-ins beside this (windows.h says what they
// are): three made-up tracks (a camera, a wide screen, a phone's camera sent on its side), a plate, the layout
// changed part way, a stop. What "Media Foundation" was handed is left as raw NV12 for run.sh to make pictures of.
#include <chrono>
#include <cstdio>
#include <functional>
#include <thread>

#include "call_recorder.h"
#include "call_video.h"
#include "flutter_webrtc.h"
#include "main_thread.h"

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;

static flutter_webrtc_plugin::FlutterWebRTCBase g_base;
flutter_webrtc_plugin::FlutterWebRTCBase* FlutterWebRTCPluginSharedInstance() { return &g_base; }
static auto g_began = std::chrono::steady_clock::now();
int64_t CallRecorderDue() {
  return std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now() - g_began).count() * 48000 / 1000000;
}
void RunOnMain(std::function<void()> work) { work(); }

// A frame with a corner of its own colour each, so a picture turned or upside down shows: red top left, green top
// right, blue bottom left, white bottom right, over a ramp that brightens to the right.
static libwebrtc::scoped_refptr<libwebrtc::RTCVideoFrame> Frame(int w, int h, int tint) {
  libwebrtc::scoped_refptr<libwebrtc::RTCVideoFrame> f(new libwebrtc::RTCVideoFrame());
  f->w = w;
  f->h = h;
  f->rgba.resize(static_cast<size_t>(w) * h * 4);
  for (int y = 0; y < h; y++) {
    for (int x = 0; x < w; x++) {
      uint8_t* p = &f->rgba[(static_cast<size_t>(y) * w + x) * 4];
      const int v = 40 + 160 * x / w;
      p[0] = static_cast<uint8_t>(tint == 0 ? v : v / 3);
      p[1] = static_cast<uint8_t>(tint == 1 ? v : v / 3);
      p[2] = static_cast<uint8_t>(tint == 2 ? v : v / 3);
      p[3] = 255;
      const bool left = x < w / 5, right = x >= w - w / 5, top = y < h / 5, bottom = y >= h - h / 5;
      if (top && left) { p[0] = 255; p[1] = 0; p[2] = 0; }
      if (top && right) { p[0] = 0; p[1] = 255; p[2] = 0; }
      if (bottom && left) { p[0] = 0; p[1] = 0; p[2] = 255; }
      if (bottom && right) { p[0] = 255; p[1] = 255; p[2] = 255; }
    }
  }
  return f;
}

struct Answer : flutter::MethodResult<EncodableValue> {
  EncodableValue* to;
  explicit Answer(EncodableValue* t) : to(t) {}
  void Success(const EncodableValue& v) override { *to = v; }
  void NotImplemented() override { *to = EncodableValue("not implemented"); }
};

// One call, and its answer once it comes: video.stop's comes from the thread that closed the file.
static EncodableValue Call(const char* method, const EncodableMap& args) {
  static std::vector<std::unique_ptr<EncodableValue>> kept;
  kept.push_back(std::make_unique<EncodableValue>());
  EncodableValue* got = kept.back().get();
  CallVideoHandle(method, &args, std::make_unique<Answer>(got));
  for (int i = 0; i < 300 && std::holds_alternative<std::monostate>(*got); i++) std::this_thread::sleep_for(std::chrono::milliseconds(10));
  return *got;
}

static EncodableValue Tile(const char* track, int x, int y, int w, int h, bool contain) {
  EncodableMap m;
  m[EncodableValue("track")] = EncodableValue(track);
  m[EncodableValue("x")] = EncodableValue(x);
  m[EncodableValue("y")] = EncodableValue(y);
  m[EncodableValue("w")] = EncodableValue(w);
  m[EncodableValue("h")] = EncodableValue(h);
  m[EncodableValue("contain")] = EncodableValue(contain);
  return EncodableValue(m);
}

int main(int argc, char** argv) {
  const std::string out = argc > 1 ? argv[1] : "check.mp4";
  const int W = 1280, H = 720;
  for (const char* id : {"camera", "screen", "phone"}) g_base.tracks[id] = libwebrtc::scoped_refptr<libwebrtc::RTCVideoTrack>(new libwebrtc::RTCVideoTrack());
  // The plate: dark grey, a lighter band along the foot of it where names would be.
  std::vector<uint8_t> plate(static_cast<size_t>(W) * H * 4);
  for (int y = 0; y < H; y++)
    for (int x = 0; x < W; x++) {
      uint8_t* p = &plate[(static_cast<size_t>(y) * W + x) * 4];
      p[0] = p[1] = p[2] = y > H - 40 ? 90 : 30;
      p[3] = 255;
    }
  EncodableMap start;
  start[EncodableValue("path")] = EncodableValue(out);
  start[EncodableValue("width")] = EncodableValue(W);
  start[EncodableValue("height")] = EncodableValue(H);
  start[EncodableValue("fps")] = EncodableValue(15);
  start[EncodableValue("bitrate")] = EncodableValue(1600000);
  if (!std::get<bool>(Call("video.start", start))) return printf("did not start\n"), 1;

  auto send = [&](const char* id, libwebrtc::scoped_refptr<libwebrtc::RTCVideoFrame> f) {
    for (auto* r : g_base.tracks[id]->renderers) r->OnFrame(f);
  };
  // First: a camera filling the left half (its edges cut), a phone's camera on the right, sent on its side.
  EncodableMap a;
  a[EncodableValue("plate")] = EncodableValue(plate);
  a[EncodableValue("width")] = EncodableValue(W);
  a[EncodableValue("height")] = EncodableValue(H);
  a[EncodableValue("tiles")] = EncodableValue(EncodableList{Tile("camera", 8, 8, 628, 664, false), Tile("phone", 644, 8, 628, 664, true), Tile("nobody", 0, 0, 10, 10, false)});
  auto missing = std::get<EncodableList>(Call("video.layout", a));
  printf("missing %zu (%s)\n", missing.size(), missing.empty() ? "" : std::get<std::string>(missing[0]).c_str());
  auto phone = Frame(640, 360, 2);  // a tall picture as a phone sends it: on its side, to be turned a quarter
  phone->turn = libwebrtc::RTCVideoFrame::kVideoRotation_90;
  for (int i = 0; i < 15; i++) {
    send("camera", Frame(640, 480, 0));
    send("phone", phone);
    std::this_thread::sleep_for(std::chrono::milliseconds(66));
  }
  // Then: the screen large and whole, the camera small beside it.
  EncodableMap b;
  b[EncodableValue("plate")] = EncodableValue(plate);
  b[EncodableValue("width")] = EncodableValue(W);
  b[EncodableValue("height")] = EncodableValue(H);
  b[EncodableValue("tiles")] = EncodableValue(EncodableList{Tile("screen", 8, 8, 1000, 664, true), Tile("camera", 1016, 8, 256, 144, false)});
  Call("video.layout", b);
  printf("renderers left on the phone's track: %zu\n", g_base.tracks["phone"]->renderers.size());
  for (int i = 0; i < 15; i++) {
    send("screen", Frame(1920, 1080, 1));
    send("camera", Frame(640, 480, 0));
    std::this_thread::sleep_for(std::chrono::milliseconds(66));
  }
  auto ended = std::get<EncodableMap>(Call("video.stop", EncodableMap{}));
  printf("frames said: %d\n", std::get<int32_t>(ended[EncodableValue("frames")]));
  printf("renderers left: %zu %zu\n", g_base.tracks["camera"]->renderers.size(), g_base.tracks["screen"]->renderers.size());
  return 0;
}
