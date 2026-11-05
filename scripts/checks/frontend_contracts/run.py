"""Compile the production value types without loading the app or a user's library."""
from pathlib import Path
import json, subprocess, tempfile, os
root = Path(__file__).resolve().parents[3]
activity = (root / 'native/Shared/ActivityCenter.swift').read_text()
core = (root / 'native/Shared/Core.swift').read_text()
sync = (root / 'native/Shared/SyncService.swift').read_text()
def section(s, start, end): return s[s.index(start):s.index(end, s.index(start))]
source = 'import Foundation\n' + section(activity, 'struct Activity:', '/// Polls every source')
source += section(core, 'struct VerifyStatus:', 'enum DownloadRoute:')
source += 'enum Core {\n' + section(core, '    struct MediaScope:', '    static func postScope(') + '\n}\n'
source += '''struct SyncFixture {
 struct Peer { var lastSync: UInt64; var lastError: String? }
 struct Status { var syncing = 0; var failed: [String:String]? = nil; var peers: [Peer] = [] }
 var hasAccount = true
 var localNetworkDenied = false
 var status: Status? = nil
'''+section(sync, '    var stateText:', '    static var deviceName:')+'\n}\n'
source += r'''
let active = Activity(kind: .download, title: "正在下载帖子", detail: "2 / 10", progress: 0.2, previewPath: nil, previewIsVideo: false)
for outcome in ["cancelled", "paused", "failed", "partial", "unknown"] {
 let ended = active.ended(outcome: outcome)
 precondition(ended.progress == 0.2 && !ended.title.contains("已完成"), outcome)
}
precondition(active.ended(outcome: "succeeded").progress == 1)
precondition(active.ended(outcome: "failed", detail: "网络错误", progress: 0.3).detail == "网络错误")
print("PASS: cancellation/failure/unknown outcomes never fabricate completion")
var scope = Core.MediaScope(ids: ["a", "b", "pending"], pendingCount: 1, userTags: ["a": ["cat"]])
precondition(scope.commonTags(["a"]).contains("cat"))
precondition(!scope.commonTags(scope.ids).contains("cat"))
precondition(scope.taggedCount("cat", ids: scope.ids) == 1)
for id in scope.ids { scope.userTags[id] = ["cat"] }
precondition(scope.commonTags(scope.ids).contains("cat"))
precondition(scope.commonTags([]).isEmpty)
print("PASS: switching from one media to the whole post allows missing tags to be filled")
precondition(IntegritySummary(total: 3, unchecked: 3, bad: 0, last: nil).text.contains("尚未检查"))
let success = VerifyStatus(outcome: "succeeded", completedAt: 1000, running: false, checked: 2, total: 2, bytes: 10, bad: 0, fixed: 0, finished: true, current: nil)
precondition(IntegritySummary(total: 3, unchecked: 1, bad: 0, last: success).text.contains("待检查"))
precondition(IntegritySummary(total: 2, unchecked: 0, bad: 0, last: success).text.contains("上次检查通过"))
let cancelled = VerifyStatus(outcome: "cancelled", completedAt: 0, running: false, checked: 1, total: 2, bytes: 10, bad: 0, fixed: 0, finished: false, current: nil)
precondition(IntegritySummary(total: 2, unchecked: 1, bad: 0, last: cancelled).text.contains("已中断"))
let repairedSincePartial = VerifyStatus(outcome: "partial", completedAt: 1000, running: false, checked: 2, total: 2, bytes: 10, bad: 1, fixed: 0, finished: true, current: nil)
precondition(!IntegritySummary(total: 2, unchecked: 0, bad: 0, last: repairedSincePartial).text.contains("上次检查通过"))
print("PASS: unchecked, interrupted and partially new libraries never claim all healthy")
var sync = SyncFixture()
precondition(sync.stateText == "正在读取同步状态")
sync.status = .init()
precondition(sync.stateText == "等待连接其他设备")
sync.status?.failed = ["peer": "offline"]
precondition(sync.stateText.contains("失败"))
sync.status?.failed = nil
sync.status?.peers = [.init(lastSync: 1000, lastError: nil)]
precondition(sync.stateText.hasPrefix("上次同步成功于"))
print("PASS: idle/missing/error sync states never claim synchronized")
'''
catalog = json.loads((root / 'native/Resources/Localizable.xcstrings').read_text())['strings']
table = {k: v['localizations']['zh-Hans']['stringUnit']['value'] for k, v in catalog.items() if 'zh-Hans' in v.get('localizations', {}) and 'stringUnit' in v['localizations']['zh-Hans']}
strings = 'import Foundation\nlet tlStrings: [String: String] = try! JSONDecoder().decode([String: String].self, from: Data(#"""\n' + json.dumps(table, ensure_ascii=False) + '\n"""#.utf8))\nfunc L(_ key: String, _ args: Any...) -> String { String(format: (tlStrings[key] ?? key).replacingOccurrences(of: "%lld", with: "%@"), arguments: args.map { String(describing: $0) as NSString }) }\n'
with tempfile.TemporaryDirectory(prefix='tl-swift-contracts-') as out:
 p=Path(out); (p/'main.swift').write_text(source)
 # the catalog's own Chinese text, as the app shows it: the checks read what the person would
 (p/'strings.swift').write_text(strings)
 subprocess.run(['swiftc','-module-cache-path',str(p/'cache'),str(p/'main.swift'),str(p/'strings.swift'),'-o',str(p/'checks')],check=True)
 subprocess.run([str(p/'checks')],check=True)
