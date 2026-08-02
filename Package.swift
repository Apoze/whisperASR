// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WhisperASR",
    platforms: [.macOS("15.0")],
    products: [
        .executable(name: "WhisperASR", targets: ["WhisperASRApp"]),
    ],
    dependencies: [
        // Lightweight, pure-Swift HTTP server (no transitive deps) used to expose
        // the local OpenAI-compatible transcription API.
        .package(url: "https://github.com/swhitty/FlyingFox.git", from: "0.26.0"),
        .package(
            url: "https://github.com/Blaizzy/mlx-audio-swift.git",
            exact: "0.1.3"
        ),
        .package(
            url: "https://github.com/ml-explore/mlx-swift",
            exact: "0.31.6"
        ),
        .package(
            url: "https://github.com/huggingface/swift-huggingface.git",
            exact: "0.9.0"
        ),
        .package(
            url: "https://github.com/FluidInference/FluidAudio.git",
            exact: "0.15.5"
        ),
        .package(path: "Vendor/SpeechSwiftPrototype"),
    ],
    targets: [
        .binaryTarget(
            name: "CWhisper",
            path: "Frameworks/CWhisper.xcframework"
        ),
        .executableTarget(
            name: "WhisperASRApp",
            dependencies: [
                "CWhisper",
                .product(name: "FlyingFox", package: "FlyingFox"),
                .product(name: "FlyingSocks", package: "FlyingFox"),
                .product(name: "Qwen3ASR", package: "SpeechSwiftPrototype"),
                .product(name: "SpeechVAD", package: "SpeechSwiftPrototype"),
                .product(name: "MLXAudioSTT", package: "mlx-audio-swift"),
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Sources",
            resources: [
                .copy("Runtime/VoxtralHelper"),
            ],
            linkerSettings: [
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("Accelerate"),
                .linkedFramework("Foundation"),
                .linkedLibrary("c++"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Speech"),
                .linkedFramework("Translation"),
            ]
        ),
        .testTarget(
            name: "WhisperASRTests",
            dependencies: [
                "CWhisper",
                "WhisperASRApp",
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXAudioSTT", package: "mlx-audio-swift"),
                .product(name: "Qwen3ASR", package: "SpeechSwiftPrototype"),
            ],
            path: "Tests"
        ),
    ]
)
