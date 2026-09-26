import Foundation

/// Stage 7: Dispatches release notifications (Slack, KokoNo) and prints execution summary.
struct PostReleaseStage: FlowStageHandler {
    init() {}

    func execute(context: inout FlowContext) async throws {
        print("   ℹ Sending notifications and publishing summary...")

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
        if let appId = context.appId {
            metadata["App ID"] = appId
        }

        await NotifyTask().notifyAllConfigured(
            status: .success,
            title: "appitool flow finished: \(context.platform.rawValue.uppercased()) (\(context.distribution.rawValue))",
            message: "Release completed successfully.",
            metadata: metadata,
            kokonoUrl: context.kokonoUrl,
            kokonoPublicKey: context.kokonoPublicKey
        )
    }
}
