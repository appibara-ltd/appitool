import ArgumentParser
import Foundation
import Rainbow

struct StatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Displays the tool name, purpose, and version."
    )

    func run() async throws {
        print("Tool: ".cyan.bold + "appitool".bold)
        print("Purpose: ".cyan.bold + "A unified CLI utility for Apple App Store Connect and Google Play operations.")
        print("Version: ".cyan.bold + "0.1.0".green)
    }
}
