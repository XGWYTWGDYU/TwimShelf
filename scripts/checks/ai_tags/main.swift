// The Swift parser of model replies (TLLocalAI's ModelInput.parseTags) against the cases every
// app's parser follows (cases.json; the Flutter tests and windows.cs read them too).
// Compiled against the real ModelInput.swift: scripts/checks/run.sh
import Foundation

struct Case: Decodable { let reply: String; let tags: [String]?; let error: String?; let requireArray: Bool? }
struct File: Decodable { let cases: [Case] }
let file = try JSONDecoder().decode(File.self, from: Data(contentsOf: URL(fileURLWithPath: "scripts/checks/ai_tags/cases.json")))
var failed = 0
for c in file.cases {
    let got: String
    do { got = "tags \(try ModelInput.parseTags(c.reply, requireArray: c.requireArray ?? false))" }
    catch ModelInput.TagsError.notTags { got = "error bad" }
    catch ModelInput.TagsError.noTags { got = "error none" }
    let want = c.tags.map { "tags \($0)" } ?? "error \(c.error ?? "?")"
    if got != want { print("ai_tags: \(c.reply.debugDescription): got \(got), want \(want)"); failed += 1 }
}
if failed > 0 { exit(1) }
print("ai_tags (Swift): \(file.cases.count) cases")
