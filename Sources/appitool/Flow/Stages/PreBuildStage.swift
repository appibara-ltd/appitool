import Foundation

/// Stage 2: Fetches remote build numbers, bumps version/build number, and prepares project configuration.
struct PreBuildStage: FlowStageHandler {
    init() {}

    func execute(context: inout FlowContext) async throws {
        print("   ℹ Retrieving latest build number and configuring versioning...")
        // Will integrate: GetLatestBuildNumberTask, BumpBuildNumberTask
    }
}
