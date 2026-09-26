#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
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
  Win32Window::Size size(1280, 720);
  // Debug aid: ZIPLINER_WINDOW=x,y,w,h sets the initial window placement in
  // logical pixels, e.g. to open on a secondary monitor.
  wchar_t placement[64] = {};
  if (::GetEnvironmentVariableW(L"ZIPLINER_WINDOW", placement, 64) > 0) {
    int x = 0, y = 0, w = 0, h = 0;
    if (::swscanf_s(placement, L"%d,%d,%d,%d", &x, &y, &w, &h) == 4 && w > 0 && h > 0) {
      origin = Win32Window::Point(x, y);
      size = Win32Window::Size(w, h);
    }
  }
  if (!window.Create(L"\u7EC8\u672B\u5730\u5750\u6807\u5DE5\u5177", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
