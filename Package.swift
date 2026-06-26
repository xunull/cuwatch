// swift-tools-version: 5.10
import PackageDescription

// CuwatchCore is the headless business-logic library; the macOS app target
// (status item, popover, lifecycle) lives in cuwatch/cuwatch.xcodeproj because
// SwiftPM can't ship a proper .app bundle with embedded fonts + Info.plist +
// codesign + notarization. Run tests headlessly with `swift test`; build /
// run the menu bar app from Xcode.
let package = Package(
    name: "CuwatchCore",
    platforms: [
        .macOS(.v12)
    ],
    products: [
        .library(
            name: "CuwatchCore",
            targets: ["CuwatchCore"]
        ),
    ],
    targets: [
        .target(
            name: "CuwatchCore",
            path: "Sources/CuwatchCore",
            resources: [],
            linkerSettings: [
                // SQLite3 ships with macOS — used by CodexLogbookReader to
                // read `~/.codex/state_5.sqlite` for the Logbook panel.
                // Keeps the "no third-party deps" promise (system framework only).
                .linkedLibrary("sqlite3")
            ]
        ),
        .testTarget(
            name: "CuwatchCoreTests",
            dependencies: ["CuwatchCore"],
            path: "Tests/CuwatchCoreTests"
        ),
    ]
)
