import ArgumentParser
import Crypto
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Rainbow

struct SelfUpdateCommand: BaseCommand {
    static let configuration = CommandConfiguration(
        commandName: "self-update",
        abstract: "Check for updates and automatically upgrade appitool to the latest release."
    )

    private static let repo = "appibara-ltd/appitool"
    private static let latestReleaseURL = URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
    private static let checksumsName = "checksums.txt"

    @Flag(name: .long, help: "Check for available updates without installing.")
    var check: Bool = false

    @Flag(name: .long, help: "Force update even if the current version is already up to date.")
    var force: Bool = false

    private var currentPlatform: (os: String, arch: String) {
        let osName: String
        #if os(macOS)
        osName = "darwin"
        #elseif os(Linux)
        osName = "linux"
        #elseif os(Windows)
        osName = "windows"
        #else
        osName = "unknown"
        #endif

        let archName: String
        #if arch(arm64)
        archName = "arm64"
        #elseif arch(x86_64)
        archName = "x86_64"
        #else
        archName = "unknown"
        #endif

        return (osName, archName)
    }

    func execute() async throws {
        let currentVersionString = appitool.configuration.version
        Log("🌊 Checking for updates (current version: \(currentVersionString))...")

        let release = try await fetchLatestRelease()
        let latestTag = release.tagName
        let latestVersionClean = latestTag.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))

        let isUpdateAvailable: Bool
        if let currentSemVer = SemanticVersion(currentVersionString),
           let latestSemVer = SemanticVersion(latestVersionClean) {
            isUpdateAvailable = latestSemVer > currentSemVer
        } else {
            isUpdateAvailable = latestVersionClean != currentVersionString
        }

        if !isUpdateAvailable && !force {
            Log("🟢 appitool is already up to date (\(currentVersionString)).".dim)
            return
        }

        if check {
            if isUpdateAvailable {
                Log("🎉 A new version of appitool is available: ".green.bold + "\(currentVersionString)".dim + " → " + "\(latestTag)".green.bold)
                Log("   Run 'appitool self-update' to upgrade.")
            } else {
                Log("🟢 appitool is up to date (\(currentVersionString)).".dim)
            }
            return
        }

        Log("   🟢 Found update: \(latestTag)".cyan)

        let platform = currentPlatform
        let expectedArtifactNames = [
            "appitool-\(platform.os)-\(platform.arch).tar.gz",
            "appitool-\(platform.os)-universal.tar.gz"
        ]

        guard let tarballAsset = release.assets.first(where: { expectedArtifactNames.contains($0.name) }) else {
            Log("🔴 Error: No compatible release artifact found for \(platform.os) (\(platform.arch)) in release \(latestTag).".red)
            if !release.assets.isEmpty {
                Log("   Available assets for \(latestTag):".yellow)
                for asset in release.assets {
                    Log("   • \(asset.name)".dim)
                }
            }
            throw ExitCode.failure
        }

        guard let checksumsAsset = release.assets.first(where: { $0.name == Self.checksumsName }) else {
            throw CommandError("Could not locate '\(Self.checksumsName)' in release assets for \(latestTag).")
        }

        let artifactName = tarballAsset.name
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        Log("   🔄 Downloading \(artifactName)...")
        let tarballData = try await downloadData(for: tarballAsset)
        let checksumsData = try await downloadData(for: checksumsAsset)

        let tarballPath = tempDir.appendingPathComponent(artifactName)
        try tarballData.write(to: tarballPath)

        Log("   🔄 Verifying SHA256 checksum...")
        guard let checksumsString = String(data: checksumsData, encoding: .utf8) else {
            throw CommandError("Invalid checksums file format.")
        }

        let calculatedHash = SHA256.hash(data: tarballData).map { String(format: "%02x", $0) }.joined()
        guard let expectedHash = parseChecksum(from: checksumsString, for: artifactName) else {
            throw CommandError("Checksum for '\(artifactName)' not found in \(Self.checksumsName).")
        }

        if calculatedHash.lowercased() != expectedHash.lowercased() {
            Log("🔴 Error: Checksum verification failed!".red)
            Log("   Expected: \(expectedHash)")
            Log("   Actual:   \(calculatedHash)")
            throw ExitCode.failure
        }
        Log("   🟢 Checksum verified.")

        Log("   🔄 Unpacking archive...")
        try await runProcess("tar", arguments: ["-xzf", tarballPath.path, "-C", tempDir.path])
        let extractedBinary = tempDir.appendingPathComponent("appitool")
        guard FileManager.default.fileExists(atPath: extractedBinary.path) else {
            throw CommandError("'appitool' binary was not found in the extracted archive.")
        }

        // Locate current running binary
        let currentExecutableURL = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath()
        let targetDirectory = currentExecutableURL.deletingLastPathComponent()

        let fileManager = FileManager.default
        let isWritable = fileManager.isWritableFile(atPath: targetDirectory.path) &&
            (!fileManager.fileExists(atPath: currentExecutableURL.path) || fileManager.isWritableFile(atPath: currentExecutableURL.path))

        if !isWritable {
            throw CommandError(
                "Permission denied to write to '\(currentExecutableURL.path)'.",
                hint: "   Please re-run with sudo: sudo appitool self-update"
            )
        }

        Log("   🔄 Replacing binary at \(currentExecutableURL.path)...")
        let backupURL = currentExecutableURL.appendingPathExtension("old")
        if fileManager.fileExists(atPath: backupURL.path) {
            try? fileManager.removeItem(at: backupURL)
        }
        if fileManager.fileExists(atPath: currentExecutableURL.path) {
            try fileManager.moveItem(at: currentExecutableURL, to: backupURL)
        }

        do {
            try fileManager.moveItem(at: extractedBinary, to: currentExecutableURL)
            try? fileManager.removeItem(at: backupURL)
        } catch {
            if fileManager.fileExists(atPath: backupURL.path) {
                try? fileManager.moveItem(at: backupURL, to: currentExecutableURL)
            }
            throw error
        }

        Log("\n" + "🎉 appitool successfully updated to \(latestTag)!".green.bold)
    }

    // MARK: - Networking & Helpers

    private var githubToken: String? {
        EnvLoader.value(for: "GITHUB_TOKEN") ?? EnvLoader.value(for: "GH_TOKEN")
    }

    private func fetchLatestRelease() async throws -> GitHubRelease {
        var request = URLRequest(url: Self.latestReleaseURL)
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
        request.setValue("appitool-self-update", forHTTPHeaderField: "User-Agent")
        if let token = githubToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            let body = String(data: data, encoding: .utf8) ?? ""
            if (statusCode == 403 || statusCode == 429) && githubToken == nil {
                Log("🔴 Error: GitHub API rate limit exceeded (HTTP \(statusCode)).".red)
                Log("   Set GITHUB_TOKEN (or GH_TOKEN) to authenticate API requests:".yellow)
                Log("   export GITHUB_TOKEN=\"ghp_...\"".dim)
            } else if statusCode == 404 {
                Log("🔴 Error: Release not found on GitHub (HTTP 404).".red)
            } else {
                Log("🔴 Error: Failed to fetch latest release from GitHub (HTTP \(statusCode)): \(body)".red)
            }
            throw ExitCode.failure
        }

        return try JSONDecoder().decode(GitHubRelease.self, from: data)
    }

    private func downloadData(for asset: GitHubAsset) async throws -> Data {
        let targetURL = githubToken != nil ? asset.url : asset.browserDownloadUrl
        var request = URLRequest(url: targetURL)
        request.setValue("appitool-self-update", forHTTPHeaderField: "User-Agent")
        if let token = githubToken {
            request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw CommandError("Failed to download asset '\(asset.name)' from \(targetURL) (HTTP \(statusCode)).")
        }
        return data
    }

    private func parseChecksum(from content: String, for filename: String) -> String? {
        let lines = content.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.contains(filename) {
                let parts = trimmed.split(separator: " ").map(String.init)
                if let hash = parts.first, !hash.isEmpty {
                    return hash
                }
            }
        }
        return nil
    }

    @discardableResult
    private func runProcess(_ executable: String, arguments: [String]) async throws -> String {
        do {
            let result = try await ProcessRunner.run(
                executable,
                arguments: arguments,
                combineOutput: true
            )
            guard result.isSuccess else {
                throw ValidationError("Process '\(executable) \(arguments.joined(separator: " "))' failed (exit code \(result.exitCode)): \(result.stdout)")
            }
            return result.stdout
        } catch let error as ValidationError {
            throw error
        } catch {
            throw ValidationError("Process '\(executable) \(arguments.joined(separator: " "))' failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - Models

private struct GitHubRelease: Decodable {
    let tagName: String
    let name: String?
    let body: String?
    let assets: [GitHubAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case body
        case assets
    }
}

private struct GitHubAsset: Decodable {
    let name: String
    let url: URL
    let browserDownloadUrl: URL

    enum CodingKeys: String, CodingKey {
        case name
        case url
        case browserDownloadUrl = "browser_download_url"
    }
}

private struct SemanticVersion: Comparable {
    let major: Int
    let minor: Int
    let patch: Int

    init?(_ string: String) {
        let cleaned = string.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        let parts = cleaned.split(separator: ".").compactMap { Int($0) }
        guard parts.count >= 2 else { return nil }
        self.major = parts[0]
        self.minor = parts[1]
        self.patch = parts.count > 2 ? parts[2] : 0
    }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }
}
