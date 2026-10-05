import ArgumentParser
import Foundation
import Rainbow

struct StatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Displays the tool name, purpose, and version."
    )

    func run() async throws {
        Log("Tool: ".cyan.bold + "appitool".bold)
        Log("Purpose: ".cyan.bold + "A unified CLI utility for Apple App Store Connect and Google Play operations.")
        Log("Version: ".cyan.bold + appitool.configuration.version.green)
    }
}
