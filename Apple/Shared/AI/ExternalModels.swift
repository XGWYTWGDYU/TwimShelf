import Foundation
import CoreImage
import ImageIO
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

/// A tagging model behind an HTTP API, used exactly like a built-in one: it can be the default,
/// gets its own prompt, and appears in every "AI 重新标记" menu.
///
/// One protocol covers nearly every service: OpenAI-style Chat Completions with an image part
/// (OpenAI, xAI Grok, OpenRouter, Ollama, LM Studio, vLLM, llama.cpp server …).
/// Only a URL → a local server (no key; the model is the server's first one unless named).
/// URL + key + model → a cloud service.
struct ExternalModel: Codable, Hashable, Identifiable {
    /// "ext:" + a random id; the same on every device (the list is synced).
    var id: String
    var name: String
    var url: String
    var model: String

    static func new() -> ExternalModel { ExternalModel(id: "ext:" + UUID().uuidString.lowercased(), name: "", url: "", model: "") }

    /// The API key lives in this device's keychain only; it is never synced. It is bound to the
    /// service it was entered for (scheme, host, port): the list of models does sync, so another
    /// device can change a model's URL, and the key must not follow it to a new address (it reads
    /// as nil there, until it is entered again for the new one).
    var apiKey: String? {
        get {
            guard let key = Keychain.get("ai.key." + id).flatMap({ $0.isEmpty ? nil : $0 }) else { return nil }
            let here = Self.origin(url)
            if let bound = Keychain.get("ai.keyorigin." + id), !bound.isEmpty { return bound == here ? key : nil }
            Keychain.set("ai.keyorigin." + id, here)    // a key saved before keys were bound: bound to where it points now
            return key
        }
        nonmutating set {
            let key = (newValue?.isEmpty ?? true) ? nil : newValue
            Keychain.set("ai.key." + id, key)
            Keychain.set("ai.keyorigin." + id, key == nil ? nil : Self.origin(url))
        }
    }

    /// "scheme://host:port" of a model's URL, as `ExternalAI.endpoint` reads it (no scheme: http).
    static func origin(_ url: String) -> String {
        var s = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.contains("://") { s = "http://" + s }
        guard let c = URLComponents(string: s), let host = c.host?.lowercased() else { return s.lowercased() }
        let scheme = (c.scheme ?? "http").lowercased()
        return "\(scheme)://\(host):\(c.port ?? (scheme == "https" ? 443 : 80))"
    }
    var isLocal: Bool { apiKey == nil }
    var kindLabel: String { isLocal ? L("models.external.local") : L("models.external.cloud") }
    var title: String { name.isEmpty ? (model.isEmpty ? host : model) : name }
    var host: String { URL(string: url)?.host ?? url }
}

/// The external models (a synced setting: every device of the account sees the same list).
enum ExternalModels {
    static let changed = Notification.Name("ExternalModelsChanged")
    private static let key = "ai.external"

    static func isExternal(_ id: String) -> Bool { id.hasPrefix("ext:") }

    static var all: [ExternalModel] {
        guard let s = Core.setting(key), let v = try? JSONDecoder().decode([ExternalModel].self, from: Data(s.utf8)) else { return [] }
        return v
    }
    static func find(_ id: String) -> ExternalModel? { all.first { $0.id == id } }

    static func save(_ m: ExternalModel) {
        var list = all
        if let i = list.firstIndex(where: { $0.id == m.id }) { list[i] = m } else { list.append(m) }
        store(list)
    }
    static func remove(_ id: String) {
        find(id)?.apiKey = nil
        store(all.filter { $0.id != id })
        ModelPrompts.forget(id)
    }
    private static func store(_ list: [ExternalModel]) {
        if list.isEmpty { Core.setSetting(key, nil) }
        else if let d = try? JSONEncoder().encode(list) { Core.setSetting(key, String(decoding: d, as: UTF8.self)) }
        NotificationCenter.default.post(name: changed, object: nil)
        NotificationCenter.default.post(name: ModelStore.changed, object: nil)
    }
}

/// Each model's prompt: shared by every device of the account, whenever a device gets that model.
/// A model that never had one starts from the default. Before models had their own, a prompt set
/// could be assigned to one, and that one still holds.
enum ModelPrompts {
    static let changed = AIEngine.Prompt.changed
    private static func key(_ model: String) -> String { "ai.modelPrompt." + model }

    private struct OldSet: Decodable { let id: String; let prompt: AIEngine.Prompt }
    private static func assigned(_ model: String) -> AIEngine.Prompt? {
        guard let a = Core.setting("ai.modelPrompts"), let map = try? JSONDecoder().decode([String: String].self, from: Data(a.utf8)), let id = map[model],
              let s = Core.setting("ai.prompts"), let sets = try? JSONDecoder().decode([OldSet].self, from: Data(s.utf8)) else { return nil }
        return sets.first { $0.id == id }?.prompt
    }

    static func prompt(forModel model: String) -> AIEngine.Prompt {
        if let s = Core.setting(key(model)), let p = try? JSONDecoder().decode(AIEngine.Prompt.self, from: Data(s.utf8)) { return p }
        return assigned(model) ?? AIEngine.Prompt.load()
    }

    /// Also when it is the default: this model then stays on it, whatever an old setting says.
    static func save(_ p: AIEngine.Prompt, forModel model: String) {
        if let d = try? JSONEncoder().encode(p) { Core.setSetting(key(model), String(decoding: d, as: UTF8.self)) }
        NotificationCenter.default.post(name: changed, object: nil)
    }

    static func forget(_ model: String) { Core.setSetting(key(model), nil) }
}

/// Services as the core reaches them (core/src/ai/external.rs): the app keeps their list and keys.
enum ExternalAI {
    /// "https://api.x.ai" / ".../v1" / ".../v1/chat/completions" all lead to the endpoint.
    static func endpoint(_ base: String, _ path: String) -> URL? {
        var s = base.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.contains("://") { s = "http://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        for tail in ["/chat/completions", "/models"] where s.hasSuffix(tail) { s.removeLast(tail.count) }
        if !s.hasSuffix("/v1") { s += "/v1" }
        return URL(string: s + "/" + path)
    }

    /// The server's models.
    static func models(_ m: ExternalModel) async throws -> [String] {
        let service: [String: Any] = ["id": m.id, "url": m.url, "model": m.model, "key": m.apiKey as Any]
        return try await Task.detached { try Core.aiServiceModels(service) }.value
    }

    /// Expensive to make and safe to share between threads.
    private static let imageContext = CIContext()

    static func jpeg(_ image: CIImage) -> Data? {
        guard let cg = imageContext.createCGImage(image, from: image.extent) else { return nil }
        let out = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dst, cg, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        return CGImageDestinationFinalize(dst) ? out as Data : nil
    }

    /// "测试": the tags for a plain grey picture, or why there are none.
    static func test(_ m: ExternalModel) async throws -> [String] {
        let request: [String: Any] = ["model": ["kind": "external", "id": m.id, "url": m.url, "model": m.model, "key": m.apiKey as Any], "image": ""]
        return try await Task.detached { try Core.aiTag(request) }.value
    }
}
