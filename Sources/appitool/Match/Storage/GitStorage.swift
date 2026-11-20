import Foundation

/// Manages Git repository operations for Match certificates and profiles storage.
public final class GitStorage: Sendable {
    public let workingDirectory: String
    let sshKeyPath: String?
    private let gitUrl: String
    private let gitBranch: String
    private let gitToken: String?
    private let sshKeyContent: String?
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
            .appendingPathComponent("match")
            .appendingPathComponent(UUID().uuidString).path
        self.workingDirectory = baseDir

        let resolvedSSHKey = Self.isSSHGitUrl(gitUrl) ? Self.resolveSSHPrivateKey(from: gitToken) : nil
        self.sshKeyContent = resolvedSSHKey
        self.sshKeyPath = resolvedSSHKey != nil ? "\(baseDir).ssh_key" : nil
    }

    deinit {
        if let sshKeyPath {
            try? FileManager.default.removeItem(atPath: sshKeyPath)
        }
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
        guard lsExit == 0 else {
            throw MatchError.gitCloneFailed(lsOut.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let branchExistsOnRemote = lsOut.contains("refs/heads/\(gitBranch)")

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
    /// If `filesToCommit` or `filesToDelete` are specified, only those specific files/directories are staged (matching Fastlane behavior).
    /// If both are nil, falls back to staging all changes via `git add -A`.
    public func saveChanges(
        filesToCommit: [String]? = nil,
        filesToDelete: [String]? = nil,
        commitMessage: String = "[appitool] Updated code signing certificates and profiles"
    ) async throws {
        if filesToCommit != nil || filesToDelete != nil {
            let toCommit = filesToCommit ?? []
            let toDelete = (filesToDelete ?? []).filter { !toCommit.contains($0) }
            guard !toCommit.isEmpty || !toDelete.isEmpty else {
                return
            }

            for file in toDelete {
                let (rmExit, rmOut) = try await runGit(args: ["rm", "-r", "--ignore-unmatch", file], in: workingDirectory)
                guard rmExit == 0 else {
                    throw MatchError.gitOperationFailed("git rm '\(file)' failed: \(rmOut)")
                }
            }

            for file in toCommit {
                let (addExit, addOut) = try await runGit(args: ["add", file], in: workingDirectory)
                guard addExit == 0 else {
                    throw MatchError.gitOperationFailed("git add '\(file)' failed: \(addOut)")
                }
            }
        } else {
            // Stage all changes
            let (addExit, addOut) = try await runGit(args: ["add", "-A"], in: workingDirectory)
            guard addExit == 0 else {
                throw MatchError.gitOperationFailed("git add failed: \(addOut)")
            }
        }

        // Check if there is anything to commit in the staging index
        let (headExit, _) = try await runGit(args: ["rev-parse", "--verify", "HEAD"], in: workingDirectory)
        if headExit == 0 {
            let (diffExit, _) = try await runGit(args: ["diff-index", "--quiet", "--cached", "HEAD", "--"], in: workingDirectory)
            if diffExit == 0 {
                // Clean index, nothing staged to commit
                return
            }
        }

        // Commit with explicit author to avoid failures on headless CI environments
        // Disable signing so global SSH/GPG commit signing in ~/.gitconfig does not prompt interactively
        let commitArgs = [
            "-c", "user.name=appitool",
            "-c", "user.email=tool@appibara.com",
            "-c", "commit.gpgsign=false",
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

    /// Safely cleans up the local temporary workspace directory, any temporary SSH key file, and its parent if empty.
    public func cleanup() {
        let fm = FileManager.default
        try? fm.removeItem(atPath: workingDirectory)
        if let sshKeyPath {
            try? fm.removeItem(atPath: sshKeyPath)
        }

        let matchDir = URL(fileURLWithPath: workingDirectory).deletingLastPathComponent()
        if let contents = try? fm.contentsOfDirectory(atPath: matchDir.path), contents.isEmpty {
            try? fm.removeItem(at: matchDir)
        }
    }

    // MARK: - Authentication & Process Helpers

    func resolveAuthenticatedGitUrl() -> String {
        guard let token = gitToken, !token.isEmpty else {
            return gitUrl
        }

        // If HTTPS url (e.g., https://github.com/owner/repo.git), inject personal access token
        if gitUrl.hasPrefix("https://"), Self.resolveSSHPrivateKey(from: token) == nil {
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

    func prepareSSHKeyIfNeeded() throws {
        guard let sshKeyContent, let sshKeyPath else { return }
        let fm = FileManager.default
        if !fm.fileExists(atPath: sshKeyPath) {
            let parentDir = URL(fileURLWithPath: sshKeyPath).deletingLastPathComponent().path
            try fm.createDirectory(atPath: parentDir, withIntermediateDirectories: true)
            let created = fm.createFile(
                atPath: sshKeyPath,
                contents: Data(sshKeyContent.utf8),
                attributes: [.posixPermissions: 0o600]
            )
            guard created else {
                throw MatchError.gitOperationFailed("Failed to write temporary SSH private key file.")
            }
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sshKeyPath)
        }
    }

    func gitEnvironment() -> [String: String] {
        var env = ["GIT_TERMINAL_PROMPT": "0"]
        if let sshKeyPath {
            env["GIT_SSH_COMMAND"] = "ssh -i \(Self.shellSingleQuote(sshKeyPath)) -o IdentitiesOnly=yes -o IdentityAgent=none -o BatchMode=yes -o StrictHostKeyChecking=accept-new"
        }
        return env
    }

    static func isSSHGitUrl(_ url: String) -> Bool {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.hasPrefix("ssh://") {
            return true
        }
        if trimmed.contains("://")
            || trimmed.hasPrefix("/")
            || trimmed.hasPrefix("./")
            || trimmed.hasPrefix("../")
            || trimmed.hasPrefix("~")
        {
            return false
        }
        guard let colonIndex = trimmed.firstIndex(of: ":") else {
            return false
        }
        let hostPart = trimmed[..<colonIndex]
        let pathPart = trimmed[trimmed.index(after: colonIndex)...]
        return hostPart.count > 1 && !hostPart.contains("/") && !pathPart.isEmpty
    }

    static func resolveSSHPrivateKey(from raw: String?, allowFilePath: Bool = true) -> String? {
        guard let raw else { return nil }
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.count >= 2,
           (trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"")) || (trimmed.hasPrefix("'") && trimmed.hasSuffix("'"))
        {
            trimmed = String(trimmed.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !trimmed.isEmpty else { return nil }

        if allowFilePath && !trimmed.contains("\n") && !trimmed.contains("-----BEGIN") {
            var filePath = trimmed
            if filePath.hasPrefix("~/") || filePath.hasPrefix("~\\") {
                let subpath = String(filePath.dropFirst(2))
                filePath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(subpath).path
            }
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: filePath, isDirectory: &isDirectory),
               !isDirectory.boolValue,
               let fileContent = try? String(contentsOfFile: filePath, encoding: .utf8)
            {
                return resolveSSHPrivateKey(from: fileContent, allowFilePath: false)
            }
        }

        let unescaped = unescapeLiteralNewlines(trimmed)
        if isPEMPrivateKey(unescaped) {
            return normalizePEMPrivateKey(unescaped)
        }

        let base64Candidate = trimmed
            .filter { !$0.isWhitespace }
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        guard !base64Candidate.isEmpty, base64Candidate.count % 4 != 1 else {
            return nil
        }
        let remainder = base64Candidate.count % 4
        let paddedBase64 = remainder == 0
            ? base64Candidate
            : base64Candidate + String(repeating: "=", count: 4 - remainder)

        if let decodedData = Data(base64Encoded: paddedBase64),
           let decodedString = String(data: decodedData, encoding: .utf8)
        {
            let decodedUnescaped = unescapeLiteralNewlines(decodedString)
            if isPEMPrivateKey(decodedUnescaped) {
                return normalizePEMPrivateKey(decodedUnescaped)
            }
        }

        return nil
    }

    static func shellSingleQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - Private Helpers

    private static func unescapeLiteralNewlines(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\r\\n", with: "\n")
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\r", with: "\n")
    }

    private static func isPEMPrivateKey(_ value: String) -> Bool {
        value.contains("-----BEGIN") && value.contains("PRIVATE KEY-----") && value.contains("-----END")
    }

    private static func normalizePEMPrivateKey(_ value: String) -> String {
        let normalizedLineEndings = value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return normalizedLineEndings + "\n"
    }

    private func runGit(args: [String], in directory: String?) async throws -> (Int32, String) {
        try prepareSSHKeyIfNeeded()
        let result = try await ProcessRunner.git(
            args,
            in: directory,
            environment: gitEnvironment(),
            combineOutput: true
        )
        return (result.exitCode, result.stdout)
    }
}
