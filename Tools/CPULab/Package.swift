// swift-tools-version: 6.0
// Pass 58: the app's CPU read (llama.cpp, Packages/LlamaCPU) on the Mac, with
// the app's own prompts (JudgePrompt), on his transcripts: speed paced or
// full, and whether every part's answer reads.
//   swift build -c release && .build/release/cpu-lab <results.json> <episode index>
//   LAB_GGUF=<file> LAB_THREADS=2 LAB_PACE=0.45 LAB_ONLY="s-e,…" LAB_OUT=cuts.json
import PackageDescription

let package = Package(
    name: "cpu-lab",
    platforms: [.macOS("15.0")],
    dependencies: [.package(path: "../../Packages/LlamaCPU")],
    targets: [
        .executableTarget(name: "cpu-lab", dependencies: [.product(name: "LlamaCPU", package: "LlamaCPU")],
                          swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
