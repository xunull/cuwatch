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
            resources: []
        ),
        .testTarget(
            name: "CuwatchCoreTests",
            dependencies: ["CuwatchCore"],
            path: "Tests/CuwatchCoreTests"
        ),
    ]
)
