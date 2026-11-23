import ArgumentParser
import Foundation
import Rainbow

/// Command that inspects local iOS and Android project metadata (identifiers, versions, build numbers, targets, and flavors).
struct InspectCommand: BaseCommand {
    static let configuration = CommandConfiguration(
        commandName: "inspect",
        abstract: "Inspects local iOS and Android project metadata (identifiers, versions, build numbers, targets, and flavors)."
    )

    enum Platform: String, ExpressibleByArgument, CaseIterable, Sendable {
        case all
        case ios
        case android
    }

    @Option(name: .shortAndLong, help: "Specify platform to inspect (ios, android, all). Defaults to all.")
    var platform: Platform = .all

    @Option(name: .long, help: "Custom Xcode workspace/project name.")
    var workspaceName: String?

    @Option(name: .shortAndLong, help: "Xcode scheme name.")
    var scheme: String?

    @Option(name: .shortAndLong, help: "Xcode configuration name (e.g. Debug, Release).")
    var configuration: String?

    @Option(name: .long, help: "Android product flavor for resolving flavor-specific version info (e.g. staging, production).")
    var flavor: String?

    @Option(name: .long, help: "Path to project root directory (defaults to current directory).")
    var projectDir: String?

    @Flag(name: .long, help: "Output identifiers as JSON format.")
    var json: Bool = false

    func execute() async throws {
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
                let explicitScheme = scheme?.trimmingCharacters(in: .whitespacesAndNewlines)
                if let explicitScheme, !explicitScheme.isEmpty {
                    iosResult = try await XCodeTasks.getIosIdentifiers(
                        workspaceRoot: root,
                        workspaceName: workspaceName,
                        scheme: explicitScheme,
                        configuration: configuration
                    )
                } else {
                    iosResult = try await XCodeTasks.inspectAllIosSchemes(
                        workspaceRoot: root,
                        workspaceName: workspaceName,
                        configuration: configuration
                    )
                }
            }
        }

        // 2. Resolve Android if requested
        if platform == .all || platform == .android {
            if platform == .android && !hasAndroid {
                throw ValidationError("Android project not found (\(root.appendingPathComponent("android").path)).")
            }

            if hasAndroid {
                androidResult = try await AndroidTasks.inspectAndroidProject(
                    in: root,
                    flavor: flavor
                )
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

        if let schemes = result.schemes, schemes.count > 1 {
            let names = schemes.map(\.scheme).joined(separator: ", ")
            print("  Workspace: ".dim + result.workspaceName.bold + " | Schemes (\(schemes.count)): ".dim + names.bold)
            for s in schemes {
                print("")
                print("  🧭 Scheme: ".dim + s.scheme.cyan.bold + " | Configuration: ".dim + s.configuration.bold)
                printIosTargetSection(
                    mainAppTargetName: s.mainAppTargetName,
                    version: s.version,
                    buildNumber: s.buildNumber,
                    targets: s.targets,
                    indent: "    "
                )
            }
        } else {
            print("  Workspace: ".dim + result.workspaceName.bold + " | Scheme: ".dim + result.scheme.bold + " | Configuration: ".dim + result.configuration.bold)
            printIosTargetSection(
                mainAppTargetName: result.mainAppTargetName,
                version: result.version,
                buildNumber: result.buildNumber,
                targets: result.targets,
                indent: "  "
            )
        }
    }

    private func printIosTargetSection(
        mainAppTargetName: String?,
        version: String?,
        buildNumber: String?,
        targets: [XCodeTasks.ResolvedTargetInfo],
        indent: String
    ) {
        if let mainApp = mainAppTargetName {
            print("\(indent)🎯 Main App Target: ".dim + mainApp.cyan)
        }

        if let version {
            let buildSuffix = buildNumber.map { " (\($0))" } ?? ""
            print("\(indent)🏷️  Version:         ".dim + "\(version)\(buildSuffix)".green.bold)
        } else if let buildNumber {
            print("\(indent)🔢 Build Number:    ".dim + buildNumber.green.bold)
        }

        for target in targets {
            let isMain = target.name == mainAppTargetName
            let targetLabel = isMain
                ? "\(target.name.green.bold) \("(main)".dim)"
                : target.name.bold
            let sourceLabel = target.configurationSource != nil
                ? " [\(target.configurationSource!.rawValue)]".dim
                : ""
            let pType = target.productType ?? "unknown"

            print("\(indent)📦 " + targetLabel)
            print("\(indent)   Bundle ID: ".dim + target.bundleId.cyan + sourceLabel)
            print("\(indent)   Type:      ".dim + pType.dim)
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

        let trimmedFlavor = flavor?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasFlavorFilter = (trimmedFlavor?.isEmpty == false)
        let flavorBadge = hasFlavorFilter ? " [\(trimmedFlavor!)]".dim : ""
        if let versionName = result.versionName {
            let codeSuffix = result.versionCode.map { " (\($0))" } ?? ""
            print("  📌 Version:        ".dim + "\(versionName)\(codeSuffix)".green.bold + flavorBadge)
        } else if let versionCode = result.versionCode {
            print("  🔢 Version Code:   ".dim + versionCode.green.bold + flavorBadge)
        }

        if !result.flavors.isEmpty {
            print("  🎨 Flavors (\(result.flavors.count)):".dim)
            for f in result.flavors {
                print("     • ".dim + f.name.cyan.bold)
                if f.applicationId != nil || f.applicationIdSuffix != nil {
                    let appIdStr = f.applicationId ?? "—"
                    let suffixNote = f.applicationIdSuffix.map { " (suffix: \($0))".dim } ?? ""
                    print("       Application ID: ".dim + appIdStr.cyan + suffixNote)
                }
                if let vn = f.versionName {
                    let vcPart = f.versionCode.map { " (\($0))" } ?? ""
                    let suffixNote = f.versionNameSuffix.map { " (suffix: \($0))".dim } ?? ""
                    print("       Version:        ".dim + "\(vn)\(vcPart)".green + suffixNote)
                } else if let vc = f.versionCode {
                    print("       Version Code:   ".dim + vc.green)
                }
            }
        } else if hasFlavorFilter, let reqFlavor = trimmedFlavor {
            print("  🟡 Requested flavor '\(reqFlavor)' was not found in productFlavors.".yellow)
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
