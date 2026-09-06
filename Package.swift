// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Cutaway",
    platforms: [.macOS(.v15)],
    products: [
        // Dynamic so the host can dlopen it. This is the whole trick: the app
        // bundle never changes, only this library does, so the TCC screen
        // recording grant stays valid across rebuilds.
        .library(name: "CutawayCore", type: .dynamic, targets: ["CutawayCore"]),
    ],
    targets: [
        .target(
            name: "CutawayCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "CutawayCoreTests",
            dependencies: ["CutawayCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "cutaway",
            // No link-time dependency on purpose: the host loads the library
            // at runtime so it never needs recompiling when the library changes.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
