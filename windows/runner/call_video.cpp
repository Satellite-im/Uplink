// A recording's picture, on Windows (GMFB-42: "capture the webcams and screenshares in the call, not just the audio
// tracks"; Matt, 2026-11-23: "One composed video", 2026-11-26: "Build Windows too"): the call's cameras and shared
// screens drawn into one video, 1280 by 720 at fifteen frames a second, encoded as it goes into an MP4 of its own
// beside the voices' files. The app puts that file's track into the recording after the voices
// (lib/voice/mp4_merge.dart). As the Mac's (macos/Runner/CallVideo.swift).
//
// What is drawn where is Dart's to say (lib/voice/recording_video.dart): it hands over a plate, the whole picture with
// every tile's back and name painted on it, and for each camera or screen that may be drawn (only of people whose own
// app said yes to voice and video) a track and a place. Nothing here decides who is seen.
//
// - Frames: a renderer on each track (libwebrtc's RTCVideoTrack::AddRenderer), found by its id through flutter_webrtc's
//   own instance, as the voices' tracks are. It keeps only the newest frame.
// - Each fifteenth of a second, on a thread of its own: the newest frame of each track is scaled into its place over
//   the plate and the whole handed to Media Foundation's H.264 writer as NV12, stamped by the same clock the voices'
//   files are held to (CallRecorderDue), so they stay in step. NV12, not RGB: a file of RGB frames is read from the
//   bottom row up unless told otherwise, and the two planes of NV12 are only ever read from the top.
//
// The file is whole only once it is ended: Media Foundation writes an MP4's index last, so a recording cut off by a
// crash keeps its voices (the app's own files) and loses its picture.
#include "call_video.h"

#include <windows.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <mferror.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <future>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "flutter_webrtc.h"
#include "flutter_webrtc/flutter_web_r_t_c_plugin.h"
#include "rtc_media_track.h"
#include "rtc_video_frame.h"
#include "rtc_video_renderer.h"
#include "rtc_video_track.h"

#include "call_recorder.h"
#include "main_thread.h"

namespace {

using Frame = libwebrtc::scoped_refptr<libwebrtc::RTCVideoFrame>;

// UTF-8 as Windows' own wide text, for its file calls.
std::wstring Wide(const std::string& s) {
  if (s.empty()) return std::wstring();
  int n = MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), nullptr, 0);
  std::wstring out(n, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), out.data(), n);
  return out;
}

// What WebRTC hands one picture's frames to. Frames come on WebRTC's own threads; the picture is asked for on the
// recording's thread alone.
class Tap : public libwebrtc::RTCVideoRenderer<Frame> {
 public:
  void OnFrame(Frame frame) override {
    std::lock_guard<std::mutex> lock(mutex_);
    newest_ = frame;
    fresh_ = true;
  }

  // The newest frame as rows of red, green, blue and a fourth byte, the way up it is meant to be seen; false until
  // one has come. What it points at is good until this is next asked.
  bool Picture(const uint8_t** data, int* width, int* height) {
    Frame frame;
    bool changed = false;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      frame = newest_;
      changed = fresh_;
      fresh_ = false;
    }
    if (changed && frame) Make(frame);
    if (pixels_.empty() || width_ <= 0 || height_ <= 0) return false;
    *data = pixels_.data();
    *width = width_;
    *height = height_;
    return true;
  }

 private:
  // [frame] as pixels, turned upright where it says it was taken on its side.
  void Make(Frame frame) {
    const int w = frame->width(), h = frame->height();
    if (w <= 0 || h <= 0 || w > 8192 || h > 8192) return;
    raw_.resize(static_cast<size_t>(w) * h * 4);
    // As flutter_webrtc's own renderer asks, for the same order of bytes: red first.
    frame->ConvertToARGB(libwebrtc::RTCVideoFrame::Type::kABGR, raw_.data(), 0, w, h);
    const int turn = static_cast<int>(frame->rotation());
    if (turn != 90 && turn != 180 && turn != 270) {
      pixels_.swap(raw_);
      width_ = w;
      height_ = h;
      return;
    }
    const bool side = turn != 180;
    const int ow = side ? h : w, oh = side ? w : h;
    pixels_.resize(static_cast<size_t>(ow) * oh * 4);
    const uint32_t* from = reinterpret_cast<const uint32_t*>(raw_.data());
    uint32_t* to = reinterpret_cast<uint32_t*>(pixels_.data());
    for (int y = 0; y < oh; y++) {
      for (int x = 0; x < ow; x++) {
        int sx, sy;
        if (turn == 90) {  // turned a quarter clockwise to be upright
          sx = y;
          sy = h - 1 - x;
        } else if (turn == 180) {
          sx = w - 1 - x;
          sy = h - 1 - y;
        } else {
          sx = w - 1 - y;
          sy = x;
        }
        to[static_cast<size_t>(y) * ow + x] = from[static_cast<size_t>(sy) * w + sx];
      }
    }
    width_ = ow;
    height_ = oh;
  }

  std::mutex mutex_;
  Frame newest_;
  bool fresh_ = false;
  // The recording's thread alone.
  std::vector<uint8_t> raw_, pixels_;
  int width_ = 0, height_ = 0;
};

