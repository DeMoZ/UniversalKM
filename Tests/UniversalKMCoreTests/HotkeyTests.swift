import Foundation
import Testing
@testable import UniversalKMCore

private let control: UInt64 = 0x0004_0000
private let option: UInt64 = 0x0008_0000
private let command: UInt64 = 0x0010_0000
private let shift: UInt64 = 0x0002_0000
private let capsLock: UInt64 = 0x0001_0000
private let fn: UInt64 = 0x0080_0000

@Test func defaultIsControlOptionCommandEsc() {
    #expect(Hotkey.default.keyCode == 0x35)
    #expect(Hotkey.default.modifiers == [.control, .option, .command])
    #expect(Hotkey.default.isValid)
    #expect(Hotkey.default.modifiers.symbols == "⌃⌥⌘")
}

@Test func escWithoutModifiersOrWithShiftIsInvalid() {
    #expect(!Hotkey(keyCode: 0x35, modifiers: []).isValid)
    #expect(!Hotkey(keyCode: 0x35, modifiers: [.shift]).isValid)
    #expect(Hotkey(keyCode: 0x33, modifiers: [.option, .command]).isValid)   // ⌥⌘⌫
}

@Test func modifierKeyAloneIsInvalid() {
    #expect(!Hotkey(keyCode: 0x37, modifiers: [.control]).isValid)   // Command key itself
    #expect(!Hotkey(keyCode: 0x39, modifiers: [.control]).isValid)   // Caps Lock
}

@Test func matchesExactModifiers() {
    let hotkey = Hotkey.default
    #expect(hotkey.matches(keyCode: 0x35, cgEventFlags: control | option | command))
    #expect(!hotkey.matches(keyCode: 0x35, cgEventFlags: control | option | command | shift))   // extra modifier
    #expect(!hotkey.matches(keyCode: 0x35, cgEventFlags: control | command))                   // missing one
    #expect(!hotkey.matches(keyCode: 0x33, cgEventFlags: control | option | command))           // other key
}

@Test func capsLockAndFnAreIgnored() {
    #expect(Hotkey.default.matches(keyCode: 0x35, cgEventFlags: control | option | command | capsLock))
    #expect(Hotkey.default.matches(keyCode: 0x35, cgEventFlags: control | option | command | fn))
}

@Test func codableRoundTrip() throws {
    let hotkey = Hotkey(keyCode: 0x33, modifiers: [.option, .command])
    let data = try JSONEncoder().encode(hotkey)
    #expect(try JSONDecoder().decode(Hotkey.self, from: data) == hotkey)
}
