import Foundation
import UniversalKMCore

/// Both transports behind one HIDTransport (add-android-usb-transport design D1): Android peer IDs
/// (`AndroidPeerRegistry.range`) go to the Android transport, all others to ChameleonUltra.
final class CompositeHIDTransport: HIDTransport, @unchecked Sendable {
    let chameleon: HIDTransport
    let android: AndroidHIDTransport

    init(chameleon: HIDTransport, android: AndroidHIDTransport) {
        self.chameleon = chameleon
        self.android = android
    }

    private func route(_ peerID: UInt16) -> HIDTransport {
        AndroidPeerRegistry.isAndroidPeer(peerID) ? android : chameleon
    }

    func start() {
        android.start()
        chameleon.start()
    }

    func setEnabled(_ enabled: Bool) {
        android.setEnabled(enabled)
        chameleon.setEnabled(enabled)
    }

    func setBoundPeers(_ peers: Set<UInt16>) {
        android.setBoundPeers(peers)
        chameleon.setBoundPeers(peers)
    }

    func moveMouse(dx: Double, dy: Double, to peerID: UInt16) { route(peerID).moveMouse(dx: dx, dy: dy, to: peerID) }
    func scroll(wheel: Double, pan: Double, to peerID: UInt16) { route(peerID).scroll(wheel: wheel, pan: pan, to: peerID) }
    func setButtons(_ buttons: MouseButtons, to peerID: UInt16) { route(peerID).setButtons(buttons, to: peerID) }
    func key(usage: UInt8, isDown: Bool, to peerID: UInt16) { route(peerID).key(usage: usage, isDown: isDown, to: peerID) }
    func sendNeutral(to peerID: UInt16) { route(peerID).sendNeutral(to: peerID) }

    func shutdown(timeout: TimeInterval) {
        android.shutdown(timeout: timeout)
        chameleon.shutdown(timeout: timeout)
    }
}
