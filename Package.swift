// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Confluo",
    platforms: [.macOS("14.4")],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1")
    ],
    targets: [
        .target(
            name: "ConfluoDSP",
            path: "Sources/ConfluoDSP"
        ),
        .executableTarget(
            name: "Confluo",
            dependencies: [
                "ConfluoDSP",
                .product(name: "Sparkle", package: "Sparkle")
            ],
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
