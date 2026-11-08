// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "UniversalKM",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "UniversalKM", targets: ["UniversalKM"]),
        .library(name: "UniversalKMCore", targets: ["UniversalKMCore"]),
    ],
    dependencies: [
        // App updates: "Обновления" button and automatic checks, EdDSA-signed appcast in each release (design D17).
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        // Pure logic: HID descriptors and report encoding, key maps, arrangement,
        // state machine. No I/O and no event taps, so it is unit-testable.
        .target(name: "UniversalKMCore"),
        // The menu bar app: event tap, Chameleon transport, SwiftUI panel, Sparkle updates.
        .executableTarget(
            name: "UniversalKM",
            dependencies: ["UniversalKMCore", .product(name: "Sparkle", package: "Sparkle")]
        ),
        .testTarget(
            name: "UniversalKMCoreTests",
            dependencies: ["UniversalKMCore"],
            // Read through #filePath, not bundled.
            exclude: ["Fixtures"]
        ),
    ]
)
