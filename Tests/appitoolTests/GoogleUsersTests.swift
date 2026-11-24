import ArgumentParser
import Foundation
import Testing
@testable import appitool
import GoogleServices

@Suite("Google Users Tests")
struct GoogleUsersTests {
    @Test("Permissions parse kebab-case and API names; developer-level _GLOBAL suffix is optional")
    func permissionParsing() throws {
        #expect(try GooglePlayPermissions.parse(["can-see-all-apps", "can-reply-to-reviews"], developerLevel: true)
            == ["CAN_SEE_ALL_APPS", "CAN_REPLY_TO_REVIEWS_GLOBAL"])
        #expect(try GooglePlayPermissions.parse(["CAN_ACCESS_APP", "can-manage-public-listing"], developerLevel: false)
            == ["CAN_ACCESS_APP", "CAN_MANAGE_PUBLIC_LISTING"])
        // Values returned by the live API but missing from the spec are accepted.
        #expect(try GooglePlayPermissions.parse(["can-view-app-quality", "can-edit-connected-apps"], developerLevel: true)
            == ["CAN_VIEW_APP_QUALITY_GLOBAL", "CAN_EDIT_CONNECTED_APPS_GLOBAL"])
        #expect(try GooglePlayPermissions.parse(["can-manage-deeplinks", "can-view-non-financial-data"], developerLevel: false)
            == ["CAN_MANAGE_DEEPLINKS", "CAN_VIEW_NON_FINANCIAL_DATA"])
        #expect(throws: (any Error).self) { try GooglePlayPermissions.parse(["can-fly"], developerLevel: true) }
        #expect(throws: (any Error).self) { try GooglePlayPermissions.parse(["can-see-all-apps"], developerLevel: false) }
    }

    @Test("Users decode from the Play Developer API JSON and invitations are detected")
    func userDecoding() throws {
        let json = """
        {"users":[
          {"name":"developers/123/users/a@b.com","email":"a@b.com","accessState":"ACCESS_GRANTED",
           "developerAccountPermissions":["CAN_SEE_ALL_APPS"],
           "grants":[{"name":"developers/123/users/a@b.com/grants/com.example","packageName":"com.example","appLevelPermissions":["CAN_ACCESS_APP"]}]},
          {"name":"developers/123/users/c@d.com","email":"c@d.com","accessState":"INVITED"}
        ]}
        """
        struct Page: Decodable { let users: [GooglePlayUser] }
        let users = try JSONDecoder().decode(Page.self, from: Data(json.utf8)).users
        #expect(users.count == 2)
        #expect(users[0].grants?.first?.packageName == "com.example")
        #expect(users[0].isInvitation == false)
        #expect(users[1].isInvitation == true)
        #expect(GoogleUserSupport.findUser(users, email: "A@B.com")?.email == "a@b.com")
    }

    @Test("list-apps decodes apps:search pages and filters by title")
    func listApps() throws {
        let json = """
        {"apps":[
          {"name":"apps/111","packageName":"com.example.zeta","displayName":"Zeta"},
          {"name":"apps/222","packageName":"com.example.alpha","displayName":"Alpha Tool"}
        ],"nextPageToken":""}
        """
        struct Page: Decodable { let apps: [GooglePlayAccessibleApp] }
        let apps = try JSONDecoder().decode(Page.self, from: Data(json.utf8)).apps
        #expect(GoogleListAppsCommand.filter(apps, name: nil, limit: nil).map(\.packageName) == ["com.example.alpha", "com.example.zeta"])
        #expect(GoogleListAppsCommand.filter(apps, name: "tool", limit: nil).map(\.packageName) == ["com.example.alpha"])
        #expect(GoogleListAppsCommand.filter(apps, name: nil, limit: 1).count == 1)

        let cmd = try #require(try appitool.parseAsRoot(["google", "list-apps", "-n", "alpha", "-l", "3"]) as? GoogleListAppsCommand)
        #expect(cmd.name == "alpha")
        #expect(cmd.limit == 3)
        #expect(GoogleListAppsCommand.hint(for: .apiError(status: 403, message: "x"))?.contains("Reporting API") == true)
    }

    @Test("Google user commands parse, validate inputs, and destructive ones are CI-guarded")
    func commandValidation() throws {
        let list = try #require(try appitool.parseAsRoot(["google", "list-users", "--account-id", "123", "-e", "a@b.com", "-l", "5"]) as? GoogleListUsersCommand)
        #expect(try list.account.requireAccountId() == "123")
        _ = try appitool.parseAsRoot(["google", "list-invitations", "--account-id", "123"])
        #expect(throws: (any Error).self) {
            _ = try appitool.parseAsRoot(["google", "list-users", "--developer-id", "123"])
        }
        _ = try appitool.parseAsRoot(["google", "invite-user", "-e", "a@b.com", "--permissions", "can-see-all-apps"])
        _ = try appitool.parseAsRoot(["google", "invite-user", "-e", "a@b.com", "--package-name", "com.example", "--app-permissions", "can-access-app"])
        _ = try appitool.parseAsRoot(["google", "update-user", "-e", "a@b.com", "--expiration", "2099-01-01T00:00:00Z"])
        _ = try appitool.parseAsRoot(["google", "grant-access", "-e", "a@b.com", "--permissions", "can-access-app"])

        for args in [
            ["google", "invite-user", "-e", "a@b.com"],
            ["google", "invite-user", "-e", "a@b.com", "--app-permissions", "can-access-app"],
            ["google", "invite-user", "-e", "a@b.com", "--package-name", "com.example"],
            ["google", "invite-user", "-e", "a@b.com", "--permissions", "can-fly"],
            ["google", "update-user", "-e", "a@b.com"],
            ["google", "update-user", "-e", "a@b.com", "--expiration", "2001-01-01T00:00:00Z"],
            ["google", "update-user", "-e", "a@b.com", "--expiration", "tomorrow"],
            ["google", "grant-access", "-e", "a@b.com", "--permissions", "can-see-all-apps"],
        ] {
            #expect(throws: (any Error).self) {
                _ = try appitool.parseAsRoot(args)
            }
        }

        for (args, description) in [
            (["google", "delete-user", "-e", "a@b.com", "--ci"], "google delete-user"),
            (["google", "cancel-invitation", "-e", "a@b.com", "--ci"], "google cancel-invitation"),
            (["google", "revoke-access", "-e", "a@b.com", "--ci"], "google revoke-access"),
        ] {
            let cmd = try #require(try appitool.parseAsRoot(args) as? any BaseCommand)
            #expect(cmd.isDestructive == true)
            #expect(cmd.destructiveCommandDescription == description)
            #expect(cmd.ciSkipResolution(environment: [:])?.isCI == true)
        }

        #expect(GoogleUserSupport.hint(for: GooglePlayImageError.apiError(status: 403, message: "x"))?.contains("Manage users") == true)
    }
}
