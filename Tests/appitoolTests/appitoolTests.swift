import Testing
import ArgumentParser
@testable import appitool

@Test func testFlowAndroidRejectsApkForAppStore() throws {
    #expect(throws: (any Error).self) {
        _ = try appitool.parseAsRoot(["flow", "android", "-d", "appstore", "--format", "apk"])
    }
    let adhocApk = try #require(
        try appitool.parseAsRoot(["flow", "android", "-d", "adhoc", "--format", "apk"]) as? FlowAndroidCommand
    )
    #expect(adhocApk.format == .apk)
    let appstoreAab = try #require(
        try appitool.parseAsRoot(["flow", "android", "-d", "appstore", "--format", "aab"]) as? FlowAndroidCommand
    )
    #expect(appstoreAab.format == .aab)
}

@Test func testBuildNumberPolicyUsesMaxOfRemoteAndLocalPlusOne() {
    #expect(BuildNumberPolicy.next(remote: "41", local: "10") == .init(value: "42", base: 41))
    // Local was bumped manually but never uploaded: never go below it.
    #expect(BuildNumberPolicy.next(remote: "41", local: "50") == .init(value: "51", base: 50))
    #expect(BuildNumberPolicy.next(remote: nil, local: "7") == .init(value: "8", base: 7))
    #expect(BuildNumberPolicy.next(remote: "7", local: nil) == .init(value: "8", base: 7))
    // Non-integer values (e.g. unresolved `$(VAR)`) are ignored.
    #expect(BuildNumberPolicy.next(remote: " 12 ", local: "$(CURRENT_PROJECT_VERSION)") == .init(value: "13", base: 12))
    #expect(BuildNumberPolicy.next(remote: nil, local: "abc") == nil)
    #expect(BuildNumberPolicy.next(remote: nil, local: nil) == nil)
}

@Test func testAndroidBumpVersionCodeUsesMax() {
    var context = FlowContext(platform: .android, distribution: .adhoc)
    context.buildNumber = "20"
    AndroidPresetHelpers.bumpVersionCode(context: &context, remoteVersionCode: "15", sourceLabel: "Firebase")
    #expect(context.buildNumber == "21")

    context.buildNumber = "3"
    AndroidPresetHelpers.bumpVersionCode(context: &context, remoteVersionCode: "15", sourceLabel: "Google Play")
    #expect(context.buildNumber == "16")
}

@Test func testAndroidMatchKeystoreIsSkippedWhenNotConfiguredAndFailsWithoutPackageName() async throws {
    var unconfigured = FlowContext(platform: .android, distribution: .adhoc)
    try await AndroidPresetHelpers.resolveMatchKeystore(context: &unconfigured)
    #expect(unconfigured.androidSigningConfig == nil)

    var missingPackage = FlowContext(
        platform: .android,
        distribution: .adhoc,
        matchGitUrl: "https://example.com/certs.git",
        matchPassword: "secret"
    )
    await #expect(throws: AndroidPresetHelpers.MatchKeystoreError.self) {
        try await AndroidPresetHelpers.resolveMatchKeystore(context: &missingPackage)
    }
}

@Test func testSigningIdentityMapping() {
    #expect(IOSPresetHelpers.signingIdentity(from: "Apple Distribution: Acme (ABCDE12345)", isDevelopment: false) == "Apple Distribution")
    #expect(IOSPresetHelpers.signingIdentity(from: "iPhone Distribution: Acme (ABCDE12345)", isDevelopment: false) == "iPhone Distribution")
    #expect(IOSPresetHelpers.signingIdentity(from: "Apple Development: Jane Doe (ABCDE12345)", isDevelopment: true) == "Apple Development")
    #expect(IOSPresetHelpers.signingIdentity(from: "iPhone Developer: Jane Doe (ABCDE12345)", isDevelopment: true) == "iPhone Developer")
    #expect(IOSPresetHelpers.signingIdentity(from: nil, isDevelopment: true) == "Apple Development")
    #expect(IOSPresetHelpers.signingIdentity(from: nil, isDevelopment: false) == "Apple Distribution")
}

