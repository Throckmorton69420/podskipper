import Foundation

@main
private struct UpdaterSafetyPolicyTests {
	private static func require(
		_ condition: @autoclosure () -> Bool,
		_ message: String
	) {
		guard condition() else {
			fatalError(message)
		}
	}

	static func main() {
		require(
			UpdaterSafetyPolicy.jaccard([], []) == 0.0,
			"Two empty fingerprints must not count as a perfect match."
		)
		require(
			UpdaterSafetyPolicy.jaccard(["a"], ["a"]) == 1.0,
			"Identical non-empty fingerprints should match."
		)
		require(
			UpdaterSafetyPolicy.jaccard(["a"], ["b"]) == 0.0,
			"Disjoint fingerprints should not match."
		)
		require(
			!UpdaterSafetyPolicy.highCollisionIdentityAgreement(
				binaryVariantOverlap: false,
				distinctiveInjectionOverlapCount: 0,
				distinctiveInjectionSimilarity: 0,
				distinctiveNormalizedHashMatches: 1
			),
			"A shared generic component hash must not verify a high-collision app."
		)
		require(
			UpdaterSafetyPolicy.highCollisionIdentityAgreement(
				binaryVariantOverlap: true,
				distinctiveInjectionOverlapCount: 0,
				distinctiveInjectionSimilarity: 0,
				distinctiveNormalizedHashMatches: 0
			),
			"Matching unambiguous binary variant markers should verify identity."
		)
		require(
			UpdaterSafetyPolicy.highCollisionIdentityAgreement(
				binaryVariantOverlap: false,
				distinctiveInjectionOverlapCount: 1,
				distinctiveInjectionSimilarity: 0.5,
				distinctiveNormalizedHashMatches: 0
			),
			"Distinctive injected-component agreement should verify identity."
		)
		require(
			!UpdaterSafetyPolicy.highCollisionIdentityAgreement(
				binaryVariantOverlap: false,
				distinctiveInjectionOverlapCount: 0,
				distinctiveInjectionSimilarity: 0,
				distinctiveNormalizedHashMatches: 0
			),
			"Semantic metadata alone must never verify a high-collision binary."
		)

		print("Updater safety policy checks passed")
	}
}
