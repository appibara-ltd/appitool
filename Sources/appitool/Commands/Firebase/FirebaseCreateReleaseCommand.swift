import ArgumentParser
import Foundation
import GoogleServices
import Rainbow

struct FirebaseCreateReleaseCommand: BaseCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Uploads an APK, AAB, or IPA binary to Firebase App Distribution, attaches notes, and distributes."
    )

    @OptionGroup
    var credentials: FirebaseCredentialsOptions

    @Option(name: .long, help: "Path to binary file (.apk, .aab, or .ipa).")
    var binary: String

    @Option(name: .long, help: "Optional release notes for testers.")
    var releaseNotes: String?

    @Option(name: .long, help: "Comma-separated tester group aliases (e.g. 'internal,qa').")
    var testGroups: String?

    @Option(name: .long, help: "Comma-separated tester email addresses.")
    var testerEmails: String?

    func execute() async throws {
        let service = try credentials.requireService()
        let appId = try credentials.requireAppId()

        let parsedGroups = CLIValues.commaSeparatedOrNil(testGroups)
        let parsedEmails = CLIValues.commaSeparatedOrNil(testerEmails)

        let task = UploadToFirebaseTask()
        let result = try await task.run(
            UploadToFirebaseTask.Input(
                binaryPath: binary,
                firebaseAppId: appId,
                service: service,
                releaseNotes: releaseNotes,
                testGroups: parsedGroups,
                testerEmails: parsedEmails,
                ensureGroupsExist: true
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
