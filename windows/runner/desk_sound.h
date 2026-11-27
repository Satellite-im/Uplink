// A voice message recorded with Windows' microphone (desk_sound.cpp).
#ifndef RUNNER_DESK_SOUND_H_
#define RUNNER_DESK_SOUND_H_

#include <flutter/method_call.h>
#include <flutter/method_result.h>
#include <flutter/encodable_value.h>

#include <memory>

// Answers "voiceStart", "voiceLevel", "voiceCancel" and "voiceStop" on "ghost_desktop/system" (lib/desktop/platform.dart,
// as the Mac's DeskSound.swift does); false where [call] is none of them and [result] is left for the caller.
bool DeskSoundHandle(const flutter::MethodCall<flutter::EncodableValue>& call,
                     std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>& result);

#endif
