// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <memory>
#include <string>
#include <vector>

#include "win32_window.h"

// The dwData of the WM_COPYDATA a second launch sends: a UTF-16 path.
constexpr ULONG_PTR kOpenFileCopyData = 0x4E4F5001;  // "NOP\1"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // The "noted/open_files" channel to Dart, for a file a second launch hands
  // over (WM_COPYDATA, dwData == kOpenFileCopyData). Paths that arrive before
  // Dart calls "ready" are held and returned by that call.
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> open_channel_;
  std::vector<std::string> pending_paths_;
  bool dart_ready_ = false;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
