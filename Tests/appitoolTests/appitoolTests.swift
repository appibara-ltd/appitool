import Testing
import ArgumentParser
@testable import appitool

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

    let cmd2 = try CleanCommand.parse(["-D"])
    #expect(cmd2.derivedDataOnly == true)

    let cmd3 = try CleanCommand.parse(["--only-derived-data"])
    #expect(cmd3.derivedDataOnly == true)
}
