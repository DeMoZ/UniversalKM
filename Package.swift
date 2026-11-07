// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "UniversalKM",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "UniversalKM", targets: ["UniversalKM"]),
        .library(name: "UniversalKMCore", targets: ["UniversalKMCore"]),
    ],
    targets: [
        // Pure logic: HID descriptors and report encoding, key maps, arrangement,
        // state machine. No CoreBluetooth and no event taps, so it is unit-testable.
        .target(name: "UniversalKMCore"),
        // Tiny Objective-C helper: catches NSExceptions raised by CoreBluetooth.
        .target(name: "ObjCSupport"),
        // The menu bar app: CoreBluetooth peripheral, event tap, SwiftUI.
        .executableTarget(
            name: "UniversalKM",
            dependencies: ["UniversalKMCore", "ObjCSupport"]
        ),
        .testTarget(
            name: "UniversalKMCoreTests",
            dependencies: ["UniversalKMCore"],
            // Read through #filePath, not bundled.
            exclude: ["Fixtures"]
        ),
    ]
)