// One picture's place, in the recording's pixels from its top left, and whether it is drawn whole (a screen) or
// fills its place with its edges cut (a camera).
struct Place {
  std::shared_ptr<Tap> tap;
  int x = 0, y = 0, w = 0, h = 0;
  bool contain = false;
};

// A track being drawn and the renderer on it. On the app's thread alone.
struct Held {
  libwebrtc::scoped_refptr<libwebrtc::RTCVideoTrack> track;
  std::shared_ptr<Tap> tap;
};
std::map<std::string, Held> g_taps;

// What the picture is made of now, under [g_layout]: the plate (width by height, four bytes a pixel) and the places.
std::mutex g_layout;
std::shared_ptr<std::vector<uint8_t>> g_plate;
std::vector<Place> g_places;

// Which recording the layout is of: counted up at each start, so a recording being ended never clears the next one's.
int g_take = 0;

// One recording's thread, and what it is told (to stop) and tells (the frames written). Each recording has its own,
// so one being ended on a thread of its own and the next being started never touch the same.
struct Take {
  std::thread thread;
  std::shared_ptr<std::atomic<bool>> stop = std::make_shared<std::atomic<bool>>(false);
  std::shared_ptr<std::atomic<int>> frames = std::make_shared<std::atomic<int>>(0);
};
// The recording being made; null while there is none. On the app's thread alone. Never deleted while its thread
// runs: a thread still running when the app is closed is left to end with it.
Take* g_now = nullptr;

// The picture track flutter_webrtc holds under [id]: this device's own camera or screen, or someone else's as their
// connection receives it. Null where there is none, or it is not a picture.
libwebrtc::scoped_refptr<libwebrtc::RTCVideoTrack> FindVideo(const std::string& id) {
  auto* webrtc = FlutterWebRTCPluginSharedInstance();
  if (!webrtc) return nullptr;
  flutter_webrtc_plugin::FlutterWebRTCBase* base = webrtc;
  auto track = base->MediaTrackForId(id);
  if (!track || track->kind().std_string() != "video") return nullptr;
  return libwebrtc::scoped_refptr<libwebrtc::RTCVideoTrack>(static_cast<libwebrtc::RTCVideoTrack*>(track.get()));
}

// Takes every renderer off its track. On the app's thread.
void Untap() {
  for (auto& entry : g_taps) {
    Held& held = entry.second;
    if (held.track && held.tap) held.track->RemoveRenderer(held.tap.get());
  }
  g_taps.clear();
}

