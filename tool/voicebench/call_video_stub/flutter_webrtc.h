// Stand-ins for flutter_webrtc and libwebrtc (see windows.h): tracks kept by id, frames of four bytes a pixel.
#ifndef STUB_FLUTTER_WEBRTC_H_
#define STUB_FLUTTER_WEBRTC_H_
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <map>
#include <memory>
#include <string>
#include <vector>
namespace libwebrtc {
// Counted inside the thing itself, as libwebrtc's are: a second pointer made from a plain one shares the count.
struct Counted {
  std::atomic<int> count{0};
  virtual ~Counted() {}
};
template <typename T>
class scoped_refptr {
 public:
  scoped_refptr() {}
  scoped_refptr(std::nullptr_t) {}
  scoped_refptr(T* p) : p_(p) { if (p_) p_->count++; }
  scoped_refptr(const scoped_refptr& o) : p_(o.p_) { if (p_) p_->count++; }
  template <typename U>
  scoped_refptr(const scoped_refptr<U>& o) : p_(o.get()) { if (p_) p_->count++; }
  ~scoped_refptr() { Drop(); }
  scoped_refptr& operator=(const scoped_refptr& o) {
    if (o.p_) o.p_->count++;
    Drop();
    p_ = o.p_;
    return *this;
  }
  T* get() const { return p_; }
  T* operator->() const { return p_; }
  explicit operator bool() const { return p_ != nullptr; }

 private:
  void Drop() { if (p_ && --p_->count == 0) delete p_; p_ = nullptr; }
  T* p_ = nullptr;
};
struct string { std::string s; std::string std_string() const { return s; } };
class RTCVideoFrame : public Counted {
 public:
  enum class Type { kARGB, kBGRA, kABGR, kRGBA };
  enum VideoRotation { kVideoRotation_0 = 0, kVideoRotation_90 = 90, kVideoRotation_180 = 180, kVideoRotation_270 = 270 };
  int w = 0, h = 0;
  VideoRotation turn = kVideoRotation_0;
  std::vector<uint8_t> rgba;
  int width() const { return w; }
  int height() const { return h; }
  VideoRotation rotation() { return turn; }
  int ConvertToARGB(Type, uint8_t* dst, int, int, int) { memcpy(dst, rgba.data(), rgba.size()); return 0; }
};
template <typename F>
class RTCVideoRenderer {
 public:
  virtual ~RTCVideoRenderer() {}
  virtual void OnFrame(F frame) = 0;
};
class RTCMediaTrack : public Counted {
 public:
  string kind() const { return string{"video"}; }
};
class RTCVideoTrack : public RTCMediaTrack {
 public:
  std::vector<RTCVideoRenderer<scoped_refptr<RTCVideoFrame>>*> renderers;
  void AddRenderer(RTCVideoRenderer<scoped_refptr<RTCVideoFrame>>* r) { renderers.push_back(r); }
  void RemoveRenderer(RTCVideoRenderer<scoped_refptr<RTCVideoFrame>>* r) {
    for (size_t i = 0; i < renderers.size(); i++) if (renderers[i] == r) { renderers.erase(renderers.begin() + static_cast<long>(i)); break; }
  }
};
}  // namespace libwebrtc
namespace flutter_webrtc_plugin {
class FlutterWebRTCBase {
 public:
  std::map<std::string, libwebrtc::scoped_refptr<libwebrtc::RTCVideoTrack>> tracks;
  libwebrtc::scoped_refptr<libwebrtc::RTCMediaTrack> MediaTrackForId(const std::string& id) {
    auto it = tracks.find(id);
    if (it == tracks.end()) return nullptr;
    return libwebrtc::scoped_refptr<libwebrtc::RTCMediaTrack>(it->second);
  }
};
}  // namespace flutter_webrtc_plugin
flutter_webrtc_plugin::FlutterWebRTCBase* FlutterWebRTCPluginSharedInstance();
#endif
