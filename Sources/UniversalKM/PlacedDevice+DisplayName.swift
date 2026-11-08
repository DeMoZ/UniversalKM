import Foundation
import UniversalKMCore

extension PlacedDevice {
    /// Default names written by earlier versions, in the language the interface had then.
    private static let legacyDefaultNames: Set<String> = ["Телефон", "Планшет", "Phone", "Tablet"]

    /// The name shown in the panel. A device the user did not name is called by its kind in the interface
    /// language, so the label follows a language change.
    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard trimmed.isEmpty || Self.legacyDefaultNames.contains(trimmed) else { return name }
        return kind == .phone ? String(localized: "Phone") : String(localized: "Tablet")
    }
}