// [src] (sw by sh) scaled into its place in [dst] (dw by dh): whole, with what is under it showing at its sides, or
// filling the place with its edges cut. Each pixel is the four of the picture nearest it, weighed by how near.
void Draw(std::vector<uint8_t>& dst, int dw, int dh, const Place& p, const uint8_t* src, int sw, int sh) {
  if (p.w <= 0 || p.h <= 0 || sw <= 0 || sh <= 0) return;
  const double fx = static_cast<double>(p.w) / sw, fy = static_cast<double>(p.h) / sh;
  const double s = p.contain ? std::min(fx, fy) : std::max(fx, fy);
  if (s <= 0) return;
  // How much of the place is drawn on, and how much of the picture is drawn.
  const int ow = std::max(1, std::min(p.w, static_cast<int>(std::lround(sw * s))));
  const int oh = std::max(1, std::min(p.h, static_cast<int>(std::lround(sh * s))));
  const int ox = p.x + (p.w - ow) / 2, oy = p.y + (p.h - oh) / 2;
  const double cw = std::min(static_cast<double>(sw), ow / s), ch = std::min(static_cast<double>(sh), oh / s);
  const double sx0 = (sw - cw) / 2, sy0 = (sh - ch) / 2;
  // Across: for each pixel, the picture's pixel to its left and how far past it (of 256).
  std::vector<int> left(ow), part(ow);
  for (int i = 0; i < ow; i++) {
    double at = sx0 + (i + 0.5) * cw / ow - 0.5;
    at = std::max(0.0, std::min(static_cast<double>(sw - 1), at));
    left[i] = static_cast<int>(at);
    part[i] = static_cast<int>((at - left[i]) * 256);
  }
  for (int j = 0; j < oh; j++) {
    const int y = oy + j;
    if (y < 0 || y >= dh) continue;
    double at = sy0 + (j + 0.5) * ch / oh - 0.5;
    at = std::max(0.0, std::min(static_cast<double>(sh - 1), at));
    const int top = static_cast<int>(at);
    const int down = static_cast<int>((at - top) * 256);
    const uint8_t* a = src + static_cast<size_t>(top) * sw * 4;
    const uint8_t* b = src + static_cast<size_t>(std::min(top + 1, sh - 1)) * sw * 4;
    uint8_t* row = dst.data() + static_cast<size_t>(y) * dw * 4;
    for (int i = 0; i < ow; i++) {
      const int x = ox + i;
      if (x < 0 || x >= dw) continue;
      uint8_t* out = row + static_cast<size_t>(x) * 4;
      const int l = left[i] * 4, r = std::min(left[i] + 1, sw - 1) * 4, wx = part[i];
      for (int c = 0; c < 3; c++) {
        const int up = a[l + c] * (256 - wx) + a[r + c] * wx;
        const int lo = b[l + c] * (256 - wx) + b[r + c] * wx;
        out[c] = static_cast<uint8_t>((up * (256 - down) + lo * down) >> 16);
      }
      out[3] = 255;
    }
  }
}

uint8_t Byte(int v) { return static_cast<uint8_t>(std::max(0, std::min(255, v))); }

// [rgba] (w by h, both even) as NV12 in [out]: a plane of brightness, then a plane half as wide and tall of the two
// colours side by side, each the mean of four pixels. BT.709, the narrow range, as a 720-line video is read.
void ToNv12(const std::vector<uint8_t>& rgba, int w, int h, uint8_t* out) {
  uint8_t* yp = out;
  uint8_t* uv = out + static_cast<size_t>(w) * h;
  for (int y = 0; y < h; y++) {
    const uint8_t* row = rgba.data() + static_cast<size_t>(y) * w * 4;
    for (int x = 0; x < w; x++) {
      const int r = row[x * 4], g = row[x * 4 + 1], b = row[x * 4 + 2];
      yp[static_cast<size_t>(y) * w + x] = Byte(((47 * r + 157 * g + 16 * b + 128) >> 8) + 16);
    }
  }
  for (int y = 0; y < h / 2; y++) {
    const uint8_t* r0 = rgba.data() + static_cast<size_t>(y) * 2 * w * 4;
    const uint8_t* r1 = r0 + static_cast<size_t>(w) * 4;
    uint8_t* to = uv + static_cast<size_t>(y) * w;
    for (int x = 0; x < w / 2; x++) {
      const int i = x * 8;
      const int r = (r0[i] + r0[i + 4] + r1[i] + r1[i + 4] + 2) >> 2;
      const int g = (r0[i + 1] + r0[i + 5] + r1[i + 1] + r1[i + 5] + 2) >> 2;
      const int b = (r0[i + 2] + r0[i + 6] + r1[i + 2] + r1[i + 6] + 2) >> 2;
      to[x * 2] = Byte(((-26 * r - 87 * g + 112 * b + 128) >> 8) + 128);
      to[x * 2 + 1] = Byte(((112 * r - 102 * g - 10 * b + 128) >> 8) + 128);
    }
  }
}

// Lets go of a COM object and forgets it; nothing where there is none.
template <typename T>
void Free(T*& p) {
  if (p) p->Release();
  p = nullptr;
}

