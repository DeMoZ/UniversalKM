import Foundation

// Ported from EnhanceCapCut (same author, MIT): the donate window's content comes from the
// DeMoZ/donations repository, so links and texts change without a release (design D18).

/// A text in several languages: language tag ("en", "ru", "pt-BR") → string.
public struct LocalizedText: Decodable, Equatable, Sendable {
    public let values: [String: String]

    public init(_ values: [String: String]) { self.values = values }

    public init(from decoder: Decoder) throws {
        // A plain string counts as English.
        if let s = try? decoder.singleValueContainer().decode(String.self) {
            values = s.isEmpty ? [:] : ["en": s]
            return
        }
        let c = try decoder.anyKeyed()
        var values: [String: String] = [:]
        for key in c.allKeys {
            if let s = c.str(key.stringValue), !s.isEmpty { values[key.stringValue] = s }
        }
        self.values = values
    }

    /// The text for the first of `languages` (most preferred first) that has one: the exact tag, then its base
    /// language ("pt-BR" → "pt"); then English. Tags compare case-insensitively, "_" counts as "-".
    public func resolved(for languages: [String]) -> String? {
        let byTag = Dictionary(values.map { (Self.normalize($0.key), $0.value) }, uniquingKeysWith: { first, _ in first })
        for language in languages {
            let tag = Self.normalize(language)
            if let text = byTag[tag] { return text }
            if let base = tag.split(separator: "-").first, let text = byTag[String(base)] { return text }
        }
        return byTag["en"]
    }

    private static func normalize(_ tag: String) -> String {
        tag.replacingOccurrences(of: "_", with: "-").lowercased()
    }
}

/// One way to donate: a payment page opened in the browser.
public struct DonationMethod: Decodable, Equatable, Sendable {
    public let id: String
    public let title: LocalizedText
    public let description: LocalizedText?
    public let url: URL

    public init(from decoder: Decoder) throws {
        let c = try decoder.anyKeyed()
        // Only https pages: the file comes from the network.
        guard let title: LocalizedText = c.opt("title"), !title.values.isEmpty,
              let link = c.str("url"), let url = URL(string: link),
              url.scheme?.lowercased() == "https", url.host?.isEmpty == false
        else { throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "No title or https url")) }
        id = c.str("id") ?? link
        self.title = title
        description = c.opt("description")
        self.url = url
    }
}

/// The donate window's content (format: README of DeMoZ/donations, `schema` 1).
/// Unknown fields are skipped, a malformed method is dropped.
public struct DonationInfo: Decodable, Equatable, Sendable {
    public let schema: Int
    public let message: LocalizedText?
    public let methods: [DonationMethod]

    public init(from decoder: Decoder) throws {
        let c = try decoder.anyKeyed()
        schema = c.num("schema").map { Int($0) } ?? 1
        message = c.opt("message")
        methods = c.list("methods")
    }

    /// Parses a donations file; nil when it isn't JSON or offers no way to donate.
    public static func parse(_ data: Data) -> DonationInfo? {
        guard let info = try? JSONDecoder().decode(DonationInfo.self, from: data), !info.methods.isEmpty else { return nil }
        return info
    }
}

/// Downloads the donations file, keeping the last good copy for when the network fails.
public enum Donations {
    /// This app's file in the repository.
    public static let fileName = "universalkm.json"

    /// GitHub first, then the jsDelivr mirror of the same repository (GitHub's raw files are sometimes unreachable).
    public static func sources(for file: String = fileName) -> [URL] {
        [
            URL(string: "https://raw.githubusercontent.com/DeMoZ/donations/main/\(file)")!,
            URL(string: "https://cdn.jsdelivr.net/gh/DeMoZ/donations@main/\(file)")!,
        ]
    }

    /// `~/Library/Caches/UniversalKM/donations.json`.
    public static var cacheURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("UniversalKM", isDirectory: true).appendingPathComponent("donations.json")
    }

    /// The last copy downloaded, if any.
    public static func cached(at cache: URL = cacheURL) -> DonationInfo? {
        (try? Data(contentsOf: cache)).flatMap(DonationInfo.parse)
    }

    /// Downloads the file from the first source that answers with a valid one and caches it; nil when none does.
    /// An invalid answer never overwrites the cache.
    public static func download(from sources: [URL] = sources(), cache: URL = cacheURL) async -> DonationInfo? {
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        for source in sources {
            var request = URLRequest(url: source, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
            request.setValue("UniversalKM", forHTTPHeaderField: "User-Agent")
            guard let (data, response) = try? await session.data(for: request) else { continue }
            // file:// sources (tests) have no HTTP status.
            if let http = response as? HTTPURLResponse, http.statusCode != 200 { continue }
            guard let info = DonationInfo.parse(data) else { continue }
            try? FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: cache, options: .atomic)
            return info
        }
        return nil
    }
}
