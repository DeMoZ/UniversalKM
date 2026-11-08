import Testing
@testable import UniversalKMCore

@Test func lettersMapToUsages() {
    #expect(KeyCodeMap.usage(forKeyCode: 0x00) == 0x04)   // A
    #expect(KeyCodeMap.usage(forKeyCode: 0x06) == 0x1D)   // Z
    #expect(KeyCodeMap.usage(forKeyCode: 0x04) == 0x0B)   // H
    #expect(KeyCodeMap.usage(forKeyCode: 0x1F) == 0x12)   // O
}

@Test func allLettersAreDistinctAndInRange() {
    let letterCodes: [UInt16] = [0x00, 0x0B, 0x08, 0x02, 0x0E, 0x03, 0x05, 0x04, 0x22, 0x26, 0x28, 0x25, 0x2E,
                                 0x2D, 0x1F, 0x23, 0x0C, 0x0F, 0x01, 0x11, 0x20, 0x09, 0x0D, 0x07, 0x10, 0x06]
    let usages = letterCodes.compactMap { KeyCodeMap.usage(forKeyCode: $0) }
    #expect(usages == Array(0x04...0x1D))
}

@Test func digitsMapToUsages() {
    #expect(KeyCodeMap.usage(forKeyCode: 0x12) == 0x1E)   // 1
    #expect(KeyCodeMap.usage(forKeyCode: 0x19) == 0x26)   // 9
    #expect(KeyCodeMap.usage(forKeyCode: 0x1D) == 0x27)   // 0
}

@Test func functionKeysF1toF12() {
    let codes: [UInt16] = [0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D, 0x67, 0x6F]
    #expect(codes.compactMap { KeyCodeMap.usage(forKeyCode: $0) } == Array(0x3A...0x45))
}

@Test func arrowsAndEditingKeys() {
    #expect(KeyCodeMap.usage(forKeyCode: 0x7C) == 0x4F)   // Right
    #expect(KeyCodeMap.usage(forKeyCode: 0x7B) == 0x50)   // Left
    #expect(KeyCodeMap.usage(forKeyCode: 0x7D) == 0x51)   // Down
    #expect(KeyCodeMap.usage(forKeyCode: 0x7E) == 0x52)   // Up
    #expect(KeyCodeMap.usage(forKeyCode: 0x24) == 0x28)   // Return
    #expect(KeyCodeMap.usage(forKeyCode: 0x35) == 0x29)   // Esc
    #expect(KeyCodeMap.usage(forKeyCode: 0x30) == 0x2B)   // Tab
    #expect(KeyCodeMap.usage(forKeyCode: 0x33) == 0x2A)   // Delete → Backspace
    #expect(KeyCodeMap.usage(forKeyCode: 0x75) == 0x4C)   // Forward Delete
}

@Test func allEightModifiers() {
    let modifiers: [(UInt16, UInt8)] = [(0x3B, 0xE0), (0x38, 0xE1), (0x3A, 0xE2), (0x37, 0xE3),
                                        (0x3E, 0xE4), (0x3C, 0xE5), (0x3D, 0xE6), (0x36, 0xE7)]
    for (code, usage) in modifiers {
        #expect(KeyCodeMap.usage(forKeyCode: code) == usage)
        #expect(KeyCodeMap.isModifier(code))
    }
    #expect(!KeyCodeMap.isModifier(0x00))
    #expect(!KeyCodeMap.isModifier(0x39))                  // Caps Lock is a normal key in HID
    #expect(KeyCodeMap.usage(forKeyCode: 0x39) == 0x39)
}

@Test func unmappedKeyReturnsNil() {
    #expect(KeyCodeMap.usage(forKeyCode: 0x3F) == nil)    // Fn
    #expect(KeyCodeMap.usage(forKeyCode: 0xFF) == nil)
}

@Test func noTwoKeyCodesShareAUsage() {
    let usages = Array(KeyCodeMap.table.values)
    #expect(Set(usages).count == usages.count)
}
