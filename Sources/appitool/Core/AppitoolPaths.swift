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
    /// `~/.appitool/<platform>/<target>/build/<name>/`
    /// Defaults to `Date().appitoolTimestamp` (`yyyy_MM_dd_HH_mm`) when `name` is nil or blank.
    package static func buildDirectory(
        platform: String,
        target: String,
        name: String? = nil
    ) -> URL {
        let folderName: String
        if let rawName = name?.trimmingCharacters(in: .whitespacesAndNewlines), !rawName.isEmpty {
            folderName = sanitizeSegment(rawName)
        } else {
            folderName = Date().appitoolTimestamp
        }
        return platformDirectory(platform)
            .appendingPathComponent(target)
            .appendingPathComponent("build")
            .appendingPathComponent(folderName)
    }

    /// Android artifact base name shared by `build android` and flow presets:
    /// `<Target>_[<flavor>_]<buildType>` (build type lowercased, e.g. `MyApp_staging_release`).
    static func androidArtifactName(target: String, flavor: String?, buildType: String) -> String {
        let flavorSuffix = CLIValues.trimmedNonEmpty(flavor).map { "\($0)_" } ?? ""
        return "\(target)_\(flavorSuffix)\(buildType.lowercased())"
    }

    /// Builds a filesystem-safe tag folder name (`<version>_<buildNumber>[_adhoc|_development]`)
    /// when both `version` and `buildNumber` are resolved non-empty literal values.
    /// Returns `nil` when either value is missing, blank, or contains an unresolved variable reference (`$`).
    static func buildTagName(
        version: String?,
        buildNumber: String?,
        distribution: BuildCommand.Distribution
    ) -> String? {
        guard let rawVersion = version?.trimmingCharacters(in: .whitespacesAndNewlines),
              let rawBuild = buildNumber?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawVersion.isEmpty,
              !rawBuild.isEmpty,
              !rawVersion.contains("$"),
              !rawBuild.contains("$")
        else {
            return nil
        }
        let normalizedVersion = rawVersion
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: "_")
        let normalizedBuild = rawBuild
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: "_")
        return sanitizeSegment("\(normalizedVersion)_\(normalizedBuild)\(distribution.tagSuffix)")
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

    /// Resolves the directory for Android keystores:
    /// `~/.appitool/android/keystores/`
    package static var androidKeystoresDirectory: URL {
        platformDirectory("android")
            .appendingPathComponent("keystores")
    }

    /// Resolves the file path for an Android keystore by package name:
    /// `~/.appitool/android/keystores/<packageName>.keystore`
    package static func androidKeystoreFile(packageName: String) -> URL {
        androidKeystoresDirectory
            .appendingPathComponent("\(packageName).keystore")
    }

    /// Resolves the centralized screenshots root directory (`~/.appitool/screenshots/`).
    package static var screenshotsRootDirectory: URL {
        rootDirectory.appendingPathComponent("screenshots")
    }

    /// Resolves the centralized per-project store screenshots directory:
    /// `~/.appitool/screenshots/<project>/<store>/`
    package static func screenshotsDirectory(project: String, store: String) -> URL {
        screenshotsRootDirectory
            .appendingPathComponent(sanitizeSegment(project))
            .appendingPathComponent(sanitizeSegment(store))
    }

    private static func sanitizeSegment(_ raw: String) -> String {
        var clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for char in ["/", "\\", ":", "\0"] {
            clean = clean.replacingOccurrences(of: char, with: "_")
        }
        while clean.contains("..") {
            clean = clean.replacingOccurrences(of: "..", with: "_")
        }
        if clean.isEmpty || clean == "." {
            return "default"
        }
        return clean
    }
}

