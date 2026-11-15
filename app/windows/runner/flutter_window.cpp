// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#include "flutter_window.h"

#include <commctrl.h>

#include <optional>

#include "flutter/generated_plugin_registrant.h"
#include "utils.h"

namespace {

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;

constexpr UINT_PTR kViewSubclassId = 1;

// The Flutter view is a child covering the client area, so it would answer
// every hit test itself. Where the frame (the parent) answers anything but
// HTCLIENT (caption, caption buttons, top resize band) it is transparent, so
// the parent's answer applies. Harmless while the custom frame is off: the
// parent then answers HTCLIENT.
LRESULT CALLBACK ViewSubclassProc(HWND hwnd, UINT message, WPARAM wparam,
                                  LPARAM lparam, UINT_PTR, DWORD_PTR) {
  if (message == WM_NCHITTEST) {
    HWND parent = GetParent(hwnd);
    if (parent != nullptr) {
      LRESULT hit = SendMessage(parent, WM_NCHITTEST, 0, lparam);
      if (hit != HTCLIENT) {
        return HTTRANSPARENT;
      }
    }
  }
  return DefSubclassProc(hwnd, message, wparam, lparam);
}

bool ToDouble(const EncodableValue& v, double* out) {
  if (const auto* d = std::get_if<double>(&v)) {
    *out = *d;
    return true;
  }
  if (const auto* i = std::get_if<int32_t>(&v)) {
    *out = *i;
    return true;
  }
  if (const auto* l = std::get_if<int64_t>(&v)) {
    *out = static_cast<double>(*l);
    return true;
  }
  return false;
}

// [left, top, right, bottom] in logical pixels.
bool ToRect(const EncodableValue& v, Win32Window::DipRect* out) {
  const auto* list = std::get_if<EncodableList>(&v);
  if (list == nullptr || list->size() != 4) {
    return false;
  }
  double n[4];
  for (int i = 0; i < 4; ++i) {
    if (!ToDouble((*list)[i], &n[i])) {
      return false;
    }
  }
  *out = {n[0], n[1], n[2], n[3]};
  return true;
}

const char* ButtonName(int button) {
  switch (button) {
    case Win32Window::kMinimize:
      return "minimize";
    case Win32Window::kMaximize:
      return "maximize";
    case Win32Window::kClose:
      return "close";
  }
  return "none";
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());

  open_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "noted/open_files",
          &flutter::StandardMethodCodec::GetInstance());
  open_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        if (call.method_name() == "ready") {
          dart_ready_ = true;
          flutter::EncodableList list;
          for (const auto& p : pending_paths_) {
            list.push_back(flutter::EncodableValue(p));
          }
          pending_paths_.clear();
          result->Success(flutter::EncodableValue(list));
        } else {
          result->NotImplemented();
        }
      });
  window_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "noted/window",
          &flutter::StandardMethodCodec::GetInstance());
  window_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) { HandleWindowCall(call, std::move(result)); });
  SetChildContent(flutter_controller_->view()->GetNativeWindow());
  view_hwnd_ = flutter_controller_->view()->GetNativeWindow();
  SetWindowSubclass(view_hwnd_, ViewSubclassProc, kViewSubclassId, 0);

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::HandleWindowCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const std::string& method = call.method_name();
  HWND hwnd = GetHandle();
  if (hwnd == nullptr) {
    result->Error("no_window", "The window is gone.");
    return;
  }
  if (method == "enable") {
    // {enabled: bool}, default true. Off is a normal captioned window.
    bool enabled = true;
    if (const auto* args = std::get_if<EncodableMap>(call.arguments())) {
      auto it = args->find(EncodableValue("enabled"));
      if (it != args->end()) {
        if (const auto* b = std::get_if<bool>(&it->second)) enabled = *b;
      }
    }
    SetCustomFrame(enabled);
    result->Success();
  } else if (method == "setCaptionRects") {
    // {buttons: {minimize, maximize, close: [l, t, r, b]},
    //  interactive: [[l, t, r, b], ...]}, logical px in the client area.
    const auto* args = std::get_if<EncodableMap>(call.arguments());
    if (args == nullptr) {
      result->Error("bad_args", "Expected a map.");
      return;
    }
    DipRect buttons[4];
    auto bit = args->find(EncodableValue("buttons"));
    if (bit != args->end()) {
      if (const auto* map = std::get_if<EncodableMap>(&bit->second)) {
        for (int b = kMinimize; b <= kClose; ++b) {
          auto rit = map->find(EncodableValue(ButtonName(b)));
          if (rit != map->end() && !ToRect(rit->second, &buttons[b])) {
            result->Error("bad_args", "A button rect is not [l, t, r, b].");
            return;
          }
        }
      }
    }
    std::vector<DipRect> interactive;
    auto iit = args->find(EncodableValue("interactive"));
    if (iit != args->end()) {
      if (const auto* list = std::get_if<EncodableList>(&iit->second)) {
        for (const auto& v : *list) {
          DipRect r;
          if (!ToRect(v, &r)) {
            result->Error("bad_args", "A rect is not [l, t, r, b].");
            return;
          }
          interactive.push_back(r);
        }
      }
    }
    SetCaptionRects(buttons, std::move(interactive));
    result->Success();
  } else if (method == "minimize") {
    PostMessage(hwnd, WM_SYSCOMMAND, SC_MINIMIZE, 0);
    result->Success();
  } else if (method == "toggleMaximize") {
    PostMessage(hwnd, WM_SYSCOMMAND, IsZoomed(hwnd) ? SC_RESTORE : SC_MAXIMIZE,
                0);
    result->Success();
  } else if (method == "close") {
    // WM_CLOSE, so the exit checks run as for Alt+F4.
    PostMessage(hwnd, WM_CLOSE, 0, 0);
    result->Success();
  } else if (method == "getState") {
    FrameState s = GetFrameState();
    EncodableMap map;
    map[EncodableValue("maximized")] = EncodableValue(s.maximized);
    map[EncodableValue("active")] = EncodableValue(s.active);
    map[EncodableValue("hovered")] = EncodableValue(ButtonName(s.hovered));
    map[EncodableValue("pressed")] = EncodableValue(ButtonName(s.pressed));
    map[EncodableValue("dpi")] = EncodableValue(static_cast<int32_t>(s.dpi));
    result->Success(EncodableValue(map));
  } else {
    result->NotImplemented();
  }
}

