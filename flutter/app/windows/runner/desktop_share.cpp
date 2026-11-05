#include "desktop_share.h"
#include <shlobj.h>
#include <shobjidl.h>
#include <propvarutil.h>
#pragma comment(lib, "propsys.lib")
#include <algorithm>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <sstream>
#include <stdexcept>
#include <winrt/Windows.Data.Json.h>
#include <winrt/Windows.Foundation.Collections.h>

namespace desktop_share {
namespace fs = std::filesystem;
using namespace winrt;
using namespace Windows::Data::Json;

std::wstring Executable() {
  std::wstring path(32768, L'\0');
  const DWORD n = GetModuleFileNameW(nullptr, path.data(), static_cast<DWORD>(path.size()));
  if (!n || n >= path.size()) throw std::runtime_error("shareInbox.executable");
  path.resize(n); return path;
}

std::wstring Root() {
  PWSTR path = nullptr;
  check_hresult(SHGetKnownFolderPath(FOLDERID_LocalAppData, 0, nullptr, &path));
  fs::path root(path); CoTaskMemFree(path);
#ifdef NDEBUG
  return (root / L"org.twimshelf" / L"Shares").wstring();
#else
  return (root / L"org.twimshelf" / L"Shares-Debug").wstring();
#endif
}

static std::wstring Id() {
  GUID guid; check_hresult(CoCreateGuid(&guid));
  wchar_t value[40]; StringFromGUID2(guid, value, 40);
  std::wstring id(value); id.erase(0, 1); id.pop_back(); return id;
}

static void Write(const fs::path& path, const std::string& text) {
  HANDLE file = CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) throw_last_error();
  DWORD count = 0;
  const bool ok = text.size() <= MAXDWORD && WriteFile(file, text.data(), static_cast<DWORD>(text.size()), &count, nullptr)
      && count == text.size() && FlushFileBuffers(file);
  const DWORD error = GetLastError(); CloseHandle(file);
  if (!ok) { DeleteFileW(path.c_str()); throw_hresult(HRESULT_FROM_WIN32(error ? error : ERROR_WRITE_FAULT)); }
}

static void Publish(const fs::path& partial, const fs::path& ready) {
  if (!MoveFileExW(partial.c_str(), ready.c_str(), MOVEFILE_WRITE_THROUGH)) throw_last_error();
}

void QueueArguments(const std::vector<std::string>& arguments) {
  bool importing = false;
  for (const auto& a : arguments) if (a == "--import" || a.rfind("--import=", 0) == 0 || a == "--quick-download") importing = true;
  if (!importing || (arguments.size() == 1 && arguments[0] == "--import")) return;
  std::wstring cwd(32768, L'\0');
  const DWORD n = GetCurrentDirectoryW(static_cast<DWORD>(cwd.size()), cwd.data());
  if (!n || n >= cwd.size()) throw std::runtime_error("shareInbox.cwd");
  cwd.resize(n);
  JsonObject data; data.Insert(L"version", JsonValue::CreateNumberValue(1));
  data.Insert(L"workingDirectory", JsonValue::CreateStringValue(cwd));
  JsonArray args;
  for (const auto& a : arguments) args.Append(JsonValue::CreateStringValue(to_hstring(a)));
  data.Insert(L"arguments", args);
  const fs::path directory = fs::path(Root()) / L"Requests";
  fs::create_directories(directory);
  const auto id = Id(); const auto partial = directory / (id + L".partial");
  Write(partial, to_string(data.Stringify()));
  Publish(partial, directory / (id + L".json"));
}

HANDLE AcquirePrimary() {
  // Stable FNV-1a of the per-user root also separates debug and release.
  uint64_t hash = 14695981039346656037ULL;
  for (const auto c : Root()) { hash ^= c; hash *= 1099511628211ULL; }
  const auto name = L"Local\\TwimShelf-" + std::to_wstring(hash);
  HANDLE mutex = CreateMutexW(nullptr, FALSE, name.c_str());
  if (!mutex) throw_last_error();
  if (GetLastError() == ERROR_ALREADY_EXISTS) { CloseHandle(mutex); return nullptr; }
  return mutex;
}

