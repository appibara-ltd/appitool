import ArgumentParser
import Foundation
import AppleServices
import Rainbow

struct AppleListDevicesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list-devices",
        abstract: "Lists Devices registered on Apple Developer Portal."
    )

    @OptionGroup
    var appleCredentials: AppleCredentialsOptions

    @Option(name: .shortAndLong, help: "Filter by platform (e.g. ios, macos, universal).")
    var platform: String?

    @Option(name: .shortAndLong, help: "Filter by status (e.g. enabled, disabled).")
    var status: String?

    @Option(name: .shortAndLong, help: "Filter by device name (case-insensitive substring match).")
    var name: String?

    @Option(name: .shortAndLong, help: "Maximum number of items to return (omit to fetch all).")
    var limit: Int?

    func run() async throws {
        _ = try? EnvLoader.loadEnv()

        guard let service = try appleCredentials.makeService() else {
            Log("Error: ".red.bold + "Missing App Store Connect credentials (configure APPLE_KEY, APPLE_KEY_ID, APPLE_ISSUER_ID).")
            return
        }

        Log("🔍 Fetching devices from Apple Developer Portal...".dim)
        let devices = try await service.fetchDevices(
            matchingName: name,
            platform: platform,
            status: status,
            limit: limit
        )

        if devices.isEmpty {
            if let filter = platform ?? name ?? status {
                Log("No devices matching filter '\(filter)' found on Apple Developer Portal.".yellow)
            } else {
                Log("No devices found on Apple Developer Portal.".yellow)
            }
            return
        }

        Log("\nFound \(devices.count) device(s):".bold)
        for device in devices {
            let nameStr = device.attributes?.name ?? "unnamed"
            let platformStr = device.attributes?.platform?.rawValue ?? "UNKNOWN"
            let classStr = device.attributes?.deviceClass?.rawValue ?? "-"
            let udidStr = device.attributes?.udid ?? "-"
            let modelStr = device.attributes?.model ?? "-"
            let status = device.attributes?.status
            let statusStr: String
            if status == .ENABLED {
                statusStr = "ENABLED".green
            } else if status == .DISABLED {
                statusStr = "DISABLED".red
            } else {
                statusStr = "UNKNOWN".yellow
            }

            Log("  • ".cyan + "\(nameStr)".bold + " [ID: \(device.id), Platform: \(platformStr), Class: \(classStr), Status: \(statusStr), Model: \(modelStr), UDID: \(udidStr)]".dim)
        }
        Log("")
    }
}
