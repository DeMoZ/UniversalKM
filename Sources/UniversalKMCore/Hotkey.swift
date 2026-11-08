import Foundation

/// Modifiers of the return-to-Mac hotkey (design D11).
public struct HotkeyModifiers: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let control = HotkeyModifiers(rawValue: 1 << 0)
    public static let option = HotkeyModifiers(rawValue: 1 << 1)
    public static let command = HotkeyModifiers(rawValue: 1 << 2)
    public static let shift = HotkeyModifiers(rawValue: 1 << 3)

    // CGEventFlags masks (CoreGraphics), kept here so Core needs no CoreGraphics.
    static let cgShift: UInt64 = 0x0002_0000
    static let cgControl: UInt64 = 0x0004_0000
    static let cgOption: UInt64 = 0x0008_0000
    static let cgCommand: UInt64 = 0x0010_0000

    /// From CGEventFlags; Caps Lock, Fn, keypad and device-dependent bits are ignored.
    public init(cgEventFlags flags: UInt64) {
        var result: HotkeyModifiers = []
        if flags & Self.cgControl != 0 { result.insert(.control) }
        if flags & Self.cgOption != 0 { result.insert(.option) }
        if flags & Self.cgCommand != 0 { result.insert(.command) }
        if flags & Self.cgShift != 0 { result.insert(.shift) }
        self = result
    }

    /// "⌃⌥⇧⌘" in the order macOS menus use.
    public var symbols: String {
        (contains(.control) ? "⌃" : "") + (contains(.option) ? "⌥" : "")
            + (contains(.shift) ? "⇧" : "") + (contains(.command) ? "⌘" : "")
    }
}

/// Return-to-Mac hotkey: a key plus an exact set of modifiers (design D11).
public struct Hotkey: Codable, Hashable, Sendable {
    public var keyCode: UInt16
    public var modifiers: HotkeyModifiers

    public init(keyCode: UInt16, modifiers: HotkeyModifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// Control + Option + Command + Esc.
    public static let `default` = Hotkey(keyCode: 0x35, modifiers: [.control, .option, .command])

    /// Valid when the key is not itself a modifier and at least one of Control, Option, Command is held
    /// (Shift alone would collide with typing on the device).
    public var isValid: Bool {
        !KeyCodeMap.isModifier(keyCode) && keyCode != 0x39 && keyCode != 0x3F
            && !modifiers.isDisjoint(with: [.control, .option, .command])
    }

    /// A keyDown with this key code and exactly these modifiers (by CGEventFlags).
    public func matches(keyCode: UInt16, cgEventFlags flags: UInt64) -> Bool {
        keyCode == self.keyCode && HotkeyModifiers(cgEventFlags: flags) == modifiers
    }
}
