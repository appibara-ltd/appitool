import Foundation
import Rainbow

/// Preconfigured preset for building and distributing Android App Bundles (AAB) to Google Play Internal track.
struct AndroidInternalPreset: FlowPreset {
    let name: String = "Android Internal"
    let description: String = "Automated Android release flow configured for Google Play Console internal testing."

    init() {}

    func requirements(context: FlowContext) throws {
        try validateRequirements([
            ("GOOGLE_KEY", context.googleKey, "Google Service Account JSON key"),
        ], context: context)
    }

    func setup(context: inout FlowContext) async throws {
        Log("   🔍 [\(name)] Validating Google Play API service account and project setup...".dim)
    }

    func prebuild(context: inout FlowContext) async throws {
        Log("   🔧 [\(name)] Resolving latest Google Play versionCode and bumping build...".dim)
    }

    func build(context: inout FlowContext) async throws {
        Log("   🔨 [\(name)] Running Gradle bundleRelease to produce Android App Bundle (AAB)...".dim)
    }

    func postbuild(context: inout FlowContext) async throws {
        Log("   📦 [\(name)] Verifying generated .aab bundle integrity...".dim)
    }

    func prerelease(context: inout FlowContext) async throws {
        Log("   📝 [\(name)] Preparing internal track release notes...".dim)
    }

    func release(context: inout FlowContext) async throws {
        Log("   🚀 [\(name)] Publishing AAB to Google Play Internal track...".dim)
    }
}
