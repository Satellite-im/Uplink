// A picture on the clipboard, for pasting into the message field on Windows (lib/desktop/platform.dart
// `pasteImage`; Matt, 2026-11-16: "add the ability to paste images into the chatbar on desktop"): the path of an
// image file copied in Explorer, or a copied picture (a screenshot, an image copied from a page) written out as a
// BMP in the temporary folder, which the app makes a PNG. Nothing where there is neither, and the field pastes words.
// Also Windows' Open dialog for choosing files and pictures (Pick, below).
#include "clipboard.h"
#include "desk_sound.h"

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <windows.h>
#include <shellapi.h>
#include <shobjidl.h>

#include <algorithm>
#include <cwctype>
#include <memory>
#include <string>
#include <vector>

namespace {

std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> g_channel;

// Windows' own wide text as UTF-8, which is what the channel carries.
std::string Utf8(const std::wstring& wide) {
  if (wide.empty()) return {};
  int size = WideCharToMultiByte(CP_UTF8, 0, wide.c_str(), -1, nullptr, 0, nullptr, nullptr);
  std::string out(size - 1, '\0');
  WideCharToMultiByte(CP_UTF8, 0, wide.c_str(), -1, out.data(), size, nullptr, nullptr);
  return out;
}

// Whether [path] ends as a picture's file does, whatever its letters' case.
bool IsImage(std::wstring path) {
  std::transform(path.begin(), path.end(), path.begin(), [](wchar_t c) { return static_cast<wchar_t>(std::towlower(c)); });
  for (const wchar_t* end : {L".png", L".jpg", L".jpeg", L".gif", L".webp", L".heic", L".bmp"}) {
    size_t n = wcslen(end);
    if (path.size() > n && path.compare(path.size() - n, n, end) == 0) return true;
  }
  return false;
}

// An image file copied in Explorer: the first one.
std::string CopiedFile() {
  HANDLE data = GetClipboardData(CF_HDROP);
  if (!data) return {};
  auto drop = static_cast<HDROP>(GlobalLock(data));
  if (!drop) return {};
  std::string found;
  UINT count = DragQueryFileW(drop, 0xFFFFFFFF, nullptr, 0);
  for (UINT i = 0; i < count && found.empty(); i++) {
    wchar_t path[MAX_PATH];
    if (DragQueryFileW(drop, i, path, MAX_PATH) && IsImage(path)) found = Utf8(path);
  }
  GlobalUnlock(data);
  return found;
}

// A copied picture, as a BMP file: the clipboard's device-independent bitmap with a file header before it.
std::string CopiedPicture() {
  HANDLE data = GetClipboardData(CF_DIB);
  if (!data) return {};
  auto bits = static_cast<const BYTE*>(GlobalLock(data));
  if (!bits) return {};
  SIZE_T size = GlobalSize(data);
  // The file header says where the pixels begin: after the bitmap's own header, its three colour masks where it has
  // them apart, and its colour table (a full one for 8 bits or fewer where the count is not given).
  auto info = reinterpret_cast<const BITMAPINFOHEADER*>(bits);
  DWORD colors = info->biClrUsed ? info->biClrUsed : (info->biBitCount <= 8 ? (1u << info->biBitCount) : 0);
  DWORD masks = (info->biCompression == BI_BITFIELDS && info->biSize == sizeof(BITMAPINFOHEADER)) ? 12 : 0;
  BITMAPFILEHEADER header{};
  header.bfType = 0x4D42;  // "BM"
  header.bfSize = static_cast<DWORD>(sizeof(header) + size);
  header.bfOffBits = static_cast<DWORD>(sizeof(header) + info->biSize + masks + colors * sizeof(RGBQUAD));
  wchar_t folder[MAX_PATH];
  GetTempPathW(MAX_PATH, folder);
  std::wstring path = std::wstring(folder) + L"ghost-pasted-" + std::to_wstring(GetTickCount64()) + L".bmp";
  std::string out;
  HANDLE file = CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_TEMPORARY, nullptr);
  if (file != INVALID_HANDLE_VALUE) {
    DWORD wrote = 0;
    bool ok = WriteFile(file, &header, sizeof(header), &wrote, nullptr) && WriteFile(file, bits, static_cast<DWORD>(size), &wrote, nullptr);
    CloseHandle(file);
    if (ok) out = Utf8(path);
  }
  GlobalUnlock(data);
  return out;
}

