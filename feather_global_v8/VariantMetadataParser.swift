import Foundation

// Value-only metadata parsing. No Core Data or filesystem access is permitted.
enum VariantMetadataParser {
	static func parse(_ input: VariantMetadataInput) -> VariantEvidence {
		var evidence = VariantEvidence()
		guard !Task.isCancelled else { return evidence }
		
		let allTexts = [
			input.name,
			input.subtitle,
			input.description,
			input.localizedDescription,
			input.versionDescription,
			input.releaseNotes
		].compactMap { $0 }
		
		evidence.family = family(from: allTexts)
		
		scanText(input.name, score: 110, source: "title", into: &evidence)
		scanText(input.subtitle, score: 95, source: "subtitle", into: &evidence)
		scanText(input.localizedDescription, score: 70, source: "localized description", into: &evidence)
		scanText(input.description, score: 60, source: "description", into: &evidence)
		scanText(input.versionDescription, score: 65, source: "version description", into: &evidence)
		scanText(input.releaseNotes, score: 65, source: "release notes", into: &evidence)
		
		if let downloadURL = input.downloadURL {
			scanText(
				downloadURL.lastPathComponent,
				score: 45,
				source: "IPA filename",
				into: &evidence
			)
		}
		
		return evidence
	}
	
	static func scanText(
		_ optionalText: String?,
		score: Int,
		source: String,
		into evidence: inout VariantEvidence
	) {
		guard !Task.isCancelled else { return }
		guard
			let optionalText,
			!optionalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
		else {
			return
		}
		
		let normalized = _normalizedSearchText(optionalText)
		let compact = normalized.replacingOccurrences(of: " ", with: "")
		
		var aliasHits: [(canonical: String, display: String, alias: String)] = []
		for alias in _variantAliases {
			if Task.isCancelled { return }
			let aliasNormalized = _normalizedSearchText(alias.alias)
			let aliasCompact = _normalizedName(alias.alias)
			
			if
				normalized.contains(aliasNormalized) ||
				(!aliasCompact.isEmpty && compact.contains(aliasCompact))
			{
				aliasHits.append(alias)
			}
		}
		
		// Prefer the more specific primary mod name when one alias contains another.
		// Example: BHTikTokPlus should not simultaneously become BHTikTok, and
		// YTPlusYTweaks should not simultaneously become YTPlus.
		if aliasHits.contains(where: { $0.canonical == "bhtiktokplus" }) {
			aliasHits.removeAll { $0.canonical == "bhtiktok" }
		}
		if aliasHits.contains(where: { $0.canonical == "ytplusytweaks" }) {
			aliasHits.removeAll { $0.canonical == "ytplus" }
		}
		
		for alias in aliasHits {
			evidence.add(
				canonical: alias.canonical,
				display: alias.display,
				score: score,
				source: source
			)
		}
		
		// Source feeds often hide the actual variant behind a generic app name:
		// "Variant: YTPlus 6.0b2", "Variant: 21.39.4 YouMod 2.0.0", etc.
		if let range = normalized.range(of: "variant ") {
			let tail = String(normalized[range.upperBound...])
			for inferred in _explicitVariantTokens(from: tail) {
				evidence.add(
					canonical: inferred.canonical,
					display: inferred.display,
					score: max(score, 105),
					source: source + " (Variant:)"
				)
			}
		}
		
		// Bracketed titles such as "TikTok [VibeTok]" and "BHTikTokPlus [BHTikTok]".
		for bracket in _contentsBetween("[", "]", in: optionalText) {
			for inferred in _explicitVariantTokens(from: bracket) {
				evidence.add(
					canonical: inferred.canonical,
					display: inferred.display,
					score: 100,
					source: source + " (bracket)"
				)
			}
		}
		
		// iOSDecrypted-style compact variant codes visible in the screenshots.
		let codeMap: [(String, String, String)] = [
			("(rs)", "rustiktok", "RusTikTok"),
			("(rx)", "rxtiktok", "RXTikTok"),
			("(gt)", "gtok", "GTok"),
			("(as)", "asjtiktok", "ASJTikTok"),
			("(in)", "infinitok", "Infinitok"),
			("(bh)", "bhtiktok", "BHTikTok")
		]
		
		let lowercase = optionalText.lowercased()
		for (code, canonical, display) in codeMap where lowercase.contains(code) {
			evidence.add(
				canonical: canonical,
				display: display,
				score: max(score, 115),
				source: source + " " + code.uppercased()
			)
		}
	}
	
