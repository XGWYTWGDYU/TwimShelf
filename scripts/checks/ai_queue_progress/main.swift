// Regression check (review 2026-10-21, finding 10): the automatic tagging queue always reaches the
// media behind a few that cannot be analysed. SCENARIO=unreadable: three damaged files first (they
// say nothing about the model, so the first run goes on to the healthy one); SCENARIO=model: three
// images the model refuses (the attempts are given back once, then counted, so the fourth run
// moves on). Compiled against the real AutoTagger.swift: scripts/checks/run.sh
import Foundation

enum Core {
 struct MediaRef: Equatable { let mediaId:String;let path:String;let kind:String;var text:String?=nil }
 struct Failure { let mediaId:String }
 struct Tag {let label:String}
 enum AiAttemptStep {case begin,failed,undo}
 static var attempts:[String:Int]=[:]
 static var completed:Set<String>=[]
 static let scenario=ProcessInfo.processInfo.environment["SCENARIO"] ?? "unreadable"
 static var lastFail:[String:Int]=[:]
 static let files=(1...4).map {MediaRef(mediaId:"\($0)",path:$0<=3 ? (scenario=="unreadable" ? "bad\($0)":"modelbad"):"healthy",kind:"photo")}
 static func epoch()throws->UInt64 {0}
 static func aiCounts()->(done:Int,total:Int) {(completed.count,4)}
 static func aiPending(model:String,since:Int,limit:Int)->[MediaRef] {Array(files.filter {let a=attempts[$0.mediaId] ?? 0; return !completed.contains($0.mediaId) && a<2 && !(a>0 && since>0 && (lastFail[$0.mediaId] ?? 0)>=since)}.prefix(limit))}
 static func mediaPage(after:String,limit:Int)->[MediaRef] {Array(files.filter {$0.mediaId>after}.prefix(limit))}
 static func aiFailures()->[Failure] {attempts.filter {$0.value>=2}.map {Failure(mediaId:$0.key)}}
 static func allTags()->[Tag] {[]}
 static func mediaTags(_ id:String)->[String] {[]}
 static func aiAttempt(_ step:AiAttemptStep,mediaId:String,model:String,reason:String="") {
  switch step {case .begin:attempts[mediaId,default:0]+=1;case .undo:attempts[mediaId,default:0]-=1;case .failed:lastFail[mediaId]=Int(Date().timeIntervalSince1970)}
 }
 static func aiApply(mediaId:String,model:String,labels:[String],replaceOld:Bool,epoch:UInt64)throws {completed.insert(mediaId)}
 static func labelsMissingVectors(model:String)->[String] {[]}
 static func setVectors(model:String,items:[(String,[Float])],epoch:UInt64)throws {}
 struct AIFailure: Error,LocalizedError {let kind:String;let status:Int?;let detail:String
  var isDeviceProblem:Bool {["noGpu","noModel","engine"].contains(kind)};var errorDescription:String?{kind}}
}
final class ModelStore {
 static let shared=ModelStore();var autoTag=true;var activeTaggerId:String?="test-model";var activeEmbedderId:String?=nil
 func displayName(_ id:String)->String {id}
}
enum AppLog {static func warn(_ a:String,_ b:String){};static func error(_ a:String,_ b:String){}}
final class AIEngine {
 enum EngineError: Error,LocalizedError {case simulator;var errorDescription:String?{"test"}}
 static let shared=AIEngine();static let isSupported=true
 static var healthyCalls=0
 static func canRun(_ s:String)->Bool {true}
 static func memoryCheck(_ s:String)->EngineError? {nil}
 // what the core reports: a damaged file cannot be read; the model refuses the "modelbad" ones
 static func tags(path:String,kind:String,repo:String,postText:String?,existing:[String],vocabulary:[String])async throws->[String] {
  if path.hasPrefix("bad") {throw Core.AIFailure(kind:"unreadable",status:nil,detail:"")}
  if path=="modelbad" {throw Core.AIFailure(kind:"badTags",status:nil,detail:"")}
  healthyCalls+=1;return ["tag"]}
 func embed(_ chunk:[String],repo:String)async throws->[[Float]] {[]}
}
@main struct QueueHarness {
 @MainActor static func main() async throws {
  let tagger=AutoTagger.shared
  for round in 1...6 {
   tagger.startIfEnabled()
   try await Task.sleep(nanoseconds:200_000_000)
   while tagger.running {try await Task.sleep(nanoseconds:10_000_000)}
   print("round \(round): completed=\(Core.completed.count), healthyCalls=\(AIEngine.healthyCalls), attempts=\(Core.attempts), error=\(tagger.lastError ?? "nil")")
  }
  if Core.completed.count != 1 { print("FAIL the healthy media was never analysed (scenario \(Core.scenario))"); exit(1) }
  print("ok: scenario \(Core.scenario)")
 }
}
