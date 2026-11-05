import Foundation

/// Every piece of text the app shows comes from the string catalog (`Localizable.xcstrings`) by a
/// stable key: source files hold keys, never the text. Languages: English (also the fallback for
/// any other language), Simplified Chinese, Traditional Chinese, Japanese. `scripts/catalog.py
/// check` fails on user-visible text written into Swift code, on a key used in code but missing
/// from the catalog, and on a key without all four languages.
///
/// Arguments fill the key's format: `%@` takes text, `%lld` a whole number, `%.1f` a decimal;
/// translations may reorder them (`%2$@`). Counts use the catalog's plural variations.
func L(_ key: String, _ args: Any...) -> String { L10n.format(key, args) }

enum L10n {
    /// This build's name, as the system shows it (a share extension's own name is another: it
    /// carries the app's as TLAppName).
    static let appName: String = {
        let info = Bundle.main.infoDictionary ?? [:]
        return info["TLAppName"] as? String ?? info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String ?? ""
    }()

    /// The app's languages, as their .lproj folders are named.
    static let languages = ["en", "zh-Hans", "zh-Hant", "ja"]

    /// The language the app runs in: the first of the user's preferred languages that it has.
    static var current: String { Bundle.main.preferredLocalizations.first ?? "en" }

    /// The language tag handed to the core, so its messages (errors, reports) match the app.
    static var coreLanguage: String { languages.contains(current) ? current : "en" }

    static func format(_ key: String, _ args: [Any]) -> String {
        let format = NSLocalizedString(key, tableName: nil, bundle: .main, value: "\u{1}", comment: "")
        #if DEBUG
        if format == "\u{1}" { NSLog("L10n: missing key %@", key) }
        #endif
        let fmt = (format == "\u{1}" ? key : format).replacingOccurrences(of: "{app}", with: appName)
        guard !args.isEmpty else { return fmt }
        // each argument as its specifier wants it (a mismatch never crashes the formatter)
        let kinds = specifiers(fmt)
        let values: [CVarArg] = args.enumerated().map { i, a in coerce(a, to: kinds.flatMap { $0.indices.contains(i) ? $0[i] : nil } ?? natural(a)) }
        return String(format: fmt, locale: Locale.current, arguments: values)
    }

    /// The text of `key` in every language of the app (words that may be typed in any of them,
    /// such as the search's conditions), the current language first.
    static func everyLanguage(_ key: String) -> [String] {
        var out: [String] = [L(key)]
        for b in bundles.values {
            let v = b.localizedString(forKey: key, value: "\u{1}", table: nil)
            if v != "\u{1}", !out.contains(v) { out.append(v) }
        }
        return out
    }

    private static let bundles: [String: Bundle] = {
        var d: [String: Bundle] = [:]
        for l in languages { if let p = Bundle.main.path(forResource: l, ofType: "lproj"), let b = Bundle(path: p) { d[l] = b } }
        return d
    }()

    private enum Kind { case object, integer, double }

    /// The argument kinds of a format in argument order (positional specifiers placed by their
    /// number); nil when the format has a kind this does not read (a plural's `%#@…@`).
    private static func specifiers(_ f: String) -> [Kind]? {
        var byPosition: [Int: Kind] = [:]
        var next = 1
        let s = Array(f.unicodeScalars)
        var i = 0
        while i < s.count {
            guard s[i] == "%" else { i += 1; continue }
            i += 1
            guard i < s.count else { break }
            if s[i] == "%" { i += 1; continue }
            // an explicit position: digits followed by $
            var j = i, digits = 0
            while j < s.count, CharacterSet.decimalDigits.contains(s[j]) { digits = digits * 10 + Int(s[j].value - 48); j += 1 }
            var pos = next
            if j < s.count, s[j] == "$", j > i { pos = digits; i = j + 1 } else { next += 1 }
            // flags, width, precision and length modifiers, then the conversion
            while i < s.count, "#0- +'.123456789lhqLzjt".unicodeScalars.contains(s[i]) {
                if s[i] == "#" , i + 1 < s.count, s[i + 1] == "@" { return nil }
                i += 1
            }
            guard i < s.count else { break }
            switch s[i] {
            case "@": byPosition[pos] = .object
            case "d", "i", "u", "x", "X", "o", "c": byPosition[pos] = .integer
            case "f", "F", "e", "E", "g", "G", "a", "A": byPosition[pos] = .double
            default: return nil
            }
            i += 1
        }
        guard let top = byPosition.keys.max() else { return [] }
        return (1...top).map { byPosition[$0] ?? .object }
    }

    private static func natural(_ a: Any) -> Kind {
        switch a {
        case is Int, is Int8, is Int16, is Int32, is Int64, is UInt, is UInt8, is UInt16, is UInt32, is UInt64: return .integer
        case is Double, is Float, is CGFloat: return .double
        default: return .object
        }
    }

    private static func coerce(_ a: Any, to k: Kind) -> CVarArg {
        switch k {
        case .integer:
            switch a {
            case let v as Int: return Int64(v)
            case let v as Int64: return v
            case let v as Int32: return Int64(v)
            case let v as UInt64: return Int64(clamping: v)
            case let v as UInt: return Int64(clamping: v)
            case let v as UInt32: return Int64(v)
            case let v as Double: return Int64(v)
            case let v as CGFloat: return Int64(v)
            default: return Int64(String(describing: a)) ?? 0
            }
        case .double:
            switch a {
            case let v as Double: return v
            case let v as Float: return Double(v)
            case let v as CGFloat: return Double(v)
            case let v as Int: return Double(v)
            case let v as Int64: return Double(v)
            default: return Double(String(describing: a)) ?? 0
            }
        case .object:
            if let s = a as? String { return s as NSString }
            return String(describing: a) as NSString
        }
    }
}
