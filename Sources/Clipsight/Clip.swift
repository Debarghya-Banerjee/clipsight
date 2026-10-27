import Foundation

/// What a clip holds, worked out once when it's copied.
enum ClipKind: String, Codable, CaseIterable, Sendable {
    case text, url, json, jwt, color, timestamp, base64, email, path, code, secret, image, files

    var title: String {
        switch self {
        case .text: "Text"
        case .url: "Link"
        case .json: "JSON"
        case .jwt: "JWT"
        case .color: "Colour"
        case .timestamp: "Timestamp"
        case .base64: "Base64"
        case .email: "Email"
        case .path: "Path"
        case .code: "Code"
        case .secret: "Secret"
        case .image: "Image"
        case .files: "Files"
        }
    }

    var symbol: String {
        switch self {
        case .text: "text.alignleft"
        case .url: "link"
        case .json: "curlybraces"
        case .jwt: "person.badge.key.fill"
        case .color: "paintpalette.fill"
        case .timestamp: "clock.fill"
        case .base64: "number"
        case .email: "envelope.fill"
        case .path: "folder.fill"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .secret: "lock.fill"
        case .image: "photo.fill"
        case .files: "doc.on.doc.fill"
        }
    }
}

struct Clip: Identifiable, Codable, Sendable, Equatable {
    var id = UUID()
    var kind: ClipKind
    var text: String?
    /// File name of the image inside the images folder.
    var imageFile: String?
    var files: [String]?
    var date = Date()
    var sourceBundleID: String?
    var sourceName: String?
    var pinned = false
    /// Text recognised in an image, so screenshots can be searched.
    var ocrText: String?
    /// Tracking parameters Clean Links removed when this was copied.
    var cleanedTrackers = 0
    /// Why Secret Shield caught this, such as "GitHub token". Secrets live in memory only.
    var secretLabel: String?
    /// When a secret is forgotten.
    var expires: Date?

    var isSecret: Bool { nil != secretLabel }

    /// One line for the list.
    var preview: String {
        switch kind {
        case .image: return ocrText.flatMap { $0.isEmpty ? nil : "Image · \($0)" } ?? "Image"
        case .files: return (files ?? []).map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
        default:
            let line = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            return isSecret ? Detector.mask(line) : String(line.prefix(300))
        }
    }

    /// Everything search looks at.
    var searchText: String {
        [text, ocrText, sourceName, files?.joined(separator: " ")].compactMap { $0 }.joined(separator: " ")
    }
}
