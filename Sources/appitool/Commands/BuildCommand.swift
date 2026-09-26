import ArgumentParser
import Foundation
import Rainbow

struct BuildCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "build",
        abstract: "Builds the project for a specified platform and distribution."
    )

    enum Platform: String, ExpressibleByArgument, CaseIterable {
        case ios
        case android

        init?(argument: String) {
            switch argument.lowercased() {
            case "ios": self = .ios
            case "android": self = .android
            default: return nil
            }
        }
    }

    enum Distribution: String, ExpressibleByArgument, CaseIterable {
        case adhoc
        case development
        case appstore

        init?(argument: String) {
            switch argument.lowercased() {
            case "adhoc", "ad-hoc": self = .adhoc
            case "development", "dev": self = .development
            case "appstore", "app-store": self = .appstore
            default: return nil
            }
        }
    }

    @Argument(help: "Target platform (ios, android).")
    var platform: Platform

    @Option(name: [.short, .long], help: "Distribution method (adhoc, development, appstore).")
    var distribution: Distribution

    func run() async throws {
        print("Platform: ".cyan.bold + platform.rawValue.bold)
        print("Distribution: ".cyan.bold + distribution.rawValue.bold)
    }
}
