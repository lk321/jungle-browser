import Foundation

enum ContentBlockingSourcePolicy {
    /// A fallback replaces unavailable coverage; it is not merged with healthy
    /// primary lists, which keeps duplicate rules and compatibility risk bounded.
    nonisolated static func shouldUseFallback(primarySourcesAreUsable: [Bool]) -> Bool {
        primarySourcesAreUsable.contains(false)
    }
}
