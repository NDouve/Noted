// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#ifndef RUNNER_WIN32_WINDOW_H_
#define RUNNER_WIN32_WINDOW_H_

#include <windows.h>

#include <functional>
#include <memory>
#include <string>
#include <vector>

// A class abstraction for a high DPI-aware Win32 Window. Intended to be
// inherited from by classes that wish to specialize with custom
// rendering and input handling
class Win32Window {
 public:
  struct Point {
    unsigned int x;
    unsigned int y;
    Point(unsigned int x, unsigned int y) : x(x), y(y) {}
  };

  struct Size {
    unsigned int width;
    unsigned int height;
    Size(unsigned int width, unsigned int height)
        : width(width), height(height) {}
  };

  Win32Window();
  virtual ~Win32Window();

  // Creates a win32 window with |title| that is positioned and sized using
  // |origin| and |size|. New windows are created on the default monitor. Window
  // sizes are specified to the OS in physical pixels, hence to ensure a
  // consistent size this function will scale the inputted width and height as
  // as appropriate for the default monitor. The window is invisible until
  // |Show| is called. Returns true if the window was created successfully.
  bool Create(const std::wstring& title, const Point& origin, const Size& size);

  // Show the current window. Returns true if the window was successfully shown.
  bool Show();

  // Release OS resources associated with window.
  void Destroy();

  // Inserts |content| into the window tree.
  void SetChildContent(HWND content);

  // Returns the backing Window handle to enable clients to set icon and other
  // window properties. Returns nullptr if the window has been destroyed.
  HWND GetHandle();

  // If true, closing this window will quit the application.
  void SetQuitOnClose(bool quit_on_close);

  // Return a RECT representing the bounds of the current client area.
  RECT GetClientArea();

  // A rectangle in logical pixels, relative to the client area.
  struct DipRect {
    double left = 0, top = 0, right = 0, bottom = 0;
  };

  // The caption buttons (0 is none).
  enum CaptionButton { kNoButton = 0, kMinimize = 1, kMaximize = 2, kClose = 3 };

  struct FrameState {
    bool maximized = false;
    bool active = true;
    int hovered = kNoButton;
    int pressed = kNoButton;
    unsigned int dpi = 96;
  };

  // Turns the custom title-bar frame on or off. Off (the default) is a normal
  // captioned window. On, the caption is removed from the client area and Dart
  // draws it (see SetCaptionRects).
  void SetCustomFrame(bool enabled);
  bool custom_frame() const { return custom_frame_; }

  // The caption-button rects (index by CaptionButton, 1..3; index 0 unused)
  // and the rects of interactive title-bar controls, in logical pixels.
  // Anything else in the top 40 logical pixels is the draggable caption.
  void SetCaptionRects(const DipRect buttons[4],
                       std::vector<DipRect> interactive);

  FrameState GetFrameState();

 protected:
  // Processes and route salient window messages for mouse handling,
  // size change and DPI. Delegates handling of these to member overloads that
  // inheriting classes can handle.
  virtual LRESULT MessageHandler(HWND window,
                                 UINT const message,
                                 WPARAM const wparam,
                                 LPARAM const lparam) noexcept;

  // Called when CreateAndShow is called, allowing subclass window-related
  // setup. Subclasses should return false if setup fails.
  virtual bool OnCreate();

  // Called when Destroy is called.
  virtual void OnDestroy();

  // Custom frame only: the maximised, active, hover, pressed or dpi state
  // changed.
  virtual void OnFrameStateChanged();

  // Custom frame only: a non-client mouse button went down (caption, caption
  // buttons or window menu), before it is handled.
  virtual void OnNcPointerDown();

 private:
  friend class WindowClassRegistrar;

  // OS callback called by message pump. Handles the WM_NCCREATE message which
  // is passed when the non-client area is being created and enables automatic
  // non-client DPI scaling so that the non-client area automatically
  // responds to changes in DPI. All other messages are handled by
  // MessageHandler.
  static LRESULT CALLBACK WndProc(HWND const window,
                                  UINT const message,
                                  WPARAM const wparam,
                                  LPARAM const lparam) noexcept;

  // Retrieves a class instance pointer for |window|
  static Win32Window* GetThisFromHandle(HWND const window) noexcept;

  // Update the window frame's theme to match the system theme.
  static void UpdateTheme(HWND const window);

  bool quit_on_close_ = false;

  // Custom-frame helpers (win32_window.cpp). |handled| is set when the result
  // is to be returned.
  LRESULT HandleCustomFrame(HWND hwnd, UINT message, WPARAM wparam,
                            LPARAM lparam, bool* handled) noexcept;
  int HitTestClient(POINT client_point, int client_width);
  int ButtonAt(POINT client_point);
  void SetHoverPressed(int hovered, int pressed);
  void RunCaptionButton(int button);

  bool custom_frame_ = false;
  bool active_ = true;
  bool tracking_nc_leave_ = false;
  int hovered_ = kNoButton;
  int pressed_ = kNoButton;
  DipRect buttons_[4];
  std::vector<DipRect> interactive_;

  // window handle for top level window.
  HWND window_handle_ = nullptr;

  // window handle for hosted content.
  HWND child_content_ = nullptr;
};

#endif  // RUNNER_WIN32_WINDOW_H_
