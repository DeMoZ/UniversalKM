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

@Test func batteryAlert() {
    #expect(AndroidBattery(percent: 21, state: .discharging).alert == nil)
    #expect(AndroidBattery(percent: 20, state: .discharging).alert == .low)
    #expect(AndroidBattery(percent: 11, state: .discharging).alert == .low)
    #expect(AndroidBattery(percent: 10, state: .discharging).alert == .critical)
    #expect(AndroidBattery(percent: 0, state: .discharging).alert == .critical)
    // On the charger nothing, even when it does not take charge.
    #expect(AndroidBattery(percent: 5, state: .charging).alert == nil)
    #expect(AndroidBattery(percent: 5, state: .notCharging).alert == nil)
}

@Test func batteryLowest() {
    let list: [(id: Int, battery: AndroidBattery)] = [
        (1, AndroidBattery(percent: 18, state: .discharging)),
        (2, AndroidBattery(percent: 3, state: .charging)),
        (3, AndroidBattery(percent: 12, state: .discharging)),
        (4, AndroidBattery(percent: 80, state: .discharging)),
    ]
    #expect(AndroidBattery.lowest(list)?.id == 3)
    #expect(AndroidBattery.lowest([(id: 4, battery: AndroidBattery(percent: 80, state: .discharging))]) == nil)
}
