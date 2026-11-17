import CryptoKit
import Foundation

/// The source files that affect tagger loading and the temporary overrides for them.
struct TaggerModelFiles: Equatable {
    private let config: Data
    private let template: Data?
    private let overrides: [String: Data]

    private static let gemmaRepository = "zecanard--gemma-4-E4B-it-uncensored-abliterix-MLX-6bit-int6-affine"
    private static let gemmaTemplateHash = "5c2de10bf7461900866fc49fe301ae74a694d5a379f1ed074c0275167b15bdfb"

    init(directory: URL) throws {
        let configFile = "config.json"
        let templateFile = "chat_template.jinja"
        config = try Data(contentsOf: directory.appendingPathComponent(configFile))
        template = try? Data(contentsOf: directory.appendingPathComponent(templateFile))
        var overrides: [String: Data] = [:]
        if var model = try? JSONSerialization.jsonObject(with: config) as? [String: Any] {
            // Older Qwen3-VL configs keep the output embedding setting at the top level.
            if let tie = model["tie_word_embeddings"] as? Bool,
               var text = model["text_config"] as? [String: Any], text["tie_word_embeddings"] == nil {
                text["tie_word_embeddings"] = tie
                model["text_config"] = text
                overrides[configFile] = try JSONSerialization.data(withJSONObject: model, options: [.sortedKeys])
            }
            if directory.lastPathComponent == Self.gemmaRepository,
               model["model_type"] as? String == "gemma4",
               let template,
               SHA256.hash(data: template).map({ String(format: "%02x", $0) }).joined() == Self.gemmaTemplateHash,
               let text = String(data: template, encoding: .utf8) {
                // Gemma E4B starts the answer directly when thinking is disabled.
                let emptyThought = """
                        {%- if not enable_thinking | default(false) -%}
                            {{- '<|channel>thought\\n<channel|>' -}}
                        {%- endif -%}

                """
                let fixed = text.replacingOccurrences(of: "{%- set enable_thinking = true %}", with: "{%- set enable_thinking = false %}")
                    .replacingOccurrences(of: emptyThought, with: "")
                overrides[templateFile] = Data(fixed.utf8)
            }
        }
        self.overrides = overrides
    }

    func makeShadow(for directory: URL) throws -> URL? {
        guard !overrides.isEmpty else { return nil }
        let fm = FileManager.default
        let shadow = fm.temporaryDirectory.appendingPathComponent("tl-model-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: shadow, withIntermediateDirectories: true)
        do {
            for name in try fm.contentsOfDirectory(atPath: directory.path) where overrides[name] == nil {
                try fm.createSymbolicLink(at: shadow.appendingPathComponent(name), withDestinationURL: directory.appendingPathComponent(name))
            }
            for (name, data) in overrides {
                try data.write(to: shadow.appendingPathComponent(name), options: [.atomic])
            }
            return shadow
        } catch {
            try? fm.removeItem(at: shadow)
            throw error
        }
    }
}
