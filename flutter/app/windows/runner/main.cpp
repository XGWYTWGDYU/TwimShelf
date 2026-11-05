#include <flutter/dart_project.h>

#include "identity.h"
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"
#include "desktop_share.h"
#include <filesystem>

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

  flutter::DartProject project((std::filesystem::path(desktop_share::Executable()).parent_path() / L"data").wstring());

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  HANDLE primary = nullptr;
  try {
    desktop_share::QueueArguments(command_line_arguments);
    primary = desktop_share::AcquirePrimary();
  } catch (...) { ::CoUninitialize(); return EXIT_FAILURE; }
  if (!primary) { ::CoUninitialize(); return EXIT_SUCCESS; }
  struct PrimaryHandle { HANDLE value; ~PrimaryHandle() { CloseHandle(value); } } primary_handle{primary};

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
#ifdef _DEBUG
  constexpr wchar_t kWindowTitle[] = TL_APP_NAME_W L" Debug";
#else
  constexpr wchar_t kWindowTitle[] = TL_APP_NAME_W;
#endif
  if (!window.Create(kWindowTitle, origin, size)) {
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
