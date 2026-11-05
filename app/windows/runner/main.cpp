// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>
#include <shellapi.h>

#include <cstdint>
#include <cwchar>
#include <cwctype>
#include <string>

#include "flutter_window.h"
#include "utils.h"

namespace {

// Single-instance guard, keyed on the data folder so that runs with another
// APPDATA (tests, scratch runs) don't collide with the user's Noted. The data
// folder is the parent of the pages folder, as in defaultPagesDirectory()
// (notebook.dart): %APPDATA%\Noted, or ~/.noted when APPDATA is unset. (A
// NOTED_PAGES_DIR dart-define is not visible here.)
//
// The first instance holds a Local\ mutex and marks its window with a window
// property named after the same key; a second launch finds the window by that
// property, brings it forward, hands it the file named on its command line
// (WM_COPYDATA, received in FlutterWindow and passed to Dart) and exits.

std::wstring EnvVar(const wchar_t *name) {
  DWORD n = ::GetEnvironmentVariableW(name, nullptr, 0);
  if (n == 0) return L"";
  std::wstring value(n, L'\0');
  n = ::GetEnvironmentVariableW(name, &value[0], n);
  value.resize(n);
  return value;
}

// FNV-1a 64 of the lower-cased full path of the data folder, as 16 hex digits.
std::wstring DataFolderKey() {
  std::wstring dir = EnvVar(L"APPDATA");
  if (!dir.empty()) {
    dir += L"\\Noted";
  } else {
    std::wstring home = EnvVar(L"HOME");
    dir = (home.empty() ? L"." : home) + L"\\.noted";
  }
  wchar_t full[MAX_PATH * 4];
  DWORD n = ::GetFullPathNameW(dir.c_str(), MAX_PATH * 4, full, nullptr);
  std::wstring path = (n > 0 && n < MAX_PATH * 4) ? std::wstring(full, n) : dir;
  while (path.size() > 3 && path.back() == L'\\') path.pop_back();
  for (auto &c : path) c = static_cast<wchar_t>(::towlower(c));
  uint64_t h = 1469598103934665603ULL;
  for (wchar_t c : path) {
    h ^= static_cast<uint64_t>(c & 0xff);
    h *= 1099511628211ULL;
    h ^= static_cast<uint64_t>((c >> 8) & 0xff);
    h *= 1099511628211ULL;
  }
  wchar_t hex[17];
  swprintf(hex, 17, L"%016llx", static_cast<unsigned long long>(h));
  return hex;
}

struct FindContext {
  const wchar_t *prop;
  HWND found;
};

BOOL CALLBACK FindMarked(HWND hwnd, LPARAM lparam) {
  auto *ctx = reinterpret_cast<FindContext *>(lparam);
  if (::GetPropW(hwnd, ctx->prop) != nullptr) {
    ctx->found = hwnd;
    return FALSE;
  }
  return TRUE;
}

// The first command-line argument that isn't a flag (the file to open), or
// empty. The app checks it; here it is only passed on.
std::wstring FileArgument() {
  int argc = 0;
  wchar_t **argv = ::CommandLineToArgvW(::GetCommandLineW(), &argc);
  std::wstring found;
  if (argv != nullptr) {
    for (int i = 1; i < argc && found.empty(); ++i) {
      if (argv[i][0] != L'\0' && wcsncmp(argv[i], L"--", 2) != 0) found = argv[i];
    }
    ::LocalFree(argv);
  }
  // Relative to this process's folder, which is not the running one's.
  if (!found.empty()) {
    wchar_t full[MAX_PATH * 4];
    DWORD n = ::GetFullPathNameW(found.c_str(), MAX_PATH * 4, full, nullptr);
    if (n > 0 && n < MAX_PATH * 4) found.assign(full, n);
  }
  return found;
}

// Brings the first instance's window forward and, when [path] is not empty,
// hands it to that instance with WM_COPYDATA (it opens the file). Returns
// false if no window appears.
bool ActivateFirstInstance(const std::wstring &prop,
                           const std::wstring &path = L"") {
  FindContext ctx{prop.c_str(), nullptr};
  // The first instance may still be creating its window; retry briefly.
  for (int i = 0; i < 50 && ctx.found == nullptr; ++i) {
    ::EnumWindows(FindMarked, reinterpret_cast<LPARAM>(&ctx));
    if (ctx.found == nullptr) ::Sleep(100);
  }
  if (ctx.found == nullptr) return false;
  if (::IsIconic(ctx.found)) ::ShowWindow(ctx.found, SW_RESTORE);
  ::SetForegroundWindow(ctx.found);
  if (!path.empty()) {
    COPYDATASTRUCT data;
    data.dwData = kOpenFileCopyData;
    data.cbData = static_cast<DWORD>((path.size() + 1) * sizeof(wchar_t));
    data.lpData = const_cast<wchar_t *>(path.c_str());
    DWORD_PTR ignored = 0;
    ::SendMessageTimeoutW(ctx.found, WM_COPYDATA, 0,
                          reinterpret_cast<LPARAM>(&data),
                          SMTO_ABORTIFHUNG | SMTO_NORMAL, 5000, &ignored);
  }
  return true;
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  const std::wstring key = DataFolderKey();
  const std::wstring window_prop = L"Noted.Instance." + key;
  const std::wstring mutex_name = L"Local\\Noted.SingleInstance.v1." + key;
  // Created owned by this (main) thread, which lives as long as the process,
  // so a waiting second launch blocks until this process exits. Never closed.
  HANDLE instance_mutex = ::CreateMutexW(nullptr, TRUE, mutex_name.c_str());
  const DWORD mutex_error = ::GetLastError();
  if (instance_mutex == nullptr && mutex_error == ERROR_ACCESS_DENIED) {
    // Held by something we can't open: treat as already running.
    ActivateFirstInstance(window_prop, FileArgument());
    return EXIT_SUCCESS;
  }
  if (instance_mutex != nullptr && mutex_error == ERROR_ALREADY_EXISTS) {
    if (ActivateFirstInstance(window_prop, FileArgument())) {
      ::CloseHandle(instance_mutex);
      return EXIT_SUCCESS;
    }
    // No window: the first instance is shutting down. Wait for it to let go
    // of the mutex, then start normally (we then own it).
    DWORD wait = ::WaitForSingleObject(instance_mutex, 10000);
    if (wait != WAIT_OBJECT_0 && wait != WAIT_ABANDONED) {
      ::CloseHandle(instance_mutex);
      return EXIT_SUCCESS;
    }
  }

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 800);
  if (!window.Create(L"Noted", origin, size)) {
    return EXIT_FAILURE;
  }
  // Mark the window so a second launch can find it (see the guard above).
  ::SetPropW(window.GetHandle(), window_prop.c_str(),
             reinterpret_cast<HANDLE>(1));
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
