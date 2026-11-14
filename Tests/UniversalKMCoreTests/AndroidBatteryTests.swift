import Testing
@testable import UniversalKMCore

private func dump(ac: Bool = false, usb: Bool = false, status: Int, level: Int, scale: Int = 100) -> String {
    """
    Current Battery Service state:
      AC powered: \(ac)
      USB powered: \(usb)
      Wireless powered: false
      Dock powered: false
      Max charging current: 0
      status: \(status)
      health: 2
      present: true
      level: \(level)
      scale: \(scale)
      voltage: 4123
      temperature: 285
      technology: Li-ion
    """
}

@Test func batteryChargingOnUSB() {
    #expect(AndroidBattery.parse(dump(usb: true, status: 2, level: 85)) == AndroidBattery(percent: 85, state: .charging))
}

@Test func batteryDischarging() {
    let battery = AndroidBattery.parse(dump(status: 3, level: 42))
    #expect(battery == AndroidBattery(percent: 42, state: .discharging))
    #expect(battery?.isPlugged == false)
}

@Test func batteryFullAndNotCharging() {
    #expect(AndroidBattery.parse(dump(ac: true, status: 5, level: 100))?.state == .full)
    #expect(AndroidBattery.parse(dump(ac: true, status: 4, level: 85))?.state == .notCharging)
    // "full" or "not charging" without a charger is just on battery.
    #expect(AndroidBattery.parse(dump(status: 5, level: 100))?.state == .discharging)
}

@Test func batteryScale() {
    #expect(AndroidBattery.parse(dump(status: 3, level: 50, scale: 200))?.percent == 25)
}

@Test func batteryFirstBatteryWins() {
    let output = dump(usb: true, status: 2, level: 70) + "\n  level: 10\n"
    #expect(AndroidBattery.parse(output)?.percent == 70)
}

@Test func batteryGarbage() {
    #expect(AndroidBattery.parse("") == nil)
    #expect(AndroidBattery.parse("Can't find service: battery") == nil)
}
