import Foundation

extension Date {
    /// Standardized timestamp string formatted as `yyyy_MM_dd_HH_mm` (e.g. `2026_10_13_17_15`).
    public var appitoolTimestamp: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy_MM_dd_HH_mm"
        return formatter.string(from: self)
    }
}

/// Centralized path resolver for `~/.appitool` directory structure.
package enum AppitoolPaths {
    /// Returns the base directory URL for `~/.appitool`.
    package static var rootDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".appitool")
    }

    /// Returns the root directory URL for a platform (`~/.appitool/<platform>`).
    package static func platformDirectory(_ platform: String) -> URL {
        rootDirectory.appendingPathComponent(platform)
    }

    /// Resolves the standardized build output directory:
    /// `~/.appitool/<platform>/<target>/build/<timestamp>/`
    package static func buildDirectory(
        platform: String,
        target: String,
        timestamp: String? = nil
    ) -> URL {
        let ts = timestamp ?? Date().appitoolTimestamp
        return platformDirectory(platform)
            .appendingPathComponent(target)
            .appendingPathComponent("build")
            .appendingPathComponent(ts)
    }

    /// Resolves the root build directory for a target:
    /// `~/.appitool/<platform>/<target>/build/`
    package static func targetBuildRoot(
        platform: String,
        target: String
    ) -> URL {
        platformDirectory(platform)
            .appendingPathComponent(target)
            .appendingPathComponent("build")
    }

    /// Resolves the derivedData path for an iOS target:
    /// `~/.appitool/ios/<target>/derivedData/`
    package static func iosDerivedDataDirectory(target: String) -> URL {
        platformDirectory("ios")
            .appendingPathComponent(target)
            .appendingPathComponent("derivedData")
    }
}
