import AppKit

/// Works out what a piece of copied text is. Everything runs on the Mac; nothing is sent anywhere.
enum Detector {
    // MARK: - Kind

    static func kind(of text: String) -> ClipKind {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let singleToken = !trimmed.contains(where: \.isWhitespace)

        if singleToken, isJWT(trimmed) { return .jwt }
        if nil != secretLabel(trimmed) { return .secret }
        if singleToken, nil != webURL(trimmed) { return .url }
        if nil != color(trimmed) { return .color }
        if nil != timestamp(trimmed) { return .timestamp }
        if ("{" == trimmed.first || "[" == trimmed.first), nil != prettyJSON(trimmed) { return .json }
        if matches(trimmed, #"^[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}$"#, caseInsensitive: true) { return .email }
        if singleToken || !trimmed.contains("\n"), trimmed.hasPrefix("/") || trimmed.hasPrefix("~/"),
           FileManager.default.fileExists(atPath: NSString(string: trimmed).expandingTildeInPath) { return .path }
        if singleToken, nil != base64Text(trimmed) { return .base64 }
        if looksLikeCode(trimmed) { return .code }
        return .text
    }

    // MARK: - Secrets

    private static let secretPatterns: [(label: String, pattern: String)] = [
        ("Private key", #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#),
        ("AWS access key", #"\b(AKIA|ASIA)[0-9A-Z]{16}\b"#),
        ("GitHub token", #"\b(gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{60,})\b"#),
        ("GitLab token", #"\bglpat-[A-Za-z0-9_-]{20,}\b"#),
        ("Slack token", #"\bxox[abprs]-[A-Za-z0-9-]{10,}\b"#),
        ("Stripe key", #"\b[sr]k_(live|test)_[A-Za-z0-9]{20,}\b"#),
        ("Anthropic key", #"\bsk-ant-[A-Za-z0-9_-]{20,}\b"#),
        ("OpenAI key", #"\bsk-(proj-)?[A-Za-z0-9_-]{32,}\b"#),
        ("Google API key", #"\bAIza[0-9A-Za-z_-]{35}\b"#),
        ("npm token", #"\bnpm_[A-Za-z0-9]{36}\b"#),
        ("SendGrid key", #"\bSG\.[A-Za-z0-9_-]{22}\.[A-Za-z0-9_-]{43}\b"#),
        ("Twilio key", #"\bSK[0-9a-fA-F]{32}\b"#),
        ("Password in URL", #"[a-z][a-z0-9+.-]*://[^/\s:@]+:[^/\s:@]+@"#),
        ("Credentials", #"(?im)^\s*(export\s+)?[A-Z0-9_]*(SECRET|TOKEN|PASSWORD|PASSWD|API_?KEY|PRIVATE_KEY)[A-Z0-9_]*\s*[=:]\s*\S{6,}"#),
    ]

    /// Why the text looks like a secret, or nil when it doesn't.
    static func secretLabel(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count < 20_000 else { return nil }
        if let hit = secretPatterns.first(where: { matches(trimmed, $0.pattern) }) { return hit.label }
        if isJWT(trimmed) { return "Access token (JWT)" }
        if isCardNumber(trimmed) { return "Card number" }
        if looksLikeToken(trimmed) { return "Looks like a token" }
        return nil
    }

    /// A random-looking single word, such as an API key nobody has a pattern for.
    private static func looksLikeToken(_ text: String) -> Bool {
        guard (24...200).contains(text.count), !text.contains(where: \.isWhitespace),
              nil == webURL(text), !text.hasPrefix("/"), !text.contains("@")
        else { return false }
        let hasUpper = text.contains(where: \.isUppercase)
        let hasLower = text.contains(where: \.isLowercase)
        let hasDigit = text.contains(where: \.isNumber)
        return hasUpper && hasLower && hasDigit && 4.2 < entropy(text)
    }

    private static func entropy(_ text: String) -> Double {
        var counts: [Character: Int] = [:]
        text.forEach { counts[$0, default: 0] += 1 }
        let length = Double(text.count)
        return -counts.values.reduce(0) { sum, count in
            let p = Double(count) / length
            return sum + p * log2(p)
        }
    }

    private static func isCardNumber(_ text: String) -> Bool {
        guard matches(text, #"^\d(?:[ -]?\d){12,18}$"#) else { return false }
        let digits = text.compactMap(\.wholeNumberValue)
        // Luhn: double every second digit from the right.
        let sum = digits.reversed().enumerated().reduce(0) { sum, pair in
            let (index, digit) = pair
            guard 1 == index % 2 else { return sum + digit }
            let doubled = digit * 2
            return sum + (9 < doubled ? doubled - 9 : doubled)
        }
        return 0 == sum % 10 && [3, 4, 5, 6].contains(digits.first ?? 0)
    }

    /// Keeps the first and last four characters so you can still tell secrets apart.
    static func mask(_ text: String) -> String {
        guard 12 < text.count else { return String(repeating: "•", count: max(text.count, 8)) }
        return "\(text.prefix(4))\(String(repeating: "•", count: 10))\(text.suffix(4))"
    }

    // MARK: - Links

    static let trackingParameters: Set<String> = [
        "fbclid", "gclid", "dclid", "gbraid", "wbraid", "msclkid", "yclid", "twclid", "ttclid", "li_fat_id",
        "mc_cid", "mc_eid", "igshid", "_hsenc", "_hsmi", "mkt_tok", "oly_anon_id", "oly_enc_id", "vero_id",
        "_ga", "_gl", "ref_src", "spm",
    ]

    static func webURL(_ text: String) -> URL? {
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), nil != url.host
        else { return nil }
        return url
    }

    /// The link without tracking parameters, and how many were removed.
    static func cleanLink(_ text: String) -> (url: String, removed: Int)? {
        guard let url = webURL(text), var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = parts.queryItems
        else { return nil }
        let kept = items.filter { item in
            let name = item.name.lowercased()
            return !name.hasPrefix("utm_") && !trackingParameters.contains(name)
        }
        guard kept.count < items.count else { return nil }
        parts.queryItems = kept.isEmpty ? nil : kept
        guard let cleaned = parts.string else { return nil }
        return (cleaned, items.count - kept.count)
    }

    // MARK: - Decoders

    static func prettyJSON(_ text: String) -> String? {
        reencodeJSON(text, options: [.prettyPrinted, .sortedKeys])
    }

    static func minifiedJSON(_ text: String) -> String? {
        reencodeJSON(text, options: [])
    }

    /// Parses and re-encodes JSON. Writing must allow fragments as reading does: a bare number or
    /// string such as `123` parses fine, and writing it without `.fragmentsAllowed` raises an
    /// Objective-C exception that `try?` can't catch, which crashes the app.
    private static func reencodeJSON(_ text: String, options: JSONSerialization.WritingOptions) -> String? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let encoded = try? JSONSerialization.data(withJSONObject: object, options: options.union([.fragmentsAllowed, .withoutEscapingSlashes]))
        else { return nil }
        return String(decoding: encoded, as: UTF8.self)
    }

    static func isJWT(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        return 3 == parts.count && text.hasPrefix("eyJ") && nil != jwtPart(String(parts[1]))
    }

    /// The decoded header and claims of a JWT.
    static func jwt(_ text: String) -> (header: [String: Any], claims: [String: Any])? {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".", omittingEmptySubsequences: false)
        guard 3 == parts.count, let header = jwtPart(String(parts[0])), let claims = jwtPart(String(parts[1])) else { return nil }
        return (header, claims)
    }

    private static func jwtPart(_ part: String) -> [String: Any]? {
        guard let data = base64URLDecode(part) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    static func base64URLDecode(_ text: String) -> Data? {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }

    /// The text a Base64 string decodes to, when it decodes to readable text.
    static func base64Text(_ text: String) -> String? {
        guard 12 <= text.count, matches(text, #"^[A-Za-z0-9+/_-]+={0,2}$"#),
              text.contains(where: \.isNumber) || text.hasSuffix("=") || text.contains(where: \.isUppercase),
              let data = base64URLDecode(text.trimmingCharacters(in: CharacterSet(charactersIn: "="))),
              let decoded = String(data: data, encoding: .utf8), !decoded.isEmpty
        else { return nil }
        let printable = decoded.unicodeScalars.filter { $0.properties.isAlphabetic || $0.properties.isWhitespace || (0x20...0x7E).contains($0.value) }
        return Double(printable.count) / Double(decoded.unicodeScalars.count) > 0.95 ? decoded : nil
    }

    /// Unix time in seconds or milliseconds between 2001 and 2100, or an ISO 8601 date.
    static func timestamp(_ text: String) -> Date? {
        if matches(text, #"^\d{10}(\.\d+)?$"#), let seconds = Double(text), (978_307_200...4_102_444_800).contains(seconds) {
            return Date(timeIntervalSince1970: seconds)
        }
        if matches(text, #"^\d{13}$"#), let ms = Double(text), (978_307_200_000...4_102_444_800_000).contains(ms) {
            return Date(timeIntervalSince1970: ms / 1000)
        }
        if matches(text, #"^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}"#) {
            let iso = ISO8601DateFormatter()
            for options: ISO8601DateFormatter.Options in [[.withInternetDateTime, .withFractionalSeconds], [.withInternetDateTime]] {
                iso.formatOptions = options
                if let date = iso.date(from: text.replacingOccurrences(of: " ", with: "T")) { return date }
            }
        }
        return nil
    }

    struct RGBA: Equatable {
        var r, g, b: Double
        var a: Double = 1

        var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }
        var hex: String {
            let base = String(format: "#%02X%02X%02X", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
            return 1 > a ? base + String(format: "%02X", Int((a * 255).rounded())) : base
        }
        var rgb: String {
            let channels = "\(Int((r * 255).rounded())), \(Int((g * 255).rounded())), \(Int((b * 255).rounded()))"
            return 1 > a ? "rgba(\(channels), \(String(format: "%.2g", a)))" : "rgb(\(channels))"
        }
        var hsl: String {
            let high = max(r, g, b), low = min(r, g, b), l = (high + low) / 2
            var h = 0.0, s = 0.0
            if high != low {
                let d = high - low
                s = 0.5 < l ? d / (2 - high - low) : d / (high + low)
                switch high {
                case r: h = (g - b) / d + (g < b ? 6 : 0)
                case g: h = (b - r) / d + 2
                default: h = (r - g) / d + 4
                }
                h /= 6
            }
            return "hsl(\(Int((h * 360).rounded())), \(Int((s * 100).rounded()))%, \(Int((l * 100).rounded()))%)"
        }
        var swiftUI: String { String(format: "Color(red: %.3f, green: %.3f, blue: %.3f)", r, g, b) }
    }

    static func color(_ text: String) -> RGBA? {
        let value = text.trimmingCharacters(in: .whitespaces).lowercased()
        if matches(value, #"^#?([0-9a-f]{3}|[0-9a-f]{6}|[0-9a-f]{8})$"#), value.hasPrefix("#") || value.count == 6 {
            var hex = value.hasPrefix("#") ? String(value.dropFirst()) : value
            if 3 == hex.count { hex = hex.map { "\($0)\($0)" }.joined() }
            // Six plain digits are more likely a number than a colour.
            if !value.hasPrefix("#") && hex.allSatisfy(\.isNumber) { return nil }
            guard let number = UInt64(hex, radix: 16) else { return nil }
            if 8 == hex.count {
                return RGBA(r: Double(number >> 24 & 0xFF) / 255, g: Double(number >> 16 & 0xFF) / 255, b: Double(number >> 8 & 0xFF) / 255, a: Double(number & 0xFF) / 255)
            }
            return RGBA(r: Double(number >> 16 & 0xFF) / 255, g: Double(number >> 8 & 0xFF) / 255, b: Double(number & 0xFF) / 255)
        }
        if let regex = try? NSRegularExpression(pattern: #"^rgba?\(\s*(\d{1,3})\s*,\s*(\d{1,3})\s*,\s*(\d{1,3})\s*(?:,\s*([\d.]+)\s*)?\)$"#),
           let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) {
            let group = { (i: Int) in Range(match.range(at: i), in: value).flatMap { Double(value[$0]) } }
            guard let r = group(1), let g = group(2), let b = group(3), r <= 255, g <= 255, b <= 255 else { return nil }
            return RGBA(r: r / 255, g: g / 255, b: b / 255, a: group(4) ?? 1)
        }
        return nil
    }

    private static func looksLikeCode(_ text: String) -> Bool {
        guard text.contains("\n") else {
            return matches(text, #"^(\$ )?(git|npm|npx|pnpm|yarn|brew|docker|kubectl|wp|composer|curl|ssh|cd|ls|sudo|swift|python3?|pip|make) \S"#)
        }
        let signals = [";\n", "{\n", "}\n", "=> ", "func ", "def ", "const ", "let ", "import ", "return ", "</", "<?php", "#!/", "$("]
        return 2 <= signals.filter { text.contains($0) }.count
    }

    static func matches(_ text: String, _ pattern: String, caseInsensitive: Bool = false) -> Bool {
        nil != text.range(of: pattern, options: caseInsensitive ? [.regularExpression, .caseInsensitive] : .regularExpression)
    }
}
