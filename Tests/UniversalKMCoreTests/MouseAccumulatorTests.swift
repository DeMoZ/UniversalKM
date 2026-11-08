import Testing
@testable import UniversalKMCore

private extension MouseAccumulator {
    /// Takes every pending report.
    mutating func drain() -> [MouseReport] {
        var out: [MouseReport] = []
        while let report = nextReport() { out.append(report) }
        return out
    }
}

@Test func emptyAccumulatorHasNoReport() {
    var acc = MouseAccumulator()
    #expect(!acc.hasPendingReport)
    #expect(acc.nextReport() == nil)
}

@Test func sentMotionEqualsInputSum() {
    var acc = MouseAccumulator()
    let deltas: [(Double, Double)] = [(1.7, -0.4), (2.6, -3.9), (-0.8, 0.25), (10.05, 7.3), (0.33, -0.11)]
    var sent = (x: 0, y: 0)
    for (dx, dy) in deltas {
        acc.addMotion(dx: dx, dy: dy)
        // Drain sometimes in the middle, as the transport would when the channel frees up.
        for report in acc.drain() { sent.x += Int(report.dx); sent.y += Int(report.dy) }
    }
    let total = deltas.reduce((0.0, 0.0)) { ($0.0 + $1.0, $0.1 + $1.1) }
    #expect(sent.x == Int(total.0.rounded(.towardZero)))
    #expect(sent.y == Int(total.1.rounded(.towardZero)))
}

@Test func tenSmallStepsSumToThree() {
    var acc = MouseAccumulator()
    var sent = 0
    for _ in 0..<10 {
        acc.addMotion(dx: 0.3, dy: 0)
        for report in acc.drain() { sent += Int(report.dx) }
    }
    #expect(sent == 3)
}

@Test func motionBeyondInt16GoesIntoNextReport() {
    var acc = MouseAccumulator()
    acc.addMotion(dx: 40_000, dy: -70_000)
    let reports = acc.drain()
    #expect(reports.map(\.dx) == [32767, 7233, 0])
    #expect(reports.map(\.dy) == [-32767, -32767, -4466])
    #expect(acc.nextReport() == nil)
}

@Test func scrollBeyondInt8GoesIntoNextReport() {
    var acc = MouseAccumulator()
    acc.addScroll(wheel: 200, pan: -130.5)
    let reports = acc.drain()
    #expect(reports.map(\.wheel) == [127, 73])
    #expect(reports.map(\.pan) == [-127, -3])
}

@Test func motionBeforeButtonChangeIsSentFirst() {
    var acc = MouseAccumulator()
    acc.addMotion(dx: 5, dy: -2)
    acc.setButtons(.left)
    acc.addMotion(dx: 1, dy: 0)
    acc.setButtons([])

    let reports = acc.drain()
    #expect(reports == [
        MouseReport(buttons: [], dx: 5, dy: -2),
        MouseReport(buttons: .left, dx: 1, dy: 0),
        MouseReport(buttons: [], dx: 0, dy: 0),
    ])
}

@Test func clickWithoutMotionGivesPressAndRelease() {
    var acc = MouseAccumulator()
    acc.setButtons(.right)
    acc.setButtons([])
    #expect(acc.drain() == [MouseReport(buttons: .right), MouseReport(buttons: [])])
}

@Test func fractionCarriesAcrossButtonSegments() {
    var acc = MouseAccumulator()
    acc.addMotion(dx: 0.6, dy: 0)
    acc.setButtons(.left)
    acc.addMotion(dx: 0.6, dy: 0)
    let reports = acc.drain()
    // 0.6 alone sends nothing; the press report then carries 0.6 + 0.6 = 1.
    #expect(reports == [MouseReport(buttons: .left, dx: 1)])
}

@Test func sameButtonsDoNotAddSegment() {
    var acc = MouseAccumulator()
    acc.setButtons([])
    #expect(!acc.hasPendingReport)
    acc.setButtons(.left)
    acc.setButtons(.left)
    #expect(acc.drain() == [MouseReport(buttons: .left)])
}

@Test func resetDropsPendingAndButtons() {
    var acc = MouseAccumulator()
    acc.addMotion(dx: 3, dy: 3)
    acc.setButtons(.left)
    _ = acc.nextReport()
    acc.reset()
    #expect(acc.nextReport() == nil)
    #expect(acc.lastSentButtons == [])
    #expect(acc.currentButtons == [])
}
