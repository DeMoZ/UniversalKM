import Foundation
import Testing
@testable import UniversalKMCore

private func fixture(_ name: String) throws -> String {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/motion").appendingPathComponent(name)
    return try String(contentsOf: url, encoding: .utf8)
}

@Suite struct MotionCameraTests {
    @Test func statusFromTablet() throws {
        let s = try #require(MotionStatus.parse(try fixture("status-sm-x115.txt")))
        #expect(s.state == .watching)
        #expect(s.on)
        #expect(s.clips == 2)
        #expect(s.bytes == 11_800_956)
        #expect(s.free > 1_000_000_000)
        #expect(s.battery == 84)
        #expect(!s.charging)
        #expect(s.version == 1)
        #expect(s.settings == MotionSettings())
    }

    @Test func statusFromTabletVersion2() throws {
        let s = try #require(MotionStatus.parse(try fixture("status-sm-x115-v2.txt")))
        #expect(s.version == 2)
        #expect(s.settings.camera == .both)
        #expect(!s.bothSupported)
        #expect(s.active == ["rear"])
    }

    @Test func statusStatesAndSettings() throws {
        let row = "Row: 0 state=low_space, on=1, clips=3, bytes=5, free=10, battery=9, charging=1, version=7, "
            + "sens=high, stop=30, cam=front, q=1080, limitMB=8192, future=x"
        let s = try #require(MotionStatus.parse(row + "\n"))
        #expect(s.state == .lowSpace)
        #expect(s.charging)
        #expect(s.settings.sensitivity == .high)
        #expect(s.settings.stopSeconds == 30)
        #expect(s.settings.camera == .front)
        #expect(s.settings.quality == .fullHD)
        #expect(s.settings.limitMB == 8192)
        #expect(MotionStatus.parse("Row: 0 state=dancing, on=0")?.state == .unknown)
        let both = try #require(MotionStatus.parse("Row: 0 state=recording, on=1, cam=both, both=1, active=rear,front"))
        #expect(both.settings.camera == .both)
        #expect(both.bothSupported)
        #expect(both.active == ["rear", "front"])
        #expect(MotionStatus.parse("Row: 0 state=watching, both=0, active=-")?.active == [])
        #expect(s.bothSupported == false)
        #expect(MotionStatus.parse("Row: 0 state=battery_low")?.state == .batteryLow)
    }

    @Test func noStatus() {
        #expect(MotionStatus.parse("") == nil)
        #expect(MotionStatus.parse("Error while accessing provider:com.universalkm.motion") == nil)
        #expect(MotionStatus.parse("No result found.") == nil)
    }

    @Test func installedVersion() throws {
        #expect(MotionCamera.installedVersion(try fixture("pm-sm-x115.txt")) == 1)
        #expect(MotionCamera.installedVersion("") == nil)
        #expect(MotionCamera.installedVersion("package:com.universalkm.motionx versionCode:4\n") == nil)
        #expect(MotionCamera.installedVersion("package:com.universalkm.motion versionCode:12\n") == 12)
    }

    @Test func commands() {
        var s = MotionSettings()
        s.sensitivity = .low
        s.stopSeconds = 20
        s.camera = .front
        s.quality = .fullHD
        s.limitMB = 2048
        #expect(MotionCamera.command(on: true, settings: s) == [
            "am", "start", "-n", "com.universalkm.motion/.ControlActivity", "--ez", "on", "true",
            "--es", "sens", "low", "--ei", "stop", "20", "--es", "cam", "front", "--ei", "q", "1080",
            "--el", "limitMB", "2048"])
        #expect(MotionCamera.command(on: false, settings: nil).suffix(3) == ["--ez", "on", "false"])
        #expect(MotionCamera.statusCommand == ["content", "query", "--uri", "content://com.universalkm.motion/status"])
    }

    @Test func installErrors() {
        #expect(MotionCamera.needsConfirmationOnDevice("Failure [INSTALL_FAILED_USER_RESTRICTED: Install canceled by user]"))
        #expect(!MotionCamera.needsConfirmationOnDevice("Success"))
    }

    /// The versionCode the app ships with and the one in version.properties are the same
    /// (scripts/build-motion-apk.sh writes Resources/ukm-motion.version).
    @Test func bundledVersionMatchesSource() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let bundled = try String(contentsOf: root.appendingPathComponent("Resources/ukm-motion.version"), encoding: .utf8)
        let props = try String(contentsOf: root.appendingPathComponent("android/motion-camera/version.properties"), encoding: .utf8)
        let code = props.split(whereSeparator: \.isNewline).first { $0.hasPrefix("versionCode=") }?.dropFirst("versionCode=".count)
        #expect(bundled.trimmingCharacters(in: .whitespacesAndNewlines) == code.map(String.init))
    }
}
