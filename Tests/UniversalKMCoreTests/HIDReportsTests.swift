import Foundation
import Testing
@testable import UniversalKMCore

// MARK: - Report Map

/// Minimal HID short-item walker: total bits of input/output fields per report ID.
private func reportBits(_ map: [UInt8]) -> [String: Int] {
    var bits: [String: Int] = [:]
    var reportID = 0, size = 0, count = 0
    var i = 0
    while i < map.count {
        let prefix = map[i]
        let length = [0, 1, 2, 4][Int(prefix & 0x03)]
        var value = 0
        for k in 0..<length { value |= Int(map[i + 1 + k]) << (8 * k) }
        switch prefix & 0xFC {
        case 0x84: reportID = value          // Report ID
        case 0x74: size = value              // Report Size
        case 0x94: count = value             // Report Count
        case 0x80: bits["in\(reportID)", default: 0] += size * count   // Input
        case 0x90: bits["out\(reportID)", default: 0] += size * count  // Output
        default: break
        }
        i += 1 + length
    }
    return bits
}

@Test func reportMapFieldSizesMatchReportStructs() {
    let bits = reportBits(HIDReportDescriptor.reportMap)
    #expect(bits["in1"] == KeyboardReport.byteCount * 8)
    #expect(bits["out1"] == 8)
    #expect(bits["in2"] == MouseReport.byteCount * 8)
    #expect(bits.count == 3)
}

@Test func reportMapCollectionsAreBalanced() {
    let map = HIDReportDescriptor.reportMap
    // Only End Collection (0xC0) and Collection (0xA1 xx) items open/close; walk items to skip data bytes.
    var depth = 0, i = 0
    while i < map.count {
        let prefix = map[i]
        if prefix & 0xFC == 0xA0 { depth += 1 }
        if prefix == 0xC0 { depth -= 1 }
        #expect(depth >= 0)
        i += 1 + [0, 1, 2, 4][Int(prefix & 0x03)]
    }
    #expect(i == map.count)
    #expect(depth == 0)
}

// MARK: - Mouse report

@Test func mouseReportEncodesNegativeAxesLittleEndian() {
    let report = MouseReport(buttons: [.left, .forward], dx: -1, dy: -300, wheel: -2, pan: 3)
    #expect(report.bytes == [0x11, 0xFF, 0xFF, 0xD4, 0xFE, 0xFE, 0x03])
    #expect(report.bytes.count == MouseReport.byteCount)
}

@Test func mouseReportClampsAxesAndScroll() {
    let big = MouseReport(dx: 40_000, dy: -40_000, wheel: 500, pan: -500)
    #expect(big.dx == 32767)
    #expect(big.dy == -32767)
    #expect(big.wheel == 127)
    #expect(big.pan == -127)
    #expect(big.bytes == [0x00, 0xFF, 0x7F, 0x01, 0x80, 0x7F, 0x81])
}

@Test func mouseButtonsKeepOnlyFiveBits() {
    #expect(MouseButtons(rawValue: 0xFF).rawValue == 0x1F)
    #expect(MouseReport.neutral.bytes == [UInt8](repeating: 0, count: 7))
}

// MARK: - Keyboard report

@Test func keyboardReportWithModifiersAndSixKeys() {
    var state = KeyboardState()
    do { let changed = state.apply(usage: 0xE1, isDown: true); #expect(changed) }   // Left Shift
    do { let changed = state.apply(usage: 0xE7, isDown: true); #expect(changed) }   // Right GUI
    for usage: UInt8 in [0x04, 0x05, 0x06, 0x07, 0x08, 0x09] {
        do { let changed = state.apply(usage: usage, isDown: true); #expect(changed) }
    }
    #expect(state.report.bytes == [0x82, 0x00, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09])
}

@Test func seventhKeyIsIgnored() {
    var state = KeyboardState()
    for usage: UInt8 in 0x04...0x09 { state.apply(usage: usage, isDown: true) }
    let before = state.report
    do { let changed = state.apply(usage: 0x0A, isDown: true); #expect(!changed) }
    #expect(state.report == before)
    // Releasing the ignored key changes nothing either.
    do { let changed = state.apply(usage: 0x0A, isDown: false); #expect(!changed) }
    #expect(state.report == before)
}

@Test func repeatPressDoesNotChangeReport() {
    var state = KeyboardState()
    state.apply(usage: 0x04, isDown: true)
    state.apply(usage: 0xE0, isDown: true)
    let before = state.report
    do { let changed = state.apply(usage: 0x04, isDown: true); #expect(!changed) }
    do { let changed = state.apply(usage: 0xE0, isDown: true); #expect(!changed) }
    #expect(state.report == before)
}

@Test func releaseRemovesKeyAndKeepsOrder() {
    var state = KeyboardState()
    for usage: UInt8 in [0x04, 0x05, 0x06] { state.apply(usage: usage, isDown: true) }
    do { let changed = state.apply(usage: 0x05, isDown: false); #expect(changed) }
    #expect(state.report.bytes == [0x00, 0x00, 0x04, 0x06, 0x00, 0x00, 0x00, 0x00])
    state.apply(usage: 0x04, isDown: false)
    state.apply(usage: 0x06, isDown: false)
    #expect(state.report == .neutral)
    #expect(state.report.bytes == [UInt8](repeating: 0, count: 8))
}

@Test func keyboardReportInitTruncatesToSixKeys() {
    let report = KeyboardReport(keys: [1, 2, 3, 4, 5, 6, 7])
    #expect(report.keys == [1, 2, 3, 4, 5, 6])
}

@Test func modifierUsageMapsToBit() {
    #expect(KeyboardModifiers(usage: 0xE0) == .leftControl)
    #expect(KeyboardModifiers(usage: 0xE6) == .rightAlt)
    #expect(KeyboardModifiers(usage: 0x04) == nil)
}

// MARK: - Firmware parity (design D4)

/// Bytes of the C array between the UKM_REPORT_MAP_BEGIN / _END markers of firmware/src/ukm_report_map.h.
private func firmwareReportMap() throws -> [UInt8] {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("firmware/src/ukm_report_map.h")
    let text = try String(contentsOf: url, encoding: .utf8)
    let begin = try #require(text.range(of: "// UKM_REPORT_MAP_BEGIN"))
    let end = try #require(text.range(of: "// UKM_REPORT_MAP_END"))
    let body = text[begin.upperBound..<end.lowerBound]
        .split(separator: "\n")
        .map { line in line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? String(line) }
        .joined(separator: "\n")
    let regex = try Regex(#"0x([0-9A-Fa-f]{2})\b"#)
    return body.matches(of: regex).compactMap { match in
        UInt8(String(body[match.range].dropFirst(2)), radix: 16)
    }
}

@Test func reportMapMatchesFirmwareHeader() throws {
    let firmware = try firmwareReportMap()
    #expect(!firmware.isEmpty)
    #expect(firmware == HIDReportDescriptor.reportMap)
}
