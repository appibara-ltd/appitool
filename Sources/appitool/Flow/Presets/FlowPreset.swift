import Foundation
import Rainbow

/// An adapter wrapping an async stage closure into a FlowStageHandler.
struct AnyFlowStageHandler: FlowStageHandler {
    let action: @Sendable (inout FlowContext) async throws -> Void

    init(_ action: @escaping @Sendable (inout FlowContext) async throws -> Void) {
        self.action = action
    }

    func execute(context: inout FlowContext) async throws {
        try await action(&context)
    }
}

/// Error thrown when required environment variables or options are missing for a flow preset.
struct FlowRequirementError: LocalizedError, Sendable {
    let presetName: String
    let missing: [String]

    var errorDescription: String? {
        let list = missing.map { "  • \($0)" }.joined(separator: "\n")
        return "Missing required configuration for '\(presetName)':\n\(list)\nPlease configure them in your .env file or provide them as command-line arguments."
    }
}

/// Error thrown when a required build artifact is missing or empty during verification.
struct FlowArtifactError: LocalizedError, Sendable {
    let message: String

    var errorDescription: String? {
        message
    }
}

/// A contract defining the lifecycle functions executed across the 7 stages of a release flow.
protocol FlowPreset: Sendable {
    var name: String { get }
    var description: String { get }

    func requirements(context: FlowContext) throws
    func setup(context: inout FlowContext) async throws
    func prebuild(context: inout FlowContext) async throws
    func build(context: inout FlowContext) async throws
    func postbuild(context: inout FlowContext) async throws
    func prerelease(context: inout FlowContext) async throws
    func release(context: inout FlowContext) async throws
    func postrelease(context: inout FlowContext) async throws
}

extension FlowPreset {
    /// Converts this preset's stage functions into a dictionary of FlowStageHandlers.
    var stageHandlers: [FlowStage: any FlowStageHandler] {
        [
            .setup: AnyFlowStageHandler { try await self.setup(context: &$0) },
            .prebuild: AnyFlowStageHandler { try await self.prebuild(context: &$0) },
            .build: AnyFlowStageHandler { try await self.build(context: &$0) },
            .postbuild: AnyFlowStageHandler { try await self.postbuild(context: &$0) },
            .prerelease: AnyFlowStageHandler { try await self.prerelease(context: &$0) },
            .release: AnyFlowStageHandler { try await self.release(context: &$0) },
            .postrelease: AnyFlowStageHandler { try await self.postrelease(context: &$0) },
        ]
    }

    /// Dispatches execution to the matching stage method.
    func execute(stage: FlowStage, context: inout FlowContext) async throws {
        switch stage {
        case .setup:
            try await setup(context: &context)
        case .prebuild:
            try await prebuild(context: &context)
        case .build:
            try await build(context: &context)
        case .postbuild:
            try await postbuild(context: &context)
        case .prerelease:
            try await prerelease(context: &context)
        case .release:
            try await release(context: &context)
        case .postrelease:
            try await postrelease(context: &context)
        }
    }

    // Default no-op implementations for stages that a preset does not need to customize
    func requirements(context: FlowContext) throws {}
    func setup(context: inout FlowContext) async throws {}
    func prebuild(context: inout FlowContext) async throws {}
    func build(context: inout FlowContext) async throws {}
    func release(context: inout FlowContext) async throws {}

    /// Default post-build handler verifies that the expected platform artifact exists and is non-empty.
    func postbuild(context: inout FlowContext) async throws {
        let ext: String
        switch context.platform {
        case .ios:
            ext = "ipa"
        case .android:
            let defaultFormat: GradleTask.BuildFormat = (context.distribution == .appstore) ? .aab : .apk
            ext = (context.androidFormat ?? defaultFormat).rawValue
        }

        Log("📦 Verifying generated .\(ext) package integrity...".dim)

        if context.isDryRun {
            Log("🟡 Dry-run enabled: skipping .\(ext) artifact verification.".yellow)
            return
        }

        guard let artifactUrl = context.artifactPaths.first(where: { $0.pathExtension.lowercased() == ext })
            ?? context.metadata["\(ext)_path"].map({ URL(fileURLWithPath: $0) }),
            FileManager.default.fileExists(atPath: artifactUrl.path) else {
            throw FlowArtifactError(message: "Expected build artifact (.\(ext)) was not produced or could not be found.")
        }

        let attrs = try FileManager.default.attributesOfItem(atPath: artifactUrl.path)
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0 else {
            throw FlowArtifactError(message: "Build artifact '\(artifactUrl.lastPathComponent)' is empty (0 bytes).")
        }

        let formattedSize = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
        Log("   ✓ Verified \(ext.uppercased()) artifact: \(artifactUrl.lastPathComponent) (\(formattedSize))".dim)
    }

