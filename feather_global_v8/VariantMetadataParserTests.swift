import Foundation

@MainActor private final class Heartbeat { var beats = 0 }

@main
private struct VariantMetadataParserTests {
	static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
		if !condition() { fatalError(message) }
	}
	static func input(_ name: String?, subtitle: String? = nil, description: String? = nil, notes: String? = nil) -> VariantMetadataInput {
		VariantMetadataInput(name: name, subtitle: subtitle, description: description,
			localizedDescription: nil, versionDescription: nil, releaseNotes: notes, downloadURL: nil)
	}
	@MainActor static func main() async {
		require(VariantMetadataParser.parse(input("BHTikTokPlus [BHTikTok]")).primaryCanonical == "bhtiktokplus", "Prefer the specific TikTok variant")
		require(VariantMetadataParser.parse(input("YouTube", subtitle: "YTPlusYTweaks")).primaryCanonical == "ytplusytweaks", "Prefer the specific YouTube variant")
		require(VariantMetadataParser.parse(input("YouTube", notes: "Variant: 21.39.4 YouMod 2.0.0")).primaryCanonical == "youmod", "Release-note variant evidence must remain supported")
		require(VariantMetadataParser.parse(input("TikTok (RX)")).primaryCanonical == "rxtiktok", "Compact variant codes must remain supported")
		require(VariantMetadataParser.parse(input("YouTube")).primaryCanonical == nil, "A generic title must not invent a variant")
		require(VariantMetadataParser.parse(input("TikTok", subtitle: "BHTikTok RusTikTok")).primaryCanonical == nil, "Conflicting evidence must remain ambiguous")
		let heartbeat = Heartbeat()
		let ticker = Task { @MainActor in
			while !Task.isCancelled {
				heartbeat.beats += 1
				try? await Task.sleep(nanoseconds: 1_000_000)
			}
		}
		let large = input("YouTube", description: String(repeating: "This is a long release description. ", count: 15000) + " Variant: YouMod 2.0.0")
		let began = ProcessInfo.processInfo.systemUptime
		let result = await Task.detached(priority: .utility) {
			require(!Thread.isMainThread, "Metadata parsing must execute away from the UI thread")
			return VariantMetadataParser.parse(large)
		}.value
		ticker.cancel()
		require(result.primaryCanonical == "youmod", "Large descriptions must retain variant evidence, including at the end")
		require(heartbeat.beats > 2, "Main actor must remain responsive during parsing")
		let duration = ProcessInfo.processInfo.systemUptime - began
		print("Metadata parser regression tests passed; 525 KB fixture in \(String(format: "%.3f", duration))s; UI-thread heartbeats: \(heartbeat.beats)")
	}
}
