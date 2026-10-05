import ArgumentParser
import Foundation
import AppStoreConnectAPI
import AppleServices
import Rainbow

struct AppleCreateProfileCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create-profile",
        abstract: "Creates and downloads a provisioning profile on Apple Developer Portal."
    )

    @OptionGroup
    var appleCredentials: AppleCredentialsOptions

    @Option(name: .shortAndLong, help: "Application Bundle Identifier (e.g. com.example.app).")
    var bundleId: String

    @Option(name: .shortAndLong, help: "Provisioning profile name. Defaults to 'match <type> <bundle-id>' if omitted.")
    var name: String?

    @Option(name: .shortAndLong, help: "Profile distribution type: appstore, development, adhoc, enterprise, developer_id. Defaults to appstore.")
    var type: String = "appstore"

    @Option(name: .customLong("platform"), help: "Target platform: ios, macos, tvos, catalyst. Defaults to ios.")
    var platform: String = "ios"

    @Option(name: .shortAndLong, help: "Certificate Portal ID. If omitted, the first valid active matching certificate is used.")
    var certificateId: String?

    @Option(name: .shortAndLong, help: "Comma-separated device Portal IDs for development/adhoc profiles. If omitted, all enabled devices are included.")
    var deviceIds: String?

    @Option(name: .shortAndLong, help: "Output file path to save the generated provisioning profile.")
    var output: String?

    func run() async throws {
        _ = try? EnvLoader.loadEnv()

        guard let service = try appleCredentials.makeService() else {
            Log("Error: ".red.bold + "Missing App Store Connect credentials (configure APPLE_KEY, APPLE_KEY_ID, APPLE_ISSUER_ID).")
            return
        }

        let cleanBundleId = bundleId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanBundleId.isEmpty else {
            Log("Error: ".red.bold + "Bundle ID cannot be empty.")
            return
        }

        let deviceList = deviceIds?.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }

        Log("🔍 Resolving App Identifier '\(cleanBundleId)' and resources on Apple Developer Portal...".dim)

        do {
            let result = try await service.createProvisioningProfile(
                bundleId: cleanBundleId,
                type: type,
                platform: platform,
                name: name,
                certificateId: certificateId,
                deviceIds: deviceList,
                outputPath: output
            )

            Log("\n✓ Provisioning profile created successfully!".green.bold)
            Log("  • Name: ".cyan + "\(result.profile.name)".bold)
            Log("  • Portal ID: ".cyan + "\(result.profile.id)".bold)
            Log("  • UUID: ".cyan + "\(result.profile.uuid)".bold)
            Log("  • Type: ".cyan + "\(result.profileType.rawValue)")
            Log("  • Bundle ID: ".cyan + "\(result.bundleId)")

            if let fileURL = result.savedURL {
                Log("  💾 Saved to: ".green.bold + "\(fileURL.path)")
            } else {
                Log("ℹ️ To save the profile to a file, re-run with -o, --output <path>.".dim)
            }
            Log("")
        } catch {
            Log("Error: ".red.bold + "Failed to create provisioning profile: \(error.localizedDescription)")
        }
    }
}
