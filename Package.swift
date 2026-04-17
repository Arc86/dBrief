// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "dBrief",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.18.0"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", from: "2.29.1"),
        .package(url: "https://github.com/apple/swift-testing.git", from: "0.6.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.13.6"),
    ],
    targets: [
        .executableTarget(
            name: "dBrief",
            dependencies: [
                "WhisperKit",
                .product(name: "SpeakerKit", package: "WhisperKit"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                "FluidAudio",
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