// Windows' own Open dialog (lib/files/file_platform.dart `pickPaths`, lib/desktop/platform.dart `pickPictures`):
// the paths chosen, at most [most], pictures alone where [pictures]. Windows had neither, so nothing could be chosen
// here at all: no file into a circle's Files, no plugin file (GMFB-7, @kevin: "I cannot see any downloaded plugins on
// windows").
std::vector<std::string> Pick(int most, bool pictures) {
  std::vector<std::string> out;
  IFileOpenDialog* dialog = nullptr;
  if (FAILED(CoCreateInstance(CLSID_FileOpenDialog, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&dialog)))) return out;
  DWORD options = 0;
  dialog->GetOptions(&options);
  options |= FOS_FORCEFILESYSTEM | FOS_FILEMUSTEXIST | FOS_PATHMUSTEXIST;
  if (most > 1) options |= FOS_ALLOWMULTISELECT;
  dialog->SetOptions(options);
  if (pictures) {
    COMDLG_FILTERSPEC spec[] = {{L"Pictures", L"*.png;*.jpg;*.jpeg;*.gif;*.webp;*.heic;*.bmp"}};
    dialog->SetFileTypes(1, spec);
  }
  if (SUCCEEDED(dialog->Show(GetActiveWindow()))) {
    IShellItemArray* items = nullptr;
    if (SUCCEEDED(dialog->GetResults(&items))) {
      DWORD count = 0;
      items->GetCount(&count);
      for (DWORD i = 0; i < count && static_cast<int>(out.size()) < most; i++) {
        IShellItem* item = nullptr;
        if (FAILED(items->GetItemAt(i, &item))) continue;
        PWSTR path = nullptr;
        if (SUCCEEDED(item->GetDisplayName(SIGDN_FILESYSPATH, &path))) {
          out.push_back(Utf8(path));
          CoTaskMemFree(path);
        }
        item->Release();
      }
      items->Release();
    }
  }
  dialog->Release();
  return out;
}

// The "most" argument of a call; [fallback] where it is not said.
int MostOf(const flutter::EncodableValue* args, int fallback) {
  if (const auto* map = std::get_if<flutter::EncodableMap>(args)) {
    auto it = map->find(flutter::EncodableValue("most"));
    if (it != map->end()) {
      if (const auto* n = std::get_if<int32_t>(&it->second)) return *n;
      if (const auto* n = std::get_if<int64_t>(&it->second)) return static_cast<int>(*n);
    }
  }
  return fallback;
}

}  // namespace

// "ghost_desktop/system" on Windows answers `pasteImage` alone: a copied file first, else a copied picture.
void RegisterClipboard(flutter::BinaryMessenger* messenger) {
  g_channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(messenger, "ghost_desktop/system", &flutter::StandardMethodCodec::GetInstance());
  g_channel->SetMethodCallHandler([](const flutter::MethodCall<flutter::EncodableValue>& call, std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
    if (call.method_name() == "pickFiles" || call.method_name() == "pickPictures") {
      const bool pictures = call.method_name() == "pickPictures";
      flutter::EncodableList paths;
      for (const auto& p : Pick(MostOf(call.arguments(), pictures ? 5 : 50), pictures)) paths.push_back(flutter::EncodableValue(p));
      result->Success(flutter::EncodableValue(paths));
      return;
    }
    // A voice message from Windows' microphone (desk_sound.cpp): this channel is the Mac's DeskChannels' too.
    if (DeskSoundHandle(call, result)) return;
    if (call.method_name() != "pasteImage") {
      result->NotImplemented();
      return;
    }
    std::string path;
    if (OpenClipboard(nullptr)) {
      path = CopiedFile();
      if (path.empty()) path = CopiedPicture();
      CloseClipboard();
    }
    if (path.empty()) {
      result->Success();
    } else {
      result->Success(flutter::EncodableValue(path));
    }
  });
}
