import Foundation

/// HID over GATT layout of the composite keyboard + mouse device (design D3, D4).
public enum HIDReportID {
    public static let keyboard: UInt8 = 1
    public static let mouse: UInt8 = 2
}

/// Value of the Report Reference descriptor (0x2908): report type.
public enum HIDReportType: UInt8 {
    case input = 1
    case output = 2
    case feature = 3
}

public enum HIDReportDescriptor {
    /// Report Map characteristic (0x2A4B) value.
    ///
    /// Report 1 (keyboard), input, 8 bytes: modifiers, reserved, 6 key codes.
    /// Report 1 (keyboard), output, 1 byte: 5 LED bits + 3 padding bits.
    /// Report 2 (mouse), input, 7 bytes: 5 buttons + 3 padding bits,
    ///   X int16 LE, Y int16 LE (relative), wheel int8, AC Pan int8.
    public static let reportMap: [UInt8] = keyboard + mouse

    static let keyboard: [UInt8] = [
        0x05, 0x01,       // Usage Page (Generic Desktop)
        0x09, 0x06,       // Usage (Keyboard)
        0xA1, 0x01,       // Collection (Application)
        0x85, HIDReportID.keyboard, // Report ID (1)
        // Modifiers: 8 bits, Left Control … Right GUI.
        0x05, 0x07,       //   Usage Page (Keyboard/Keypad)
        0x19, 0xE0,       //   Usage Minimum (Left Control)
        0x29, 0xE7,       //   Usage Maximum (Right GUI)
        0x15, 0x00,       //   Logical Minimum (0)
        0x25, 0x01,       //   Logical Maximum (1)
        0x75, 0x01,       //   Report Size (1)
        0x95, 0x08,       //   Report Count (8)
        0x81, 0x02,       //   Input (Data, Variable, Absolute)
        // Reserved byte.
        0x95, 0x01,       //   Report Count (1)
        0x75, 0x08,       //   Report Size (8)
        0x81, 0x01,       //   Input (Constant)
        // LEDs: 5 bits + 3 bits padding (output report).
        0x95, 0x05,       //   Report Count (5)
        0x75, 0x01,       //   Report Size (1)
        0x05, 0x08,       //   Usage Page (LEDs)
        0x19, 0x01,       //   Usage Minimum (Num Lock)
        0x29, 0x05,       //   Usage Maximum (Kana)
        0x91, 0x02,       //   Output (Data, Variable, Absolute)
        0x95, 0x01,       //   Report Count (1)
        0x75, 0x03,       //   Report Size (3)
        0x91, 0x01,       //   Output (Constant)
        // Key array: 6 keys.
        0x95, 0x06,       //   Report Count (6)
        0x75, 0x08,       //   Report Size (8)
        0x15, 0x00,       //   Logical Minimum (0)
        0x25, 0x65,       //   Logical Maximum (101)
        0x05, 0x07,       //   Usage Page (Keyboard/Keypad)
        0x19, 0x00,       //   Usage Minimum (0)
        0x29, 0x65,       //   Usage Maximum (101)
        0x81, 0x00,       //   Input (Data, Array, Absolute)
        0xC0,             // End Collection
    ]

    static let mouse: [UInt8] = [
        0x05, 0x01,       // Usage Page (Generic Desktop)
        0x09, 0x02,       // Usage (Mouse)
        0xA1, 0x01,       // Collection (Application)
        0x85, HIDReportID.mouse, // Report ID (2)
        0x09, 0x01,       //   Usage (Pointer)
        0xA1, 0x00,       //   Collection (Physical)
        // Buttons 1…5 + 3 bits padding.
        0x05, 0x09,       //     Usage Page (Button)
        0x19, 0x01,       //     Usage Minimum (1)
        0x29, 0x05,       //     Usage Maximum (5)
        0x15, 0x00,       //     Logical Minimum (0)
        0x25, 0x01,       //     Logical Maximum (1)
        0x95, 0x05,       //     Report Count (5)
        0x75, 0x01,       //     Report Size (1)
        0x81, 0x02,       //     Input (Data, Variable, Absolute)
        0x95, 0x01,       //     Report Count (1)
        0x75, 0x03,       //     Report Size (3)
        0x81, 0x01,       //     Input (Constant)
        // X, Y: int16, relative.
        0x05, 0x01,       //     Usage Page (Generic Desktop)
        0x09, 0x30,       //     Usage (X)
        0x09, 0x31,       //     Usage (Y)
        0x16, 0x01, 0x80, //     Logical Minimum (-32767)
        0x26, 0xFF, 0x7F, //     Logical Maximum (32767)
        0x75, 0x10,       //     Report Size (16)
        0x95, 0x02,       //     Report Count (2)
        0x81, 0x06,       //     Input (Data, Variable, Relative)
        // Vertical wheel: int8, relative.
        0x09, 0x38,       //     Usage (Wheel)
        0x15, 0x81,       //     Logical Minimum (-127)
        0x25, 0x7F,       //     Logical Maximum (127)
        0x75, 0x08,       //     Report Size (8)
        0x95, 0x01,       //     Report Count (1)
        0x81, 0x06,       //     Input (Data, Variable, Relative)
        // Horizontal scroll: AC Pan, int8, relative.
        0x05, 0x0C,       //     Usage Page (Consumer)
        0x0A, 0x38, 0x02, //     Usage (AC Pan)
        0x95, 0x01,       //     Report Count (1)
        0x81, 0x06,       //     Input (Data, Variable, Relative)
        0xC0,             //   End Collection
        0xC0,             // End Collection
    ]

    /// HID Information characteristic (0x2A4A): bcdHID 1.11, country 0,
    /// flags = NormallyConnectable (bit 1).
    public static let hidInformation: [UInt8] = [0x11, 0x01, 0x00, 0x02]

    /// PnP ID (0x2A50) the firmware publishes: vendor ID source 0x02 (USB-IF), the ChameleonUltra
    /// USB VID 0x6868 / PID 0x8686, version 1 (all little-endian), see firmware/src/ukm_hid.c.
    public static let pnpID: [UInt8] = [0x02, 0x68, 0x68, 0x86, 0x86, 0x01, 0x00]
}