@Test func testDevelopmentDistributionUsesDevelopmentPresets() {
    #expect(IOSDevelopmentPreset().name == "iOS Development")
    #expect(AndroidDevelopmentPreset().name == "Android Development")
    #expect(GradleTask.resolveTaskName(format: .apk, buildType: "debug", flavor: "staging") == "assembleStagingDebug")
    #expect(AppitoolPaths.androidArtifactName(target: "MyApp", flavor: nil, buildType: "debug") == "MyApp_debug")
}

@Test func testAndroidArtifactNaming() {
    #expect(AppitoolPaths.androidArtifactName(target: "MyApp", flavor: nil, buildType: "Release") == "MyApp_release")
    #expect(AppitoolPaths.androidArtifactName(target: "MyApp", flavor: "staging", buildType: "release") == "MyApp_staging_release")
    #expect(AppitoolPaths.androidArtifactName(target: "MyApp", flavor: "  ", buildType: "Debug") == "MyApp_debug")
}

@Test func testStatusCommandConfiguration() async throws {
    #expect(StatusCommand.configuration.commandName == "status")
    #expect(StatusCommand.configuration.abstract == "Displays the tool name, purpose, and version.")
    #expect(appitool.configuration.subcommands.contains(where: { $0 == StatusCommand.self }))
}

@Test func testStatusCommandRun() async throws {
    let command = try StatusCommand.parse([])
    try await command.run()
}

@Test func testBuildCommandConfiguration() throws {
    #expect(BuildCommand.configuration.commandName == "build")
    #expect(BuildCommand.configuration.abstract == "Builds the project for a specified platform and distribution.")
    #expect(appitool.configuration.subcommands.contains(where: { $0 == BuildCommand.self }))
    #expect(BuildCommand.configuration.subcommands.contains(where: { $0 == BuildIOSCommand.self }))
    #expect(BuildCommand.configuration.subcommands.contains(where: { $0 == BuildAndroidCommand.self }))
}

@Test func testBuildCommandValidPlatformsAndDistributions() throws {
    let iosCommand = try #require(
        try BuildCommand.parseAsRoot(["ios", "--distribution", "appstore"]) as? BuildIOSCommand
    )
    #expect(iosCommand.distribution == .appstore)

    let androidCommand = try #require(
        try BuildCommand.parseAsRoot(["android", "-d", "development"]) as? BuildAndroidCommand
    )
    #expect(androidCommand.distribution == .development)

    let adhocCommand = try BuildIOSCommand.parse(["--distribution", "adhoc"])
    #expect(adhocCommand.distribution == .adhoc)
}

@Test func testBuildCommandInvalidPlatformFails() throws {
    #expect(throws: (any Error).self) {
        try BuildCommand.parseAsRoot(["windows", "--distribution", "appstore"])
    }
}

@Test func testBuildCommandInvalidDistributionFails() throws {
    #expect(throws: (any Error).self) {
        try BuildCommand.parseAsRoot(["ios", "--distribution", "store"])
    }
}

@Test func testCleanCommandConfiguration() async throws {
    #expect(CleanCommand.configuration.commandName == "clean")
    #expect(appitool.configuration.subcommands.contains(where: { $0 == CleanCommand.self }))
}

@Test func testCleanCommandDerivedDataOnlyFlags() throws {
    let cmd1 = try CleanCommand.parse(["--derived-data-only"])
    #expect(cmd1.derivedDataOnly == true)
    #expect(cmd1.derivedData == false)

    let cmd2 = try CleanCommand.parse(["--derived-data"])
    #expect(cmd2.derivedData == true)

    #expect(try CleanCommand.parse(["--dd"]).derivedData == true)
    #expect(try CleanCommand.parse(["--ddo"]).derivedDataOnly == true)

    for removed in [["-D"], ["-d"], ["--only-derived-data"]] {
        #expect(throws: (any Error).self) {
            _ = try CleanCommand.parse(removed)
        }
    }
}

@Test func testUnifiedSilentFlagDefaults() throws {
    #expect(try BuildIOSCommand.parse([]).silent == true)
    #expect(try BuildIOSCommand.parse(["--no-silent"]).silent == false)
    #expect(try BuildAndroidCommand.parse([]).silent == true)
    #expect(try BuildAndroidCommand.parse(["--no-silent"]).silent == false)
    #expect(try MatchAndroidCommand.parse([]).silent == true)
    #expect(try MatchAndroidCommand.parse(["--no-silent"]).silent == false)
}