// A type of video for the writer: [format] at [w] by [h], [fps] a second, whole frames, square pixels.
IMFMediaType* VideoType(const GUID& format, int w, int h, int fps) {
  IMFMediaType* t = nullptr;
  if (FAILED(MFCreateMediaType(&t))) return nullptr;
  t->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
  t->SetGUID(MF_MT_SUBTYPE, format);
  t->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
  MFSetAttributeSize(t, MF_MT_FRAME_SIZE, static_cast<UINT32>(w), static_cast<UINT32>(h));
  MFSetAttributeRatio(t, MF_MT_FRAME_RATE, static_cast<UINT32>(fps), 1);
  MFSetAttributeRatio(t, MF_MT_PIXEL_ASPECT_RATIO, 1, 1);
  t->SetUINT32(MF_MT_YUV_MATRIX, MFVideoTransferMatrix_BT709);
  t->SetUINT32(MF_MT_VIDEO_NOMINAL_RANGE, MFNominalRange_16_235);
  return t;
}

// The recording's thread: opens the file at [path], says through [began] whether it could, then makes a frame each
// [fps]th of a second until told to stop, and ends the file.
void Run(std::wstring path, int w, int h, int fps, int bitrate, std::shared_ptr<std::atomic<bool>> stop, std::shared_ptr<std::atomic<int>> frames, std::promise<bool> began) {
  const HRESULT co = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  const HRESULT mf = MFStartup(MF_VERSION);
  IMFSinkWriter* writer = nullptr;
  IMFAttributes* how = nullptr;
  IMFMediaType* target = nullptr;
  IMFMediaType* given = nullptr;
  DWORD stream = 0;
  bool ok = SUCCEEDED(mf);
  if (ok) {
    DeleteFileW(path.c_str());
    // Never held back to the clock by the writer: the frames are made on the clock here.
    if (SUCCEEDED(MFCreateAttributes(&how, 1))) how->SetUINT32(MF_SINK_WRITER_DISABLE_THROTTLING, TRUE);
    ok = SUCCEEDED(MFCreateSinkWriterFromURL(path.c_str(), nullptr, how, &writer));
  }
  if (ok) {
    target = VideoType(MFVideoFormat_H264, w, h, fps);
    ok = target != nullptr;
    if (ok) {
      target->SetUINT32(MF_MT_AVG_BITRATE, static_cast<UINT32>(bitrate));
      ok = SUCCEEDED(writer->AddStream(target, &stream));
    }
  }
  if (ok) {
    given = VideoType(MFVideoFormat_NV12, w, h, fps);
    ok = given != nullptr;
    if (ok) {
      given->SetUINT32(MF_MT_DEFAULT_STRIDE, static_cast<UINT32>(w));
      given->SetUINT32(MF_MT_ALL_SAMPLES_INDEPENDENT, TRUE);
      ok = SUCCEEDED(writer->SetInputMediaType(stream, given, nullptr)) && SUCCEEDED(writer->BeginWriting());
    }
  }
  began.set_value(ok);

  if (ok) {
    const size_t size = static_cast<size_t>(w) * h * 4;
    const DWORD nv12 = static_cast<DWORD>(w * h * 3 / 2);
    std::vector<uint8_t> canvas(size);
    const LONGLONG each = 10000000LL / fps;  // Media Foundation's times are in units of 100 nanoseconds
    LONGLONG last = -1;
    int written = 0;
    auto next = std::chrono::steady_clock::now();
    while (!stop->load()) {
      // The voices' clock (samples at 48 kHz since the recording began); the first frame is the file's beginning.
      LONGLONG at = written == 0 ? 0 : CallRecorderDue() * 10000000LL / 48000;
      if (at > last) {
        std::shared_ptr<std::vector<uint8_t>> plate;
        std::vector<Place> places;
        {
          std::lock_guard<std::mutex> lock(g_layout);
          plate = g_plate;
          places = g_places;
        }
        if (plate && plate->size() == size) {
          memcpy(canvas.data(), plate->data(), size);
        } else {
          std::fill(canvas.begin(), canvas.end(), static_cast<uint8_t>(0));
        }
        for (const auto& p : places) {
          const uint8_t* data = nullptr;
          int pw = 0, ph = 0;
          if (p.tap && p.tap->Picture(&data, &pw, &ph)) Draw(canvas, w, h, p, data, pw, ph);
        }
        IMFMediaBuffer* buffer = nullptr;
        IMFSample* sample = nullptr;
        if (SUCCEEDED(MFCreateMemoryBuffer(nv12, &buffer)) && SUCCEEDED(MFCreateSample(&sample))) {
          BYTE* to = nullptr;
          if (SUCCEEDED(buffer->Lock(&to, nullptr, nullptr))) {
            ToNv12(canvas, w, h, to);
            buffer->Unlock();
            buffer->SetCurrentLength(nv12);
            sample->AddBuffer(buffer);
            sample->SetSampleTime(at);
            sample->SetSampleDuration(each);
            if (SUCCEEDED(writer->WriteSample(stream, sample))) {
              written++;
              last = at;
              frames->store(written);
            }
          }
        }
        Free(sample);
        Free(buffer);
      }
      next += std::chrono::nanoseconds(1000000000LL / fps);
      const auto now = std::chrono::steady_clock::now();
      // Fallen far behind (the computer slept, or was very busy): go on from now, not in a burst.
      if (next < now) next = now;
      std::this_thread::sleep_until(next);
    }
    // A file with no frame in it is no file.
    if (written == 0 || FAILED(writer->Finalize())) {
      frames->store(0);
      Free(writer);
      DeleteFileW(path.c_str());
    }
  }
  Free(given);
  Free(target);
  Free(writer);
  Free(how);
  if (SUCCEEDED(mf)) MFShutdown();
  if (SUCCEEDED(co)) CoUninitialize();
}

