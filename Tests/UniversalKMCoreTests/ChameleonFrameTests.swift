import Testing
@testable import UniversalKMCore

// The enter-DFU frame of upstream resource/tools/enter_dfu.py (DATA_CMD_ENTER_BOOTLOADER = 1010, no data).
private let upstreamEnterDFU: [UInt8] = [0x11, 0xEF, 0x03, 0xF2, 0x00, 0x00, 0x00, 0x00, 0x0B, 0x00]

@Test func encodesLikeUpstream() {
    #expect(ChameleonFrame(command: 1010).encoded == upstreamEnterDFU)
}

@Test func lrcIsTwosComplementOfSum() {
    #expect(ChameleonFrame.lrc([0x11]) == 0xEF)
    #expect(ChameleonFrame.lrc([]) == 0x00)
    #expect(ChameleonFrame.lrc([0x80, 0x80]) == 0x00)
    #expect(ChameleonFrame.lrc([0x01, 0x02, 0x03]) == 0xFA)
}

@Test func encodesDataAndHeader() {
    let frame = ChameleonHID.setEnabled(true)
    // 9001 = 0x2329, length 1, data 01, LRC3 = FF.
    #expect(frame.encoded == [0x11, 0xEF, 0x23, 0x29, 0x00, 0x00, 0x00, 0x01, ChameleonFrame.lrc([0x11, 0xEF, 0x23, 0x29, 0, 0, 0, 1]), 0x01, 0xFF])
}

@Test func reportFramesCarryThePeerID() {
    let mouse = ChameleonHID.mouse(MouseReport(dx: 30), to: 1)
    #expect(mouse.command == 9003)
    #expect(mouse.data == [0x00, 0x01, 0x00, 0x1E, 0x00, 0x00, 0x00, 0x00, 0x00])
    let keyboard = ChameleonHID.keyboard(KeyboardReport(modifiers: .leftShift, keys: [0x04]), to: 0x0102)
    #expect(keyboard.command == 9002)
    #expect(keyboard.data == [0x01, 0x02, 0x02, 0x00, 0x04, 0, 0, 0, 0, 0])
}

@Test func parsesWholeFrame() {
    var parser = ChameleonFrameParser()
    let frame = ChameleonFrame(command: 9000, status: 0x68, data: [2, 1, 0, 3])
    #expect(parser.append(frame.encoded) == [frame])
}

@Test func parsesFrameSplitIntoPieces() {
    var parser = ChameleonFrameParser()
    let frame = ChameleonFrame(command: 9004, status: 0x68, data: Array(0..<30))
    let bytes = frame.encoded
    var out: [ChameleonFrame] = []
    for byte in bytes { out += parser.append([byte]) }
    #expect(out == [frame])
}

@Test func skipsGarbageBeforeSOF() {
    var parser = ChameleonFrameParser()
    let frame = ChameleonFrame(command: 1000, status: 0x68, data: [0x02, 0x03])
    #expect(parser.append([0x00, 0xFF, 0x42, 0x11, 0x00] + frame.encoded) == [frame])
}

@Test func dropsFrameWithBadLRC() {
    var parser = ChameleonFrameParser()
    var bad = ChameleonFrame(command: 9003, status: 0xA0, data: [3, 2]).encoded
    bad[bad.count - 1] ^= 0xFF               // data LRC
    var badHeader = ChameleonFrame(command: 9003, status: 0x68, data: [3, 2]).encoded
    badHeader[8] ^= 0x01                     // header LRC
    let good = ChameleonFrame(command: 9002, status: 0x68, data: [3, 2])
    #expect(parser.append(bad + badHeader + good.encoded) == [good])
}

@Test func parsesSeveralFramesInOneChunk() {
    var parser = ChameleonFrameParser()
    let a = ChameleonFrame(command: 9003, status: 0xA0, data: [3, 2])
    let b = ChameleonFrame(command: 9003, status: 0x68, data: [3, 2])
    #expect(parser.append(a.encoded + b.encoded) == [a, b])
}

@Test func emptyDataFrame() {
    var parser = ChameleonFrameParser()
    let frame = ChameleonFrame(command: 9000, status: 0x67)
    #expect(parser.append(frame.encoded) == [frame])
    #expect(frame.knownStatus == .invalidCommand)
}

// MARK: - HID replies (bytes captured from the device)

@Test func parsesInfo() throws {
    let info = try #require(ChameleonHIDInfo([0x02, 0x01, 0x02, 0x03]))
    #expect(info.protocolVersion == 2)
    #expect(info.isEnabled)
    #expect(info.hostCount == 2)
    #expect(info.maxHosts == 3)
    #expect(info.isSupported)
    #expect(ChameleonHIDInfo([0x01, 0x00, 0xFF, 0xFF])?.isSupported == false)  // protocol 1 (single host)
    #expect(ChameleonHIDInfo([0x02, 0x01]) == nil)
}

@Test func parsesHostList() throws {
    // 9004 reply with the tablet (peer 1) and the phone (peer 0), both subscribed.
    let data: [UInt8] = [0x01, 0x01, 0x02,
                         0x00, 0x01, 0xd8, 0x52, 0xef, 0x54, 0x06, 0x64, 0x03,
                         0x00, 0x00, 0x88, 0x66, 0xd8, 0x68, 0x34, 0x7d, 0x03]
    let state = try #require(ChameleonHIDState(data))
    #expect(state.isEnabled)
    #expect(state.isAdvertising)
    #expect(state.hosts.map(\.peerID) == [1, 0])
    #expect(state.hosts[0].addressString == "64:06:54:ef:52:d8")
    #expect(state.hosts.allSatisfy { $0.state == .subscribed })
    #expect(state.subscribedPeerIDs == [0, 1])
}

@Test func unbondedHostHasNoPeerID() throws {
    let data: [UInt8] = [0x01, 0x00, 0x01, 0xFF, 0xFF, 0x5a, 0x22, 0xe9, 0xa3, 0x24, 0x54, 0x02]
    let state = try #require(ChameleonHIDState(data))
    #expect(state.hosts == [ChameleonHost(peerID: nil, address: [0x5a, 0x22, 0xe9, 0xa3, 0x24, 0x54], state: .connected)])
    #expect(state.subscribedPeerIDs.isEmpty)
    #expect(!state.isAdvertising)
}

@Test func rejectsTruncatedHostList() {
    #expect(ChameleonHIDState([0x01, 0x01, 0x01, 0x00, 0x00]) == nil)
    #expect(ChameleonHIDState([0x01, 0x01]) == nil)
    #expect(ChameleonHIDState([0x01, 0x01, 0x00]) == ChameleonHIDState(isEnabled: true, isAdvertising: true, hosts: []))
}

@Test func parsesReportReply() {
    #expect(ChameleonReportReply([0x03, 0x02]) == ChameleonReportReply([3, 2]))
    #expect(ChameleonReportReply([0x01, 0x02])?.targetState == 1)
    #expect(ChameleonReportReply([0x03]) == nil)
}
