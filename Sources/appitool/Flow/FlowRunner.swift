import Foundation
import Rainbow

/// A stage handler responsible for executing a specific stage in the flow pipeline.
protocol FlowStageHandler: Sendable {
    func execute(context: inout FlowContext) async throws
}

/// The execution engine that orchestrates the 7-stage flow pipeline and handles error boundaries.
struct FlowRunner: Sendable {
    let platform: FlowContext.Platform?
    let distribution: BuildCommand.Distribution?
    let isDryRun: Bool
    let bundleId: String?
    let slackUrl: String?
    let kokonoUrl: String?
    let kokonoPublicKey: String?

    init(
        platform: FlowContext.Platform? = nil,
        distribution: BuildCommand.Distribution? = nil,
        isDryRun: Bool = false,
        bundleId: String? = nil,
        slackUrl: String? = nil,
        kokonoUrl: String? = nil,
        kokonoPublicKey: String? = nil
    ) {
        self.platform = platform
        self.distribution = distribution
        self.isDryRun = isDryRun
        self.bundleId = bundleId
        self.slackUrl = slackUrl
        self.kokonoUrl = kokonoUrl
        self.kokonoPublicKey = kokonoPublicKey
    }

    /// Runs the complete flow using an existing context, automatically resolving preset stage handlers.
    func run(
        context: inout FlowContext,
        stageHandlers: [FlowStage: any FlowStageHandler] = [:]
    ) async throws {
        printHeader(context: context)

        // Resolve handlers: context.preset handlers as baseline, overridden by any custom stageHandlers
        let effectiveHandlers = (context.preset?.stageHandlers ?? [:]).merging(stageHandlers) { _, custom in custom }

        do {
            for stage in FlowStage.allCases {
                try await runStage(stage, context: &context, handler: effectiveHandlers[stage])
            }
            printSuccessSummary(context: context)
        } catch {
            await handleFailure(error: error, context: context)
            throw error
        }
    }

    /// Runs the complete flow through its 7 sequential stages using context built from runner properties.
    func run(
        stageHandlers: [FlowStage: any FlowStageHandler] = [:]
    ) async throws {
        guard let platform, let distribution else {
            fatalError("FlowRunner must be initialized with platform and distribution, or run(context:stageHandlers:) must be called.")
        }
        var context = FlowContext(
            platform: platform,
            distribution: distribution,
            isDryRun: isDryRun,
            bundleId: bundleId,
            slackUrl: slackUrl,
            kokonoUrl: kokonoUrl,
            kokonoPublicKey: kokonoPublicKey
        )
        try await run(context: &context, stageHandlers: stageHandlers)
    }

    // MARK: - Stage Execution

    private func runStage(
        _ stage: FlowStage,
        context: inout FlowContext,
        handler: (any FlowStageHandler)?
    ) async throws {
        context.currentStage = stage
        let stageStart = Date()

        Log("\n\(stage.emoji) [\(stage.rawValue.uppercased())] ".cyan.bold + stage.displayName.bold)
        Log("   " + "─".repeated(50).dim)

        if let handler {
            try await handler.execute(context: &context)
        }

        let duration = Date().timeIntervalSince(stageStart)
        context.stageDurations[stage] = duration
        Log("   ✓ ".green.bold + "\(stage.displayName) completed in \(String(format: "%.2fs", duration))".dim)
    }

    // MARK: - Global Error Handling

    private func handleFailure(error: Error, context: FlowContext) async {
        let failingStage = context.currentStage ?? .setup
        Log("\n" + "=".repeated(60).red.bold)
        Log("💥 FLOW EXECUTION FAILED AT STAGE: [\(failingStage.rawValue.uppercased())]".red.bold)
        Log("   Reason: \(error.localizedDescription)".red)
        Log("=".repeated(60).red.bold)

        // Dispatch failure notifications to connected webhook services (Slack, KokoNo)
        await notifyFailureWebhooks(error: error, stage: failingStage, context: context)
    }

    private func notifyFailureWebhooks(error: Error, stage: FlowStage, context: FlowContext) async {
        let totalDuration = Date().timeIntervalSince(context.startTime)
        var metadata: [String: String] = [
            "Platform": context.platform.rawValue.uppercased(),
            "Distribution": context.distribution.rawValue,
            "Failing Stage": "\(stage.emoji) \(stage.displayName)",
            "Elapsed Time": String(format: "%.2fs", totalDuration),
        ]
        if let bundleId = context.bundleId {
            let key = context.platform == .ios ? "Bundle ID" : "Package Name"
            metadata[key] = bundleId
        }

        let title = "💥 AppiFlow \(context.platform.icon) \(context.distribution.icon)"
        let message = error.localizedDescription

        guard !context.isDryRun else {
            Log("   ℹ Skipping failure notifications (dry-run mode).".yellow)
            Log("     Title:   \(title)".dim)
            Log("     Message: \(message)".dim)
            for (key, value) in metadata.sorted(by: { $0.key < $1.key }) {
                Log("     • \(key): \(value)".dim)
            }
            return
        }

        await NotifyTask().notifyAllConfigured(
            status: .failure,
            title: title,
            message: message,
            metadata: metadata,
            slackUrl: context.slackUrl,
            kokonoUrl: context.kokonoUrl,
            kokonoPublicKey: context.kokonoPublicKey
        )
    }

    // MARK: - Presentation Helpers

    private func printHeader(context: FlowContext) {
        Log("\n" + "🌊 Starting AppiFlow: \(context.platform.rawValue.uppercased()) (\(context.distribution.rawValue))".cyan.bold)
        if let preset = context.preset {
            Log("   Preset: \(preset.name)".magenta.bold + " - \(preset.description)".dim)
        }
        Log("   Working Directory: \(context.projectDirectory.path)".dim)
        if context.isDryRun {
            Log("   Mode: DRY RUN (No mutations will be performed)".yellow.bold)
        }
    }

    private func printSuccessSummary(context: FlowContext) {
        let totalDuration = Date().timeIntervalSince(context.startTime)
        Log("\n" + "=".repeated(60).green.bold)
        Log("🎉 FLOW COMPLETED SUCCESSFULLY".green.bold)
        Log("   Platform:     \(context.platform.rawValue.uppercased())")
        Log("   Distribution: \(context.distribution.rawValue)")
        Log("   Total Time:   \(String(format: "%.2fs", totalDuration))")
        Log("─".repeated(60).dim)
        Log("   Stage Durations:")
        for stage in FlowStage.allCases {
            let duration = context.stageDurations[stage] ?? 0.0
            let name = stage.rawValue.padding(toLength: 12, withPad: " ", startingAt: 0)
            let formattedDuration = String(format: "%5.2fs", duration)
            Log("   • \(stage.emoji) \(name): \(formattedDuration)".dim)
        }
        Log("=".repeated(60).green.bold + "\n")
    }
}

private extension String {
    func repeated(_ count: Int) -> String {
        String(repeating: self, count: count)
    }
}
