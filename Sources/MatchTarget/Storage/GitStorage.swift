import Foundation

/// Manages Git repository operations for Match certificates and profiles storage.
public final class GitStorage: Sendable {
    public let workingDirectory: String
    private let gitUrl: String
    private let gitBranch: String
    private let gitToken: String?
    private let shallowClone: Bool
    private let silent: Bool

    public init(
        gitUrl: String,
        gitBranch: String = "master",
        gitToken: String? = nil,
        shallowClone: Bool = true,
        silent: Bool = false
    ) {
        self.gitUrl = gitUrl
        self.gitBranch = gitBranch
        self.gitToken = gitToken
        self.shallowClone = shallowClone
        self.silent = silent

        let baseDir = URL(fileURLWithPath: FileManager.default.homeDirectoryForCurrentUser.path)
            .appendingPathComponent(".appitool")
            .appendingPathComponent("ios")
            .appendingPathComponent("match")
            .appendingPathComponent("workspaces")
            .appendingPathComponent(UUID().uuidString).path
        self.workingDirectory = baseDir
    }

    /// Clones the remote git repository into `workingDirectory`.
    public func download() async throws {
        let fm = FileManager.default
        // Ensure clean working directory before cloning
        if fm.fileExists(atPath: workingDirectory) {
            try? fm.removeItem(atPath: workingDirectory)
        }

        let authenticatedUrl = resolveAuthenticatedGitUrl()

        // 1. Check if the target branch exists on the remote (matching Fastlane match behavior)
        let (lsExit, lsOut) = try await runGit(args: ["ls-remote", "--heads", authenticatedUrl, gitBranch], in: nil)
        let branchExistsOnRemote = (lsExit == 0 && lsOut.contains("refs/heads/\(gitBranch)"))

        if branchExistsOnRemote {
            var cloneArgs = ["clone"]
            if shallowClone {
                cloneArgs.append(contentsOf: ["--depth", "1"])
            }
            cloneArgs.append(contentsOf: ["-b", gitBranch, authenticatedUrl, workingDirectory])

            let (exitCode, output) = try await runGit(args: cloneArgs, in: nil)
            guard exitCode == 0 else {
                throw MatchError.gitCloneFailed(output.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        } else {
            // Branch does not exist yet on remote.
            // Fastlane Match parity: Clone default branch, checkout as 'orphan' and clean
            // all files so the new branch does NOT inherit master's certificates/profiles.
            var cloneArgs = ["clone"]
            if shallowClone {
                cloneArgs.append(contentsOf: ["--depth", "1"])
            }
            cloneArgs.append(contentsOf: [authenticatedUrl, workingDirectory])

            let (cloneExit, _) = try await runGit(args: cloneArgs, in: nil)
            if cloneExit == 0 {
                _ = try await runGit(args: ["checkout", "--orphan", gitBranch], in: workingDirectory)
                _ = try await runGit(args: ["rm", "-rf", "."], in: workingDirectory)
                _ = try await runGit(args: ["clean", "-fdx"], in: workingDirectory)
            } else {
                // Remote repository might be completely empty (no commits yet)
                try fm.createDirectory(atPath: workingDirectory, withIntermediateDirectories: true)
                _ = try await runGit(args: ["init"], in: workingDirectory)
                _ = try await runGit(args: ["checkout", "-b", gitBranch], in: workingDirectory)
                _ = try await runGit(args: ["remote", "add", "origin", authenticatedUrl], in: workingDirectory)
            }
        }
    }

    /// Commits and pushes changes in `workingDirectory` back to the remote repository.
    public func saveChanges(commitMessage: String = "[appitool] Updated code signing certificates and profiles") async throws {
        // Stage all changes
        let (addExit, addOut) = try await runGit(args: ["add", "-A"], in: workingDirectory)
        guard addExit == 0 else {
            throw MatchError.gitOperationFailed("git add failed: \(addOut)")
        }

        // Check if there is anything to commit
        let (headExit, _) = try await runGit(args: ["rev-parse", "--verify", "HEAD"], in: workingDirectory)
        if headExit == 0 {
            let (diffExit, _) = try await runGit(args: ["diff-index", "--quiet", "HEAD", "--"], in: workingDirectory)
            if diffExit == 0 {
                // Clean working tree, nothing to commit
                return
            }
        }

        // Commit with explicit author to avoid failures on headless CI environments
        let commitArgs = [
            "-c", "user.name=appitool",
            "-c", "user.email=match@appitool.dev",
            "commit",
            "-m", commitMessage
        ]
        let (commitExit, commitOut) = try await runGit(args: commitArgs, in: workingDirectory)
        guard commitExit == 0 else {
            throw MatchError.gitOperationFailed("git commit failed: \(commitOut)")
        }

        // If repository is shallow, unshallow it before push to prevent git rejection
        let (revParseExit, revParseOut) = try await runGit(args: ["rev-parse", "--is-shallow-repository"], in: workingDirectory)
        if revParseExit == 0 && revParseOut.trimmingCharacters(in: .whitespacesAndNewlines) == "true" {
            _ = try await runGit(args: ["fetch", "--unshallow"], in: workingDirectory)
        }

        // Push
        let (pushExit, pushOut) = try await runGit(args: ["push", "origin", gitBranch], in: workingDirectory)
        guard pushExit == 0 else {
            throw MatchError.gitOperationFailed("git push failed: \(pushOut)")
        }
    }

    /// Safely cleans up the local temporary workspace directory.
    public func cleanup() {
        try? FileManager.default.removeItem(atPath: workingDirectory)
    }

    // MARK: - Private Helpers

    private func resolveAuthenticatedGitUrl() -> String {
        guard let token = gitToken, !token.isEmpty else {
            return gitUrl
        }

        // If HTTPS url (e.g., https://github.com/owner/repo.git), inject personal access token
        if gitUrl.hasPrefix("https://") {
            let withoutScheme = String(gitUrl.dropFirst("https://".count))
            // Check if credentials are not already in the URL
            if !withoutScheme.contains("@"), let slashIndex = withoutScheme.firstIndex(of: "/") {
                let host = String(withoutScheme[..<slashIndex])
                let path = String(withoutScheme[slashIndex...])
                return "https://x-access-token:\(token)@\(host)\(path)"
            }
        }
        return gitUrl
    }

    private func runGit(args: [String], in directory: String?) async throws -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        // -c core.askPass="" and -c credential.helper="" prevents hanging on credentials prompts without reading ProcessInfo
        process.arguments = ["-c", "core.askPass=", "-c", "credential.helper="] + args
        process.standardInput = FileHandle.nullDevice

        if let directory {
            process.currentDirectoryURL = URL(fileURLWithPath: directory)
        }

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let output = String(data: data, encoding: .utf8) ?? ""
        return (process.terminationStatus, output)
    }
}
