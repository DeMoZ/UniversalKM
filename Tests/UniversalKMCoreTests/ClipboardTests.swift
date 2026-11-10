import Foundation
import Testing
@testable import UniversalKMCore

// MARK: Protocol (design D2)

private let tricky = "Привет 👋\nстрока 2 \"q\" \\ \t конец"

@Test func setIsOneLineAndCarriesTheTextIntact() throws {
    let line = try #require(ClipboardProtocol.set(tricky, id: 7))
    #expect(line.hasSuffix("\n"))
    #expect(!line.dropLast().contains("\n"))
    let object = try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    #expect(object["t"] as? String == "set")
    #expect(object["id"] as? Int == 7)
    let encoded = try #require(object["b64"] as? String)
    let data = try #require(Data(base64Encoded: encoded))
    #expect(String(data: data, encoding: .utf8) == tricky)
}

@Test func changedRoundTrips() {
    let b64 = Data(tricky.utf8).base64EncodedString()
    #expect(ClipboardProtocol.parse(#"{"t":"changed","b64":"\#(b64)"}"#) == .changed(tricky))
}

@Test func helperMessagesParse() {
    #expect(ClipboardProtocol.parse(#"{"t":"hello","v":1,"sdk":31,"watch":"listener"}"#)
            == .hello(version: 1, sdk: 31, listening: true))
    #expect(ClipboardProtocol.parse(#"{"t":"hello","v":1,"sdk":29,"watch":"poll"}"#)
            == .hello(version: 1, sdk: 29, listening: false))
    #expect(ClipboardProtocol.parse(#"{"t":"ack","id":12}"#) == .ack(12))
    #expect(ClipboardProtocol.parse(#"{"t":"pong"}"#) == .pong)
    #expect(ClipboardProtocol.parse(#"{"t":"error","msg":"text too long"}"#) == .error("text too long"))
    #expect(ClipboardProtocol.ping == "{\"t\":\"ping\"}\n")
}

@Test func garbageIsIgnored() {
    #expect(ClipboardProtocol.parse("") == nil)
    #expect(ClipboardProtocol.parse("Exception in thread main") == nil)
    #expect(ClipboardProtocol.parse(#"{"t":"changed","b64":"%%%"}"#) == nil)
    #expect(ClipboardProtocol.parse(#"{"t":"unknown"}"#) == nil)
    #expect(ClipboardProtocol.parse(#"[1,2]"#) == nil)
}

@Test func textOverTheLimitIsNotSent() {
    let limit = String(repeating: "a", count: ClipboardProtocol.maxTextBytes)
    #expect(ClipboardProtocol.set(limit, id: 1) != nil)
    #expect(ClipboardProtocol.set(limit + "a", id: 1) == nil)
    // The limit is in UTF-8 bytes: "я" is two.
    #expect(ClipboardProtocol.set(String(repeating: "я", count: ClipboardProtocol.maxTextBytes / 2 + 1), id: 1) == nil)
    let big = Data((limit + "a").utf8).base64EncodedString()
    #expect(ClipboardProtocol.parse(#"{"t":"changed","b64":"\#(big)"}"#) == nil)
}

@Test func protocolVersionMatchesTheAndroidHelper() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let java = try String(contentsOf: root.appendingPathComponent(
        "android/clipboard-helper/src/com/universalkm/clipboard/Main.java"), encoding: .utf8)
    #expect(java.contains("static final int PROTOCOL_VERSION = \(ClipboardProtocol.version);"))
    #expect(java.contains("static final int MAX_TEXT_BYTES = 1 << 20;"))
    #expect(ClipboardProtocol.maxTextBytes == 1 << 20)
}

// MARK: Relay (design D5)

private let phoneA: UInt16 = 0x8000
private let phoneB: UInt16 = 0x8001

@Test func macTextGoesToConnectedPhonesOnce() {
    var relay = ClipboardRelay()
    let sends = relay.macChanged(changeCount: 1, types: ["public.utf8-plain-text"], text: "hi", connected: [phoneA, phoneB])
    #expect(sends.map(\.peer) == [phoneA, phoneB])
    #expect(sends.allSatisfy { $0.text == "hi" })
    // Copying the same text again changes nothing on the phones.
    #expect(relay.macChanged(changeCount: 2, types: ["public.utf8-plain-text"], text: "hi", connected: [phoneA, phoneB]).isEmpty)
}

@Test func privateAndNonTextContentStaysOnTheMac() {
    var relay = ClipboardRelay()
    for type in ClipboardRelay.privateTypes {
        #expect(relay.macChanged(changeCount: 1, types: ["public.utf8-plain-text", type], text: "secret", connected: [phoneA]).isEmpty)
    }
    #expect(relay.macChanged(changeCount: 2, types: ["public.png"], text: nil, connected: [phoneA]).isEmpty)
    #expect(relay.macChanged(changeCount: 3, types: ["public.utf8-plain-text"], text: "", connected: [phoneA]).isEmpty)
    let tooLong = String(repeating: "a", count: ClipboardProtocol.maxTextBytes + 1)
    #expect(relay.macChanged(changeCount: 4, types: ["public.utf8-plain-text"], text: tooLong, connected: [phoneA]).isEmpty)
}

@Test func phoneTextReachesTheMacButNotOtherPhones() {
    var relay = ClipboardRelay()
    #expect(relay.phoneChanged(phoneA, text: "from A", allPeers: [phoneA, phoneB]) == "from A")
    relay.wroteToMac(changeCount: 10)
    // The app's own write shows up as a pasteboard change; it is not relayed.
    #expect(relay.macChanged(changeCount: 10, types: ["public.utf8-plain-text"], text: "from A", connected: [phoneA, phoneB]).isEmpty)
    // Phone B reconnecting does not get A's text either.
    #expect(relay.connected(phoneB, macText: "from A") == nil)
}

@Test func echoFromThePhoneIsIgnored() {
    var relay = ClipboardRelay()
    _ = relay.macChanged(changeCount: 1, types: ["public.utf8-plain-text"], text: "to phone", connected: [phoneA])
    #expect(relay.phoneChanged(phoneA, text: "to phone", allPeers: [phoneA]) == nil)
    // A real new copy on the phone gets through.
    #expect(relay.phoneChanged(phoneA, text: "new on phone", allPeers: [phoneA]) == "new on phone")
}

@Test func phoneConnectingLaterGetsTheCurrentMacText() {
    var relay = ClipboardRelay()
    #expect(relay.macChanged(changeCount: 1, types: ["public.utf8-plain-text"], text: "copied offline", connected: []).isEmpty)
    #expect(relay.connected(phoneA, macText: "copied offline") == "copied offline")
    // Losing the link and coming back without a new Mac copy does not overwrite the phone.
    #expect(relay.connected(phoneA, macText: "copied offline") == nil)
    // After being switched off and on, the phone gets the current text again.
    relay.forget(phoneA)
    #expect(relay.connected(phoneA, macText: "copied offline") == "copied offline")
    #expect(relay.connected(phoneA, macText: nil) == nil)
}
