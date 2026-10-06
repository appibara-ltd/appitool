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
    func postbuild(context: inout FlowContext) async throws {}
    func prerelease(context: inout FlowContext) async throws {}
    func release(context: inout FlowContext) async throws {}

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

    /// Default post-release handler sends configured success notifications (Slack, KokoNo).
    func postrelease(context: inout FlowContext) async throws {
        let totalDuration = Date().timeIntervalSince(context.startTime)
        var metadata: [String: String] = [
            "Platform": context.platform.rawValue.uppercased(),
            "Distribution": context.distribution.rawValue,
            "Total Duration": String(format: "%.2fs", totalDuration),
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
            Log("🟡 Skipping notifications (dry-run mode).".yellow)
            return
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
