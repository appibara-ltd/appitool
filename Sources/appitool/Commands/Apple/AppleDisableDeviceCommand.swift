import ArgumentParser
import Foundation
import AppleServices
import Rainbow

struct AppleDisableDeviceCommand: DestructiveCommand {
    static let configuration = CommandConfiguration(
        commandName: "disable",
        abstract: "Disables a registered Device by UDID on Apple Developer Portal."
    )

    var destructiveCommandDescription: String { "apple devices disable" }

    @OptionGroup
    var appleCredentials: AppleCredentialsOptions

    @OptionGroup
    var ciOptions: GlobalCIOptions

    @Option(name: .long, help: "Device Unique Device Identifier (UDID).")
    var udid: String

    func execute() async throws {
        let service = try appleCredentials.requireService()

        Log("🔍 Searching for device with UDID '\(udid)' on Apple Developer Portal...".dim)
        guard let device = try await service.findDevice(udid: udid) else {
            throw CommandError("Device with UDID '\(udid)' not found on Apple Developer Portal.")
        }

        let devName = device.attributes?.name ?? "unnamed"
        let devUdid = device.attributes?.udid ?? udid

        Log("🚫 Disabling device '\(devName)' [ID: \(device.id), UDID: \(devUdid)]...".dim)

        let updatedDevice = try await service.disableDevice(id: device.id)
        let statusStr = updatedDevice.attributes?.status?.rawValue ?? "DISABLED"

        Log("\n🟢 Device disabled successfully!".green.bold)
        Log("  • Name: ".cyan + "\(devName)".bold)
        Log("  • Portal ID: ".cyan + "\(updatedDevice.id)")
        Log("  • UDID: ".cyan + "\(devUdid)")
        Log("  • Status: ".cyan + "\(statusStr)".red.bold)
        Log("  • Note: Disabled devices will no longer be included in new provisioning profiles.".dim)
        Log("")
    }
}
