import Foundation

enum UpdaterSafetyPolicy {
	static func jaccard(_ lhs: Set<String>, _ rhs: Set<String>) -> Double {
		// The absence of evidence on both sides is not positive evidence that two
		// binaries are the same. Treat two empty sets as zero similarity.
		guard !lhs.isEmpty || !rhs.isEmpty else { return 0.0 }
		let union = lhs.union(rhs)
		guard !union.isEmpty else { return 0.0 }
		return Double(lhs.intersection(rhs).count) / Double(union.count)
	}

	static func highCollisionIdentityAgreement(
		binaryVariantOverlap: Bool,
		distinctiveInjectionOverlapCount: Int,
		distinctiveInjectionSimilarity: Double,
		distinctiveNormalizedHashMatches: Int
	) -> Bool {
		if binaryVariantOverlap {
			return true
		}

		// A repository label, a shared stock framework, or an otherwise generic
		// component hash cannot prove tweak identity in collision-heavy families.
		// Require a distinctive component on both sides, then corroborate it by
		// name-set agreement or its signature-normalized binary hash.
		guard distinctiveInjectionOverlapCount > 0 else { return false }
		return distinctiveInjectionSimilarity >= 0.50 || distinctiveNormalizedHashMatches > 0
	}
}
