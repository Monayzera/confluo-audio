// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Confluo",
    platforms: [.macOS("14.4")],
    targets: [
        .target(
            name: "ConfluoDSP",
            path: "Sources/ConfluoDSP"
        ),
        .executableTarget(
            name: "Confluo",
            dependencies: ["ConfluoDSP"],
            path: "Sources/Confluo",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("Network"),
                .linkedFramework("Security"),
                .linkedFramework("Carbon"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("UserNotifications")
            ]
        ),
        .testTarget(
            name: "ConfluoTests",
            dependencies: ["Confluo", "ConfluoDSP"],
            path: "Tests/ConfluoTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
