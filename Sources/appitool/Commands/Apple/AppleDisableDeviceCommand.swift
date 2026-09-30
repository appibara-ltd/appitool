import ArgumentParser
import Foundation
import AppleServices
import Rainbow

struct AppleDisableDeviceCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "disable-device",
        abstract: "Disables a registered Device by UDID on Apple Developer Portal."
    )

    @OptionGroup
    var appleCredentials: AppleCredentialsOptions

    @Option(name: .shortAndLong, help: "Device Unique Device Identifier (UDID).")
    var udid: String

    func run() async throws {
        _ = try? EnvLoader.loadEnv()

        guard let service = try appleCredentials.makeService() else {
            print("Error: ".red.bold + "Missing App Store Connect credentials (configure APPLE_KEY, APPLE_KEY_ID, APPLE_ISSUER_ID).")
            return
        }

        print("🔍 Searching for device with UDID '\(udid)' on Apple Developer Portal...".dim)
        guard let device = try await service.findDevice(udid: udid) else {
            print("Error: ".red.bold + "Device with UDID '\(udid)' not found on Apple Developer Portal.")
            return
        }

        let devName = device.attributes?.name ?? "unnamed"
        let devUdid = device.attributes?.udid ?? udid

        print("🚫 Disabling device '\(devName)' [ID: \(device.id), UDID: \(devUdid)]...".dim)

        let updatedDevice = try await service.disableDevice(id: device.id)
        let statusStr = updatedDevice.attributes?.status?.rawValue ?? "DISABLED"

        print("\n✓ Device disabled successfully!".green.bold)
        print("  • Name: ".cyan + "\(devName)".bold)
        print("  • Portal ID: ".cyan + "\(updatedDevice.id)")
        print("  • UDID: ".cyan + "\(devUdid)")
        print("  • Status: ".cyan + "\(statusStr)".red.bold)
        print("  • Note: Disabled devices will no longer be included in new provisioning profiles.".dim)
        print("")
    }
}
