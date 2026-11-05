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
  // a setup-sized window in the middle of the main screen (logical pixels: Win32Window scales
  // them for the monitor's DPI, so it is the same size and sharp at any display scale)
  const unsigned int width = 640, height = 520;
  const UINT dpi = ::GetDpiForSystem();
  const int screen_w = ::GetSystemMetrics(SM_CXSCREEN) * 96 / dpi, screen_h = ::GetSystemMetrics(SM_CYSCREEN) * 96 / dpi;
  Win32Window::Point origin((screen_w - width) / 2, (screen_h - height) / 2);
  Win32Window::Size size(width, height);
  if (!window.Create(L"Setup", origin, size)) {
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
