// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#include "win32_window.h"

#include <dwmapi.h>
#include <flutter_windows.h>
#include <shellapi.h>
#include <windowsx.h>

#include <algorithm>

#include "resource.h"

namespace {

/// Window attribute that enables dark mode window decorations.
///
/// Redefined in case the developer's machine has a Windows SDK older than
/// version 10.0.22000.0.
/// See: https://docs.microsoft.com/windows/win32/api/dwmapi/ne-dwmapi-dwmwindowattribute
#ifndef DWMWA_USE_IMMERSIVE_DARK_MODE
#define DWMWA_USE_IMMERSIVE_DARK_MODE 20
#endif

constexpr const wchar_t kWindowClassName[] = L"FLUTTER_RUNNER_WIN32_WINDOW";

/// Registry key for app theme preference.
///
/// A value of 0 indicates apps should use dark mode. A non-zero or missing
/// value indicates apps should use light mode.
constexpr const wchar_t kGetPreferredBrightnessRegKey[] =
  L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize";
constexpr const wchar_t kGetPreferredBrightnessRegValue[] = L"AppsUseLightTheme";

// The number of Win32Window objects that currently exist.
static int g_active_window_count = 0;

using EnableNonClientDpiScaling = BOOL __stdcall(HWND hwnd);

// Scale helper to convert logical scaler values to physical using passed in
// scale factor
int Scale(int source, double scale_factor) {
  return static_cast<int>(source * scale_factor);
}

// Dynamically loads the |EnableNonClientDpiScaling| from the User32 module.
// This API is only needed for PerMonitor V1 awareness mode.
void EnableFullDpiSupportIfAvailable(HWND hwnd) {
  HMODULE user32_module = LoadLibraryA("User32.dll");
  if (!user32_module) {
    return;
  }
  auto enable_non_client_dpi_scaling =
      reinterpret_cast<EnableNonClientDpiScaling*>(
          GetProcAddress(user32_module, "EnableNonClientDpiScaling"));
  if (enable_non_client_dpi_scaling != nullptr) {
    enable_non_client_dpi_scaling(hwnd);
  }
  FreeLibrary(user32_module);
}

}  // namespace

// Manages the Win32Window's window class registration.
class WindowClassRegistrar {
 public:
  ~WindowClassRegistrar() = default;

  // Returns the singleton registrar instance.
  static WindowClassRegistrar* GetInstance() {
    if (!instance_) {
      instance_ = new WindowClassRegistrar();
    }
    return instance_;
  }

  // Returns the name of the window class, registering the class if it hasn't
  // previously been registered.
  const wchar_t* GetWindowClass();

  // Unregisters the window class. Should only be called if there are no
  // instances of the window.
  void UnregisterWindowClass();

 private:
  WindowClassRegistrar() = default;

  static WindowClassRegistrar* instance_;

  bool class_registered_ = false;
};

WindowClassRegistrar* WindowClassRegistrar::instance_ = nullptr;

const wchar_t* WindowClassRegistrar::GetWindowClass() {
  if (!class_registered_) {
    WNDCLASS window_class{};
    window_class.hCursor = LoadCursor(nullptr, IDC_ARROW);
    window_class.lpszClassName = kWindowClassName;
    window_class.style = CS_HREDRAW | CS_VREDRAW;
    window_class.cbClsExtra = 0;
    window_class.cbWndExtra = 0;
    window_class.hInstance = GetModuleHandle(nullptr);
    window_class.hIcon =
        LoadIcon(window_class.hInstance, MAKEINTRESOURCE(IDI_APP_ICON));
    window_class.hbrBackground = 0;
    window_class.lpszMenuName = nullptr;
    window_class.lpfnWndProc = Win32Window::WndProc;
    RegisterClass(&window_class);
    class_registered_ = true;
  }
  return kWindowClassName;
}

void WindowClassRegistrar::UnregisterWindowClass() {
  UnregisterClass(kWindowClassName, nullptr);
  class_registered_ = false;
}