void FlutterWindow::OnFrameStateChanged() {
  if (!window_channel_ || !custom_frame()) {
    return;
  }
  FrameState s = GetFrameState();
  EncodableMap map;
  map[EncodableValue("maximized")] = EncodableValue(s.maximized);
  map[EncodableValue("active")] = EncodableValue(s.active);
  map[EncodableValue("hovered")] = EncodableValue(ButtonName(s.hovered));
  map[EncodableValue("pressed")] = EncodableValue(ButtonName(s.pressed));
  map[EncodableValue("dpi")] = EncodableValue(static_cast<int32_t>(s.dpi));
  window_channel_->InvokeMethod(
      "state", std::make_unique<EncodableValue>(std::move(map)));
}

void FlutterWindow::OnNcPointerDown() {
  if (window_channel_) {
    window_channel_->InvokeMethod("ncPointerDown", nullptr);
  }
}

void FlutterWindow::OnDestroy() {
  if (view_hwnd_ != nullptr) {
    RemoveWindowSubclass(view_hwnd_, ViewSubclassProc, kViewSubclassId);
    view_hwnd_ = nullptr;
  }
  window_channel_ = nullptr;
  open_channel_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_COPYDATA: {
      // A second launch handing over a file to open. Dart checks the path.
      const auto* data = reinterpret_cast<const COPYDATASTRUCT*>(lparam);
      if (data != nullptr && data->dwData == kOpenFileCopyData &&
          data->lpData != nullptr && data->cbData >= sizeof(wchar_t) &&
          data->cbData <= 65536 && open_channel_) {
        const auto* w = static_cast<const wchar_t*>(data->lpData);
        std::wstring path(w, data->cbData / sizeof(wchar_t));
        while (!path.empty() && path.back() == L'\0') path.pop_back();
        std::string utf8 = Utf8FromUtf16(path.c_str());
        if (!utf8.empty()) {
          if (dart_ready_) {
            open_channel_->InvokeMethod(
                "open", std::make_unique<flutter::EncodableValue>(utf8));
          } else {
            pending_paths_.push_back(utf8);
          }
        }
        return TRUE;
      }
      break;
    }
    case WM_SYSCOMMAND:
      // F10, a lone Alt and Alt+letter with no native menu send SC_KEYMENU.
      // Without this, DefWindowProc enters system-menu mode (keys go to the
      // invisible window menu) or beeps. Flutter has already seen the key
      // events, so the in-window menu bar works as it should. Alt+Space
      // (lParam is the space character) still opens the window menu.
      if ((wparam & 0xFFF0) == SC_KEYMENU && lparam != ' ') {
        return 0;
      }
      break;
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
