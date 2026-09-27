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
  Win32Window::Size size(1280, 720);
  Win32Window::Point origin(10, 10);
  if (!window.Create(L"\u5c40\u57df\u5feb\u4f20", origin, size)) {
    return EXIT_FAILURE;
  }
  RECT window_rect{};
  ::GetWindowRect(window.GetHandle(), &window_rect);
  MONITORINFO monitor_info{};
  monitor_info.cbSize = sizeof(MONITORINFO);
  const HMONITOR monitor =
      ::MonitorFromWindow(window.GetHandle(), MONITOR_DEFAULTTONEAREST);
  ::GetMonitorInfo(monitor, &monitor_info);
  const int window_width = window_rect.right - window_rect.left;
  const int window_height = window_rect.bottom - window_rect.top;
  const int centered_x = monitor_info.rcWork.left +
                         (monitor_info.rcWork.right - monitor_info.rcWork.left -
                          window_width) /
                             2;
  const int centered_y = monitor_info.rcWork.top +
                         (monitor_info.rcWork.bottom - monitor_info.rcWork.top -
                          window_height) /
                             2;
  ::SetWindowPos(window.GetHandle(), nullptr, centered_x, centered_y, 0, 0,
                 SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
