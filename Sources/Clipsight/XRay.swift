import AppKit

struct Fact: Identifiable {
    let label: String
    let value: String
    var id: String { label }
}

/// What Clipsight can tell about a clip: facts to show and copy, and a decoded body.
struct XRay {
    var facts: [Fact] = []
    var bodyTitle: String?
    var body: String?
    var color: Detector.RGBA?

    init(_ clip: Clip, imageSize: CGSize? = nil) {
        let text = clip.text ?? ""
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if let label = clip.secretLabel {
            add("Detected", label)
            if let expires = clip.expires { add("Forgotten", relative(expires)) }
        }

        switch clip.kind {
        case .url:
            if let url = Detector.webURL(trimmed), let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                add("Host", parts.host ?? "")
                if !parts.path.isEmpty && "/" != parts.path { add("Path", parts.path) }
                for item in parts.queryItems ?? [] { add("?\(item.name)", item.value ?? "") }
                if let fragment = parts.fragment { add("#", fragment) }
            }
            if 0 < clip.cleanedTrackers { add("Trackers removed", "\(clip.cleanedTrackers)") }

        case .json:
            if let data = trimmed.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
                if let dict = object as? [String: Any] {
                    add("Type", "Object with \(dict.count) keys")
                    add("Keys", dict.keys.sorted().prefix(12).joined(separator: ", "))
                } else if let array = object as? [Any] {
                    add("Type", "Array of \(array.count)")
                }
            }
            bodyTitle = "Formatted"
            body = Detector.prettyJSON(trimmed)

        case .jwt:
            if let (header, claims) = Detector.jwt(trimmed) {
                add("Algorithm", "\(header["alg"] ?? "none")")
                for key in ["sub", "iss", "aud", "email", "name", "scope"] {
                    if let value = claims[key] { add(key, "\(value)") }
                }
                for (key, label) in [("exp", "Expires"), ("iat", "Issued"), ("nbf", "Valid from")] {
                    if let seconds = (claims[key] as? NSNumber)?.doubleValue {
                        let date = Date(timeIntervalSince1970: seconds)
                        add(label, "\(relative(date)) · \(date.formatted(date: .abbreviated, time: .shortened))")
                    }
                }
                if let seconds = (claims["exp"] as? NSNumber)?.doubleValue {
                    add("Status", Date(timeIntervalSince1970: seconds) < Date() ? "Expired" : "Valid")
                }
                bodyTitle = "Claims"
                body = (try? JSONSerialization.data(withJSONObject: claims, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]))
                    .map { String(decoding: $0, as: UTF8.self) }
            }

        case .color:
            if let rgba = Detector.color(trimmed) {
                color = rgba
                add("Hex", rgba.hex)
                add("RGB", rgba.rgb)
                add("HSL", rgba.hsl)
                add("SwiftUI", rgba.swiftUI)
            }

        case .timestamp:
            if let date = Detector.timestamp(trimmed) {
                add("Local", date.formatted(date: .complete, time: .standard))
                add("Relative", relative(date))
                let iso = ISO8601DateFormatter()
                add("ISO 8601 (UTC)", iso.string(from: date))
                add("Unix seconds", "\(Int(date.timeIntervalSince1970))")
                add("Unix milliseconds", "\(Int64(date.timeIntervalSince1970 * 1000))")
            }

        case .base64:
            bodyTitle = "Decoded"
            body = Detector.base64Text(trimmed)

        case .email:
            add("Domain", String(trimmed.split(separator: "@").last ?? ""))

        case .path:
            let path = NSString(string: trimmed).expandingTildeInPath
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            add("Exists", nil == attributes ? "No" : "Yes")
            if let type = attributes?[.type] as? FileAttributeType {
                add("Type", .typeDirectory == type ? "Folder" : "File")
            }
            if let size = attributes?[.size] as? Int64, .typeDirectory != attributes?[.type] as? FileAttributeType {
                add("Size", ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
            }

        case .image:
            if let size = imageSize { add("Size", "\(Int(size.width)) × \(Int(size.height))") }
            if let ocr = clip.ocrText, !ocr.isEmpty {
                bodyTitle = "Text in image"
                body = ocr
            }

        case .files:
            add("Items", "\(clip.files?.count ?? 0)")

        case .text, .code, .secret:
            break
        }

        if nil != clip.text, !clip.isSecret || .secret != clip.kind {
            let words = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
            add("Length", "\(text.count) characters · \(words) words · \(text.split(separator: "\n", omittingEmptySubsequences: false).count) lines")
        }
    }

    private mutating func add(_ label: String, _ value: String) {
        guard !value.isEmpty, !facts.contains(where: { $0.label == label }) else { return }
        facts.append(Fact(label: label, value: value))
    }

    private func relative(_ date: Date) -> String {
        RelativeDateTimeFormatter().localizedString(for: date, relativeTo: Date())
    }
}

/// One-click rewrites of copied text. The result is copied as a new clip.
enum Transform: String, CaseIterable, Identifiable {
    case trim = "Trim whitespace"
    case upper = "UPPERCASE"
    case lower = "lowercase"
    case title = "Title Case"
    case camel = "camelCase"
    case snake = "snake_case"
    case kebab = "kebab-case"
    case sortLines = "Sort lines"
    case uniqueLines = "Remove duplicate lines"
    case jsonPretty = "Format JSON"
    case jsonMinify = "Minify JSON"
    case urlEncode = "URL-encode"
    case urlDecode = "URL-decode"
    case base64Encode = "Base64-encode"
    case base64Decode = "Base64-decode"
    case cleanLink = "Remove link trackers"

    var id: String { rawValue }

    func apply(_ text: String) -> String? {
        switch self {
        case .trim: return text.trimmingCharacters(in: .whitespacesAndNewlines)
        case .upper: return text.uppercased()
        case .lower: return text.lowercased()
        case .title: return text.capitalized
        case .camel:
            let words = Transform.words(text)
            return words.enumerated().map { 0 == $0 ? $1.lowercased() : $1.capitalized }.joined()
        case .snake: return Transform.words(text).map { $0.lowercased() }.joined(separator: "_")
        case .kebab: return Transform.words(text).map { $0.lowercased() }.joined(separator: "-")
        case .sortLines: return text.split(separator: "\n", omittingEmptySubsequences: false).sorted().joined(separator: "\n")
        case .uniqueLines:
            var seen = Set<Substring>()
            return text.split(separator: "\n", omittingEmptySubsequences: false).filter { seen.insert($0).inserted }.joined(separator: "\n")
        case .jsonPretty: return Detector.prettyJSON(text)
        case .jsonMinify: return Detector.minifiedJSON(text)
        case .urlEncode: return text.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~")))
        case .urlDecode: return text.removingPercentEncoding
        case .base64Encode: return Data(text.utf8).base64EncodedString()
        case .base64Decode: return Detector.base64URLDecode(text.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { String(data: $0, encoding: .utf8) }
        case .cleanLink: return Detector.cleanLink(text.trimmingCharacters(in: .whitespacesAndNewlines))?.url
        }
    }

    /// Splits "someText here_and-there" into its words, including camelCase humps.
    private static func words(_ text: String) -> [String] {
        let spaced = text.replacingOccurrences(of: "([a-z0-9])([A-Z])", with: "$1 $2", options: .regularExpression)
        return spaced.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }
}
