import Foundation

/// Stage 3: Runs platform-specific build commands (xcodebuild for iOS, gradle for Android).
struct BuildStage: FlowStageHandler {
    init() {}

    func execute(context: inout FlowContext) async throws {
        print("   ℹ Compiling \(context.platform.rawValue) application for \(context.distribution.rawValue)...")
        // Will integrate: XcodebuildTask (iOS), GradleTask (Android)
    }
}
