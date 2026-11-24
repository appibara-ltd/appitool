import ArgumentParser
import Testing
@testable import appitool

@Suite("Command Structure Tests")
struct CommandStructureTests {
    /// Resources are nouns and actions are verbs: `apple users list`, never `apple list-users`.
    @Test("apple, google, and firebase use <resource> <action> without dashed action names")
    func resourceActionStructure() {
        let multiWordResources: Set<String> = ["signing-certs"]
        for root in [AppleCommand.self, GoogleCommand.self, FirebaseCommand.self] as [any ParsableCommand.Type] {
            for resource in root.configuration.subcommands {
                let resourceName = resource._commandName
                #expect(!resourceName.contains("-") || multiWordResources.contains(resourceName), "\(resourceName) looks like a dashed action")
                #expect(!resource.configuration.subcommands.isEmpty, "\(resourceName) must group actions as subcommands")
                for action in resource.configuration.subcommands {
                    #expect(!action._commandName.contains("-"), "\(resourceName) \(action._commandName) should be a single verb")
                }
            }
        }
    }

    @Test("Apple and Google invitations share the same command structure")
    func invitationsStructure() throws {
        _ = try appitool.parseAsRoot(["apple", "invitations", "list"])
        _ = try appitool.parseAsRoot(["google", "invitations", "list", "--account-id", "123"])
        #expect(try appitool.parseAsRoot(["apple", "invitations", "cancel", "--id", "inv-1"]) is AppleCancelInvitationCommand)
        #expect(try appitool.parseAsRoot(["google", "invitations", "cancel", "-e", "a@b.com"]) is GoogleCancelInvitationCommand)
        #expect(throws: (any Error).self) { _ = try appitool.parseAsRoot(["apple", "list-users"]) }
    }
}
