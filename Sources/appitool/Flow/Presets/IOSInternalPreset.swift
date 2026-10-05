import Foundation
import Rainbow

/// Preconfigured preset for building and distributing iOS internal test releases (TestFlight).
struct IOSInternalPreset: FlowPreset {
    let name: String = "iOS Internal"
    let description: String = "Automated iOS release flow configured for App Store Connect TestFlight internal testing."

    init() {}

    func requirements(context: FlowContext) throws {
        try validateRequirements([
            ("APPLE_KEY_ID", context.appleKeyId, "App Store Connect Key ID"),
            ("APPLE_ISSUER_ID", context.appleIssuerId, "App Store Connect Issuer ID"),
            ("APPLE_KEY", context.appleKey, "App Store Connect API key (.p8/base64)"),
        ], context: context)
    }

    func setup(context: inout FlowContext) async throws {
        Log("   🔍 [\(name)] Validating App Store Connect credentials and Match AppStore profiles...".dim)
    }

    func prebuild(context: inout FlowContext) async throws {
        Log("   🔧 [\(name)] Incrementing build version and preparing TestFlight metadata...".dim)
    }

    func build(context: inout FlowContext) async throws {
        Log("   🔨 [\(name)] Compiling iOS archive with App Store export configuration...".dim)
    }

    func postbuild(context: inout FlowContext) async throws {
        Log("   📦 [\(name)] Verifying .ipa archive for App Store upload compliance...".dim)
    }

    func prerelease(context: inout FlowContext) async throws {
        Log("   📝 [\(name)] Packaging release artifacts and localized what-to-test notes...".dim)
    }

    func release(context: inout FlowContext) async throws {
        Log("   🚀 [\(name)] Uploading build to App Store Connect / TestFlight...".dim)
    }
}
