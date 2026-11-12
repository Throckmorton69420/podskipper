// swift-tools-version:6.0
// Pass 58: llama.cpp (release b12283 since Pass 63) built from source by
// Scripts/build-llama.sh into llama.xcframework here (git-ignored), used
// CPU-only so a model can read while PodSkipper isn't on screen — iOS refuses
// the GPU to an app in the background unless it is signed with Background GPU
// Access. Not llama.cpp's own Apple release: that is compiled for the oldest
// ARM (no dot-product instructions in its iOS slice) and read Qwen3.5 4B at
// 1.3 tokens/s on the Mac where a native build reads ~20. Device and Mac
// slices only, so the app's simulator build leaves this package out
// (Scripts/generate-project.sh).
import PackageDescription

let package = Package(
    name: "LlamaCPU",
    platforms: [.iOS("18.0"), .macOS("15.0")],
    products: [.library(name: "LlamaCPU", targets: ["LlamaCPU"])],
    targets: [
        .binaryTarget(name: "llama", path: "llama.xcframework"),
        .target(name: "LlamaCPU", dependencies: ["llama"], path: "Sources/LlamaCPU"),
    ]
)
