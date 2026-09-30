import ArgumentParser
import Foundation
import AppleServices
import Rainbow

struct AppleAddDeviceCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add-device",
        abstract: "Registers a new Device on Apple Developer Portal."
    )

    @OptionGroup
    var appleCredentials: AppleCredentialsOptions

    @Option(name: .shortAndLong, help: "Device name (e.g. \"John's iPhone\").")
    var name: String

    @Option(name: .shortAndLong, help: "Device Unique Device Identifier (UDID).")
    var udid: String

    @Option(name: .shortAndLong, help: "Platform: ios, macos, universal. Defaults to ios.")
    var platform: String = "ios"

    func run() async throws {
        _ = try? EnvLoader.loadEnv()

        guard let service = try appleCredentials.makeService() else {
            print("Error: ".red.bold + "Missing App Store Connect credentials (configure APPLE_KEY, APPLE_KEY_ID, APPLE_ISSUER_ID).")
            return
        }

        print("🚀 Registering device '\(name)' (\(udid)) on Apple Developer Portal...".dim)
        let device = try await service.registerDevice(name: name, udid: udid, platform: platform)

        let devName = device.attributes?.name ?? name
        let devPlatform = device.attributes?.platform?.rawValue ?? platform
        let devClass = device.attributes?.deviceClass?.rawValue ?? "-"
        let devStatus = device.attributes?.status?.rawValue ?? "ENABLED"

        print("\n✓ Device registered successfully!".green.bold)
        print("  • Name: ".cyan + "\(devName)".bold)
        print("  • Portal ID: ".cyan + "\(device.id)")
        print("  • UDID: ".cyan + "\(udid)")
        print("  • Platform: ".cyan + "\(devPlatform)")
        print("  • Class: ".cyan + "\(devClass)")
        print("  • Status: ".cyan + "\(devStatus)".green)
        print("")
    }
}
