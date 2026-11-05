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

extension AIEngine.Prompt {
    /// The question sent with each image: the prompt, then this media's tags, the library's
    /// tags and the post text (each only when there is something to say).
    func question(existing: [String], vocabulary: [String], postText: String?) -> String {
        var q = prompt
        if !existing.isEmpty { q += "\n\n" + self.existing.replacingOccurrences(of: "{existing}", with: existing.joined(separator: L("list.separator"))) }
        if !vocabulary.isEmpty { q += "\n\n" + self.vocabulary.replacingOccurrences(of: "{tags}", with: vocabulary.joined(separator: L("list.separator"))) }
        if let ctx = AIEngine.cleanContext(postText) { q += "\n\n" + context.replacingOccurrences(of: "{text}", with: ctx) }
        return q
    }
}

/// The OpenAI-compatible client.
enum ExternalAI {
    enum Failure: LocalizedError {
        case badURL, http(Int, String), noModel, empty
        var errorDescription: String? {
            switch self {
            case .badURL: L("models.external.err.url")
            case .http(let c, let m): m.isEmpty ? L("models.external.err.status", c) : L("format.labelValue", L("models.external.err.status", c), m)
            case .noModel: L("models.external.err.noModel")
            case .empty: L("models.external.err.empty")
            }
        }
    }

    /// "https://api.x.ai" / ".../v1" / ".../v1/chat/completions" all lead to the endpoint.
    static func endpoint(_ base: String, _ path: String) -> URL? {
        var s = base.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.contains("://") { s = "http://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        for tail in ["/chat/completions", "/models"] where s.hasSuffix(tail) { s.removeLast(tail.count) }
        if !s.hasSuffix("/v1") { s += "/v1" }
        return URL(string: s + "/" + path)
    }

    static var session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 120
        return URLSession(configuration: c)
    }()

    private static func request(_ url: URL, key: String?, body: Data? = nil) -> URLRequest {
        var r = URLRequest(url: url)
        r.httpMethod = body == nil ? "GET" : "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key { r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        r.httpBody = body
        return r
    }

    private static func send(_ r: URLRequest) async throws -> Data {
        let (data, resp) = try await session.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]).flatMap { ($0["error"] as? [String: Any])?["message"] as? String ?? $0["error"] as? String }
                ?? String(decoding: data.prefix(200), as: UTF8.self)
            throw Failure.http(code, msg)
        }
        return data
    }

    /// The server's models (GET /v1/models).
    static func models(_ m: ExternalModel) async throws -> [String] {
        guard let url = endpoint(m.url, "models") else { throw Failure.badURL }
        let data = try await send(request(url, key: m.apiKey))
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (obj?["data"] as? [[String: Any]])?.compactMap { $0["id"] as? String } ?? []
    }

    /// The model name to send: the one configured, or (a local server) its first model.
    static func modelName(_ m: ExternalModel) async throws -> String {
        if !m.model.trimmingCharacters(in: .whitespaces).isEmpty { return m.model.trimmingCharacters(in: .whitespaces) }
        guard let first = try await models(m).first else { throw Failure.noModel }
        return first
    }

    /// The request body: a system message and a user message with the text and the image.
    static func body(model: String, system: String, question: String, jpeg: Data) -> Data {
        let json: [String: Any] = [
            "model": model,
            "temperature": 0.1,
            "max_tokens": 300,
            "stream": false,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": [
                    ["type": "text", "text": question],
                    ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64," + jpeg.base64EncodedString()]],
                ]],
            ],
        ]
        return (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
    }

    /// The answer text of a Chat Completions response.
    static func answer(_ data: Data) throws -> String {
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let msg = (obj?["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any]
        if let s = msg?["content"] as? String, !s.isEmpty { return s }
        // some servers return content as parts
        if let parts = msg?["content"] as? [[String: Any]] {
            let s = parts.compactMap { $0["text"] as? String }.joined()
            if !s.isEmpty { return s }
        }
        throw Failure.empty
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

    static func tags(for image: CIImage, model m: ExternalModel, postText: String?, existing: [String], vocabulary: [String]) async throws -> [String] {
        guard let url = endpoint(m.url, "chat/completions") else { throw Failure.badURL }
        guard let jpg = jpeg(image) else { throw Failure.empty }
        let p = ModelPrompts.prompt(forModel: m.id)
        let name = try await modelName(m)
        let data = try await send(request(url, key: m.apiKey, body: body(model: name, system: p.system, question: p.question(existing: existing, vocabulary: vocabulary, postText: postText), jpeg: jpg)))
        return AIEngine.parseTags(try answer(data))
    }

    /// "测试": one small request with a plain gray image; returns the tags or throws.
    static func test(_ m: ExternalModel) async throws -> [String] {
        let img = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))
        return try await tags(for: img, model: m, postText: nil, existing: [], vocabulary: [])
    }
}