	private static func _explicitVariantTokens(from text: String) -> [(canonical: String, display: String)] {
		let normalized = _normalizedSearchText(text)
		let words = normalized
			.split(separator: " ")
			.map(String.init)
			.filter { !$0.isEmpty }
		
		var results: [(String, String)] = []
		
		for word in words.prefix(8) {
			if _looksLikeVersion(word) { continue }
			if _variantStopWords.contains(word) { continue }
			
			if let alias = _variantAliases.first(where: {
				_normalizedName($0.alias) == _normalizedName(word)
			}) {
				results.append((alias.canonical, alias.display))
				break
			}
			
			// Unknown-but-explicit variant names are still useful. Only accept
			// tokens that are sufficiently specific and not the base app itself.
			let compact = _normalizedName(word)
			if compact.count >= 4,
			   !_genericBaseNames.contains(compact)
			{
				results.append((compact, _prettyVariantLabel(word)))
				break
			}
		}
		
		return results
	}
	
	static func family(from texts: [String]) -> String? {
		let joined = texts.map(_normalizedName).joined(separator: " ")
		
		if joined.contains("youtubemusic") { return "youtubemusic" }
		if joined.contains("youtube") || joined.contains("youmod") || joined.contains("ytkace") || joined.contains("ytplus") || joined.contains("maxtube") || joined.contains("uyou") {
			return "youtube"
		}
		if joined.contains("tiktok") || joined.contains("bhtiktok") || joined.contains("vibetok") || joined.contains("infinitok") || joined.contains("gtok") {
			return "tiktok"
		}
		if joined.contains("instagram") { return "instagram" }
		if joined.contains("spotify") { return "spotify" }
		if joined.contains("reddit") { return "reddit" }
		if joined.contains("twitter") { return "twitter" }
		if joined.contains("discord") { return "discord" }
		if joined.contains("twitch") { return "twitch" }
		if joined.contains("facebook") { return "facebook" }
		if joined.contains("messenger") { return "messenger" }
		if joined.contains("snapchat") { return "snapchat" }
		
		return nil
	}
	
	private static var _variantAliases: [(canonical: String, display: String, alias: String)] {
		[
			// TikTok family
			("bhtiktokplus", "BHTikTokPlus", "bhtiktokplus"),
			("bhtiktok", "BHTikTok", "bhtiktok"),
			("bhtiktok", "BHTikTok", "tiktok bh"),
			("rustiktok", "RusTikTok", "rustiktok"),
			("rxtiktok", "RXTikTok", "rxtiktok"),
			("gtok", "GTok", "gtok"),
			("asjtiktok", "ASJTikTok", "asjtiktok"),
			("infinitok", "Infinitok", "infinitok"),
			("vibetok", "VibeTok", "vibetok"),
			("tiktokeos", "TikTok EOS", "tiktok eos"),
			
			// YouTube family
			("ytliteplus", "YTLitePlus", "ytliteplus"),
			("uyouenhanced", "uYouEnhanced", "uyouenhanced"),
			("uyouplus", "uYouPlus", "uyouplus"),
			("ytplusytweaks", "YTPlusYTweaks", "ytplusytweaks"),
			("ytkace", "YTKACE", "ytkace"),
			("youmod", "YouMod", "youmod"),
			("ytplus", "YTPlus", "ytplus"),
			("maxtube", "MaxTube", "maxtube"),
			("youtubeplusplus", "YouTube++", "youtube plusplus")
		]
	}
	
