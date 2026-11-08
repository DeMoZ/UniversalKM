// UniversalKM HID mode for ChameleonUltra: Report Map of the composite keyboard + mouse (design D4).
// SPDX-License-Identifier: GPL-3.0-or-later
//
// The single source of these bytes. The macOS app keeps the same array in
// HIDReportDescriptor.reportMap, and a unit test compares the two byte for byte:
// it reads every 0xNN literal between the UKM_REPORT_MAP_BEGIN / _END markers.
//
// Report 1 (keyboard), input, 8 bytes:  modifiers, reserved, 6 key codes.
// Report 1 (keyboard), output, 1 byte:  5 LED bits + 3 padding bits.
// Report 2 (mouse), input, 7 bytes:     5 buttons + 3 padding bits, X int16 LE, Y int16 LE (relative),
//                                       wheel int8, AC Pan int8.
#ifndef UKM_REPORT_MAP_H
#define UKM_REPORT_MAP_H

#include <stdint.h>

#define UKM_REPORT_ID_KEYBOARD      1
#define UKM_REPORT_ID_MOUSE         2
#define UKM_KEYBOARD_INPUT_LEN      8
#define UKM_KEYBOARD_OUTPUT_LEN     1
#define UKM_MOUSE_INPUT_LEN         7

// UKM_REPORT_MAP_BEGIN
static uint8_t ukm_report_map[] = {
    // Keyboard
    0x05, 0x01,         // Usage Page (Generic Desktop)
    0x09, 0x06,         // Usage (Keyboard)
    0xA1, 0x01,         // Collection (Application)
    0x85, 0x01,         //   Report ID (1)
    0x05, 0x07,         //   Usage Page (Keyboard/Keypad)
    0x19, 0xE0,         //   Usage Minimum (Left Control)
    0x29, 0xE7,         //   Usage Maximum (Right GUI)
    0x15, 0x00,         //   Logical Minimum (0)
    0x25, 0x01,         //   Logical Maximum (1)
    0x75, 0x01,         //   Report Size (1)
    0x95, 0x08,         //   Report Count (8)
    0x81, 0x02,         //   Input (Data, Variable, Absolute): modifiers
    0x95, 0x01,         //   Report Count (1)
    0x75, 0x08,         //   Report Size (8)
    0x81, 0x01,         //   Input (Constant): reserved byte
    0x95, 0x05,         //   Report Count (5)
    0x75, 0x01,         //   Report Size (1)
    0x05, 0x08,         //   Usage Page (LEDs)
    0x19, 0x01,         //   Usage Minimum (Num Lock)
    0x29, 0x05,         //   Usage Maximum (Kana)
    0x91, 0x02,         //   Output (Data, Variable, Absolute): LEDs
    0x95, 0x01,         //   Report Count (1)
    0x75, 0x03,         //   Report Size (3)
    0x91, 0x01,         //   Output (Constant): padding
    0x95, 0x06,         //   Report Count (6)
    0x75, 0x08,         //   Report Size (8)
    0x15, 0x00,         //   Logical Minimum (0)
    0x25, 0x65,         //   Logical Maximum (101)
    0x05, 0x07,         //   Usage Page (Keyboard/Keypad)
    0x19, 0x00,         //   Usage Minimum (0)
    0x29, 0x65,         //   Usage Maximum (101)
    0x81, 0x00,         //   Input (Data, Array, Absolute): 6 keys
    0xC0,               // End Collection

    // Mouse
    0x05, 0x01,         // Usage Page (Generic Desktop)
    0x09, 0x02,         // Usage (Mouse)
    0xA1, 0x01,         // Collection (Application)
    0x85, 0x02,         //   Report ID (2)
    0x09, 0x01,         //   Usage (Pointer)
    0xA1, 0x00,         //   Collection (Physical)
    0x05, 0x09,         //     Usage Page (Button)
    0x19, 0x01,         //     Usage Minimum (1)
    0x29, 0x05,         //     Usage Maximum (5)
    0x15, 0x00,         //     Logical Minimum (0)
    0x25, 0x01,         //     Logical Maximum (1)
    0x95, 0x05,         //     Report Count (5)
    0x75, 0x01,         //     Report Size (1)
    0x81, 0x02,         //     Input (Data, Variable, Absolute): buttons
    0x95, 0x01,         //     Report Count (1)
    0x75, 0x03,         //     Report Size (3)
    0x81, 0x01,         //     Input (Constant): padding
    0x05, 0x01,         //     Usage Page (Generic Desktop)
    0x09, 0x30,         //     Usage (X)
    0x09, 0x31,         //     Usage (Y)
    0x16, 0x01, 0x80,   //     Logical Minimum (-32767)
    0x26, 0xFF, 0x7F,   //     Logical Maximum (32767)
    0x75, 0x10,         //     Report Size (16)
    0x95, 0x02,         //     Report Count (2)
    0x81, 0x06,         //     Input (Data, Variable, Relative): X, Y
    0x09, 0x38,         //     Usage (Wheel)
    0x15, 0x81,         //     Logical Minimum (-127)
    0x25, 0x7F,         //     Logical Maximum (127)
    0x75, 0x08,         //     Report Size (8)
    0x95, 0x01,         //     Report Count (1)
    0x81, 0x06,         //     Input (Data, Variable, Relative): wheel
    0x05, 0x0C,         //     Usage Page (Consumer)
    0x0A, 0x38, 0x02,   //     Usage (AC Pan)
    0x95, 0x01,         //     Report Count (1)
    0x81, 0x06,         //     Input (Data, Variable, Relative): horizontal scroll
    0xC0,               //   End Collection
    0xC0,               // End Collection
};
// UKM_REPORT_MAP_END

#endif // UKM_REPORT_MAP_H