// Earlier versions put a shortcut in Explorer's Send to: this install's own goes away.
void RemoveSendTo(const std::string& title) {
  PWSTR send_to = nullptr;
  check_hresult(SHGetKnownFolderPath(FOLDERID_SendTo, 0, nullptr, &send_to));
  fs::path directory(send_to); CoTaskMemFree(send_to);
  std::wstring label(to_hstring(title));
  for (auto& c : label) if (c < 32 || std::wstring(L"<>:\"/\\|?*").find(c) != label.npos) c = L'_';
  const fs::path destination = directory / (label + L".lnk");
  if (!fs::exists(destination)) return;
  com_ptr<IShellLinkW> shortcut;
  check_hresult(CoCreateInstance(CLSID_ShellLink, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(shortcut.put())));
  check_hresult(shortcut.as<IPersistFile>()->Load(destination.c_str(), STGM_READ));
  wchar_t target[32768]{};
  check_hresult(shortcut->GetPath(target, 32768, nullptr, SLGP_RAWPATH));
  if (_wcsicmp(target, Executable().c_str()) != 0) return; // Never another install's.
  std::error_code error;
  fs::remove(destination, error);
}

void CopyFileToClipboard(const std::string& path) {
  std::wstring wide(winrt::to_hstring(path));
  std::replace(wide.begin(), wide.end(), L'/', L'\\');
  const size_t size = sizeof(DROPFILES) + (wide.size() + 2) * sizeof(wchar_t);
  HGLOBAL memory = GlobalAlloc(GHND, size);
  if (memory == nullptr) throw std::runtime_error("clipboard.memory");
  auto* drop = static_cast<DROPFILES*>(GlobalLock(memory));
  drop->pFiles = sizeof(DROPFILES);
  drop->fWide = TRUE;
  memcpy(reinterpret_cast<char*>(drop) + sizeof(DROPFILES), wide.c_str(), wide.size() * sizeof(wchar_t));
  GlobalUnlock(memory);
  if (!OpenClipboard(nullptr)) { GlobalFree(memory); throw std::runtime_error("clipboard.busy"); }
  EmptyClipboard();
  const bool done = SetClipboardData(CF_HDROP, memory) != nullptr;
  CloseClipboard();
  if (!done) { GlobalFree(memory); throw std::runtime_error("clipboard.set"); }
}

void InstallJumpList(const std::string& title) {
  // System.Title: the text of a task in the list
  static const PROPERTYKEY kTitle = {{0xF29F85E0, 0x4FF9, 0x1068, {0xAB, 0x91, 0x08, 0x00, 0x2B, 0x27, 0xB3, 0xD9}}, 2};
  const auto executable = Executable();
  com_ptr<IShellLinkW> link;
  check_hresult(CoCreateInstance(CLSID_ShellLink, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(link.put())));
  check_hresult(link->SetPath(executable.c_str()));
  check_hresult(link->SetArguments(L"--quick-download"));
  check_hresult(link->SetIconLocation(executable.c_str(), 0));
  const auto store = link.as<IPropertyStore>();
  PROPVARIANT value;
  check_hresult(InitPropVariantFromString(to_hstring(title).c_str(), &value));
  const HRESULT set = store->SetValue(kTitle, value);
  PropVariantClear(&value);
  check_hresult(set);
  check_hresult(store->Commit());
  com_ptr<ICustomDestinationList> list;
  check_hresult(CoCreateInstance(CLSID_DestinationList, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(list.put())));
  UINT slots = 0;
  com_ptr<IObjectArray> removed;
  check_hresult(list->BeginList(&slots, IID_PPV_ARGS(removed.put())));
  com_ptr<IObjectCollection> tasks;
  check_hresult(CoCreateInstance(CLSID_EnumerableObjectCollection, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(tasks.put())));
  check_hresult(tasks->AddObject(link.get()));
  check_hresult(list->AddUserTasks(tasks.as<IObjectArray>().get()));
  check_hresult(list->CommitList());
}
}