	private static var _variantStopWords: Set<String> {
		[
			"the", "this", "with", "bonus", "tweaks", "tweak", "mod", "modded",
			"version", "build", "youtube", "tiktok", "app", "ios", "for", "and"
		]
	}
	
	private static var _genericBaseNames: Set<String> {
		[
			"youtube", "youtubemusic", "tiktok", "instagram", "spotify",
			"reddit", "twitter", "discord", "twitch", "facebook",
			"messenger", "snapchat"
		]
	}
	
	private static func _contentsBetween(_ open: Character, _ close: Character, in text: String) -> [String] {
		var results: [String] = []
		var buffer = ""
		var collecting = false
		
		for character in text {
			if character == open {
				buffer = ""
				collecting = true
				continue
			}
			
			if character == close, collecting {
				if !buffer.isEmpty {
					results.append(buffer)
				}
				buffer = ""
				collecting = false
				continue
			}
			
			if collecting {
				buffer.append(character)
			}
		}
		
		return results
	}
	
	private static func _looksLikeVersion(_ value: String) -> Bool {
		guard let first = value.first else { return false }
		return first.isNumber && value.contains(".")
	}
	
	private static func _prettyVariantLabel(_ value: String) -> String {
		value.trimmingCharacters(in: .whitespacesAndNewlines)
	}
	
	private static func _normalizedSearchText(_ text: String) -> String {
		var value = text
			.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
			.lowercased()
		value = value.replacingOccurrences(of: "++", with: " plusplus ")
		value = value.replacingOccurrences(of: "+", with: " plus ")
		
		let separators = CharacterSet.alphanumerics.inverted
		return value
			.components(separatedBy: separators)
			.filter { !$0.isEmpty }
			.joined(separator: " ")
	}
	
	private static func _normalizedName(_ name: String) -> String {
		_normalizedSearchText(name).replacingOccurrences(of: " ", with: "")
	}
	
	static func displayName(_ canonical: String) -> String {
		_variantAliases.first { $0.canonical == canonical }?.display ?? canonical
	}
}

struct VariantEvidence: Sendable {
	var family: String?
	private var items: [String: VariantEvidenceItem] = [:]
	
	var primaryCanonical: String? {
		let primary = primaryItems
		return primary.count == 1 ? primary[0].canonical : nil
	}
	
	var displayLabel: String? {
		guard let primaryCanonical else { return nil }
		return items[primaryCanonical]?.display
	}
	
	var evidenceSummary: String? {
		guard let primaryCanonical, let item = items[primaryCanonical] else { return nil }
		return "\(item.source): \(item.display)"
	}
	
	var allCanonicals: [String] {
		items.values
			.filter { $0.score >= 60 }
			.sorted { $0.score > $1.score }
			.map(\.canonical)
	}
	
	private var primaryItems: [VariantEvidenceItem] {
		guard let maxScore = items.values.map(\.score).max(), maxScore >= 45 else {
			return []
		}
		return items.values
			.filter { $0.score >= maxScore - 8 }
			.sorted { $0.score > $1.score }
	}
	
	mutating func add(
		canonical: String,
		display: String,
		score: Int,
		source: String
	) {
		if let current = items[canonical], current.score >= score {
			return
		}
		items[canonical] = VariantEvidenceItem(
			canonical: canonical,
			display: display,
			score: score,
			source: source
		)
	}
	
	mutating func merge(_ other: VariantEvidence) {
		if family == nil {
			family = other.family
		}
		for item in other.items.values {
			add(
				canonical: item.canonical,
				display: item.display,
				score: item.score,
				source: item.source
			)
		}
	}
}

struct VariantEvidenceItem: Sendable {
	let canonical: String
	let display: String
	let score: Int
	let source: String
}

struct VariantMetadataInput: Sendable {
	let name: String?
	let subtitle: String?
	let description: String?
	let localizedDescription: String?
	let versionDescription: String?
	let releaseNotes: String?
	let downloadURL: URL?
}