Win32Window::Win32Window() {
  ++g_active_window_count;
}

Win32Window::~Win32Window() {
  --g_active_window_count;
  Destroy();
}

bool Win32Window::Create(const std::wstring& title,
                         const Point& origin,
                         const Size& size) {
  Destroy();

  const wchar_t* window_class =
      WindowClassRegistrar::GetInstance()->GetWindowClass();

  const POINT target_point = {static_cast<LONG>(origin.x),
                              static_cast<LONG>(origin.y)};
  HMONITOR monitor = MonitorFromPoint(target_point, MONITOR_DEFAULTTONEAREST);
  UINT dpi = FlutterDesktopGetDpiForMonitor(monitor);
  double scale_factor = dpi / 96.0;

  HWND window = CreateWindow(
      window_class, title.c_str(), WS_OVERLAPPEDWINDOW,
      Scale(origin.x, scale_factor), Scale(origin.y, scale_factor),
      Scale(size.width, scale_factor), Scale(size.height, scale_factor),
      nullptr, nullptr, GetModuleHandle(nullptr), this);

  if (!window) {
    return false;
  }

  UpdateTheme(window);

  return OnCreate();
}

bool Win32Window::Show() {
  return ShowWindow(window_handle_, SW_SHOWNORMAL);
}

// static
LRESULT CALLBACK Win32Window::WndProc(HWND const window,
                                      UINT const message,
                                      WPARAM const wparam,
                                      LPARAM const lparam) noexcept {
  if (message == WM_NCCREATE) {
    auto window_struct = reinterpret_cast<CREATESTRUCT*>(lparam);
    SetWindowLongPtr(window, GWLP_USERDATA,
                     reinterpret_cast<LONG_PTR>(window_struct->lpCreateParams));

    auto that = static_cast<Win32Window*>(window_struct->lpCreateParams);
    EnableFullDpiSupportIfAvailable(window);
    that->window_handle_ = window;
  } else if (Win32Window* that = GetThisFromHandle(window)) {
    return that->MessageHandler(window, message, wparam, lparam);
  }

  return DefWindowProc(window, message, wparam, lparam);
}

LRESULT
Win32Window::MessageHandler(HWND hwnd,
                            UINT const message,
                            WPARAM const wparam,
                            LPARAM const lparam) noexcept {
  if (custom_frame_) {
    bool handled = false;
    LRESULT result = HandleCustomFrame(hwnd, message, wparam, lparam, &handled);
    if (handled) {
      return result;
    }
  }

  switch (message) {
    case WM_DESTROY:
      window_handle_ = nullptr;
      Destroy();
      if (quit_on_close_) {
        PostQuitMessage(0);
      }
      return 0;

    case WM_DPICHANGED: {
      auto newRectSize = reinterpret_cast<RECT*>(lparam);
      LONG newWidth = newRectSize->right - newRectSize->left;
      LONG newHeight = newRectSize->bottom - newRectSize->top;

      SetWindowPos(hwnd, nullptr, newRectSize->left, newRectSize->top, newWidth,
                   newHeight, SWP_NOZORDER | SWP_NOACTIVATE);

      return 0;
    }
    case WM_SIZE: {
      RECT rect = GetClientArea();
      if (child_content_ != nullptr) {
        // Size and position the child window.
        MoveWindow(child_content_, rect.left, rect.top, rect.right - rect.left,
                   rect.bottom - rect.top, TRUE);
      }
      return 0;
    }

    case WM_ACTIVATE:
      if (child_content_ != nullptr) {
        SetFocus(child_content_);
      }
      return 0;

    case WM_DWMCOLORIZATIONCOLORCHANGED:
      UpdateTheme(hwnd);
      return 0;
  }

  return DefWindowProc(window_handle_, message, wparam, lparam);
}

void Win32Window::Destroy() {
  OnDestroy();

  if (window_handle_) {
    DestroyWindow(window_handle_);
    window_handle_ = nullptr;
  }
  if (g_active_window_count == 0) {
    WindowClassRegistrar::GetInstance()->UnregisterWindowClass();
  }
}

