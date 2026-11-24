import CoreImage
import Foundation
import Metal
#if os(iOS)
import os
#endif

/// MLX as the Rust core's on-device engine. The apps hand these two functions to the core
/// (`tl_ai_set_mlx`); the core calls them, on a thread of its own and never the main one, with the
/// picture it prepared and the prompt it made, and reads the tags out of the reply itself
/// (core/src/ai). The same in the native apps and the Flutter app.
public enum CoreBridge {
    public typealias Describe = @convention(c) (
        UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?, Int32,
        UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
    ) -> UnsafeMutablePointer<CChar>?
    public typealias Free = @convention(c) (UnsafeMutablePointer<CChar>?) -> Void

    /// MLX's answer about the picture at `image` from the model in `modelDir`, or nil with `error` set.
    public static let describe: Describe = { dir, image, system, question, maxTokens, error in
        func fail(_ why: String) -> UnsafeMutablePointer<CChar>? { error?.pointee = strdup(why); return nil }
        guard let dir, let image, let system, let question else { return fail("arguments") }
        let modelDir = URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        #if os(iOS)
        // iOS ends an app over its memory limit without a warning that arrives in time
        let need = folderBytes(modelDir) * 5 / 4 + 500_000_000
        let available = UInt64(os_proc_available_memory())
        if available < need { return fail(String(format: "%.1f GB > %.1f GB", Double(need) / 1e9, Double(available) / 1e9)) }
        #endif
        guard let picture = ModelInput.stillImage(path: String(cString: image), kind: "photo") else { return fail("image") }
        let (s, q, limit) = (String(cString: system), String(cString: question), Int(maxTokens))
        let done = DispatchSemaphore(value: 0)
        let answer = Answer()
        Task.detached(priority: .utility) {
            do { answer.value = .success(try await MLXRuntime.shared.respond(modelDir: modelDir, system: s, question: q, image: picture, maxTokens: limit)) }
            catch { answer.value = .failure(error) }
            done.signal()
        }
        done.wait()
        switch answer.value {
        case .success(let text): return strdup(text)
        case .failure(let e): return fail("\(e)")
        }
    }

    public static let free: Free = { p in Foundation.free(p) }

    /// The memory the GPU has for a model, for the core's advice on which models fit.
    public static var memory: UInt64 {
        #if os(iOS)
        // what this app may use, which is what decides whether a model runs here
        return UInt64(os_proc_available_memory())
        #else
        return MTLCreateSystemDefaultDevice()?.recommendedMaxWorkingSetSize ?? 0
        #endif
    }

    /// Written by the task before it signals, read after the wait: never at the same time.
    private final class Answer: @unchecked Sendable { var value: Result<String, Error> = .failure(CancellationError()) }

    private static func folderBytes(_ dir: URL) -> UInt64 {
        let files = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey])
        var total: UInt64 = 0
        while let f = files?.nextObject() as? URL { total += UInt64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        return total
    }
}
