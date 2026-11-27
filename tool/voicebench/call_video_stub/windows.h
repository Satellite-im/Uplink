// A stand-in for the few names of Windows and Media Foundation that windows/runner/call_video.cpp uses, so its own
// work (taking frames, turning, scaling, laying over the plate, NV12, the clock) can be compiled and run on a Mac
// (tool/voicebench/call_video_stub/run.sh). The "writer" here writes each frame it is given, as it is, to
// <path>.nv12, and the times to <path>.times. Nothing here says the real calls are right: only Windows does.
#ifndef STUB_WINDOWS_H_
#define STUB_WINDOWS_H_
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>
typedef long HRESULT;
typedef unsigned long DWORD;
typedef unsigned char BYTE;
typedef unsigned int UINT32;
typedef long long LONGLONG;
typedef void* HWND;
typedef void* WNDPROC;
struct GUID { int id; };
#define TRUE 1
#define CP_UTF8 65001
#define COINIT_MULTITHREADED 0
#define MF_VERSION 0
#define SUCCEEDED(hr) ((hr) >= 0)
#define FAILED(hr) ((hr) < 0)
inline int MultiByteToWideChar(int, int, const char* s, int n, wchar_t* out, int) {
  if (out) for (int i = 0; i < n; i++) out[i] = static_cast<wchar_t>(static_cast<unsigned char>(s[i]));
  return n;
}
inline std::string StubNarrow(const wchar_t* w) { std::string s; for (; *w; w++) s.push_back(static_cast<char>(*w)); return s; }
inline void DeleteFileW(const wchar_t* w) { remove(StubNarrow(w).c_str()); }
inline HRESULT CoInitializeEx(void*, int) { return 0; }
inline void CoUninitialize() {}
inline HRESULT MFStartup(int) { return 0; }
inline void MFShutdown() {}
const GUID MF_MT_MAJOR_TYPE{1}, MF_MT_SUBTYPE{2}, MFMediaType_Video{3}, MFVideoFormat_H264{4}, MFVideoFormat_NV12{5}, MF_MT_INTERLACE_MODE{6}, MF_MT_FRAME_SIZE{7}, MF_MT_FRAME_RATE{8}, MF_MT_PIXEL_ASPECT_RATIO{9}, MF_MT_YUV_MATRIX{10}, MF_MT_VIDEO_NOMINAL_RANGE{11}, MF_MT_AVG_BITRATE{12}, MF_MT_DEFAULT_STRIDE{13}, MF_MT_ALL_SAMPLES_INDEPENDENT{14}, MF_SINK_WRITER_DISABLE_THROTTLING{15};
enum { MFVideoInterlace_Progressive = 2, MFVideoTransferMatrix_BT709 = 1, MFNominalRange_16_235 = 2 };
struct IMFAttributes {
  virtual ~IMFAttributes() {}
  HRESULT SetUINT32(const GUID&, UINT32) { return 0; }
  HRESULT SetGUID(const GUID&, const GUID&) { return 0; }
  void Release() { delete this; }
};
struct IMFMediaType : IMFAttributes {};
inline HRESULT MFCreateAttributes(IMFAttributes** a, int) { *a = new IMFAttributes(); return 0; }
inline HRESULT MFCreateMediaType(IMFMediaType** t) { *t = new IMFMediaType(); return 0; }
inline HRESULT MFSetAttributeSize(IMFAttributes*, const GUID&, UINT32, UINT32) { return 0; }
inline HRESULT MFSetAttributeRatio(IMFAttributes*, const GUID&, UINT32, UINT32) { return 0; }
struct IMFMediaBuffer {
  std::vector<BYTE> bytes;
  HRESULT Lock(BYTE** p, DWORD*, DWORD*) { *p = bytes.data(); return 0; }
  void Unlock() {}
  void SetCurrentLength(DWORD) {}
  void Release() {}
};
inline HRESULT MFCreateMemoryBuffer(DWORD n, IMFMediaBuffer** b) { *b = new IMFMediaBuffer(); (*b)->bytes.resize(n); return 0; }
struct IMFSample {
  IMFMediaBuffer* buffer = nullptr;
  LONGLONG time = 0;
  void AddBuffer(IMFMediaBuffer* b) { buffer = b; }
  void SetSampleTime(LONGLONG t) { time = t; }
  void SetSampleDuration(LONGLONG) {}
  void Release() { delete buffer; delete this; }
};
inline HRESULT MFCreateSample(IMFSample** s) { *s = new IMFSample(); return 0; }
struct IMFSinkWriter {
  FILE* frames = nullptr;
  FILE* times = nullptr;
  HRESULT AddStream(IMFMediaType*, DWORD* stream) { *stream = 0; return 0; }
  HRESULT SetInputMediaType(DWORD, IMFMediaType*, void*) { return 0; }
  HRESULT BeginWriting() { return frames ? 0 : -1; }
  HRESULT WriteSample(DWORD, IMFSample* s) {
    fwrite(s->buffer->bytes.data(), 1, s->buffer->bytes.size(), frames);
    fprintf(times, "%lld\n", s->time);
    return 0;
  }
  HRESULT Finalize() { fclose(frames); fclose(times); frames = times = nullptr; return 0; }
  void Release() { if (frames) fclose(frames); if (times) fclose(times); delete this; }
};
inline HRESULT MFCreateSinkWriterFromURL(const wchar_t* path, void*, IMFAttributes*, IMFSinkWriter** w) {
  *w = new IMFSinkWriter();
  (*w)->frames = fopen((StubNarrow(path) + ".nv12").c_str(), "wb");
  (*w)->times = fopen((StubNarrow(path) + ".times").c_str(), "w");
  return 0;
}
#endif
