import Foundation

/// Chooses the version string for a new App Store version.
///
/// Default (no explicit version): use the Xcode project's `MARKETING_VERSION` when it is higher than every existing
/// App Store version; otherwise bump the patch number of the highest existing version and update the project to match.
enum AppVersionPolicy {
    struct Decision: Equatable {
        let version: String
        /// `true` when the Xcode project's `MARKETING_VERSION` must be updated to `version`.
        let updatesProject: Bool
        let reason: String
    }

    /// Compares dotted numeric versions (`1.10` > `1.9`, `1.0` == `1.0.0`). Non-numeric parts count as 0.
    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = components(lhs)
        let right = components(rhs)
        for index in 0..<max(left.count, right.count) {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            if l != r { return l < r ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    /// Highest version string in `versions` (`nil` when empty).
    static func highest(_ versions: [String]) -> String? {
        versions.max { compare($0, $1) == .orderedAscending }
    }

    /// Bumps the patch component: `1.0.8` → `1.0.9`, `1.2` → `1.2.1`, `2` → `2.0.1`.
    static func bumpPatch(_ version: String) -> String {
        var parts = components(version)
        while parts.count < 3 { parts.append(0) }
        parts[2] += 1
        return parts.prefix(max(3, components(version).count)).map(String.init).joined(separator: ".")
    }

    /// `true` when `version` looks like a valid App Store version string (1–3 dot-separated integers).
    static func isValid(_ version: String) -> Bool {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        return (1...3).contains(parts.count) && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }

    /// Default version decision from the project version and the existing App Store versions.
    static func resolveDefault(projectVersion: String?, existingVersions: [String]) throws -> Decision {
        let project = projectVersion.flatMap { isValid($0) ? $0 : nil }
        guard let latest = highest(existingVersions.filter(isValid)) else {
            guard let project else {
                throw CommandError(
                    "Cannot determine a version: no Xcode project MARKETING_VERSION found and the app has no App Store versions yet.",
                    hint: "Pass --app-version explicitly."
                )
            }
            return Decision(version: project, updatesProject: false, reason: "Xcode project version (first App Store version)")
        }

        if let project, compare(project, latest) == .orderedDescending {
            return Decision(version: project, updatesProject: false, reason: "Xcode project version (higher than App Store \(latest))")
        }

        let bumped = bumpPatch(latest)
        if let project {
            return Decision(
                version: bumped,
                updatesProject: true,
                reason: "Xcode project version \(project) is not higher than App Store \(latest); bumped the patch number"
            )
        }
        return Decision(version: bumped, updatesProject: false, reason: "no Xcode project version found; bumped App Store \(latest)")
    }

    private static func components(_ version: String) -> [Int] {
        version.split(separator: ".").map { Int($0) ?? 0 }
    }
}