// Tells the recording being made to stop and hands it over, to be waited for ([Finish]); null where there is none.
// On the app's thread.
Take* Halt() {
  Take* take = g_now;
  g_now = nullptr;
  if (take) take->stop->store(true);
  return take;
}

// Waits for [take]'s file to be closed and says how many frames it has. On any thread; [take] is gone after.
int Finish(Take* take) {
  if (!take) return 0;
  if (take->thread.joinable()) take->thread.join();
  const int frames = take->frames->load();
  delete take;
  return frames;
}

// Forgets the layout, where it is still recording [take]'s.
void Forget(int take) {
  std::lock_guard<std::mutex> lock(g_layout);
  if (g_take != take) return;
  g_plate = nullptr;
  g_places.clear();
}

// Begins the picture's file at [path]; false where it couldn't be begun (no H.264 encoder on this Windows, or the
// file can't be made).
bool Start(const std::string& path, int w, int h, int fps, int bitrate) {
  // Even sizes only: the colours of NV12 are a plane half as wide and tall.
  if (path.empty() || w <= 0 || h <= 0 || fps <= 0 || fps > 60 || w % 2 != 0 || h % 2 != 0 || w > 4096 || h > 4096) return false;
  Untap();
  Finish(Halt());
  {
    std::lock_guard<std::mutex> lock(g_layout);
    g_take++;
    g_plate = nullptr;
    g_places.clear();
  }
  Take* take = new Take();
  std::promise<bool> began;
  std::future<bool> answer = began.get_future();
  take->thread = std::thread(Run, Wide(path), w, h, fps, bitrate, take->stop, take->frames, std::move(began));
  if (!answer.get()) {
    take->stop->store(true);
    Finish(take);
    return false;
  }
  g_now = take;
  return true;
}

// A call's argument by name; null where it is missing.
const flutter::EncodableValue* Arg(const flutter::EncodableMap* args, const char* name) {
  if (!args) return nullptr;
  auto it = args->find(flutter::EncodableValue(name));
  return it == args->end() ? nullptr : &it->second;
}

std::string Str(const flutter::EncodableMap* args, const char* name) {
  const auto* v = Arg(args, name);
  const auto* s = v ? std::get_if<std::string>(v) : nullptr;
  return s ? *s : std::string();
}

// A whole number, which Dart sends as 32 or 64 bits by its size; [otherwise] where it is missing.
int Int(const flutter::EncodableMap* args, const char* name, int otherwise) {
  const auto* v = Arg(args, name);
  if (!v) return otherwise;
  if (const auto* a = std::get_if<int32_t>(v)) return static_cast<int>(*a);
  if (const auto* b = std::get_if<int64_t>(v)) return static_cast<int>(*b);
  return otherwise;
}