Win32Window* Win32Window::GetThisFromHandle(HWND const window) noexcept {
  return reinterpret_cast<Win32Window*>(
      GetWindowLongPtr(window, GWLP_USERDATA));
}

void Win32Window::SetChildContent(HWND content) {
  child_content_ = content;
  SetParent(content, window_handle_);
  RECT frame = GetClientArea();

  MoveWindow(content, frame.left, frame.top, frame.right - frame.left,
             frame.bottom - frame.top, true);

  SetFocus(child_content_);
}

RECT Win32Window::GetClientArea() {
  RECT frame;
  GetClientRect(window_handle_, &frame);
  return frame;
}

HWND Win32Window::GetHandle() {
  return window_handle_;
}

void Win32Window::SetQuitOnClose(bool quit_on_close) {
  quit_on_close_ = quit_on_close;
}

bool Win32Window::OnCreate() {
  // No-op; provided for subclasses.
  return true;
}

void Win32Window::OnDestroy() {
  // No-op; provided for subclasses.
}

void Win32Window::UpdateTheme(HWND const window) {
  DWORD light_mode;
  DWORD light_mode_size = sizeof(light_mode);
  LSTATUS result = RegGetValue(HKEY_CURRENT_USER, kGetPreferredBrightnessRegKey,
                               kGetPreferredBrightnessRegValue,
                               RRF_RT_REG_DWORD, nullptr, &light_mode,
                               &light_mode_size);

  if (result == ERROR_SUCCESS) {
    BOOL enable_dark_mode = light_mode == 0;
    DwmSetWindowAttribute(window, DWMWA_USE_IMMERSIVE_DARK_MODE,
                          &enable_dark_mode, sizeof(enable_dark_mode));
  }
}

void Win32Window::OnFrameStateChanged() {
  // No-op; provided for subclasses.
}

void Win32Window::OnNcPointerDown() {
  // No-op; provided for subclasses.
}

// ---------------------------------------------------------------------------
// Custom title-bar frame. Off unless Dart calls SetCustomFrame(true).
// ---------------------------------------------------------------------------

namespace {

// The title bar's height in logical pixels (the design's title-bar-height).
constexpr double kCaptionHeightDip = 40.0;

int ButtonHitCode(int button) {
  switch (button) {
    case Win32Window::kMinimize:
      return HTMINBUTTON;
    case Win32Window::kMaximize:
      return HTMAXBUTTON;
    case Win32Window::kClose:
      return HTCLOSE;
  }
  return HTNOWHERE;
}

int ButtonFromHitCode(WPARAM hit) {
  switch (hit) {
    case HTMINBUTTON:
      return Win32Window::kMinimize;
    case HTMAXBUTTON:
      return Win32Window::kMaximize;
    case HTCLOSE:
      return Win32Window::kClose;
  }
  return Win32Window::kNoButton;
}

bool DipRectContains(const Win32Window::DipRect& r, double x, double y) {
  return x >= r.left && x < r.right && y >= r.top && y < r.bottom;
}

// The width of the sizing frame at the top, in physical pixels.
int TopFrameThickness(UINT dpi) {
  return GetSystemMetricsForDpi(SM_CYSIZEFRAME, dpi) +
         GetSystemMetricsForDpi(SM_CXPADDEDBORDER, dpi);
}

}  // namespace

void Win32Window::SetCustomFrame(bool enabled) {
  if (custom_frame_ == enabled || !window_handle_) {
    return;
  }
  custom_frame_ = enabled;
  hovered_ = pressed_ = kNoButton;
  MARGINS margins = {0, 0, enabled ? 1 : 0, 0};  // left, right, top, bottom
  DwmExtendFrameIntoClientArea(window_handle_, &margins);
  // Apply the new non-client size now, before the next paint.
  SetWindowPos(window_handle_, nullptr, 0, 0, 0, 0,
               SWP_FRAMECHANGED | SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER |
                   SWP_NOACTIVATE);
  OnFrameStateChanged();
}

