#ifndef RUNNER_DESKTOP_SHARE_H_
#define RUNNER_DESKTOP_SHARE_H_
#include <windows.h>
#include <string>
#include <vector>
namespace desktop_share {
std::wstring Executable();
std::wstring Root();
void QueueArguments(const std::vector<std::string>& arguments);
// Hold this handle until process exit; null means another primary owns it.
HANDLE AcquirePrimary();
void RemoveSendTo(const std::string& title);
// 下载帖子 in the taskbar icon's menu.
void InstallJumpList(const std::string& title);
// 拷贝 in the viewers: the file on the clipboard, as Explorer copies one.
void CopyFileToClipboard(const std::string& path);
}
#endif