bool Flag(const flutter::EncodableMap* args, const char* name) {
  const auto* v = Arg(args, name);
  const auto* b = v ? std::get_if<bool>(v) : nullptr;
  return b && *b;
}

// What the picture is made of from now on: the plate under each tile (a track, and its place in pixels from the top
// left). Answers the tracks that could not be found, for Dart to say again once they are held.
flutter::EncodableList Layout(const flutter::EncodableMap* args) {
  flutter::EncodableList missing;
  const int width = Int(args, "width", 0), height = Int(args, "height", 0);
  std::map<std::string, Held> next;
  std::vector<Place> placed;
  const auto* tilesValue = Arg(args, "tiles");
  const auto* tiles = tilesValue ? std::get_if<flutter::EncodableList>(tilesValue) : nullptr;
  if (tiles) {
    for (const auto& value : *tiles) {
      const auto* t = std::get_if<flutter::EncodableMap>(&value);
      if (!t) continue;
      const std::string id = Str(t, "track");
      Place p;
      p.x = Int(t, "x", 0);
      p.y = Int(t, "y", 0);
      p.w = Int(t, "w", 0);
      p.h = Int(t, "h", 0);
      p.contain = Flag(t, "contain");
      if (id.empty() || p.w <= 0 || p.h <= 0) continue;
      auto track = FindVideo(id);
      if (!track) {
        missing.push_back(flutter::EncodableValue(id));
        continue;
      }
      std::shared_ptr<Tap> tap;
      auto made = next.find(id);
      auto had = g_taps.find(id);
      if (made != next.end()) {
        tap = made->second.tap;
      } else if (had != g_taps.end() && had->second.track.get() == track.get()) {
        tap = had->second.tap;
      } else {
        // A new track, or the same id on a connection made again: a renderer of its own.
        tap = std::make_shared<Tap>();
        track->AddRenderer(tap.get());
      }
      next[id] = Held{track, tap};
      p.tap = tap;
      placed.push_back(std::move(p));
    }
  }
  // Renderers no tile has any more come off their tracks.
  for (auto& entry : g_taps) {
    Held& held = entry.second;
    auto kept = next.find(entry.first);
    if (kept == next.end() || kept->second.tap.get() != held.tap.get()) {
      if (held.track && held.tap) held.track->RemoveRenderer(held.tap.get());
    }
  }
  g_taps = std::move(next);
  // The plate only where it is the size it says: width by height pixels of four bytes, the top row first.
  std::shared_ptr<std::vector<uint8_t>> plate;
  const auto* plateValue = Arg(args, "plate");
  const auto* bytes = plateValue ? std::get_if<std::vector<uint8_t>>(plateValue) : nullptr;
  if (bytes && width > 0 && height > 0 && bytes->size() == static_cast<size_t>(width) * height * 4) {
    plate = std::make_shared<std::vector<uint8_t>>(*bytes);
  }
  {
    std::lock_guard<std::mutex> lock(g_layout);
    if (plate) g_plate = plate;
    g_places = std::move(placed);
  }
  return missing;
}

}  // namespace

void CallVideoHandle(const std::string& method, const flutter::EncodableMap* args, std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (method == "video.start") {
    result->Success(flutter::EncodableValue(Start(Str(args, "path"), Int(args, "width", 1280), Int(args, "height", 720), Int(args, "fps", 15), Int(args, "bitrate", 1600000))));
  } else if (method == "video.layout") {
    result->Success(flutter::EncodableValue(Layout(args)));
  } else if (method == "video.stop") {
    // The file is closed on a thread of its own (the encoder is emptied first); the answer goes back on the app's.
    Untap();
    Take* take = Halt();
    int of = 0;
    {
      std::lock_guard<std::mutex> lock(g_layout);
      of = g_take;
    }
    std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> held(result.release());
    std::thread([held, take, of] {
      const int frames = Finish(take);
      Forget(of);
      RunOnMain([held, frames] {
        flutter::EncodableMap answer;
        answer[flutter::EncodableValue("frames")] = flutter::EncodableValue(frames);
        held->Success(flutter::EncodableValue(answer));
      });
    }).detach();
  } else {
    result->NotImplemented();
  }
}
