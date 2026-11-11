import CoreGraphics
import Foundation
import Testing
@testable import UniversalKMCore

private func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }

/// Bytes as scrcpy-server 5.0.1 writes them (Streamer.java).
private func session(_ w: UInt32, _ h: UInt32) -> [UInt8] { be32(0x8000_0000) + be32(w) + be32(h) }

private func media(_ payload: [UInt8], pts: Int64 = 0, config: Bool = false, key: Bool = false) -> [UInt8] {
    var flags = UInt64(pts)
    if config { flags = 1 << 62 }
    if key { flags |= 1 << 61 }
    return be32(UInt32(flags >> 32)) + be32(UInt32(flags & 0xFFFF_FFFF)) + be32(UInt32(payload.count)) + payload
}

@Suite struct ScreenMirrorTests {
    private let cfg: [UInt8] = [0, 0, 0, 1, 0x67, 0x42, 0, 0x1F, 0, 0, 0, 1, 0x68, 0xCE]
    private let idr: [UInt8] = [0, 0, 0, 1, 0x65, 1, 2, 3]

    /// The start of the stream seen on SM-G970F: dummy byte, "h264", session 606×1280, config, key frame.
    private var stream: [UInt8] {
        [0] + be32(ScreenMirror.h264) + session(606, 1280) + media(cfg, config: true)
            + media(idr, pts: 33_333, key: true) + media([0, 0, 1, 0x41, 9], pts: 0x1_0000_0001)
    }

    private var expected: [ScreenMirror.Packet] {
        [.codec(ScreenMirror.h264), .session(width: 606, height: 1280), .config(Data(cfg)),
         .frame(ptsUs: 33_333, key: true, data: Data(idr)),
         .frame(ptsUs: 0x1_0000_0001, key: false, data: Data([0, 0, 1, 0x41, 9]))]
    }

    @Test func wholeStream() throws {
        var p = ScreenMirror.Parser()
        #expect(try p.append(Data(stream)) == expected)
    }

    @Test func splitAnywhere() throws {
        let bytes = stream
        for cut in 0...bytes.count {
            var p = ScreenMirror.Parser()
            let out = try p.append(Data(bytes[..<cut])) + p.append(Data(bytes[cut...]))
            #expect(out == expected, "cut at \(cut)")
        }
        var p = ScreenMirror.Parser()
        var out: [ScreenMirror.Packet] = []
        for b in bytes { out += try p.append(Data([b])) }
        #expect(out == expected)
    }

    @Test func rotationStartsANewSession() throws {
        var p = ScreenMirror.Parser(dummyByte: false)
        let out = try p.append(Data(be32(ScreenMirror.h264) + session(606, 1280) + session(1280, 606)))
        #expect(out == [.codec(ScreenMirror.h264), .session(width: 606, height: 1280), .session(width: 1280, height: 606)])
    }

    @Test func videoTurnedOff() throws {
        var p = ScreenMirror.Parser()
        #expect(try p.append(Data([0, 0, 0, 0, 1])) == [.codec(1)])
    }

    @Test func brokenStream() {
        var p = ScreenMirror.Parser()
        #expect(throws: ScreenMirror.ProtocolError.self) { try p.append(Data([7])) }
        var q = ScreenMirror.Parser(dummyByte: false)
        let huge = be32(ScreenMirror.h264) + be32(0) + be32(0) + be32(0x7FFF_FFFF)
        #expect(throws: ScreenMirror.ProtocolError.self) { try q.append(Data(huge)) }
    }

    @Test func parameterSets() {
        let sets = ScreenMirror.parameterSets(Data(cfg))
        #expect(sets?.sps == Data([0x67, 0x42, 0, 0x1F]))
        #expect(sets?.pps == Data([0x68, 0xCE]))
        #expect(ScreenMirror.parameterSets(Data(idr)) == nil)
    }