@Test func testRemovedShortFlagsAreRejected() throws {
    let removed: [[String]] = [
        ["build", "ios", "-w", "App.xcworkspace"],
        ["build", "ios", "-p", "App.xcodeproj"],
        ["build", "ios", "-t", "TEAM123"],
        ["build", "android", "-p", "com.example.app"],
        ["flow", "android", "-p", "com.example.app"],
        ["match", "android", "-a", "release"],
        ["match", "android", "--store-password", "secret"],
        ["match", "android", "--add", "./release.keystore"],
        ["match", "ios", "--app-identifiers", "com.example.app"],
        ["apple", "create-identifier", "--app-identifier", "com.example.app"],
        ["apple", "delete-identifier", "--app-identifier", "com.example.app"],
        ["match", "ios", "-A"],
        ["notes", "-p", "v"],
        ["apple", "prune-profiles", "-d"],
        ["apple", "screenshots", "upload", "--no-wait"],
        // Shorthands removed by the global short-flag scheme.
        ["apple", "list-identifiers", "-i", "com.example.app"],
        ["apple", "list-identifiers", "--identifier", "com.example.app"],
        ["apple", "delete-user", "-u", "a@b.com"],
        ["apple", "update-user", "-v", "com.example.app"],
        ["apple", "screenshots", "list", "-l", "en-US"],
        ["apple", "screenshots", "list", "-v", "1.0.0"],
        ["apple", "screenshots", "upload", "-r"],
        ["notes", "-f", "v1.0.0"],
        ["notes", "-t", "v2.0.0"],
        ["self-update", "-f"],
        ["kokono", "-m", "hi", "-u", "https://example.com"],
        ["kokono", "-m", "hi", "-e", "KEY"],
        ["kokono", "-m", "hi", "-t", "Title"],
        ["firebase", "firestore", "set", "users/a", "--data", "{}", "-m"],
        ["firebase", "firestore", "list", "users", "-o", "createdAt desc"],
    ]
    for args in removed {
        #expect(throws: (any Error).self) {
            _ = try appitool.parseAsRoot(args)
        }
    }

    let renamed = try #require(
        try appitool.parseAsRoot(["build", "ios", "--workspace-path", "App.xcworkspace", "--team-id", "TEAM123"]) as? BuildIOSCommand
    )
    #expect(renamed.workspacePath == "App.xcworkspace")
    #expect(renamed.teamId == "TEAM123")

    let matchAndroid = try #require(
        try appitool.parseAsRoot(["match", "android", "--keystore-password", "secret"]) as? MatchAndroidCommand
    )
    #expect(matchAndroid.keystorePassword == "secret")

    let matchAndroidAdd = try #require(
        try appitool.parseAsRoot(["match", "android", "-k", "./release.keystore"]) as? MatchAndroidCommand
    )
    #expect(matchAndroidAdd.keystore == "./release.keystore")

    let matchIOS = try #require(
        try appitool.parseAsRoot(["match", "ios", "--identifiers", "com.example.app,com.example.app.widget"]) as? MatchIOSSyncCommand
    )
    #expect(matchIOS.identifiers == "com.example.app,com.example.app.widget")

    let deleteIdentifier = try #require(
        try appitool.parseAsRoot(["apple", "delete-identifier", "-b", "com.example.app"]) as? AppleDeleteIdentifierCommand
    )
    #expect(deleteIdentifier.bundleId == "com.example.app")

    let kokono = try #require(
        try appitool.parseAsRoot(["kokono", "-m", "hi", "--url", "https://example.com", "--e2e", "KEY"]) as? KokonoCommand
    )
    #expect(kokono.url == "https://example.com")
    #expect(kokono.e2e == "KEY")

    let listIdentifiers = try #require(
        try appitool.parseAsRoot(["apple", "list-identifiers", "-b", "com.example.app", "-l", "5"]) as? AppleListIdentifiersCommand
    )
    #expect(listIdentifiers.bundleId == "com.example.app")
    #expect(listIdentifiers.limit == 5)

    let notes = try #require(
        try appitool.parseAsRoot(["notes", "--from", "v1.0.0", "--to", "v2.0.0", "-o", "notes.md"]) as? NotesCommand
    )
    #expect(notes.from == "v1.0.0")
    #expect(notes.to == "v2.0.0")
    #expect(notes.output == "notes.md")
}
