import Foundation
import Testing
@testable import UniversalKMCore

@Suite struct DonationsTests {
    private let file = """
    {
      "schema": 1,
      "future": {"anything": true},
      "message": {"en": "Support it", "ru": "Поддержите", "pt-BR": "Apoie"},
      "methods": [
        {"id": "cloudtips", "title": {"en": "Card", "ru": "Карта"}, "url": "https://pay.cloudtips.ru/p/1"},
        {"id": "plain", "title": "Plain title", "description": {"ru": "Только по-русски"}, "url": "https://example.com/d"},
        {"id": "http", "title": {"en": "Insecure"}, "url": "http://example.com"},
        {"id": "script", "title": {"en": "Script"}, "url": "javascript:alert(1)"},
        {"id": "untitled", "url": "https://example.com"},
        42
      ]
    }
    """

    private func temporaryFile(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ukm-\(name)-\(UUID().uuidString).json")
    }

    @Test func readsMethodsLenientlyAndOnlyHttps() throws {
        let info = try #require(DonationInfo.parse(Data(file.utf8)))
        #expect(info.schema == 1)
        #expect(info.methods.map(\.id) == ["cloudtips", "plain"])
        #expect(info.methods[0].url.absoluteString == "https://pay.cloudtips.ru/p/1")
        #expect(info.methods[1].title.resolved(for: ["ru"]) == "Plain title")
        // A description without English shows only for its language.
        #expect(info.methods[1].description?.resolved(for: ["ru-RU"]) == "Только по-русски")
        #expect(info.methods[1].description?.resolved(for: ["de"]) == nil)
    }

    @Test func picksTheLanguage() throws {
        let message = try #require(DonationInfo.parse(Data(file.utf8))?.message)
        #expect(message.resolved(for: ["pt-BR"]) == "Apoie")
        #expect(message.resolved(for: ["pt_br"]) == "Apoie")
        #expect(message.resolved(for: ["ru-RU", "en-US"]) == "Поддержите")
        // The next preferred language before English.
        #expect(message.resolved(for: ["de-DE", "ru"]) == "Поддержите")
        #expect(message.resolved(for: ["de-DE"]) == "Support it")
        #expect(message.resolved(for: []) == "Support it")
    }

    @Test func rejectsFilesWithoutMethods() {
        #expect(DonationInfo.parse(Data("not json".utf8)) == nil)
        #expect(DonationInfo.parse(Data(#"{"schema": 2, "methods": []}"#.utf8)) == nil)
        #expect(DonationInfo.parse(Data(#"{"methods": "none"}"#.utf8)) == nil)
    }

    @Test func readsTheCachedCopy() throws {
        let cache = temporaryFile("cache")
        defer { try? FileManager.default.removeItem(at: cache) }
        #expect(Donations.cached(at: cache) == nil)
        try Data(file.utf8).write(to: cache)
        #expect(Donations.cached(at: cache)?.methods.count == 2)
    }

    @Test func downloadCachesAValidFileAndSkipsInvalidSources() async throws {
        let bad = temporaryFile("bad")
        let good = temporaryFile("good")
        let cache = temporaryFile("cache")
        defer { [bad, good, cache].forEach { try? FileManager.default.removeItem(at: $0) } }
        try Data("not json".utf8).write(to: bad)
        try Data(file.utf8).write(to: good)

        let info = await Donations.download(from: [bad, good], cache: cache)
        #expect(info?.methods.count == 2)
        #expect(Donations.cached(at: cache)?.methods.count == 2)
    }

    @Test func invalidDownloadKeepsTheCache() async throws {
        let bad = temporaryFile("bad")
        let cache = temporaryFile("cache")
        defer { [bad, cache].forEach { try? FileManager.default.removeItem(at: $0) } }
        try Data(#"{"schema": 1, "methods": []}"#.utf8).write(to: bad)
        try Data(file.utf8).write(to: cache)

        #expect(await Donations.download(from: [bad], cache: cache) == nil)
        #expect(Donations.cached(at: cache)?.methods.count == 2)
    }
}

/// The real `universalkm.json` from DeMoZ/donations (a copy, kept in sync by hand).
@Test func publishedFileParses() throws {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/universalkm.json")
    let info = try #require(DonationInfo.parse(try Data(contentsOf: url)))
    #expect(info.methods.map(\.id) == ["tribute", "cloudtips"])
    #expect(info.message?.resolved(for: ["ru"])?.hasPrefix("UniversalKM") == true)
    #expect(info.message?.resolved(for: ["de"])?.hasPrefix("UniversalKM") == true)
}
