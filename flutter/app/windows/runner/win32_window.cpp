#include "win32_window.h"

#include <dwmapi.h>
#include <algorithm>
#include <filesystem>
#include <fstream>
#include <shlobj.h>
#include <flutter_windows.h>

#include "resource.h"

namespace {

constexpr const wchar_t kWindowClassName[] = L"FLUTTER_RUNNER_WIN32_WINDOW";

// Only window geometry is persisted; never library paths or user content.
std::filesystem::path GeometryPath() {
  PWSTR root = nullptr;
  if (FAILED(SHGetKnownFolderPath(FOLDERID_LocalAppData, 0, nullptr, &root))) return {};
#ifdef _DEBUG
  const wchar_t* app = L"TwimShelfDebug";
#else
  const wchar_t* app = L"TwimShelf";
#endif
  auto path = std::filesystem::path(root) / app / L"window.txt";
  CoTaskMemFree(root);
  return path;
}

bool ReadGeometry(RECT* bounds, bool* maximized) {
  try {
    std::ifstream stream(GeometryPath());
    int version, zoom;
    long x, y, w, h;
    if (!(stream >> version >> x >> y >> w >> h >> zoom) || version != 1 ||
        w < 360 || h < 480 || w > 32768 || h > 32768 ||
        x < -131072 || x > 131072 || y < -131072 || y > 131072) return false;
    *bounds = {x, y, x + w, y + h};
    *maximized = zoom == 1;
    return true;
  } catch (...) { return false; }
}

void SaveGeometry(HWND window) noexcept {
  try {
    WINDOWPLACEMENT placement{};
    placement.length = sizeof(placement);
    if (!GetWindowPlacement(window, &placement)) return;
    // Convert workspace coordinates to screen coordinates before persisting.
    auto r = placement.rcNormalPosition;
    MONITORINFO monitor{}; monitor.cbSize = sizeof(monitor);
    if (GetMonitorInfo(MonitorFromWindow(window, MONITOR_DEFAULTTONEAREST), &monitor)) {
      OffsetRect(&r, monitor.rcWork.left-monitor.rcMonitor.left,
                     monitor.rcWork.top-monitor.rcMonitor.top);
    }
    auto path = GeometryPath();
    if (path.empty()) return;
    std::filesystem::create_directories(path.parent_path());
    auto temporary = path; temporary += L".partial";
    std::ofstream stream(temporary, std::ios::trunc);
    stream << 1 << ' ' << r.left << ' ' << r.top << ' ' << r.right-r.left << ' '
           << r.bottom-r.top << ' ' << (placement.showCmd == SW_SHOWMAXIMIZED ||
               (placement.flags & WPF_RESTORETOMAXIMIZED) ? 1 : 0) << '\n';
    stream.close();
    if (stream) MoveFileExW(temporary.c_str(), path.c_str(), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH);
  } catch (...) {}  // An unwritable preferences directory must not prevent closing.
}

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

  RECT saved{};
  if (ReadGeometry(&saved, &restore_maximized_)) {
    HMONITOR target = MonitorFromRect(&saved, MONITOR_DEFAULTTONEAREST);
    MONITORINFO info{};
    info.cbSize = sizeof(info);
    if (GetMonitorInfo(target, &info)) {
      const auto& work = info.rcWork;
      LONG width = std::min(saved.right-saved.left, work.right-work.left);
      LONG height = std::min(saved.bottom-saved.top, work.bottom-work.top);
      saved.left = std::clamp(saved.left, work.left, work.right-width);
      saved.top = std::clamp(saved.top, work.top, work.bottom-height);
      saved.right = saved.left+width; saved.bottom = saved.top+height;
      SetWindowPos(window, nullptr, saved.left, saved.top, width, height,
                   SWP_NOZORDER | SWP_NOACTIVATE);
    }
  }
  UpdateTheme(window);

  return OnCreate();
}

bool Win32Window::Show() {
  return ShowWindow(window_handle_, restore_maximized_ ? SW_SHOWMAXIMIZED : SW_SHOWNORMAL);
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
  switch (message) {
    case WM_CLOSE:
      SaveGeometry(hwnd);
      break;
    case WM_GETMINMAXINFO: {
      const UINT dpi = GetDpiForWindow(hwnd);
      RECT minimum{0, 0, MulDiv(360, dpi ? dpi : 96, 96), MulDiv(480, dpi ? dpi : 96, 96)};
      AdjustWindowRectExForDpi(&minimum, WS_OVERLAPPEDWINDOW, FALSE, 0, dpi ? dpi : 96);
      auto limits = reinterpret_cast<MINMAXINFO*>(lparam);
      limits->ptMinTrackSize = {minimum.right-minimum.left, minimum.bottom-minimum.top};
      return 0;
    }
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
  // Material theming is handled in Dart. Keep the runner at Windows 10 1803.
  (void)window;
}