void Win32Window::SetCaptionRects(const DipRect buttons[4],
                                  std::vector<DipRect> interactive) {
  for (int i = 0; i < 4; ++i) {
    buttons_[i] = buttons[i];
  }
  interactive_ = std::move(interactive);
}

Win32Window::FrameState Win32Window::GetFrameState() {
  FrameState state;
  state.maximized = window_handle_ && IsZoomed(window_handle_);
  state.active = active_;
  state.hovered = hovered_;
  state.pressed = pressed_;
  state.dpi = window_handle_ ? GetDpiForWindow(window_handle_) : 96;
  return state;
}

int Win32Window::ButtonAt(POINT p) {
  double scale = GetDpiForWindow(window_handle_) / 96.0;
  double x = p.x / scale, y = p.y / scale;
  for (int b = kMinimize; b <= kClose; ++b) {
    if (DipRectContains(buttons_[b], x, y)) {
      return b;
    }
  }
  return kNoButton;
}

// The hit code for a point (client coordinates) that DefWindowProc called
// HTCLIENT. Only the top kCaptionHeightDip changes.
int Win32Window::HitTestClient(POINT p, int client_width) {
  UINT dpi = GetDpiForWindow(window_handle_);
  double scale = dpi / 96.0;
  double x = p.x / scale, y = p.y / scale;
  if (y < 0 || y >= kCaptionHeightDip) {
    return HTCLIENT;
  }
  if (!IsZoomed(window_handle_)) {
    int band = TopFrameThickness(dpi);
    if (p.y < band) {
      if (p.x < band) return HTTOPLEFT;
      if (p.x >= client_width - band) return HTTOPRIGHT;
      return HTTOP;
    }
  }
  int button = ButtonAt(p);
  if (button != kNoButton) {
    return ButtonHitCode(button);
  }
  for (const DipRect& r : interactive_) {
    if (DipRectContains(r, x, y)) {
      return HTCLIENT;
    }
  }
  return HTCAPTION;
}

void Win32Window::SetHoverPressed(int hovered, int pressed) {
  if (hovered == hovered_ && pressed == pressed_) {
    return;
  }
  hovered_ = hovered;
  pressed_ = pressed;
  OnFrameStateChanged();
}

void Win32Window::RunCaptionButton(int button) {
  WPARAM command = 0;
  switch (button) {
    case kMinimize:
      command = SC_MINIMIZE;
      break;
    case kMaximize:
      command = IsZoomed(window_handle_) ? SC_RESTORE : SC_MAXIMIZE;
      break;
    case kClose:
      command = SC_CLOSE;
      break;
    default:
      return;
  }
  PostMessage(window_handle_, WM_SYSCOMMAND, command, 0);
}

