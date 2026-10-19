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

@Test func testBuildCommandConfiguration() async throws {
    #expect(BuildCommand.configuration.commandName == "build")
    #expect(BuildCommand.configuration.abstract == "Builds the project for a specified platform and distribution.")
    #expect(appitool.configuration.subcommands.contains(where: { $0 == BuildCommand.self }))
}

@Test func testBuildCommandValidPlatformsAndDistributions() async throws {
    let iosCommand = try BuildCommand.parse(["ios", "--distribution", "appstore"])
    #expect(iosCommand.platform == .ios)
    #expect(iosCommand.distribution == .appstore)
    try await iosCommand.run()

    let androidCommand = try BuildCommand.parse(["android", "-d", "development"])
    #expect(androidCommand.platform == .android)
    #expect(androidCommand.distribution == .development)
    try await androidCommand.run()

    let adhocCommand = try BuildCommand.parse(["iOS", "--distribution", "adhoc"])
    #expect(adhocCommand.platform == .ios)
    #expect(adhocCommand.distribution == .adhoc)
}

@Test func testBuildCommandInvalidPlatformFails() throws {
    #expect(throws: (any Error).self) {
        try BuildCommand.parse(["windows", "--distribution", "appstore"])
    }
}

@Test func testBuildCommandInvalidDistributionFails() throws {
    #expect(throws: (any Error).self) {
        try BuildCommand.parse(["ios", "--distribution", "store"])
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
