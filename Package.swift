// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "VoiceRecorder",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "VoiceRecorder",
            exclude: ["Resources/Info.plist"],
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("AVFoundation"),
            ]
        ),
    ]
)
