import Foundation

/// A task that generates formatted Markdown or plain-text release notes from git commits between two tags or revisions.
public struct GenerateReleaseNotesTask: Task, Sendable {
    public struct Input: Sendable {
        /// Starting tag or commit reference (exclusive).
        public let from: String?
        /// Ending tag or commit reference (inclusive). Defaults to `HEAD` when `from` or auto-tag detection is used.
        public let to: String?
        /// Working directory of the git repository.
        public let workingDirectory: String?
        /// Optional path to write the generated release notes file.
        public let outputPath: String?
        /// Automatically resolve the latest ancestor tag before `to` (or `HEAD`) when `from` is omitted.
        public let autoDetectLatestTag: Bool
        /// Optional prefix to filter tags when `autoDetectLatestTag` is enabled (e.g. `v`, `ios-v`, `android-`).
        public let tagPrefix: String?
        /// Optional tag glob patterns to exclude when `autoDetectLatestTag` is enabled (e.g. `*_adhoc`).
        public let excludeTagPatterns: [String]
        /// Maximum number of recent commits to include when `from` is omitted and no Git tag is found.
        public let fallbackMaxCommits: Int?
        /// Format output as clean plain text (without Markdown headings, bold markers, or URL links) for store uploads.
        public let plainText: Bool
        /// Whether to append commit hash / web link suffixes. Defaults to `!plainText`.
        public let includeCommitLinks: Bool?
        /// Optional maximum character length; truncates cleanly at line boundaries when exceeded.
        public let maxLength: Int?

        public init(
            from: String? = nil,
            to: String? = nil,
            workingDirectory: String? = nil,
            outputPath: String? = nil,
            autoDetectLatestTag: Bool = true,
            tagPrefix: String? = nil,
            excludeTagPatterns: [String] = [],
            fallbackMaxCommits: Int? = 20,
            plainText: Bool = false,
            includeCommitLinks: Bool? = nil,
            maxLength: Int? = nil
        ) {
            self.from = from
            self.to = to
            self.workingDirectory = workingDirectory
            self.outputPath = outputPath
            self.autoDetectLatestTag = autoDetectLatestTag
            self.tagPrefix = tagPrefix
            self.excludeTagPatterns = excludeTagPatterns
            self.fallbackMaxCommits = fallbackMaxCommits
            self.plainText = plainText
            self.includeCommitLinks = includeCommitLinks
            self.maxLength = maxLength
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
        let shouldIncludeLinks = input.includeCommitLinks ?? !input.plainText
        let commitBaseURL = shouldIncludeLinks
            ? Self.resolveWebCommitBaseURL(workingDirectory: input.workingDirectory)
            : nil

        var args = ["--no-pager", "log", "--no-merges", "--pretty=format:%h|%s"]
        let targetRef = (input.to?.isEmpty == false) ? input.to! : "HEAD"

        if let from = input.from, !from.isEmpty {
            args.append("\(from)..\(targetRef)")
        } else if input.autoDetectLatestTag {
            if let latestTag = Self.resolveLatestTag(
                for: targetRef,
                tagPrefix: input.tagPrefix,
                excludeTagPatterns: input.excludeTagPatterns,
                workingDirectory: input.workingDirectory
            ) {
                args.append("\(latestTag)..\(targetRef)")
            } else {
                if let maxCommits = input.fallbackMaxCommits, maxCommits > 0 {
                    args.append(contentsOf: ["-n", String(maxCommits)])
                }
                args.append(targetRef)
            }
        } else if let to = input.to, !to.isEmpty {
            args.append(to)
        }

        let gitResult = try Self.runGit(arguments: args, workingDirectory: input.workingDirectory)
        guard gitResult.exitCode == 0 else {
            let errorMsg = gitResult.stderr.isEmpty ? "Unknown git error" : gitResult.stderr
            throw ReleaseNotesError.gitExecutionFailed(exitCode: gitResult.exitCode, message: errorMsg)
        }

        let lines = gitResult.stdout.components(separatedBy: .newlines)
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

            let fullDescription: String
            if shouldIncludeLinks {
                let hashFormatted = commitBaseURL.map { "([#\(hash)](\($0)/\(hash)))" } ?? "(#\(hash))"
                fullDescription = "\(description) \(hashFormatted)"
            } else {
                fullDescription = description
            }

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
        let categoryDefinitions: [(bucket: CategoryBucket, markdownTitle: String, plainTitle: String)] = [
            (features, "### 🚀 Features", "🚀 Features"),
            (bugFixes, "### 🐛 Bug Fixes", "🐛 Bug Fixes"),
            (others, "### 🔧 Other Changes", "🔧 Other Changes"),
        ]

        for category in categoryDefinitions {
            let title = input.plainText ? category.plainTitle : category.markdownTitle
            if let rendered = category.bucket.render(title: title, plainText: input.plainText) {
                sections.append(rendered)
            }
        }

        var formattedNotes = sections.joined(separator: "\n\n")
        if let maxLength = input.maxLength {
            formattedNotes = Self.truncate(formattedNotes, maxLength: maxLength)
        }

        if let outputPath = input.outputPath {
            let fileURL: URL
            if outputPath.hasPrefix("/") {
                fileURL = URL(fileURLWithPath: outputPath)
            } else {
                let baseDir = input.workingDirectory ?? FileManager.default.currentDirectoryPath
                fileURL = URL(fileURLWithPath: baseDir).appendingPathComponent(outputPath)
            }

            do {
                try formattedNotes.write(to: fileURL, atomically: true, encoding: .utf8)
            } catch {
                throw ReleaseNotesError.fileWriteFailed(path: fileURL.path, error: error.localizedDescription)
            }
        }

        return formattedNotes
    }

