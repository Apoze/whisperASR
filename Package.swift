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
            ],
            path: "Sources",
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
            dependencies: ["WhisperASRApp"],
            path: "Tests"
        ),
    ]
)
