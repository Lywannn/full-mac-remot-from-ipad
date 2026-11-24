// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ipadmode",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "CPrivateDisplay",
            linkerSettings: [.linkedFramework("CoreGraphics"), .linkedFramework("Foundation")]
        ),
        .target(name: "IPadModeCore"),
        .target(
            name: "IPadModeSystem",
            dependencies: ["IPadModeCore", "CPrivateDisplay"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("Carbon")]
        ),
        .executableTarget(
            name: "ipadmode",
            dependencies: ["IPadModeSystem"],
            path: "Sources/ipadmode",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "ipadmode-spike",
            dependencies: ["CPrivateDisplay"],
            path: "spikes/ipadmode-spike",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "IPadModeCoreTests",
            dependencies: ["IPadModeCore"]
        ),
        .testTarget(
            name: "IPadModeSystemTests",
            dependencies: ["IPadModeSystem"]
        ),
    ]
)
