import Foundation
import Testing
@testable import UniversalKMCore

private func be32(_ v: Int) -> [UInt8] { [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }

/// Packets as LiveHub.java writes them (design D11).
private func config(_ w: Int, _ h: Int, _ sps: [UInt8], _ pps: [UInt8]) -> [UInt8] {
    [UInt8(ascii: "C")] + be32(w) + be32(h) + be32(sps.count) + sps + be32(pps.count) + pps
}

private func frame(_ pts: Int64, key: Bool, rotation: Int, _ data: [UInt8]) -> [UInt8] {
    var b: [UInt8] = [UInt8(ascii: "F")]
    for i in (0..<8).reversed() { b.append(UInt8(truncatingIfNeeded: pts >> (8 * Int64(i)))) }
    b.append(key ? 1 : 0)
    b += [UInt8(rotation >> 8), UInt8(rotation & 0xFF)]
    return b + be32(data.count) + data
}

@Suite struct MotionLiveTests {
    @Test func packetsInOneRead() throws {
        let sps: [UInt8] = [0x67, 0x42, 0x00, 0x1F]
        let pps: [UInt8] = [0x68, 0xCE]
        let au: [UInt8] = [0, 0, 0, 1, 0x65, 9, 9, 9]
        var p = MotionLive.Parser()
        let out = try p.append(Data(config(1280, 720, sps, pps) + frame(123_456_789, key: true, rotation: 270, au)))
        #expect(out == [.config(width: 1280, height: 720, sps: Data(sps), pps: Data(pps)),
                        .frame(ptsUs: 123_456_789, key: true, rotation: 270, annexB: Data(au))])
    }

    @Test func packetsSplitAnywhere() throws {
        let bytes = config(640, 360, [0x67, 1, 2], [0x68, 3]) + frame(1, key: true, rotation: 90, [0, 0, 1, 0x65, 7])
            + frame(33_333, key: false, rotation: 90, [0, 0, 1, 0x41, 8, 8])
        // Every split point gives the same three packets.
        for cut in 0...bytes.count {
            var p = MotionLive.Parser()
            let out = try p.append(Data(bytes[..<cut])) + p.append(Data(bytes[cut...]))
            #expect(out.count == 3, "cut at \(cut)")
        }
        // One byte at a time.
        var p = MotionLive.Parser()
        var n = 0
        for b in bytes { n += try p.append(Data([b])).count }
        #expect(n == 3)
    }

    @Test func garbageIsAnError() {
        var p = MotionLive.Parser()
        #expect(throws: MotionLive.ProtocolError.self) { try p.append(Data("HTTP/1.1".utf8)) }
        var q = MotionLive.Parser()
        #expect(throws: MotionLive.ProtocolError.self) {
            try q.append(Data([UInt8(ascii: "F")] + [UInt8](repeating: 0, count: 11) + be32(-1)))
        }
    }

    @Test func annexBToAVCC() {
        // 4- and 3-byte start codes; parameter sets are dropped.
        let annexB = Data([0, 0, 0, 1, 0x67, 1, 2, 0, 0, 1, 0x68, 3, 0, 0, 0, 1, 0x65, 0xAA, 0xBB, 0, 0, 1, 0x65, 0xCC])
        #expect(MotionLive.nalUnits(annexB).count == 4)
        #expect(MotionLive.avcc(annexB) == Data([0, 0, 0, 3, 0x65, 0xAA, 0xBB, 0, 0, 0, 2, 0x65, 0xCC]))
    }

    @Test func liveCommand() {
        let head = ["am", "start", "-n", "com.universalkm.motion/.ControlActivity", "--es", "live"]
        #expect(MotionCamera.liveCommand([.back, .front]) == head + ["both"])
        #expect(MotionCamera.liveCommand([.front]) == head + ["front"])
        #expect(MotionCamera.liveCommand([]) == head + ["none"])
    }

    @Test func statusWithLive() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/motion/status-sm-g970f-v3.txt")
        let s = try #require(MotionStatus.parse(try String(contentsOf: url, encoding: .utf8)))
        #expect(s.version == 3)
        #expect(s.bothSupported)
        #expect(s.live == ["rear", "front"])
        #expect(s.active.isEmpty)
        #expect(s.settings.quality == .fullHD)
    }
}
