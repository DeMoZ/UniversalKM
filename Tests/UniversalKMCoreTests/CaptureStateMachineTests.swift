import Foundation
import Testing
@testable import UniversalKMCore

private let phone = UUID()
private let tablet = UUID()

private func remote(_ device: UUID = phone) -> CaptureStateMachine {
    var machine = CaptureStateMachine()
    _ = machine.handle(.zoneHit(device: device, hostConnected: true))
    return machine
}

@Test func zoneHitWithoutHostOrDeviceIsIgnored() {
    var machine = CaptureStateMachine()
    #expect(machine.handle(.zoneHit(device: phone, hostConnected: false)).isEmpty)
    #expect(machine.handle(.zoneHit(device: nil, hostConnected: true)).isEmpty)
    #expect(machine.mode == .local)
}

@Test func zoneHitWithHostGoesRemote() {
    var machine = CaptureStateMachine()
    #expect(machine.handle(.zoneHit(device: phone, hostConnected: true)) == [.hideCursor, .lockCursor, .notifyUI])
    #expect(machine.mode == .remote(phone))
    #expect(machine.remoteDevice == phone)
    #expect(machine.isCursorHidden)
}

@Test func everyReleaseEventReturnsToLocal() {
    let events: [CaptureStateMachine.Event] = [.hotkey, .hostDisconnected(phone), .permissionLost, .tapDisabled,
                                               .deviceRemoved(phone), .quit, .releaseRequested]
    for event in events {
        var machine = remote()
        #expect(machine.handle(event) == [.sendNeutralReports(phone), .unlockCursor, .showCursor, .notifyUI], "\(event)")
        #expect(machine.mode == .local)
        #expect(!machine.isCursorHidden)
    }
}

@Test func otherDeviceDisconnectingChangesNothing() {
    var machine = remote(phone)
    #expect(machine.handle(.hostDisconnected(tablet)).isEmpty)
    #expect(machine.handle(.deviceRemoved(tablet)).isEmpty)
    #expect(machine.mode == .remote(phone))
}

@Test func hideIsNotIssuedTwice() {
    var machine = remote()
    #expect(machine.handle(.zoneHit(device: tablet, hostConnected: true)).isEmpty)   // already remote
    _ = machine.handle(.hotkey)
    let again = machine.handle(.zoneHit(device: tablet, hostConnected: true))
    #expect(again.filter { $0 == .hideCursor }.count == 1)
    #expect(machine.mode == .remote(tablet))
}

@Test func hotkeyInLocalPassesThrough() {
    var machine = CaptureStateMachine()
    #expect(machine.handle(.hotkey).isEmpty)
    #expect(machine.handle(.quit).isEmpty)
}
