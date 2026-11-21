import Foundation
import Testing
@testable import UniversalKMCore

@Suite struct SecondDisplayTests {
    private let messages: [SecondDisplay.Message] = [
        .hello(version: 1, width: 2000, height: 1200, hardwareH264: true),
        .config(width: 2000, height: 1200, parameterSets: Data([0, 0, 0, 1, 0x67, 0x42, 0, 0, 0, 1, 0x68, 0xCE])),
        .frame(ptsUs: 0x1_0000_0001, key: true, data: Data([0, 0, 0, 1, 0x65, 1, 2, 3])),
        .frame(ptsUs: 33_333, key: false, data: Data([0, 0, 1, 0x41])),
        .keyFrameRequest,
        .rotated(width: 1200, height: 2000),
        .stats(decodeUs: 4_000, presentUs: 9_000),
        .touch(.init(action: .down, fingers: 1, x: 65535, y: 0, timeMs: 123_456)),
    ]

    private var stream: Data { messages.reduce(Data()) { $0 + SecondDisplay.encode($1) } }

    @Test func wholeStream() throws {
        var p = SecondDisplay.Parser()
        #expect(try p.append(stream) == messages)
    }

    @Test func splitAnywhere() throws {
        let bytes = stream
        for cut in 0...bytes.count {
            var p = SecondDisplay.Parser()
            let a = try p.append(bytes.prefix(cut))
            let b = try p.append(bytes.dropFirst(cut))
            #expect(a + b == messages, "cut at \(cut)")
        }
    }

    @Test func byteByByte() throws {
        var p = SecondDisplay.Parser()
        var out: [SecondDisplay.Message] = []
        for byte in stream { out += try p.append(Data([byte])) }
        #expect(out == messages)
    }

    @Test func unknownTypeIsSkipped() throws {
        var p = SecondDisplay.Parser()
        let unknown = Data([99, 0, 0, 0, 2, 7, 7])
        #expect(try p.append(unknown + SecondDisplay.encode(.keyFrameRequest)) == [.keyFrameRequest])
    }

    @Test func truncatedBodyIsAnError() {
        var p = SecondDisplay.Parser()
        // A hello (type 1) with a 3-byte body.
        #expect(throws: SecondDisplay.ProtocolError.self) { try p.append(Data([1, 0, 0, 0, 3, 0, 1, 2])) }
    }

    @Test func hugeLengthIsAnError() {
        var p = SecondDisplay.Parser()
        #expect(throws: SecondDisplay.ProtocolError.self) { try p.append(Data([3, 0xFF, 0xFF, 0xFF, 0xFF])) }
    }

