// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "dBrief",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.18.0"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", from: "3.0.0"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.1.6"),
        .package(url: "https://github.com/apple/swift-testing.git", from: "0.6.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.13.6"),
    ],
    targets: [
        .target(
            name: "dBriefWire"
        ),
        .executableTarget(
            name: "dBriefMLHost",
            dependencies: [
                "dBriefWire",
                "WhisperKit",
                .product(name: "SpeakerKit", package: "WhisperKit"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                "FluidAudio",
                .product(name: "Hub", package: "swift-transformers"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ]
        ),
        .executableTarget(
            name: "dBriefMLHostStub",
            dependencies: ["dBriefWire"]
        ),
        .executableTarget(
            name: "dBrief",
            dependencies: [
                "dBriefWire",
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
                "dBriefWire",
                .product(name: "Testing", package: "swift-testing"),
            ]
        ),
        .testTarget(
            name: "dBriefMLHostTests",
            dependencies: [
                "dBriefMLHost",
                "dBriefWire",
                "FluidAudio",
                .product(name: "Testing", package: "swift-testing"),
            ]
        ),
    ]
)