    @Test func serverCommand() {
        let c = ScreenMirror.serverCommand(scid: 0x0BAD_C0DE)
        #expect(c.hasPrefix("CLASSPATH=/data/local/tmp/ukm-scrcpy-server-5.0.1.jar app_process / com.genymobile.scrcpy.Server 5.0.1 "))
        #expect(c.contains(" scid=0badc0de "))
        #expect(c.contains(" tunnel_forward=true "))
        #expect(c.contains(" audio=false "))
        #expect(ScreenMirror.socket(scid: 0xFFFF_FFFF) == "localabstract:scrcpy_7fffffff")
    }

    @Test func pointsOnTheVideo() {
        // A 600×1200 portrait video in an 800×600 view: 300×600 shown, bars of 250 on both sides.
        let view = CGSize(width: 800, height: 600), video = CGSize(width: 600, height: 1200)
        #expect(ScreenMirror.videoPoint(CGPoint(x: 250, y: 0), view: view, video: video)! == (0, 0))
        #expect(ScreenMirror.videoPoint(CGPoint(x: 400, y: 300), view: view, video: video)! == (300, 600))
        #expect(ScreenMirror.videoPoint(CGPoint(x: 549.9, y: 599.9), view: view, video: video)! == (599, 1199))
        #expect(ScreenMirror.videoPoint(CGPoint(x: 100, y: 300), view: view, video: video) == nil)
        #expect(ScreenMirror.videoPoint(CGPoint(x: 560, y: 300), view: view, video: video) == nil)
        #expect(ScreenMirror.clampedVideoPoint(CGPoint(x: 100, y: -5), view: view, video: video) == (0, 0))
        #expect(ScreenMirror.clampedVideoPoint(CGPoint(x: 700, y: 900), view: view, video: video) == (599, 1199))
    }

    /// Byte layouts from scrcpy's app/tests/test_control_msg_serialize.c.
    @Test func touchMessages() {
        let down = ScreenMirror.Control.touch(.down, x: 100, y: 200, width: 1080, height: 1920)
        #expect(down == Data([0x02, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
                              0x00, 0x00, 0x00, 0x64, 0x00, 0x00, 0x00, 0xC8, 0x04, 0x38, 0x07, 0x80,
                              0xFF, 0xFF, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01]))
        let move = ScreenMirror.Control.touch(.move, x: 1, y: 2, width: 3, height: 4)
        #expect(move.count == 32 && move[1] == 2 && move[22...23] == Data([0xFF, 0xFF]))
        #expect(move[24...27] == Data([0, 0, 0, 0]) && move[28...31] == Data([0, 0, 0, 1]))
        let up = ScreenMirror.Control.touch(.up, x: 1, y: 2, width: 3, height: 4)
        #expect(up[22...23] == Data([0, 0]) && up[24...27] == Data([0, 0, 0, 1]) && up[28...31] == Data([0, 0, 0, 0]))
    }

    @Test func scrollMessage() {
        let s = ScreenMirror.Control.scroll(x: 260, y: 1026, width: 1080, height: 1920, horizontal: 16, vertical: -16)
        #expect(s == Data([0x03, 0x00, 0x00, 0x01, 0x04, 0x00, 0x00, 0x04, 0x02, 0x04, 0x38, 0x07, 0x80,
                           0x7F, 0xFF, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00]))
        // Beyond the range: clamped.
        let big = ScreenMirror.Control.scroll(x: 0, y: 0, width: 1, height: 1, horizontal: 0, vertical: 100)
        #expect(big[15...16] == Data([0x7F, 0xFF]))
    }

    @Test func keyTextBack() {
        #expect(ScreenMirror.Control.key(.up, .enter, metaState: 0x41) ==
                Data([0x00, 0x01, 0x00, 0x00, 0x00, 0x42, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x41]))
        #expect(ScreenMirror.Control.text("hello, world!") ==
                Data([0x01, 0x00, 0x00, 0x00, 0x0D]) + Data("hello, world!".utf8))
        #expect(ScreenMirror.Control.backOrScreenOn(.up) == Data([0x04, 0x01]))
        // 300 bytes at most, never half a character: 150 × "й" (2 bytes) fits, the 151st does not.
        let long = ScreenMirror.Control.text(String(repeating: "й", count: 200))
        #expect(long.count == 5 + 300)
        #expect(String(data: long.dropFirst(5), encoding: .utf8) == String(repeating: "й", count: 150))
    }
}
