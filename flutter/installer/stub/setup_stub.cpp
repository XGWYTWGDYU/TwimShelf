// setup.exe: the one file people download. It carries the setup app and the program as a tar
// archive appended after this executable, followed by an 8-byte little-endian length and the
// marker "TLSETUP1". It unpacks them into a fresh temporary folder with the tar.exe Windows has
// had since 10 1803, runs the setup there, waits, and removes the folder.
//
// Build (MSVC):  cl /O2 /EHsc /DUNICODE setup_stub.cpp setup_stub.res /link /SUBSYSTEM:WINDOWS shell32.lib
// Then:          copy /b setup_stub.exe + payload.tar + trailer.bin TwimShelf-setup.exe
#define NOMINMAX
#include <windows.h>
#include <shellapi.h>
#include <algorithm>
#include <string>
#include <vector>

static void fail(const wchar_t* what) {
  MessageBoxW(nullptr, what, L"Setup", MB_ICONERROR | MB_OK);
  ExitProcess(1);
}

static bool run(std::wstring cmd, const std::wstring& dir, DWORD* code) {
  STARTUPINFOW si{sizeof si};
  PROCESS_INFORMATION pi{};
  si.dwFlags = STARTF_USESHOWWINDOW;
  si.wShowWindow = SW_HIDE;
  if (!CreateProcessW(nullptr, cmd.data(), nullptr, nullptr, FALSE, CREATE_NO_WINDOW, nullptr, dir.c_str(), &si, &pi)) return false;
  WaitForSingleObject(pi.hProcess, INFINITE);
  GetExitCodeProcess(pi.hProcess, code);
  CloseHandle(pi.hThread);
  CloseHandle(pi.hProcess);
  return true;
}

int WINAPI wWinMain(HINSTANCE, HINSTANCE, PWSTR, int) {
  SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
  wchar_t self[MAX_PATH * 4];
  if (!GetModuleFileNameW(nullptr, self, ARRAYSIZE(self))) fail(L"Cannot read the setup file.");

  HANDLE f = CreateFileW(self, GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING, 0, nullptr);
  if (f == INVALID_HANDLE_VALUE) fail(L"Cannot read the setup file.");
  LARGE_INTEGER size;
  GetFileSizeEx(f, &size);
  char trailer[16];
  LARGE_INTEGER at;
  at.QuadPart = size.QuadPart - 16;
  DWORD got = 0;
  SetFilePointerEx(f, at, nullptr, FILE_BEGIN);
  if (!ReadFile(f, trailer, 16, &got, nullptr) || got != 16 || memcmp(trailer + 8, "TLSETUP1", 8) != 0) fail(L"The setup file is damaged. Download it again.");
  unsigned long long len = 0;
  memcpy(&len, trailer, 8);
  if (len == 0 || len > (unsigned long long)size.QuadPart - 16) fail(L"The setup file is damaged. Download it again.");

  // a temporary folder of our own
  wchar_t tmp[MAX_PATH];
  GetTempPathW(MAX_PATH, tmp);
  std::wstring dir = std::wstring(tmp) + L"tl-setup-" + std::to_wstring(GetCurrentProcessId()) + L"-" + std::to_wstring(GetTickCount64());
  if (!CreateDirectoryW(dir.c_str(), nullptr)) fail(L"Cannot create a temporary folder.");
  std::wstring tar = dir + L"\\payload.tar";
  HANDLE out = CreateFileW(tar.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_NEW, 0, nullptr);
  if (out == INVALID_HANDLE_VALUE) fail(L"Cannot unpack the setup.");
  at.QuadPart = size.QuadPart - 16 - (long long)len;
  SetFilePointerEx(f, at, nullptr, FILE_BEGIN);
  std::vector<char> buf(1 << 20);
  unsigned long long left = len;
  while (left > 0) {
    DWORD want = (DWORD)std::min<unsigned long long>(left, buf.size()), n = 0, w = 0;
    if (!ReadFile(f, buf.data(), want, &n, nullptr) || n == 0 || !WriteFile(out, buf.data(), n, &w, nullptr) || w != n) fail(L"Cannot unpack the setup.");
    left -= n;
  }
  CloseHandle(out);
  CloseHandle(f);

  DWORD code = 1;
  wchar_t system[MAX_PATH];
  GetSystemDirectoryW(system, MAX_PATH);
  if (!run(L"\"" + std::wstring(system) + L"\\tar.exe\" -xf payload.tar", dir, &code) || code != 0) fail(L"Cannot unpack the setup (tar.exe is part of Windows 10 1803 and later).");
  DeleteFileW(tar.c_str());

  // the setup app: setup\tl_setup.exe, the program: payload\, its description: payload.json
  STARTUPINFOW si{sizeof si};
  PROCESS_INFORMATION pi{};
  std::wstring cmd = L"\"" + dir + L"\\setup\\tl_setup.exe\" --payload \"" + dir + L"\\payload\"";
  if (!CreateProcessW(nullptr, cmd.data(), nullptr, nullptr, FALSE, 0, nullptr, (dir + L"\\setup").c_str(), &si, &pi)) fail(L"Cannot start the setup.");
  WaitForSingleObject(pi.hProcess, INFINITE);
  CloseHandle(pi.hThread);
  CloseHandle(pi.hProcess);

  // remove the temporary folder
  std::wstring from = dir + L'\0';
  SHFILEOPSTRUCTW op{};
  op.wFunc = FO_DELETE;
  op.pFrom = from.c_str();
  op.fFlags = FOF_NO_UI;
  SHFileOperationW(&op);
  return 0;
}