    /// Default pre-release handler generates store-compatible release notes from git commits
    /// using the platform-specific tag prefix (`🍏_` for iOS, `🤖_` for Android).
    func prerelease(context: inout FlowContext) async throws {
        if let existing = context.changelog?.trimmingCharacters(in: .whitespacesAndNewlines), !existing.isEmpty {
            context.changelog = existing
            Log("📝 Using existing release notes (\(existing.count) chars).".dim)
            logReleaseNotesPreview(existing)
            return
        }

        let tagPrefix = context.platform.tagPrefix
        let excludePatterns: [String] = (context.distribution == .appstore) ? ["*_adhoc", "*_development"] : []
        let maxLength = (context.platform == .android && context.distribution == .appstore) ? 500 : 4000
        let rawFrom = context.releaseNotesFrom?.trimmingCharacters(in: .whitespacesAndNewlines)
        let explicitFrom = (rawFrom?.isEmpty == false) ? rawFrom : nil

        if let explicitFrom {
            Log("📝 Generating release notes from git (from: '\(explicitFrom)')...".dim)
        } else {
            Log("📝 Generating release notes from git (tag prefix: '\(tagPrefix)')...".dim)
        }

        do {
            let output = try await GenerateReleaseNotesTask().run(
                .init(
                    from: explicitFrom,
                    workingDirectory: context.projectDirectory.path,
                    autoDetectLatestTag: true,
                    tagPrefix: tagPrefix,
                    excludeTagPatterns: excludePatterns,
                    plainText: true,
                    maxLength: maxLength
                )
            )

            switch output.source {
            case .explicitFrom(let ref):
                Log("   • Source: '\(ref)..HEAD'".dim)
            case .tag(let tag):
                Log("   • Source: tag '\(tag)..HEAD'".dim)
            case .fallback(let limit):
                let fallbackDesc = limit.map { "last \($0) commit(s)" } ?? "git history"
                Log("🚧 No matching '\(tagPrefix)*' tag found; fell back to \(fallbackDesc).".yellow)
            case .explicitToOnly(let ref):
                Log("   • Source: '\(ref)'".dim)
            case .fullHistory:
                Log("   • Source: full git history".dim)
            }

            let trimmed = output.notes.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                switch output.source {
                case .tag(let tag):
                    Log("ℹ️ No commits found since tag '\(tag)'; release notes left empty.".yellow)
                case .explicitFrom(let ref):
                    Log("ℹ️ No commits found since '\(ref)'; release notes left empty.".yellow)
                default:
                    Log("ℹ️ No commits found since last '\(tagPrefix)*' tag; release notes left empty.".yellow)
                }
            } else {
                context.changelog = trimmed
                Log("🟢 Generated release notes (\(trimmed.count) chars).".green)
                logReleaseNotesPreview(trimmed)
            }
        } catch {
            Log("🚧 Could not generate release notes from git: \(error.localizedDescription)".yellow)
        }
    }

    private func logReleaseNotesPreview(_ notes: String) {
        Log("   Preview:".dim)
        for line in notes.components(separatedBy: .newlines) {
            Log("   \(line)".dim)
        }
    }

    /// Validates a list of required configuration key-value pairs, printing missing items and throwing if any are missing.
    func validateRequirements(_ items: [(key: String, value: String?, description: String?)], context: FlowContext) throws {
        var missing: [String] = []
        for item in items {
            guard let val = item.value?.trimmingCharacters(in: .whitespacesAndNewlines), !val.isEmpty else {
                let desc = item.description.map { " (\($0))" } ?? ""
                missing.append("\(item.key)\(desc)")
                continue
            }
        }
        if !missing.isEmpty {
            Log("   🔴 [\(name)] Missing \(missing.count) required configuration value(s):".red.bold)
            for m in missing {
                Log("      • \(m)".red)
            }
            throw FlowRequirementError(presetName: name, missing: missing)
        }
        Log("   🟢 [\(name)] Requirements verified (\(items.count) checked).".green)
    }

    /// Default post-release handler creates/pushes the release Git tag and sends configured notifications (Slack, KokoNo).
    func postrelease(context: inout FlowContext) async throws {
        let totalDuration = Date().timeIntervalSince(context.startTime)
        var metadata: [String: String] = [
            "Platform": context.platform.rawValue.uppercased(),
            "Distribution": context.distribution.rawValue,
            "Total Duration": totalDuration.formattedDuration,
        ]
        if let version = context.version {
            metadata["Version"] = version
        }
        if let buildNumber = context.buildNumber {
            metadata["Build Number"] = buildNumber
        }
        if let bundleId = context.bundleId {
            let key = context.platform == .ios ? "Bundle ID" : "Package Name"
            metadata[key] = bundleId
        }

        let title = "🟢 AppiFlow \(context.platform.icon) \(context.distribution.icon)"
        let message = "Release completed successfully."

        guard !context.isDryRun else {
            if let tagName = context.releaseTagName {
                Log("🏷️  [Dry Run] Would create and push git tag: \(tagName)".yellow)
            }
            Log("🟡 Skipping notifications (dry-run mode).".yellow)
            return
        }

        if let tagName = context.releaseTagName {
            do {
                let tagResult = try await GitTagTask().run(
                    .init(
                        tagName: tagName,
                        message: "Release \(tagName)",
                        workingDirectory: context.projectDirectory.path
                    )
                )
                context.metadata["git_tag"] = tagResult.tagName
                metadata["Git Tag"] = tagResult.tagName
                if tagResult.pushed {
                    Log("🏷️  Created and pushed git tag: \(tagResult.tagName)".green.bold)
                }
            } catch {
                Log("🚧 Failed to create/push git tag '\(tagName)': \(error.localizedDescription)".yellow)
            }
        } else {
            Log("ℹ️ Skipping git tag creation (version or build number unavailable).".dim)
        }

        Log("📣 Dispatching release notifications...".dim)
        await NotifyTask().notifyAllConfigured(
            status: .success,
            title: title,
            message: message,
            metadata: metadata,
            slackUrl: context.slackUrl,
            kokonoUrl: context.kokonoUrl,
            kokonoPublicKey: context.kokonoPublicKey
        )
    }
}
