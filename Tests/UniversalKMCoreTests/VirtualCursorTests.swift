import CoreGraphics
import Testing
@testable import UniversalKMCore

private let tablet = CGSize(width: 800, height: 1280)

/// `#expect` cannot take a mutating call.
private func moved(_ cursor: inout VirtualCursor, _ dx: Double, _ dy: Double) -> Bool {
    cursor.move(dx: dx, dy: dy)
}

@Test func startsAtTheMacFacingEdge() {
    let right = VirtualCursor(screen: tablet, side: .right, entryFraction: 0.25)
    #expect(right.x == 0 && right.y == 320)
    let left = VirtualCursor(screen: tablet, side: .left, entryFraction: 0.5)
    #expect(left.x == 800 && left.y == 640)
    let below = VirtualCursor(screen: tablet, side: .bottom, entryFraction: 0.5)
    #expect(below.x == 400 && below.y == 0)
    let above = VirtualCursor(screen: tablet, side: .top, entryFraction: 1)
    #expect(above.x == 800 && above.y == 1280)
}

@Test func clampedToTheScreen() {
    var cursor = VirtualCursor(screen: tablet, side: .right, entryFraction: 0.5)
    _ = cursor.move(dx: 5000, dy: 5000)
    #expect(cursor.x == 800 && cursor.y == 1280)
}

@Test func returnsOnlyAfterAPushThroughTheEdge() {
    var cursor = VirtualCursor(screen: tablet, side: .right, entryFraction: 0.5)
    do { let r = moved(&cursor, 300, 0); #expect(!r) }          // into the device
    do { let r = moved(&cursor, -300, 0); #expect(!r) }         // back to the edge: touching is not enough
    do { let r = moved(&cursor, -20, 0); #expect(!r) }          // 20 of 40
    do { let r = moved(&cursor, -25, 0); #expect(r) }           // 45 ≥ 40: back to the Mac
}

@Test func movingInwardResetsThePush() {
    var cursor = VirtualCursor(screen: tablet, side: .right, entryFraction: 0.5)
    do { let r = moved(&cursor, -30, 0); #expect(!r) }
    do { let r = moved(&cursor, 5, 0); #expect(!r) }            // away from the edge
    do { let r = moved(&cursor, -30, 0); #expect(!r) }          // 25 beyond the edge, counting anew
}

@Test func estimateRealignsAtTheFarEdge() {
    // The host moved its pointer further than sent (acceleration): pushing against the far edge clamps
    // the estimate the same way the real pointer is clamped, so the way back is measured correctly again.
    var cursor = VirtualCursor(screen: tablet, side: .right, entryFraction: 0.5)
    _ = cursor.move(dx: 2000, dy: 0)
    #expect(cursor.x == 800)
    do { let r = moved(&cursor, -790, 0); #expect(!r) }
    do { let r = moved(&cursor, -60, 0); #expect(r) }
}

@Test func eachSideReturnsThroughItsOwnEdge() {
    var left = VirtualCursor(screen: tablet, side: .left, entryFraction: 0.5)
    do { let r = moved(&left, -50, 0); #expect(!r) }            // deeper into the device
    do { let r = moved(&left, 100, 0); #expect(r) }             // 50 back + 50 beyond x = 800
    var below = VirtualCursor(screen: tablet, side: .bottom, entryFraction: 0.5)
    do { let r = moved(&below, 0, -50); #expect(r) }            // up through the top edge
    var above = VirtualCursor(screen: tablet, side: .top, entryFraction: 0.5)
    do { let r = moved(&above, 0, 50); #expect(r) }             // down through the bottom edge
}

@Test func exitFractionFollowsThePositionAlongTheEdge() {
    var cursor = VirtualCursor(screen: tablet, side: .right, entryFraction: 0.1)
    _ = cursor.move(dx: 200, dy: 512)              // y 128 + 512 = 640
    #expect(abs(cursor.exitFraction - 0.5) < 1e-9)
}
