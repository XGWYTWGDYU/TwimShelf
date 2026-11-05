import CoreImage
import Foundation
import MLX
import MLXEmbedders
import MLXLMCommon
import MLXVLM

/// Runs MLX vision-language models (tags) and embedders (vectors) from local model folders.
///
/// One GPU job at a time: an actor is re-entrant, so while one inference awaits, another call (a
/// search embedding, a single re-tag, unloading on a memory warning) could enter and drive MLX /
/// Metal from a second thread at the same time — that crashed in Metal's command-buffer code.
/// Every MLX operation, unloading included, runs through a first-come-first-served gate. Weights
/// stay loaded between images of a batch and go 30 s after the last job.
public actor MLXRuntime {
    public static let shared = MLXRuntime()

    /// Where the runtime reports what it did with memory (the app's log).
    nonisolated(unsafe) public static var log: (String) -> Void = { _ in }

    /// Metal is needed (the simulator has none that MLX can use).
    public static var isSupported: Bool {
        #if targetEnvironment(simulator)
        false
        #else
        true
        #endif
    }

    public enum RuntimeError: Error { case simulator, notInstalled(URL) }

    private var tagger: (dir: URL, container: ModelContainer)?
    private var embedder: (dir: URL, container: EmbedderModelContainer)?
    private var idleUnload: Task<Void, Never>?
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private func acquire() async {
        idleUnload?.cancel()
        idleUnload = nil
        if !busy { busy = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            busy = false
            guard tagger != nil || embedder != nil else { return }
            idleUnload = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { return }
                await self?.unloadIfIdle()
            }
        } else { waiters.removeFirst().resume() }
    }

    private func unloadIfIdle() {
        guard !Task.isCancelled, !busy, waiters.isEmpty else { return }
        idleUnload = nil
        releaseModels()
    }

    private func releaseModels() {
        let before = MLX.Memory.snapshot()
        tagger = nil
        embedder = nil
        MLX.GPU.clearCache()
        let after = MLX.Memory.snapshot()
        Self.log("AI unloaded: active \(before.activeMemory) -> \(after.activeMemory), cache \(before.cacheMemory) -> \(after.cacheMemory) bytes")
    }

    private func exclusive<T>(_ body: () async throws -> T) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await body()
    }

    /// Releases the models (after the running inference, never during it).
    public func unloadAll() async { await exclusive { releaseModels() } }

    /// For diagnostics: whether weights are loaded, and MLX's memory.
    public func state() -> (tagger: Bool, embedder: Bool, active: Int, cache: Int) {
        let s = MLX.Memory.snapshot()
        return (tagger != nil, embedder != nil, s.activeMemory, s.cacheMemory)
    }

    private static func check(_ dir: URL) throws {
        guard isSupported else { throw RuntimeError.simulator }
        guard FileManager.default.fileExists(atPath: dir.appendingPathComponent("config.json").path) else { throw RuntimeError.notInstalled(dir) }
    }

    private func loadTagger(_ dir: URL) async throws -> ModelContainer {
        if let t = tagger, t.dir == dir { return t.container }
        tagger = nil
        MLX.GPU.clearCache()
        try Self.check(dir)
        MLX.GPU.set(cacheLimit: 128 * 1024 * 1024)
        let c = try await VLMModelFactory.shared.loadContainer(from: dir, using: LocalTokenizerLoader())
        tagger = (dir, c)
        return c
    }

    private func loadEmbedder(_ dir: URL) async throws -> EmbedderModelContainer {
        if let e = embedder, e.dir == dir { return e.container }
        embedder = nil
        MLX.GPU.clearCache()
        try Self.check(dir)
        MLX.GPU.set(cacheLimit: 128 * 1024 * 1024)
        let c = try await EmbedderModelFactory.shared.loadContainer(from: dir, using: LocalTokenizerLoader())
        embedder = (dir, c)
        return c
    }

    /// The model's answer about one picture (the caller parses it).
    public func respond(modelDir: URL, system: String, question: String, image: CIImage, maxTokens: Int = 160) async throws -> String {
        try await exclusive {
            let container = try await loadTagger(modelDir)
            let session = ChatSession(
                container, instructions: system,
                generateParameters: GenerateParameters(maxTokens: maxTokens, temperature: 0.1),
                processing: .init(resize: CGSize(width: 448, height: 448)))
            return try await session.respond(to: question, image: .ciImage(image), video: nil)
        }
    }

    /// L2-normalized embeddings, one per text (texts are embedded individually: labels are short
    /// and this avoids padding effects with last-token pooling).
    public func embed(modelDir: URL, texts: [String]) async throws -> [[Float]] {
        try await exclusive {
            let container = try await loadEmbedder(modelDir)
            return await container.perform { ctx in
                texts.map { t in
                    let ids = ctx.tokenizer.encode(text: t, addSpecialTokens: true)
                    let input = MLXArray(ids.map { Int32($0) }).expandedDimensions(axis: 0)
                    let mask = MLXArray.ones(input.shape, dtype: .int32)
                    let out = ctx.model(input, positionIds: nil, tokenTypeIds: nil, attentionMask: mask)
                    let pooled = ctx.pooling(out, mask: mask, normalize: true)
                    pooled.eval()
                    return pooled.asArray(Float.self)
                }
            }
        }
    }
}
