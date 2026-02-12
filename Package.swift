// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "dBrief",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/exPHAT/SwiftWhisper.git", from: "1.2.0"),
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.4"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", from: "2.29.1"),
        .package(url: "https://github.com/apple/swift-testing.git", from: "0.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "dBrief",
            dependencies: [
                "SwiftWhisper",
                "WhisperKit",
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
            ],
            exclude: ["Resources", "Images"],
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("EventKit"),
                .linkedFramework("Security"),
            ]
        ),
        .testTarget(
            name: "dBriefTests",
            dependencies: [
                "dBrief",
                .product(name: "Testing", package: "swift-testing"),
            ]
        ),
    ]
)
