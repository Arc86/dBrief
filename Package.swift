// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "dBrief",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/exPHAT/SwiftWhisper.git", from: "1.2.0"),
    ],
    targets: [
        .executableTarget(
            name: "dBrief",
            dependencies: [
                "SwiftWhisper",
            ],
            exclude: ["Resources", "Images"],
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("EventKit"),
                .linkedFramework("Security"),
            ]
        ),
    ]
)
