import Foundation

/// Mouse buttons bitmask of the mouse input report.
public struct MouseButtons: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue & 0x1F }

    public static let left = MouseButtons(rawValue: 1 << 0)
    public static let right = MouseButtons(rawValue: 1 << 1)
    public static let middle = MouseButtons(rawValue: 1 << 2)
    public static let back = MouseButtons(rawValue: 1 << 3)
    public static let forward = MouseButtons(rawValue: 1 << 4)
}

/// Mouse input report (Report ID 2), 7 bytes without the report ID.
public struct MouseReport: Equatable, Sendable {
    public static let byteCount = 7
    public static let axisRange = -32767...32767
    public static let scrollRange = -127...127

    public var buttons: MouseButtons
    public var dx: Int16
    public var dy: Int16
    public var wheel: Int8
    public var pan: Int8

    public init(buttons: MouseButtons = [], dx: Int = 0, dy: Int = 0, wheel: Int = 0, pan: Int = 0) {
        self.buttons = buttons
        self.dx = Int16(dx.clamped(to: Self.axisRange))
        self.dy = Int16(dy.clamped(to: Self.axisRange))
        self.wheel = Int8(wheel.clamped(to: Self.scrollRange))
        self.pan = Int8(pan.clamped(to: Self.scrollRange))
    }

    public static let neutral = MouseReport()

    public var bytes: [UInt8] {
        let x = UInt16(bitPattern: dx)
        let y = UInt16(bitPattern: dy)
        return [
            buttons.rawValue,
            UInt8(x & 0xFF), UInt8(x >> 8),
            UInt8(y & 0xFF), UInt8(y >> 8),
            UInt8(bitPattern: wheel),
            UInt8(bitPattern: pan),
        ]
    }
}

/// Keyboard modifier bits (first byte of the keyboard input report).
public struct KeyboardModifiers: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let leftControl = KeyboardModifiers(rawValue: 1 << 0)
    public static let leftShift = KeyboardModifiers(rawValue: 1 << 1)
    public static let leftAlt = KeyboardModifiers(rawValue: 1 << 2)
    public static let leftGUI = KeyboardModifiers(rawValue: 1 << 3)
    public static let rightControl = KeyboardModifiers(rawValue: 1 << 4)
    public static let rightShift = KeyboardModifiers(rawValue: 1 << 5)
    public static let rightAlt = KeyboardModifiers(rawValue: 1 << 6)
    public static let rightGUI = KeyboardModifiers(rawValue: 1 << 7)

    /// Modifier bit for a HID usage 0xE0…0xE7, nil for other usages.
    public init?(usage: UInt8) {
        guard (0xE0...0xE7).contains(usage) else { return nil }
        self.init(rawValue: 1 << (usage - 0xE0))
    }
}

/// Keyboard input report (Report ID 1), 8 bytes without the report ID.
public struct KeyboardReport: Equatable, Sendable {
    public static let byteCount = 8
    public static let maxKeys = 6

    public var modifiers: KeyboardModifiers
    /// Up to 6 pressed key usages, in press order.
    public var keys: [UInt8]

    public init(modifiers: KeyboardModifiers = [], keys: [UInt8] = []) {
        self.modifiers = modifiers
        self.keys = Array(keys.prefix(Self.maxKeys))
    }

    public static let neutral = KeyboardReport()

    public var bytes: [UInt8] {
        var out: [UInt8] = [modifiers.rawValue, 0]
        out += keys
        out += [UInt8](repeating: 0, count: Self.maxKeys - keys.count)
        return out
    }
}

/// Pressed-key state of the virtual keyboard. Produces a report after every change.
public struct KeyboardState: Equatable, Sendable {
    public private(set) var modifiers: KeyboardModifiers = []
    public private(set) var keys: [UInt8] = []

    public init() {}

    public var report: KeyboardReport { KeyboardReport(modifiers: modifiers, keys: keys) }

    /// Applies a key press or release by HID usage. Returns false when nothing changed
    /// (repeat press, release of an unpressed key, or a seventh simultaneous key).
    @discardableResult
    public mutating func apply(usage: UInt8, isDown: Bool) -> Bool {
        if let modifier = KeyboardModifiers(usage: usage) {
            let before = modifiers
            if isDown { modifiers.insert(modifier) } else { modifiers.remove(modifier) }
            return before != modifiers
        }
        guard usage != 0 else { return false }
        if isDown {
            guard !keys.contains(usage), keys.count < KeyboardReport.maxKeys else { return false }
            keys.append(usage)
            return true
        }
        guard let index = keys.firstIndex(of: usage) else { return false }
        keys.remove(at: index)
        return true
    }

    public mutating func reset() {
        modifiers = []
        keys = []
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
