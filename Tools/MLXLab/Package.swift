// swift-tools-version: 6.2
// Pass 40: the app's MLX read path (PromptPrefixCache, the held-to-the-format
// loop with kv8 and 256-token `.remainder` prefill, JudgePrompt) on the Mac,
// so prompt reuse, answers that run out of room and prefill settings can be
// compared on his transcripts before a build reaches the phone.
//
// Build with xcodebuild (SwiftPM alone doesn't compile MLX's Metal kernels):
//   xcodebuild -scheme mlx-lab -destination 'platform=macOS' -derivedDataPath ../../build/mlxlab-dd build
// Uses the app's pinned package checkouts in build/DerivedData.
import PackageDescription

let checkouts = "../../build/DerivedData/SourcePackages/checkouts/"
let package = Package(
    name: "mlx-lab",
    platforms: [.macOS("15.0")],
    dependencies: [
        .package(path: checkouts + "mlx-swift"),
        .package(path: checkouts + "mlx-swift-lm"),
        .package(path: checkouts + "swift-transformers"),
    ],
    targets: [
        .executableTarget(
            name: "mlx-lab",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXGuidedGeneration", package: "mlx-swift-lm"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
