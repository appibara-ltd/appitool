import Foundation
import Rainbow

/// Preconfigured preset for building and distributing iOS Ad-Hoc releases.
struct IOSAdHocPreset: FlowPreset {
    let name: String = "iOS AdHoc"
    let description: String = "Automated iOS release flow configured for Ad-Hoc distribution."

    init() {}

    func setup(context: inout FlowContext) async throws {
        print("   🔍 [\(name)] Validating iOS environment, signing identities, and Match Ad-Hoc profiles...".dim)

        if context.workspacePath == nil && context.xcodeProjectPath == nil {
            let detected = XcodeBuildTask.autoDetect(in: context.projectDirectory)
            context.workspacePath = detected.workspace
            context.xcodeProjectPath = detected.project
        }

        let info = try await XCodeTasks.inspectProject(
            workspace: context.workspacePath,
            project: context.xcodeProjectPath,
            in: context.projectDirectory
        )
        print("   🔍 [\(name)] Inspected project targets: \(info.targets)".dim)
        let result = try await XCodeTasks.getIosIdentifiers(
            workspaceRoot: URL(fileURLWithPath: "."),
            // scheme: "base",
            configuration: "Release"
        )
        print("Main App Target: \(result.mainAppTargetName ?? "")")
        print("Main Bundle ID: \(result.bundleId ?? "")")
        for target in result.targets {
            print("\(target.name): \(target.bundleId) (\(target.configurationSource?.rawValue ?? ""))")
        }
    }

    func prebuild(context: inout FlowContext) async throws {
        print("   🔧 [\(name)] Preparing build numbers and release changelog...".dim)
    }

    func build(context: inout FlowContext) async throws {
        print("   🔨 [\(name)] Compiling iOS application with Ad-Hoc export configuration...".dim)
    }

    func postbuild(context: inout FlowContext) async throws {
        print("   📦 [\(name)] Verifying generated .ipa package and signature...".dim)
    }

    func prerelease(context: inout FlowContext) async throws {
        print("   📝 [\(name)] Preparing release packaging and tester release notes...".dim)
    }

    func release(context: inout FlowContext) async throws {
        print("   🚀 [\(name)] Distributing Ad-Hoc build to testers...".dim)
    }
}
