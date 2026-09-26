import Foundation
import Rainbow

/// A stage handler responsible for executing a specific stage in the flow pipeline.
protocol FlowStageHandler: Sendable {
    func execute(context: inout FlowContext) async throws
}

/// The execution engine that orchestrates the 7-stage flow pipeline and handles error boundaries.
struct FlowRunner: Sendable {
    let platform: FlowContext.Platform
    let distribution: BuildCommand.Distribution
    let isDryRun: Bool
    let slackUrl: String?
    let kokonoUrl: String?
    let kokonoPublicKey: String?

    init(
        platform: FlowContext.Platform,
        distribution: BuildCommand.Distribution,
        isDryRun: Bool = false,
        slackUrl: String? = nil,
        kokonoUrl: String? = nil,
        kokonoPublicKey: String? = nil
    ) {
        self.platform = platform
        self.distribution = distribution
        self.isDryRun = isDryRun
        self.slackUrl = slackUrl
        self.kokonoUrl = kokonoUrl
        self.kokonoPublicKey = kokonoPublicKey
    }

    /// Runs the complete flow through its 7 sequential stages.
    func run(
        stageHandlers: [FlowStage: FlowStageHandler] = [:]
    ) async throws {
        var context = FlowContext(
            platform: platform,
            distribution: distribution,
            isDryRun: isDryRun,
            slackUrl: slackUrl,
            kokonoUrl: kokonoUrl,
            kokonoPublicKey: kokonoPublicKey
        )

        printHeader(context: context)

        do {
            for stage in FlowStage.allCases {
                try await runStage(stage, context: &context, customHandler: stageHandlers[stage])
            }
            printSuccessSummary(context: context)
        } catch {
            await handleFailure(error: error, context: context)
            throw error
        }
    }

    // MARK: - Stage Execution

    private func runStage(
        _ stage: FlowStage,
        context: inout FlowContext,
        customHandler: FlowStageHandler?
    ) async throws {
        context.currentStage = stage
        let stageStart = Date()

        print("\n\(stage.emoji)  [\(stage.rawValue.uppercased())] ".cyan.bold + stage.displayName.bold)
        print("   " + "─".repeated(50).dim)

        let handler = customHandler ?? defaultHandler(for: stage)
        try await handler.execute(context: &context)

        let duration = Date().timeIntervalSince(stageStart)
        context.stageDurations[stage] = duration
        print("   ✓ ".green.bold + "\(stage.displayName) completed in \(String(format: "%.2fs", duration))".dim)
    }

    // MARK: - Default Modular Stage Handlers

    private func defaultHandler(for stage: FlowStage) -> FlowStageHandler {
        switch stage {
        case .setup:
            return SetupStage()
        case .prebuild:
            return PreBuildStage()
        case .build:
            return BuildStage()
        case .postbuild:
            return PostBuildStage()
        case .prerelease:
            return PreReleaseStage()
        case .release:
            return ReleaseStage()
        case .postrelease:
            return PostReleaseStage()
        }
    }

    // MARK: - Global Error Handling

    private func handleFailure(error: Error, context: FlowContext) async {
        let failingStage = context.currentStage ?? .setup
        print("\n" + "=".repeated(60).red.bold)
        print("💥 FLOW EXECUTION FAILED AT STAGE: [\(failingStage.rawValue.uppercased())]".red.bold)
        print("   Reason: \(error.localizedDescription)".red)
        print("=".repeated(60).red.bold)

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
        if let appId = context.appId {
            metadata["App ID"] = appId
        }

        await NotifyTask().notifyAllConfigured(
            status: .failure,
            title: "💥 AppiFlow \(context.platform.icon) \(context.distribution.icon)",
            message: error.localizedDescription,
            metadata: metadata,
            slackUrl: context.slackUrl,
            kokonoUrl: context.kokonoUrl,
            kokonoPublicKey: context.kokonoPublicKey
        )
    }

    // MARK: - Presentation Helpers

    private func printHeader(context: FlowContext) {
        print("\n" + "🌊 Starting appitool flow: \(context.platform.rawValue.uppercased()) (\(context.distribution.rawValue))".cyan.bold)
        print("   Working Directory: \(context.projectDirectory.path)".dim)
        if context.isDryRun {
            print("   Mode: DRY RUN (No mutations will be performed)".yellow.bold)
        }
    }

    private func printSuccessSummary(context: FlowContext) {
        let totalDuration = Date().timeIntervalSince(context.startTime)
        print("\n" + "=".repeated(60).green.bold)
        print("🎉 FLOW COMPLETED SUCCESSFULLY".green.bold)
        print("   Platform:     \(context.platform.rawValue.uppercased())")
        print("   Distribution: \(context.distribution.rawValue)")
        print("   Total Time:   \(String(format: "%.2fs", totalDuration))")
        print("─".repeated(60).dim)
        print("   Stage Durations:")
        for stage in FlowStage.allCases {
            let duration = context.stageDurations[stage] ?? 0.0
            let name = stage.rawValue.padding(toLength: 12, withPad: " ", startingAt: 0)
            let formattedDuration = String(format: "%5.2fs", duration)
            print("   • \(stage.emoji) \(name): \(formattedDuration)".dim)
        }
        print("=".repeated(60).green.bold + "\n")
    }
}

private extension String {
    func repeated(_ count: Int) -> String {
        String(repeating: self, count: count)
    }
}
