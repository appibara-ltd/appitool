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
        if let bundleId = context.bundleId {
            let key = context.platform == .ios ? "Bundle ID" : "Package Name"
            metadata[key] = bundleId
        }

        await NotifyTask().notifyAllConfigured(
            status: .success,
            title: "✅ AppiFlow \(context.platform.icon) \(context.distribution.icon)",
            message: "Release completed successfully.",
            metadata: metadata,
            slackUrl: context.slackUrl,
            kokonoUrl: context.kokonoUrl,
            kokonoPublicKey: context.kokonoPublicKey
        )
    }
}