    @Test func badTouchActionIsAnError() {
        var p = SecondDisplay.Parser()
        let body = Data([9, 1, 0, 0, 0, 0, 0, 0, 0, 0])
        #expect(throws: SecondDisplay.ProtocolError.self) {
            try p.append(Data([7, 0, 0, 0, UInt8(body.count)]) + body)
        }
    }

    /// The same bytes are asserted by the receiver's CoreTests (android/display/test).
    @Test func goldenBytes() {
        func enc(_ m: SecondDisplay.Message) -> [UInt8] { [UInt8](SecondDisplay.encode(m)) }
        #expect(enc(.hello(version: 1, width: 2000, height: 1200, hardwareH264: true))
            == [1, 0, 0, 0, 11, 0, 1, 0, 0, 7, 0xD0, 0, 0, 4, 0xB0, 1])
        #expect(enc(.keyFrameRequest) == [4, 0, 0, 0, 0])
        #expect(enc(.rotated(width: 1200, height: 2000)) == [5, 0, 0, 0, 8, 0, 0, 4, 0xB0, 0, 0, 7, 0xD0])
        #expect(enc(.stats(decodeUs: 4000, presentUs: 9000)) == [6, 0, 0, 0, 8, 0, 0, 0x0F, 0xA0, 0, 0, 0x23, 0x28])
        #expect(enc(.touch(.init(action: .down, fingers: 1, x: 65535, y: 0, timeMs: 123_456)))
            == [7, 0, 0, 0, 10, 0, 1, 0xFF, 0xFF, 0, 0, 0, 0x01, 0xE2, 0x40])
    }

    // MARK: Display mode

    @Test func displaySizeKeepsSmallScreens() {
        #expect(SecondDisplay.displaySize(forDevice: 1080, 2280) == (1080, 2280))
        #expect(SecondDisplay.displaySize(forDevice: 2000, 1200) == (2000, 1200))
    }

    @Test func displaySizeShrinksBigScreensKeepingProportions() {
        let s = SecondDisplay.displaySize(forDevice: 3200, 2000)
        #expect(s.width == 2560 && s.height == 1600)
        let portrait = SecondDisplay.displaySize(forDevice: 1440, 3200)
        #expect(portrait.height == 2560 && portrait.width == 1152)
    }

    @Test func displaySizeIsEven() {
        let s = SecondDisplay.displaySize(forDevice: 1081, 2279)
        #expect(s.width % 2 == 0 && s.height % 2 == 0)
        #expect(SecondDisplay.displaySize(forDevice: 0, 100) == (0, 0))
    }

    // MARK: Gestures

    private func touch(_ a: SecondDisplay.Touch.Action, _ x: Int, _ y: Int, fingers: Int = 1, at t: UInt32 = 0)
        -> SecondDisplay.Touch {
        .init(action: a, fingers: fingers, x: x, y: y, timeMs: t)
    }

    private func run(_ events: [SecondDisplay.Touch]) -> [SecondDisplay.MouseEvent] {
        var g = SecondDisplay.Gesture(displayWidth: 1000, displayHeight: 500)
        return events.flatMap { g.feed($0) }
    }

    @Test func tapIsAClick() {
        // Centre of the picture: 32767/65535 of 1000×500.
        let out = run([touch(.down, 32767, 32767, at: 0), touch(.up, 32767, 32767, at: 80)])
        #expect(out == [.leftDown(x: 499, y: 249), .leftUp(x: 499, y: 249)])
    }

    @Test func tinyWobbleStaysATap() {
        let out = run([touch(.down, 1000, 1000, at: 0), touch(.move, 1100, 1050, at: 30), touch(.up, 1100, 1050, at: 60)])
        #expect(out == [.leftDown(x: 15, y: 7), .leftUp(x: 15, y: 7)])
    }

    @Test func dragStartsWhereTheFingerWentDown() {
        let out = run([touch(.down, 0, 0, at: 0), touch(.move, 6554, 0, at: 20), touch(.move, 13107, 0, at: 40),
                       touch(.up, 13107, 0, at: 60)])
        #expect(out == [.leftDown(x: 0, y: 0), .leftDragged(x: 100, y: 0), .leftDragged(x: 200, y: 0),
                        .leftUp(x: 200, y: 0)])
    }

    @Test func longTouchIsARightClick() {
        let out = run([touch(.down, 32767, 32767, at: 0), touch(.up, 32767, 32767, at: 600)])
        #expect(out == [.rightClick(x: 499, y: 249)])
    }

    @Test func twoFingersScroll() {
        let out = run([touch(.down, 32767, 32767, fingers: 2, at: 0), touch(.move, 32767, 39321, fingers: 2, at: 20),
                       touch(.up, 32767, 39321, fingers: 2, at: 40)])
        // From y 249 to y 300 of 500: 51 pixels down (integer rounding of the 16-bit coordinates).
        #expect(out == [.scroll(x: 499, y: 300, dx: 0, dy: 51)])
    }

    @Test func secondFingerEndsADragWithoutAJump() {
        let out = run([touch(.down, 0, 0, at: 0), touch(.move, 13107, 0, at: 20),
                       touch(.move, 13107, 0, fingers: 2, at: 40), touch(.move, 13107, 6554, fingers: 2, at: 60),
                       touch(.move, 13107, 6554, fingers: 1, at: 80), touch(.up, 13107, 6554, at: 100)])
        #expect(out == [.leftDown(x: 0, y: 0), .leftDragged(x: 200, y: 0), .leftUp(x: 200, y: 0),
                        .scroll(x: 200, y: 50, dx: 0, dy: 50)])
    }

    @Test func pointsOutsideThePictureAreClamped() {
        let out = run([touch(.down, 65535, 65535, at: 0), touch(.up, 65535, 65535, at: 50)])
        #expect(out == [.leftDown(x: 999, y: 499), .leftUp(x: 999, y: 499)])
    }
}
