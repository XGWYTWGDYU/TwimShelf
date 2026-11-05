import Foundation
import CoreImage
import TLLocalAI
#if os(iOS)
import os
#endif

/// The library's side of on-device AI: which model, its prompt, what the picture is, and what
/// the answer means. The MLX work itself is `TLLocalAI.MLXRuntime` (shared with the Flutter
/// app's Apple runner). The vision model only produces tags and the embedder only produces
/// vectors for tag matching; neither output is ever shown as free text.
actor AIEngine {
    static let shared = AIEngine()
    private init() { MLXRuntime.log = { AppLog.info("memory", $0) } }

    enum EngineError: LocalizedError {
        case simulator, notInstalled(String), notEnoughMemory(need: UInt64, available: UInt64)
        var errorDescription: String? {
            switch self {
            case .simulator: L("ai.err.simulator")
            case .notInstalled(let r): L("ai.err.notInstalled", r)
            case .notEnoughMemory(let need, let avail):
                L("ai.err.memory", ByteCountFormatter.string(fromByteCount: Int64(need), countStyle: .memory), ByteCountFormatter.string(fromByteCount: Int64(avail), countStyle: .memory))
            }
        }
    }

    /// Whether this model can tag here: external ones always; built-in ones need Metal.
    nonisolated static func canRun(_ model: String) -> Bool { ExternalModels.isExternal(model) || isSupported }

    /// Memory a built-in model needs when loaded (weights plus working memory), and whether it
    /// fits in what this process may still use. iOS ends an app that goes over its limit without
    /// any warning that arrives in time (a model loads in a few seconds), so the check comes
    /// before loading, never after. On the Mac there is no such limit.
    nonisolated static func memoryCheck(_ model: String) -> EngineError? {
        #if os(iOS)
        guard !ExternalModels.isExternal(model), let info = Core.installedModels().first(where: { $0.id == model }) else { return nil }
        let need = info.bytes + info.bytes / 4 + 500_000_000
        let available = UInt64(os_proc_available_memory())
        return available < need ? .notEnoughMemory(need: need, available: available) : nil
        #else
        return nil
        #endif
    }

    static var isSupported: Bool { MLXRuntime.isSupported }
    private var runtime: MLXRuntime { MLXRuntime.shared }

    /// Releases the models (after the running inference, never during it).
    func unloadAll() async { await runtime.unloadAll() }

    // MARK: Tagging

    #if DEBUG
    /// Isolated diagnostic: synthetic input, no tags or media are written to the library.
    func auditIdleMemory(to output: URL) async {
        var lines: [String] = []
        func record(_ label: String) async {
            let s = await runtime.state()
            lines.append("\(label): active=\(s.active) cache=\(s.cache) tagger=\(s.tagger) embedder=\(s.embedder)")
            try? lines.joined(separator: "\n").write(to: output, atomically: true, encoding: .utf8)
        }
        await record("baseline")
        do {
            guard let model = Core.installedModels().first(where: { $0.vision }) else {
                await record("SKIP: no vision model installed"); return
            }
            for round in 1...2 {
                let image = CIImage(color: CIColor(red: 0.2, green: 0.4, blue: 0.8)).cropped(to: CGRect(x: 0, y: 0, width: 448, height: 448))
                _ = try await tags(for: image, repo: model.id)
                await record("round \(round) after inference")
                try await Task.sleep(nanoseconds: 35_000_000_000)
                await record("round \(round) after idle")
                let st = await runtime.state()
                guard !st.tagger, !st.embedder else { await record("FAIL: idle models retained"); return }
            }
            await record("PASS")
        } catch {
            lines.append("ERROR: \(error.localizedDescription)")
            try? lines.joined(separator: "\n").write(to: output, atomically: true, encoding: .utf8)
        }
    }
    #endif

    /// The tagging prompt is an in-app setting (Settings → AI 模型 → 提示词). The bundled
    /// AIPrompt.txt only supplies the defaults.
    struct Prompt: Codable, Equatable {
        var system = L("prompt.default.system")
        var prompt = L("prompt.default.prompt")
        var context = L("prompt.default.context")
        /// This media's current tags ({existing}).
        var existing = L("prompt.default.existing")
        /// The library's tags ({tags}), so the model reuses names instead of inventing synonyms.
        var vocabulary = L("prompt.default.vocabulary")

        init(system: String? = nil, prompt: String? = nil, context: String? = nil, existing: String? = nil, vocabulary: String? = nil) {
            if let system { self.system = system }; if let prompt { self.prompt = prompt }; if let context { self.context = context }
            if let existing { self.existing = existing }; if let vocabulary { self.vocabulary = vocabulary }
        }
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            let def = Prompt()
            system = try c.decodeIfPresent(String.self, forKey: .system) ?? def.system
            prompt = try c.decodeIfPresent(String.self, forKey: .prompt) ?? def.prompt
            context = try c.decodeIfPresent(String.self, forKey: .context) ?? def.context
            existing = try c.decodeIfPresent(String.self, forKey: .existing) ?? Prompt.defaults.existing
            vocabulary = try c.decodeIfPresent(String.self, forKey: .vocabulary) ?? Prompt.defaults.vocabulary
        }

        private static let key = "ai.prompt"
        /// Bumped when the default prompt changes in a way saved prompts must follow; older
        /// saved prompts are replaced once (the user agreed to this for version 2).
        private static let version = 2
        private static let versionKey = "ai.prompt.version"
        static let changed = Notification.Name("AIPromptChanged")

        /// The prompt in use: the shared setting (the same on every device of the sync account),
        /// or the defaults.
        static func load() -> Prompt {
            migrateLocal()
            if let s = Core.setting(key), let p = try? JSONDecoder().decode(Prompt.self, from: Data(s.utf8)) { return p }
            return defaults
        }
        /// Saved here and sent to every device (the defaults clear the setting everywhere).
        static func save(_ p: Prompt) {
            if p == defaults { Core.setSetting(key, nil) }
            else if let d = try? JSONEncoder().encode(p) { Core.setSetting(key, String(decoding: d, as: UTF8.self)) }
            NotificationCenter.default.post(name: changed, object: nil)
        }

        /// Earlier versions kept a custom prompt on this device only: hand it to the shared
        /// setting once (unless another device already shared one).
        private static func migrateLocal() {
            let ud = UserDefaults.standard
            if ud.integer(forKey: versionKey) < version { ud.removeObject(forKey: key); ud.set(version, forKey: versionKey) }
            guard let d = ud.data(forKey: key) else { return }
            if Core.setting(key) == nil, (try? JSONDecoder().decode(Prompt.self, from: d)) != nil { Core.setSetting(key, String(decoding: d, as: UTF8.self)) }
            ud.removeObject(forKey: key)
        }

        /// Defaults from the bundled AIPrompt.txt ([system] / [prompt] / [context] sections).
        static var defaults: Prompt {
            guard let url = Bundle.main.url(forResource: "AIPrompt", withExtension: "txt"), let raw = try? String(contentsOf: url, encoding: .utf8) else { return Prompt() }
            var p = Prompt(), section: String?, buf: [String] = []
            func flush() {
                let text = buf.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    switch section {
                    case "system": p.system = text; case "prompt": p.prompt = text; case "context": p.context = text
                    case "existing": p.existing = text; case "vocabulary": p.vocabulary = text
                    default: break
                    }
                }
                buf = []
            }
            for line in raw.components(separatedBy: .newlines) {
                if line.hasPrefix("#") { continue }
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("[") && t.hasSuffix("]") { flush(); section = String(t.dropFirst().dropLast()); continue }
                buf.append(line)
            }
            flush()
            return p
        }
    }

    /// Post text for the model: @mentions and links removed, trimmed to 300 characters. Author
    /// name and handle are never passed.
    nonisolated static func cleanContext(_ text: String?) -> String? {
        guard var t = text else { return nil }
        t = t.replacingOccurrences(of: #"https?://\S+"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"@[A-Za-z0-9_]{1,15}"#, with: "", options: .regularExpression)
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        return t.count > 300 ? String(t.prefix(300)) + "…" : t
    }

    /// The installed folder of a built-in model, checked against this device's memory first.
    private func modelDir(_ repo: String) throws -> URL {
        guard Self.isSupported else { throw EngineError.simulator }
        guard let dir = Core.installedModels().first(where: { $0.id == repo })?.url else { throw EngineError.notInstalled(repo) }
        if let e = Self.memoryCheck(repo) { throw e }
        return dir
    }

    private static func mapped(_ e: Error, _ repo: String) -> Error {
        switch e as? MLXRuntime.RuntimeError {
        case .simulator?: EngineError.simulator
        case .notInstalled?: EngineError.notInstalled(repo)
        case nil: e
        }
    }

    /// Tags for one image. The model also sees the post text, the media's current tags and the
    /// library's existing tags, so it keeps fitting tags and reuses existing names verbatim.
    func tags(for image: CIImage, repo: String, postText: String? = nil, existing: [String] = [], vocabulary: [String] = []) async throws -> [String] {
        // an external model runs elsewhere: no GPU gate, works in the simulator too
        if let m = ExternalModels.find(repo) {
            return try await ExternalAI.tags(for: image, model: m, postText: postText, existing: existing, vocabulary: vocabulary)
        }
        let p = ModelPrompts.prompt(forModel: repo)
        let question = p.question(existing: existing, vocabulary: vocabulary, postText: postText)
        do {
            return Self.parseTags(try await runtime.respond(modelDir: try modelDir(repo), system: p.system, question: question, image: image))
        } catch { throw Self.mapped(error, repo) }
    }

    static func parseTags(_ raw: String) -> [String] { ModelInput.parseTags(raw) }

    // MARK: Embeddings

    /// L2-normalized embeddings, one per text (texts are embedded individually: labels are short
    /// and this avoids padding effects with last-token pooling).
    func embed(_ texts: [String], repo: String) async throws -> [[Float]] {
        do { return try await runtime.embed(modelDir: try modelDir(repo), texts: texts) } catch { throw Self.mapped(error, repo) }
    }

    /// Qwen3-Embedding is trained with an instruction prefix on queries (documents are embedded plain).
    nonisolated static func queryText(_ term: String) -> String {
        "Instruct: Given a search keyword, retrieve image tags with the same or closely related meaning\nQuery: \(term)"
    }

    /// Vectors for search terms if an embedder is installed; nil otherwise (substring matching still applies).
    func queryVectors(_ terms: [String]) async -> (model: String, vectors: [[Float]?])? {
        guard Self.isSupported, let repo = ModelStore.shared.activeEmbedderId, !terms.isEmpty else { return nil }
        guard let v = try? await embed(terms.map(Self.queryText), repo: repo) else { return nil }
        return (repo, v.map { Optional($0) })
    }

    // MARK: Image preparation

    nonisolated static func stillImage(path: String, kind: String) -> CIImage? { ModelInput.stillImage(path: path, kind: kind) }
    nonisolated static func fitForModel(_ image: CIImage) -> CIImage { ModelInput.fitForModel(image) }
}