    // MARK: - Git Helpers

    private static func runGit(
        arguments: [String],
        workingDirectory: String?
    ) throws -> (exitCode: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.standardInput = FileHandle.nullDevice

        if let workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        }

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

    /// Resolves the latest ancestor tag before `targetRef` (optionally filtered by `tagPrefix`).
    /// If `targetRef` itself sits on a matching tag, returns the previous matching tag (`<targetRef>^`) so the diff is non-empty.
    private static func resolveLatestTag(
        for targetRef: String,
        tagPrefix: String?,
        excludeTagPatterns: [String],
        workingDirectory: String?
    ) -> String? {
        var matchArgs: [String] = []
        if let rawPrefix = tagPrefix?.trimmingCharacters(in: .whitespacesAndNewlines), !rawPrefix.isEmpty {
            let glob = rawPrefix.hasSuffix("*") ? rawPrefix : "\(rawPrefix)*"
            matchArgs.append(contentsOf: ["--match", glob])
        }
        for rawPattern in excludeTagPatterns {
            let pattern = rawPattern.trimmingCharacters(in: .whitespacesAndNewlines)
            if !pattern.isEmpty {
                matchArgs.append(contentsOf: ["--exclude", pattern])
            }
        }

        if let exact = try? runGit(
            arguments: ["describe", "--tags", "--exact-match"] + matchArgs + [targetRef],
            workingDirectory: workingDirectory
        ), exact.exitCode == 0 {
            if let prev = try? runGit(
                arguments: ["describe", "--tags", "--abbrev=0"] + matchArgs + ["\(targetRef)^"],
                workingDirectory: workingDirectory
            ), prev.exitCode == 0 {
                let tag = prev.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                return tag.isEmpty ? nil : tag
            }
            return nil
        }

        guard let latest = try? runGit(
            arguments: ["describe", "--tags", "--abbrev=0"] + matchArgs + [targetRef],
            workingDirectory: workingDirectory
        ), latest.exitCode == 0 else {
            return nil
        }

        let tag = latest.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return tag.isEmpty ? nil : tag
    }

    // MARK: - Remote URL Resolution

    private static func resolveWebCommitBaseURL(workingDirectory: String?) -> String? {
        guard let result = try? runGit(arguments: ["config", "--get", "remote.origin.url"], workingDirectory: workingDirectory),
              result.exitCode == 0 else {
            return nil
        }

        var raw = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }

        if raw.hasSuffix(".git") {
            raw = String(raw.dropLast(4))
        }

        if raw.hasPrefix("git@") {
            let withoutPrefix = String(raw.dropFirst(4))
            if let colonIndex = withoutPrefix.firstIndex(of: ":") {
                let host = String(withoutPrefix[..<colonIndex])
                let path = String(withoutPrefix[withoutPrefix.index(after: colonIndex)...])
                return "https://\(host)/\(path)/commit"
            }
        }

        if raw.hasPrefix("ssh://git@") {
            let withoutPrefix = String(raw.dropFirst("ssh://git@".count))
            return "https://\(withoutPrefix)/commit"
        }

        if raw.hasPrefix("http://") || raw.hasPrefix("https://") {
            return "\(raw)/commit"
        }

        return nil
    }

    // MARK: - Formatting & Truncation

    private static func truncate(_ text: String, maxLength: Int) -> String {
        guard maxLength > 0 else { return "" }
        guard text.count > maxLength else { return text }
        guard maxLength > 3 else { return String(text.prefix(maxLength)) }

        let suffix = "\n..."
        let lines = text.components(separatedBy: .newlines)
        var kept: [String] = []
        var currentLength = 0

        for line in lines {
            let separatorCost = kept.isEmpty ? 0 : 1
            let nextLength = currentLength + separatorCost + line.count
            if nextLength + suffix.count <= maxLength {
                kept.append(line)
                currentLength = nextLength
            } else {
                break
            }
        }

        if !kept.isEmpty {
            return kept.joined(separator: "\n") + suffix
        }

        return String(text.prefix(maxLength - 3)) + "..."
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

        func render(title: String, plainText: Bool) -> String? {
            guard !unscoped.isEmpty || !scoped.isEmpty else { return nil }
            var lines: [String] = [title]

            for item in unscoped {
                lines.append("- \(item)")
            }

            for scope in scopeOrder {
                guard let items = scoped[scope], !items.isEmpty else { continue }
                lines.append(plainText ? "- \(scope):" : "* **\(scope)**:")
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
