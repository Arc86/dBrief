// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "dBrief",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "1.1.0"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", from: "3.31.4"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.4"),
        .package(url: "https://github.com/apple/swift-testing.git", from: "6.3.2"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.15.6"),
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.9.6"),
    ],
    targets: [
        .target(
            name: "dBriefWire"
        ),
        .executableTarget(
            name: "dBriefMLHost",
            dependencies: [
                "dBriefWire",
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
                .product(name: "SpeakerKit", package: "argmax-oss-swift"),
                .product(name: "TTSKit", package: "argmax-oss-swift"),
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
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            exclude: ["Resources"],
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("EventKit"),
                .linkedFramework("Security"),
                .linkedFramework("ServiceManagement"),
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