LRESULT Win32Window::HandleCustomFrame(HWND hwnd, UINT message, WPARAM wparam,
                                       LPARAM lparam, bool* handled) noexcept {
  *handled = true;
  switch (message) {
    case WM_NCCALCSIZE: {
      if (!wparam) {
        break;
      }
      auto* params = reinterpret_cast<NCCALCSIZE_PARAMS*>(lparam);
      LONG proposed_top = params->rgrc[0].top;
      // The default result keeps the left, right and bottom borders.
      LRESULT result = DefWindowProc(hwnd, message, wparam, lparam);
      if (result != 0) {
        return result;
      }
      // The caption goes: the top is the proposed top again.
      RECT& rc = params->rgrc[0];
      rc.top = proposed_top;
      if (IsZoomed(hwnd)) {
        rc.top += TopFrameThickness(GetDpiForWindow(hwnd));
        // An auto-hide taskbar needs a 1 px edge left to reveal it.
        HMONITOR monitor = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
        MONITORINFO info = {sizeof(info)};
        if (GetMonitorInfo(monitor, &info)) {
          const UINT edges[] = {ABE_LEFT, ABE_TOP, ABE_RIGHT, ABE_BOTTOM};
          for (UINT edge : edges) {
            APPBARDATA bar = {sizeof(bar)};
            bar.rc = info.rcMonitor;
            bar.uEdge = edge;
            if (!SHAppBarMessage(ABM_GETAUTOHIDEBAREX, &bar)) {
              continue;
            }
            switch (edge) {
              case ABE_LEFT:
                rc.left = std::max<LONG>(rc.left, info.rcMonitor.left + 1);
                break;
              case ABE_TOP:
                rc.top = std::max<LONG>(rc.top, info.rcMonitor.top + 1);
                break;
              case ABE_RIGHT:
                rc.right = std::min<LONG>(rc.right, info.rcMonitor.right - 1);
                break;
              case ABE_BOTTOM:
                rc.bottom =
                    std::min<LONG>(rc.bottom, info.rcMonitor.bottom - 1);
                break;
            }
          }
        }
      }
      return 0;
    }

    case WM_NCHITTEST: {
      LRESULT hit = DefWindowProc(hwnd, message, wparam, lparam);
      if (hit != HTCLIENT) {
        return hit;
      }
      POINT p = {GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
      ScreenToClient(hwnd, &p);
      RECT client = GetClientArea();
      return HitTestClient(p, client.right - client.left);
    }

    case WM_NCACTIVATE:
      active_ = wparam != FALSE;
      OnFrameStateChanged();
      // lParam -1: no repaint of a native caption on activation changes.
      return DefWindowProc(hwnd, message, wparam, -1);

    case WM_NCLBUTTONDOWN:
    case WM_NCRBUTTONDOWN: {
      OnNcPointerDown();
      int button = message == WM_NCLBUTTONDOWN ? ButtonFromHitCode(wparam)
                                               : kNoButton;
      if (button != kNoButton) {
        // Tracked here, not by DefWindowProc, which would draw its own button.
        SetCapture(hwnd);
        SetHoverPressed(button, button);
        return 0;
      }
      break;
    }

    case WM_NCLBUTTONDBLCLK:
      if (ButtonFromHitCode(wparam) != kNoButton) {
        return 0;
      }
      break;

    case WM_NCLBUTTONUP: {
      int button = ButtonFromHitCode(wparam);
      if (button != kNoButton) {
        // Released without our capture (a snap-layouts flyout click).
        bool same = pressed_ == button;
        SetHoverPressed(button, kNoButton);
        if (same) {
          RunCaptionButton(button);
        }
        return 0;
      }
      break;
    }

    case WM_MOUSEMOVE:
      if (pressed_ != kNoButton) {  // captured by a pressed button
        POINT p = {GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
        SetHoverPressed(ButtonAt(p), pressed_);
        return 0;
      }
      break;

    case WM_LBUTTONUP:
      if (pressed_ != kNoButton) {
        POINT p = {GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
        int pressed = pressed_;
        int under = ButtonAt(p);
        ReleaseCapture();
        SetHoverPressed(under, kNoButton);
        if (under == pressed) {
          RunCaptionButton(pressed);
        }
        return 0;
      }
      break;

    case WM_CAPTURECHANGED:
      if (pressed_ != kNoButton) {
        SetHoverPressed(kNoButton, kNoButton);
      }
      break;

    case WM_NCMOUSEMOVE:
      if (!tracking_nc_leave_) {
        TRACKMOUSEEVENT track = {sizeof(track), TME_LEAVE | TME_NONCLIENT,
                                 hwnd, 0};
        tracking_nc_leave_ = TrackMouseEvent(&track) != FALSE;
      }
      if (pressed_ == kNoButton) {
        SetHoverPressed(ButtonFromHitCode(wparam), kNoButton);
      }
      break;

    case WM_NCMOUSELEAVE:
      tracking_nc_leave_ = false;
      if (pressed_ == kNoButton) {
        SetHoverPressed(kNoButton, kNoButton);
      }
      break;

    case WM_SIZE:
    case WM_DPICHANGED:
      OnFrameStateChanged();
      break;
  }
  *handled = false;
  return 0;
}
