import Foundation
import Rainbow

/// Stage 7: Dispatches release notifications (Slack, KokoNo) and prints execution summary.
struct PostReleaseStage: FlowStageHandler {
    init() {}

    func execute(context: inout FlowContext) async throws {
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

        let title = "✅ AppiFlow \(context.platform.icon) \(context.distribution.icon)"
        let message = "Release completed successfully."

        guard !context.isDryRun else {
            print("   ℹ Skipping notifications (dry-run mode).".yellow)
            print("     Title:   \(title)".dim)
            print("     Message: \(message)".dim)
            for (key, value) in metadata.sorted(by: { $0.key < $1.key }) {
                print("     • \(key): \(value)".dim)
            }
            return
        }

        print("   ℹ Sending notifications and publishing summary...")

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
