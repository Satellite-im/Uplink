// Whether Windows lowers every other sound while the app is in a call (Matt, 2026-11-21: "When on windows in a call
// it's making my background audio on my PC quieter is this a setting we can turn off?"). Windows does it to any app
// that opens a microphone for talking (Sound › Communications, "Reduce other sounds by 80%" unless changed there).
// An app may say it does not want that: IAudioSessionControl2::SetDuckingPreference on its own sound sessions. Here
// that is said, or unsaid, for this app's default session on every working microphone and speaker, which is the one
// libwebrtc's sound uses; lib/voice/ducking.dart says which before each call opens the microphone, and again after.
#include "ducking.h"

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <windows.h>
#include <audiopolicy.h>
#include <mmdeviceapi.h>
#include <wrl/client.h>

#include <memory>

using Microsoft::WRL::ComPtr;

namespace {

std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> g_channel;

// [optOut] true: other sounds are left alone. Returns how many sessions took it.
int SetDucking(bool optOut) {
  ComPtr<IMMDeviceEnumerator> devices;
  if (FAILED(CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL, IID_PPV_ARGS(&devices)))) return 0;
  ComPtr<IMMDeviceCollection> all;
  if (FAILED(devices->EnumAudioEndpoints(eAll, DEVICE_STATE_ACTIVE, &all))) return 0;
  UINT count = 0;
  all->GetCount(&count);
  int done = 0;
  for (UINT i = 0; i < count; i++) {
    ComPtr<IMMDevice> device;
    if (FAILED(all->Item(i, &device))) continue;
    ComPtr<IAudioSessionManager2> sessions;
    if (FAILED(device->Activate(__uuidof(IAudioSessionManager2), CLSCTX_ALL, nullptr, reinterpret_cast<void**>(sessions.GetAddressOf())))) continue;
    // GUID_NULL with no flags: this process's default session on the device, made if it is not there yet.
    ComPtr<IAudioSessionControl> control;
    if (FAILED(sessions->GetAudioSessionControl(&GUID_NULL, 0, &control))) continue;
    ComPtr<IAudioSessionControl2> control2;
    if (FAILED(control.As(&control2))) continue;
    if (SUCCEEDED(control2->SetDuckingPreference(optOut ? TRUE : FALSE))) done++;
  }
  return done;
}

}  // namespace

void RegisterDucking(flutter::BinaryMessenger* messenger) {
  // Other sounds left alone from the start, as the app's choice is unless changed; the app says again before a call.
  SetDucking(true);
  g_channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(messenger, "ghost/ducking", &flutter::StandardMethodCodec::GetInstance());
  g_channel->SetMethodCallHandler([](const flutter::MethodCall<flutter::EncodableValue>& call, std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
    if (call.method_name() == "set") {
      bool optOut = true;
      if (const auto* args = std::get_if<flutter::EncodableMap>(call.arguments())) {
        auto o = args->find(flutter::EncodableValue("leaveOthers"));
        if (o != args->end()) {
          if (const auto* v = std::get_if<bool>(&o->second)) optOut = *v;
        }
      }
      result->Success(flutter::EncodableValue(SetDucking(optOut)));
      return;
    }
    result->NotImplemented();
  });
}
