import ArgumentParser
import Foundation
import Rainbow

struct CleanCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clean",
        abstract: "Cleans previously built archives/IPAs/AABs under ~/.appitool (iOS & Android) and optional derived data."
    )

    @Option(name: .shortAndLong, help: "Platform to clean (ios, android, or all). Defaults to all.")
    var platform: String = "all"

    @Flag(name: [.customLong("dd"), .long], help: "Also clean Xcode derived data directories under ~/.appitool/ios.")
    var derivedData: Bool = false

    @Flag(name: [.customLong("ddo"), .long], help: "Only clean Xcode derived data directories without deleting build archives.")
    var derivedDataOnly: Bool = false

    @Flag(name: .long, help: "Preview items to be cleaned without deleting them.")
    var dryRun: Bool = false

    private enum ItemType: String {
        case build = "Build"
        case derivedData = "DerivedData"
    }

    private struct CleanItem {
        let platform: String
        let url: URL
        let project: String
        let type: ItemType
        let size: Int64
    }

    func run() async throws {
        let fm = FileManager.default
        let homeDir = fm.homeDirectoryForCurrentUser
        let iosDir = homeDir.appendingPathComponent(".appitool").appendingPathComponent("ios")
        let androidDir = homeDir.appendingPathComponent(".appitool").appendingPathComponent("android")

        let shouldCleanIos = platform.lowercased() == "all" || platform.lowercased() == "ios"
        let shouldCleanAndroid = !derivedDataOnly && (platform.lowercased() == "all" || platform.lowercased() == "android")

        let hasIos = fm.fileExists(atPath: iosDir.path)
        let hasAndroid = fm.fileExists(atPath: androidDir.path)

        guard (shouldCleanIos && hasIos) || (shouldCleanAndroid && hasAndroid) else {
            let target = derivedDataOnly ? "Xcode derived data" : "build directories"
            Log("🟢 No \(target) found under ~/.appitool for platform '\(platform)'. Nothing to clean.".green)
            return
        }

        let prefix = dryRun ? "[Dry Run] ".yellow.bold : ""
        let targetDesc = derivedDataOnly ? "Xcode derived data" : "build artifacts"
        Log("🧹 \(prefix)Scanning ~/.appitool for \(targetDesc)...".bold)

        var itemsToDelete: [CleanItem] = []

        // 1. Scan iOS hierarchy: ~/.appitool/ios/{{PROJECT_NAME}}/
        if shouldCleanIos && hasIos {
            let projectDirs = (try? fm.contentsOfDirectory(at: iosDir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
            for projUrl in projectDirs {
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: projUrl.path, isDirectory: &isDir), isDir.boolValue else { continue }
                let projectName = projUrl.lastPathComponent

                // Check derivedData
                if derivedData || derivedDataOnly {
                    let derivedDataDir = projUrl.appendingPathComponent("derivedData")
                    if fm.fileExists(atPath: derivedDataDir.path) {
                        let size = calculateSize(of: derivedDataDir, fm: fm)
                        itemsToDelete.append(CleanItem(
                            platform: "iOS",
                            url: derivedDataDir,
                            project: projectName,
                            type: .derivedData,
                            size: size
                        ))
                    }
                }

                // Check build directories
                if !derivedDataOnly {
                    let buildDir = projUrl.appendingPathComponent("build")
                    if fm.fileExists(atPath: buildDir.path) {
                        let buildEntries = (try? fm.contentsOfDirectory(at: buildDir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
                        for entry in buildEntries {
                            let size = calculateSize(of: entry, fm: fm)
                            itemsToDelete.append(CleanItem(
                                platform: "iOS",
                                url: entry,
                                project: projectName,
                                type: .build,
                                size: size
                            ))
                        }
                    }
                }
            }
        }

        // 2. Scan Android hierarchy: ~/.appitool/android/{{PROJECT_NAME}}/
        if shouldCleanAndroid && hasAndroid {
            let projectDirs = (try? fm.contentsOfDirectory(at: androidDir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
            for projUrl in projectDirs {
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: projUrl.path, isDirectory: &isDir), isDir.boolValue else { continue }
                let projectName = projUrl.lastPathComponent

                // Ignore reserved/system folders like "keystores" or "tmp"
                if projectName == "keystores" || projectName == "tmp" { continue }

                // Check build directories
                let buildDir = projUrl.appendingPathComponent("build")
                if fm.fileExists(atPath: buildDir.path) {
                    let buildEntries = (try? fm.contentsOfDirectory(at: buildDir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
                    for entry in buildEntries {
                        let size = calculateSize(of: entry, fm: fm)
                        itemsToDelete.append(CleanItem(
                            platform: "Android",
                            url: entry,
                            project: projectName,
                            type: .build,
                            size: size
                        ))
                    }
                }
            }
        }

        if itemsToDelete.isEmpty {
            let emptyMsg = derivedDataOnly
                ? "🟢 No Xcode derived data found to clean. ~/.appitool is clean!".green.bold
                : "🟢 No build artifacts found to clean. ~/.appitool is clean!".green.bold
            Log(emptyMsg)
            return
        }

        let totalBytes = itemsToDelete.reduce(0) { $0 + $1.size }
        let totalSizeStr = formatBytes(totalBytes)

        Log("\nFound \(itemsToDelete.count) item(s) to clean (Total: \(totalSizeStr)):".bold)
        for item in itemsToDelete {
            let badge: String
            switch item.type {
            case .build:
                badge = "[\(item.platform)][Build] ".magenta.bold
            case .derivedData:
                badge = "[\(item.platform)][Derived]".yellow.bold
            }
            let baseAppitool = homeDir.appendingPathComponent(".appitool").path + "/"
            let relativePath = item.url.path.replacingOccurrences(of: baseAppitool, with: "")
            Log("  • \(badge) [\(item.project)] \(relativePath) " + "(\(formatBytes(item.size)))".dim)
        }
        Log("")

        if dryRun {
            Log("🟡 Dry run complete. No files were deleted. Re-run without --dry-run to delete them.".yellow)
            return
        }

        var deletedCount = 0
        var freedBytes: Int64 = 0
        var failedCount = 0

        for item in itemsToDelete {
            do {
                try fm.removeItem(at: item.url)
                deletedCount += 1
                freedBytes += item.size
                Log("  ✔ Removed: ".green + "\(item.url.lastPathComponent)".bold + " (\(formatBytes(item.size)))".dim)
            } catch {
                failedCount += 1
                Log("  🔴 Failed to remove '\(item.url.path)': \(error.localizedDescription)".red)
            }
        }

        // Clean up empty directories under ios and android hierarchies
        if shouldCleanIos && hasIos {
            pruneEmptyDirectories(at: iosDir, fm: fm)
        }
        if shouldCleanAndroid && hasAndroid {
            pruneEmptyDirectories(at: androidDir, fm: fm)
        }

        let freedSizeStr = formatBytes(freedBytes)
        if failedCount == 0 {
            Log("\n🟢 Clean finished: Successfully deleted \(deletedCount) item(s) and freed \(freedSizeStr).".green.bold)
        } else {
            Log("\n🟡 Clean finished with warnings: \(deletedCount) deleted (\(freedSizeStr) freed), \(failedCount) failed.".yellow.bold)
        }
    }

    private func calculateSize(of url: URL, fm: FileManager) -> Int64 {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue {
            return (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        }

        let resourceKeys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .totalFileAllocatedSizeKey,
            .fileAllocatedSizeKey,
            .fileSizeKey
        ]

        // errorHandler returning true prevents early abort on broken symlinks or transient files
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [],
            errorHandler: { _, _ in true }
        ) else { return 0 }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let values = try? fileURL.resourceValues(forKeys: resourceKeys),
               values.isRegularFile == true {
                let size = values.totalFileAllocatedSize
                    ?? values.fileAllocatedSize
                    ?? values.fileSize
                    ?? ((try? fm.attributesOfItem(atPath: fileURL.path)[.size] as? Int64).map(Int.init))
                    ?? 0
                total += Int64(size)
            }
        }
        return total
    }

    private func pruneEmptyDirectories(at url: URL, fm: FileManager) {
        guard fm.fileExists(atPath: url.path) else { return }
        guard let contents = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: []) else { return }
        for item in contents {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: item.path, isDirectory: &isDir), isDir.boolValue {
                pruneEmptyDirectories(at: item, fm: fm)
                if let subContents = try? fm.contentsOfDirectory(atPath: item.path), subContents.isEmpty {
                    try? fm.removeItem(at: item)
                }
            }
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useAll]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
