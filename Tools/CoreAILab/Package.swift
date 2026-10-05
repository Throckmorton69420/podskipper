// swift-tools-version: 6.1
// Pass 30: the app's own Core AI ad reader (CoreAIClassifierSession +
// JudgePrompt, linked from Services/) run on the Mac against the lab's
// labelled fixtures, so prompts and models can be compared on his shows
// before a build reaches the phone.
//
//   swift run -c release coreai-lab <bundle dir> <fixture> [lean|compact|full] [engine hint]
//
// COREAI_LAB_IOS_CAP=1 holds GPU-pipelined bundles to iPhone's 1,024 tokens.
import PackageDescription

let package = Package(
    name: "coreai-lab",
    platforms: [.macOS("27.0")],
    dependencies: [
        .package(path: "../../build/DerivedData/SourcePackages/checkouts/coreai-kit"),
    ],
    targets: [
        .executableTarget(
            name: "coreai-lab",
            dependencies: [.product(name: "CoreAIKit", package: "coreai-kit")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
