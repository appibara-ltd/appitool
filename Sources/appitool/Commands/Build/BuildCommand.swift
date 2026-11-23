import ArgumentParser
import Foundation

struct BuildCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "build",
        abstract: "Builds the project for a specified platform and distribution.",
        subcommands: [
            BuildIOSCommand.self,
            BuildAndroidCommand.self,
        ]
    )

    enum Distribution: String, ExpressibleByArgument, CaseIterable, Sendable {
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

        var icon: String {
            switch self {
            case .appstore: return "🚀"
            case .adhoc: return "🧪"
            case .development: return "🛠️"
            }
        }

        var tagSuffix: String {
            switch self {
            case .appstore: return ""
            case .adhoc: return "_adhoc"
            case .development: return "_development"
            }
        }
    }
}
