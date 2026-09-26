import Foundation

/// Stage 6: Distributes build artifacts to App Store Connect / TestFlight, Google Play, or Firebase.
struct ReleaseStage: FlowStageHandler {
    init() {}

    func execute(context: inout FlowContext) async throws {
        print("   ℹ Uploading release to \(context.distribution.rawValue)...")
        // Will integrate: TestFlightUploadTask, PlayConsoleUploadTask, FirebaseUploadTask
    }
}
