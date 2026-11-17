import Foundation
import Rainbow

/// A task that creates an annotated Git tag and pushes it to the configured remote.
public struct GitTagTask: Task, Sendable {
    public struct Input: Sendable {
        public let tagName: String
        public let message: String?
        public let remote: String
        public let push: Bool
        public let workingDirectory: String?

        public init(
            tagName: String,
            message: String? = nil,
            remote: String = "origin",
            push: Bool = true,
            workingDirectory: String? = nil
        ) {
            self.tagName = tagName
            self.message = message
            self.remote = remote
            self.push = push
            self.workingDirectory = workingDirectory
        }
    }

    public struct Output: Sendable {
        public let tagName: String
        public let pushed: Bool

        public init(tagName: String, pushed: Bool) {
            self.tagName = tagName
            self.pushed = pushed
        }
    }

    public enum GitTagError: LocalizedError, Sendable {
        case emptyTagName
        case notAGitRepository(String)
        case tagCreationFailed(tagName: String, message: String)
        case pushFailed(tagName: String, remote: String, message: String)

        public var errorDescription: String? {
            switch self {
            case .emptyTagName:
                return "Git tag name cannot be empty."
            case .notAGitRepository(let path):
                return "Directory is not a Git repository: \(path)"
            case .tagCreationFailed(let tagName, let message):
                return "Failed to create Git tag '\(tagName)': \(message)"
            case .pushFailed(let tagName, let remote, let message):
                return "Failed to push Git tag '\(tagName)' to '\(remote)': \(message)"
            }
        }
    }

    public init() {}

    @discardableResult
    public func run(_ input: Input) async throws -> Output {
        let tagName = input.tagName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tagName.isEmpty else {
            throw GitTagError.emptyTagName
        }

        let workDir = input.workingDirectory ?? FileManager.default.currentDirectoryPath
        let repoCheck = try Self.runGit(arguments: ["rev-parse", "--is-inside-work-tree"], workingDirectory: workDir)
        guard repoCheck.exitCode == 0 else {
            throw GitTagError.notAGitRepository(workDir)
        }

        var tagArgs: [String] = []
        if !Self.hasGitAuthorIdentity(in: workDir) {
            tagArgs.append(contentsOf: ["-c", "user.name=appitool", "-c", "user.email=tool@appibara.com"])
        }

        let tagMessage = input.message ?? "Release \(tagName)"
        tagArgs.append(contentsOf: ["tag", "-a", "-f", tagName, "-m", tagMessage])

        let tagResult = try Self.runGit(arguments: tagArgs, workingDirectory: workDir)
        guard tagResult.exitCode == 0 else {
            let reason = tagResult.stderr.isEmpty ? tagResult.stdout : tagResult.stderr
            throw GitTagError.tagCreationFailed(tagName: tagName, message: reason)
        }

        guard input.push else {
            return Output(tagName: tagName, pushed: false)
        }

        let remoteCheck = try Self.runGit(arguments: ["remote", "get-url", input.remote], workingDirectory: workDir)
        guard remoteCheck.exitCode == 0 else {
            Log("ℹ️ Created local Git tag '\(tagName)' (remote '\(input.remote)' not configured; skipping push).".yellow)
            return Output(tagName: tagName, pushed: false)
        }

        let pushResult = try Self.runGit(arguments: ["push", input.remote, tagName], workingDirectory: workDir)
        guard pushResult.exitCode == 0 else {
            let reason = pushResult.stderr.isEmpty ? pushResult.stdout : pushResult.stderr
            throw GitTagError.pushFailed(tagName: tagName, remote: input.remote, message: reason)
        }

        return Output(tagName: tagName, pushed: true)
    }

    // MARK: - Private Helpers

    private static func hasGitAuthorIdentity(in directory: String) -> Bool {
        let name = (try? runGit(arguments: ["config", "--get", "user.name"], workingDirectory: directory))
        let email = (try? runGit(arguments: ["config", "--get", "user.email"], workingDirectory: directory))
        let hasName = name?.exitCode == 0 && name?.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let hasEmail = email?.exitCode == 0 && email?.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        return hasName && hasEmail
    }

    private static func runGit(
        arguments: [String],
        workingDirectory: String
    ) throws -> (exitCode: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-c", "core.askPass=", "-c", "credential.helper="] + arguments
        process.standardInput = FileHandle.nullDevice
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let stdout = String(data: outData, encoding: .utf8) ?? ""
        let stderr = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (process.terminationStatus, stdout, stderr)
    }
}
