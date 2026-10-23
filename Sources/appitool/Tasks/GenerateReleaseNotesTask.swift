import Foundation

/// A task that generates formatted Markdown release notes from git commits between two tags or revisions.
public struct GenerateReleaseNotesTask: Task, Sendable {
    public struct Input: Sendable {
        /// Starting tag or commit reference (exclusive).
        public let from: String?
        /// Ending tag or commit reference (inclusive). Defaults to HEAD if from is provided without to.
        public let to: String?
        /// Working directory of the git repository.
        public let workingDirectory: String?
        /// Optional path to write the generated markdown file.
        public let outputPath: String?

        public init(
            from: String? = nil,
            to: String? = nil,
            workingDirectory: String? = nil,
            outputPath: String? = nil
        ) {
            self.from = from
            self.to = to
            self.workingDirectory = workingDirectory
            self.outputPath = outputPath
        }
    }

    public enum ReleaseNotesError: LocalizedError, Sendable {
        case gitExecutionFailed(exitCode: Int32, message: String)
        case emptyCommitHistory
        case fileWriteFailed(path: String, error: String)

        public var errorDescription: String? {
            switch self {
            case .gitExecutionFailed(let exitCode, let message):
                return "git log failed with exit code \(exitCode): \(message)"
            case .emptyCommitHistory:
                return "No commits found for the specified range."
            case .fileWriteFailed(let path, let error):
                return "Failed to write release notes to \(path): \(error)"
            }
        }
    }

    public typealias Output = String

    public init() {}

    @discardableResult
    public func run(_ input: Input) async throws -> Output {
        let commitBaseURL = Self.resolveWebCommitBaseURL(workingDirectory: input.workingDirectory)

        var args = ["--no-pager", "log", "--no-merges", "--pretty=format:%h|%s"]

        if let from = input.from, let to = input.to {
            args.append("\(from)..\(to)")
        } else if let from = input.from {
            args.append("\(from)..HEAD")
        } else if let to = input.to {
            args.append(to)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + args
        process.standardInput = FileHandle.nullDevice

        if let workingDirectory = input.workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errorMsg = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Unknown git error"
            throw ReleaseNotesError.gitExecutionFailed(exitCode: process.terminationStatus, message: errorMsg)
        }

        guard let output = String(data: data, encoding: .utf8) else {
            return ""
        }

        let lines = output.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var features = CategoryBucket()
        var bugFixes = CategoryBucket()
        var others = CategoryBucket()

        for line in lines {
            let parts = line.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let hash = String(parts[0]).trimmingCharacters(in: .whitespaces)
            let subject = String(parts[1]).trimmingCharacters(in: .whitespaces)

            let (type, scope, description) = Self.parseCommit(subject)

            let hashFormatted: String
            if let commitBaseURL {
                hashFormatted = "([#\(hash)](\(commitBaseURL)/\(hash)))"
            } else {
                hashFormatted = "(#\(hash))"
            }

            let fullDescription = "\(description) \(hashFormatted)"

            switch type {
            case "feat":
                features.add(scope: scope, description: fullDescription)
            case "fix":
                bugFixes.add(scope: scope, description: fullDescription)
            default:
                others.add(scope: scope, description: fullDescription)
            }
        }

        var sections: [String] = []
        if let featuresSection = features.render(title: "### 🚀 Features") {
            sections.append(featuresSection)
        }
        if let fixesSection = bugFixes.render(title: "### 🐛 Bug Fixes") {
            sections.append(fixesSection)
        }
        if let othersSection = others.render(title: "### 🔧 Other Changes") {
            sections.append(othersSection)
        }

        let markdown = sections.joined(separator: "\n\n")

        if let outputPath = input.outputPath {
            let fileURL: URL
            if outputPath.hasPrefix("/") {
                fileURL = URL(fileURLWithPath: outputPath)
            } else {
                let baseDir = input.workingDirectory ?? FileManager.default.currentDirectoryPath
                fileURL = URL(fileURLWithPath: baseDir).appendingPathComponent(outputPath)
            }

            do {
                try markdown.write(to: fileURL, atomically: true, encoding: .utf8)
            } catch {
                throw ReleaseNotesError.fileWriteFailed(path: fileURL.path, error: error.localizedDescription)
            }
        }

        return markdown
    }

    // MARK: - Remote URL Resolution

    private static func resolveWebCommitBaseURL(workingDirectory: String?) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "config", "--get", "remote.origin.url"]
        process.standardInput = FileHandle.nullDevice

        if let workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        }

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            guard process.terminationStatus == 0,
                  var raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty else {
                return nil
            }

            // Remove trailing .git
            if raw.hasSuffix(".git") {
                raw = String(raw.dropLast(4))
            }

            // git@github.com:owner/repo -> https://github.com/owner/repo/commit
            if raw.hasPrefix("git@") {
                let withoutPrefix = String(raw.dropFirst(4))
                if let colonIndex = withoutPrefix.firstIndex(of: ":") {
                    let host = String(withoutPrefix[..<colonIndex])
                    let path = String(withoutPrefix[withoutPrefix.index(after: colonIndex)...])
                    return "https://\(host)/\(path)/commit"
                }
            }

            // ssh://git@github.com/owner/repo -> https://github.com/owner/repo/commit
            if raw.hasPrefix("ssh://git@") {
                let withoutPrefix = String(raw.dropFirst("ssh://git@".count))
                return "https://\(withoutPrefix)/commit"
            }

            // https://github.com/owner/repo -> https://github.com/owner/repo/commit
            if raw.hasPrefix("http://") || raw.hasPrefix("https://") {
                return "\(raw)/commit"
            }

            return nil
        } catch {
            return nil
        }
    }

    // MARK: - Internal Grouping & Parsing

    private struct CategoryBucket {
        var unscoped: [String] = []
        var scoped: [String: [String]] = [:]
        var scopeOrder: [String] = []

        mutating func add(scope: String?, description: String) {
            if let scope = scope, !scope.isEmpty {
                if scoped[scope] == nil {
                    scopeOrder.append(scope)
                    scoped[scope] = []
                }
                scoped[scope]?.append(description)
            } else {
                unscoped.append(description)
            }
        }

        func render(title: String) -> String? {
            guard !unscoped.isEmpty || !scoped.isEmpty else { return nil }
            var lines: [String] = [title]

            for item in unscoped {
                lines.append("- \(item)")
            }

            for scope in scopeOrder {
                guard let items = scoped[scope], !items.isEmpty else { continue }
                lines.append("* **\(scope)**:")
                for item in items {
                    lines.append("  - \(item)")
                }
            }

            return lines.joined(separator: "\n")
        }
    }

    private static func parseCommit(_ line: String) -> (type: String, scope: String?, description: String) {
        guard let regex = try? NSRegularExpression(pattern: #"^([a-zA-Z0-9_-]+)(?:\(([^)]+)\))?!?:[ \t]*(.*)$"#),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..<line.endIndex, in: line)) else {
            return ("other", nil, line)
        }

        func substring(at index: Int) -> String? {
            guard index < match.numberOfRanges else { return nil }
            let nsRange = match.range(at: index)
            guard nsRange.location != NSNotFound, let range = Range(nsRange, in: line) else { return nil }
            return String(line[range])
        }

        let type = substring(at: 1)?.lowercased() ?? "other"
        let scope = substring(at: 2)
        let description = substring(at: 3) ?? line

        return (type, scope, description)
    }
}
