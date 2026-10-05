import ArgumentParser
import Foundation
import Rainbow

/// Command that lists iOS bundle identifiers and Android applicationId/namespace.
struct ListIdentifiersCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list-identifiers",
        abstract: "List iOS bundle identifiers and Android applicationId/namespace."
    )

    enum Platform: String, ExpressibleByArgument, CaseIterable, Sendable {
        case all
        case ios
        case android
    }

    @Option(name: .shortAndLong, help: "Specify platform to inspect (ios, android, all). Defaults to all.")
    var platform: Platform = .all

    @Option(name: .shortAndLong, help: "Custom Xcode workspace/project name.")
    var workspaceName: String?

    @Option(name: .shortAndLong, help: "Xcode scheme name.")
    var scheme: String?

    @Option(name: .shortAndLong, help: "Xcode configuration name (e.g. Debug, Release).")
    var configuration: String?

    @Option(name: [.short, .long, .customLong("workspace-root")], help: "Path to project root directory (defaults to current directory).")
    var projectDir: String?

    @Flag(name: .long, help: "Output identifiers as JSON format.")
    var json: Bool = false

    func run() async throws {
        _ = try? EnvLoader.loadEnv()

        let root = URL(fileURLWithPath: projectDir ?? FileManager.default.currentDirectoryPath)
        let hasIos = XCodeTasks.hasIosProject(in: root)
        let hasAndroid = AndroidTasks.hasAndroidProject(in: root)

        var iosResult: XCodeTasks.IosIdentifiersResult? = nil
        var androidResult: AndroidTasks.AndroidIdentifiersResult? = nil

        // 1. Resolve iOS if requested
        if platform == .all || platform == .ios {
            if platform == .ios && !hasIos {
                throw ValidationError("iOS project not found (\(root.appendingPathComponent("ios").path)).")
            }

            if hasIos {
                iosResult = try await XCodeTasks.getIosIdentifiers(
                    workspaceRoot: root,
                    workspaceName: workspaceName,
                    scheme: scheme,
                    configuration: configuration
                )
            }
        }

        // 2. Resolve Android if requested
        if platform == .all || platform == .android {
            if platform == .android && !hasAndroid {
                throw ValidationError("Android project not found (\(root.appendingPathComponent("android").path)).")
            }

            if hasAndroid {
                androidResult = try AndroidTasks.getAndroidIdentifiers(workspaceRoot: root)
            }
        }

        if iosResult == nil && androidResult == nil {
            throw ValidationError("Neither iOS nor Android project found in the specified directory (\(root.path)).")
        }

        // Output as JSON
        if json {
            struct JsonOutput: Codable {
                let ios: XCodeTasks.IosIdentifiersResult?
                let android: AndroidTasks.AndroidIdentifiersResult?
            }

            let combined = JsonOutput(ios: iosResult, android: androidResult)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(combined)
            if let jsonString = String(data: data, encoding: .utf8) {
                print(jsonString)
            }
            return
        }

        // Formatted console output
        if let ios = iosResult {
            printIosIdentifiers(ios, root: root)
        }

        if let android = androidResult {
            printAndroidIdentifiers(android, root: root)
        }
    }

    // MARK: - Console Output Helpers

    private func printIosIdentifiers(_ result: XCodeTasks.IosIdentifiersResult, root: URL) {
        print("\n" + "◆ ".blue.bold + "iOS".bold)
        let relRoot = relativePath(from: root, to: result.iosRoot)
        print("  Path: ".dim + relRoot.bold)
        print("  Workspace: ".dim + result.workspaceName.bold + " | Scheme: ".dim + result.scheme.bold + " | Configuration: ".dim + result.configuration.bold)

        if let mainApp = result.mainAppTargetName {
            print("  🎯 Main App Target: ".dim + mainApp.cyan)
        }

        for target in result.targets {
            let isMain = target.name == result.mainAppTargetName
            let targetLabel = isMain
                ? "\(target.name.green.bold) \("(main)".dim)"
                : target.name.bold
            let sourceLabel = target.configurationSource != nil
                ? " [\(target.configurationSource!.rawValue)]".dim
                : ""
            let pType = target.productType ?? "unknown"

            print("  📦 " + targetLabel)
            print("     Bundle ID: ".dim + target.bundleId.cyan + sourceLabel)
            print("     Type:      ".dim + pType.dim)
        }
    }

    private func printAndroidIdentifiers(_ result: AndroidTasks.AndroidIdentifiersResult, root: URL) {
        print("\n" + "◆ ".blue.bold + "Android".bold)
        let relRoot = relativePath(from: root, to: URL(fileURLWithPath: result.androidRoot))
        print("  Path: ".dim + relRoot.bold)

        if let appId = result.applicationId {
            print("  🤖 Application ID: ".dim + appId.cyan.bold)
        }

        if let namespace = result.namespace {
            print("  🏷️  Namespace:      ".dim + namespace.magenta)
        }

        if let pkg = result.packageName, pkg != result.namespace {
            print("  📦 Package Name:   ".dim + pkg.yellow)
        }

        if !result.flavors.isEmpty {
            let flavorStrings = result.flavors.map { f in
                var parts = [f.name.cyan]
                if let aId = f.applicationId { parts.append("appId: \(aId)") }
                if let suffix = f.applicationIdSuffix { parts.append("suffix: \(suffix)") }
                return parts.joined(separator: " ")
            }
            print("  🎨 Flavors:        ".dim + flavorStrings.joined(separator: " | "))
        }
    }

    private func relativePath(from base: URL, to target: URL) -> String {
        let basePath = base.standardized.path
        let targetPath = target.standardized.path

        if targetPath.hasPrefix(basePath) {
            let relative = String(targetPath.dropFirst(basePath.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return relative.isEmpty ? "." : relative
        }
        return targetPath
    }
}
