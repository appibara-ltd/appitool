import Foundation

/// Single rule for the next build number / `versionCode` used by every flow preset (iOS and Android).
enum BuildNumberPolicy {
    /// Result of computing the next build number.
    struct Next: Equatable, Sendable {
        /// The new build number (`max(remote, local) + 1`).
        let value: String
        /// The value it was incremented from (the higher of `remote` and `local`).
        let base: Int
    }

    /// Returns `max(remote, local) + 1`, ignoring values that are missing or not plain integers.
    /// Using the maximum ensures the next build never goes below a local build number that was
    /// bumped manually but never uploaded, nor below the latest remote build.
    /// Returns `nil` when neither value is a valid integer.
    static func next(remote: String?, local: String?) -> Next? {
        let candidates = [remote, local].compactMap { raw -> Int? in
            guard let trimmed = CLIValues.trimmedNonEmpty(raw) else { return nil }
            return Int(trimmed)
        }
        guard let base = candidates.max() else { return nil }
        return Next(value: String(base + 1), base: base)
    }
}
