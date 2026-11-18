import ArgumentParser
import Foundation
import GoogleServices
import Rainbow

struct FirebaseCreateReleaseCommand: BaseCommand {
    static let configuration = CommandConfiguration(
        commandName: "create-release",
        abstract: "Uploads an APK, AAB, or IPA binary to Firebase App Distribution, attaches notes, and distributes."
    )

    @OptionGroup
    var credentials: FirebaseCredentialsOptions

    @Option(name: .shortAndLong, help: "Path to binary file (.apk, .aab, or .ipa).")
    var binary: String

    @Option(name: .shortAndLong, help: "Optional release notes for testers.")
    var releaseNotes: String?

    @Option(name: .shortAndLong, help: "Comma-separated tester group aliases (e.g. 'internal,qa').")
    var testGroups: String?

    @Option(name: [.customShort("e"), .long], help: "Comma-separated tester email addresses.")
    var testerEmails: String?

    func execute() async throws {
        guard let service = try credentials.makeService() else {
            Log("Error: ".red.bold + "Missing Google credentials (configure GOOGLE_KEY in .env or via --google-key).")
            return
        }

        guard let appId = credentials.resolveAppId() else {
            Log("Error: ".red.bold + "Missing Firebase App ID (configure FIREBASE_IOS_APP_ID / FIREBASE_ANDROID_APP_ID in .env or via --firebase-app-id).")
            return
        }

        let parsedGroups = testGroups?.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let parsedEmails = testerEmails?.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }

        let task = UploadToFirebaseTask()
        let result = try await task.run(
            UploadToFirebaseTask.Input(
                binaryPath: binary,
                firebaseAppId: appId,
                service: service,
                releaseNotes: releaseNotes,
                testGroups: parsedGroups,
                testerEmails: parsedEmails
            )
        )

        Log("\n🟢 Release created and processed successfully!".green.bold)
        Log("  • Name: \(result.releaseName)".bold)
        if let version = result.displayVersion, let build = result.buildVersion {
            Log("  • Version: v\(version) (\(build))".bold.green)
        }
        if let consoleUri = result.firebaseConsoleUri {
            Log("  • Console: \(consoleUri)".cyan)
        }
        if let downloadUri = result.binaryDownloadUri {
            Log("  • Binary Download: \(downloadUri)".dim)
        }
    }
}
