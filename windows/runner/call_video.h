// A recording's picture, on Windows (call_video.cpp).
#ifndef RUNNER_CALL_VIDEO_H_
#define RUNNER_CALL_VIDEO_H_

#include <flutter/encodable_value.h>
#include <flutter/method_result.h>

#include <memory>
#include <string>

// Takes one of lib/voice/recorder.dart's `video.` calls on "ghost/recorder" (video.start, video.layout, video.stop),
// from call_recorder.cpp, on the app's thread. Any other name is answered as not implemented.
void CallVideoHandle(const std::string& method, const flutter::EncodableMap* args, std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

#endif
