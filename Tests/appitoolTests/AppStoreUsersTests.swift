import ArgumentParser
import Foundation
import HTTPTypes
import OpenAPIRuntime
import Testing
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
@testable import appitool
import AppStoreConnectAPI
import AppleServices

@Suite("AppStore Users & Invitations Tests")
struct AppStoreUsersTests {

    private final class CapturingTransport: ClientTransport, @unchecked Sendable {
        struct CapturedRequest {
            let request: HTTPRequest
            let operationID: String
            let bodyData: Data?
        }

        private let lock = NSLock()
        private var responses: [(status: HTTPResponse.Status, body: Data?)]
        private(set) var capturedRequests: [CapturedRequest] = []

        init(statusCode: HTTPResponse.Status, responseBody: Data? = nil) {
            self.responses = [(statusCode, responseBody)]
        }

        init(responses: [(status: HTTPResponse.Status, body: Data?)]) {
            self.responses = responses
        }

        func send(
            _ request: HTTPRequest,
            body: HTTPBody?,
            baseURL: URL,
            operationID: String
        ) async throws -> (HTTPResponse, HTTPBody?) {
            var collected: Data? = nil
            if let body {
                var data = Data()
                for try await chunk in body {
                    data.append(contentsOf: chunk)
                }
                collected = data
            }

            let nextResponse: (status: HTTPResponse.Status, body: Data?) = lock.withLock {
                capturedRequests.append(CapturedRequest(request: request, operationID: operationID, bodyData: collected))
                if responses.count > 1 {
                    return responses.removeFirst()
                }
                return responses.first ?? (.ok, nil)
            }

            let response = HTTPResponse(status: nextResponse.status)
            let outBody = nextResponse.body.map { HTTPBody($0) }
            return (response, outBody)
        }

        var lastRequest: CapturedRequest? {
            lock.withLock { capturedRequests.last }
        }
    }

    private func makeService(transport: CapturingTransport) throws -> AppStoreService {
        let key = P256.Signing.PrivateKey()
        return try AppStoreService(
            keyId: "TEST_KID",
            issuerId: "TEST_ISS",
            key: key.pemRepresentation,
            transport: transport
        )
    }

    private func decodeJSON(_ data: Data?) throws -> [String: Any] {
        let rawData = try #require(data)
        let obj = try JSONSerialization.jsonObject(with: rawData)
        return try #require(obj as? [String: Any])
    }

    // MARK: - Role Mapper Tests

    @Test("AppleTypeMapper parses UserRole strings, aliases, deduplication, and rejects invalid/empty inputs")
    func userRoleParsing() throws {
        #expect(try AppleTypeMapper.parseUserRole("admin") == .ADMIN)
        #expect(try AppleTypeMapper.parseUserRole("app-manager") == .APP_MANAGER)
        #expect(try AppleTypeMapper.parseUserRole("app_manager") == .APP_MANAGER)
        #expect(try AppleTypeMapper.parseUserRole("DEVELOPER") == .DEVELOPER)
        #expect(try AppleTypeMapper.parseUserRole("support") == .CUSTOMER_SUPPORT)
        #expect(try AppleTypeMapper.parseUserRole("customer-support") == .CUSTOMER_SUPPORT)
        #expect(try AppleTypeMapper.parseUserRole("reports") == .ACCESS_TO_REPORTS)
        #expect(try AppleTypeMapper.parseUserRole("access-to-reports") == .ACCESS_TO_REPORTS)
        #expect(try AppleTypeMapper.parseUserRole("cloud-managed-developer-id") == .CLOUD_MANAGED_DEVELOPER_ID)
        #expect(try AppleTypeMapper.parseUserRole("cloud-managed-app-distribution") == .CLOUD_MANAGED_APP_DISTRIBUTION)
        #expect(try AppleTypeMapper.parseUserRole("generate-individual-keys") == .GENERATE_INDIVIDUAL_KEYS)

        let roles = try AppleTypeMapper.parseUserRoles(["developer", "admin", "DEVELOPER", " ", "reports"])
        #expect(roles == [.DEVELOPER, .ADMIN, .ACCESS_TO_REPORTS])

        #expect(try AppleTypeMapper.parseUserRoleQueryFilter("admin") == .ADMIN)
        #expect(try AppleTypeMapper.parseUserInvitationRoleQueryFilter("app-manager") == .APP_MANAGER)

        #expect(throws: AppStoreServiceError.self) {
            _ = try AppleTypeMapper.parseUserRole("super-admin")
        }
        #expect(throws: AppStoreServiceError.self) {
            _ = try AppleTypeMapper.parseUserRoles(["", "  "])
        }
    }

    // MARK: - Service Tests

    @Test("fetchUsers queries users_getCollection with filters and decodes response")
    func fetchUsers() async throws {
        let responseJSON = """
        {
            "data": [
                {
                    "type": "users",
                    "id": "u-1",
                    "attributes": {
                        "username": "alice@example.com",
                        "firstName": "Alice",
                        "lastName": "Smith",
                        "roles": ["ADMIN"],
                        "allAppsVisible": true,
                        "provisioningAllowed": true
                    }
                }
            ],
            "links": {
                "self": "https://api.appstoreconnect.apple.com/v1/users"
            }
        }
        """.data(using: .utf8)!

        let transport = CapturingTransport(statusCode: .ok, responseBody: responseJSON)
        let service = try makeService(transport: transport)

        let users = try await service.fetchUsers(
            username: "alice@example.com",
            roles: ["admin"],
            visibleAppIds: ["123456"],
            limit: 50
        )

        #expect(users.count == 1)
        #expect(users.first?.id == "u-1")
        #expect(users.first?.attributes?.username == "alice@example.com")
        #expect(users.first?.attributes?.roles == [.ADMIN])

        let captured = try #require(transport.lastRequest)
        #expect(captured.operationID == "users_getCollection")
        #expect(captured.request.method == .get)
        let path = captured.request.path ?? ""
        #expect(path.contains("/v1/users"))
        // swift-openapi-runtime percent-encodes everything outside RFC 3986 "unreserved", so `@` becomes `%40`.
        #expect(path.contains("filter%5Busername%5D=alice%40example.com"))
    }

    @Test("inviteUser sends UserInvitationCreateRequest with allAppsVisible true by default and false when visibleApps supplied")
    func inviteUserPayloadsAndValidation() async throws {
        let createdJSON = """
        {
            "data": {
                "type": "userInvitations",
                "id": "inv-42",
                "attributes": {
                    "email": "dev@example.com",
                    "firstName": "Dev",
                    "lastName": "User",
                    "expirationDate": "2026-12-01T00:00:00Z",
                    "roles": ["DEVELOPER"],
                    "allAppsVisible": true,
                    "provisioningAllowed": true
                }
            },
            "links": {
                "self": "https://api.appstoreconnect.apple.com/v1/userInvitations/inv-42"
            }
        }
        """.data(using: .utf8)!

        // 1. Default allAppsVisible = true when visibleAppIds is empty
        let transport1 = CapturingTransport(statusCode: .created, responseBody: createdJSON)
        let service1 = try makeService(transport: transport1)
        let invitation1 = try await service1.inviteUser(
            email: "dev@example.com",
            firstName: "Dev",
            lastName: "User",
            roles: ["developer"]
        )
        #expect(invitation1.id == "inv-42")
        let req1 = try #require(transport1.lastRequest)
        #expect(req1.operationID == "userInvitations_createInstance")
        #expect(req1.request.method == .post)
        let json1 = try decodeJSON(req1.bodyData)
        let data1 = try #require(json1["data"] as? [String: Any])
        #expect(data1["type"] as? String == "userInvitations")
        let attrs1 = try #require(data1["attributes"] as? [String: Any])
        #expect(attrs1["email"] as? String == "dev@example.com")
        #expect(attrs1["firstName"] as? String == "Dev")
        #expect(attrs1["lastName"] as? String == "User")
        #expect(attrs1["roles"] as? [String] == ["DEVELOPER"])
        #expect(attrs1["allAppsVisible"] as? Bool == true)
        #expect(attrs1["provisioningAllowed"] == nil)
        #expect(data1["relationships"] == nil)

        // 2. Visible apps supplied -> allAppsVisible defaults to false and relationships.visibleApps populated
        let transport2 = CapturingTransport(statusCode: .created, responseBody: createdJSON)
        let service2 = try makeService(transport: transport2)
        _ = try await service2.inviteUser(
            email: "dev@example.com",
            firstName: "Dev",
            lastName: "User",
            roles: ["developer"],
            provisioningAllowed: true,
            visibleAppIds: ["987654321"]
        )
        let json2 = try decodeJSON(try #require(transport2.lastRequest?.bodyData))
        let data2 = try #require(json2["data"] as? [String: Any])
        let attrs2 = try #require(data2["attributes"] as? [String: Any])
        #expect(attrs2["allAppsVisible"] as? Bool == false)
        #expect(attrs2["provisioningAllowed"] as? Bool == true)
        let rels2 = try #require(data2["relationships"] as? [String: Any])
        let visibleApps = try #require(rels2["visibleApps"] as? [String: Any])
        let appItems = try #require(visibleApps["data"] as? [[String: Any]])
        #expect(appItems.count == 1)
        #expect(appItems.first?["id"] as? String == "987654321")
        #expect(appItems.first?["type"] as? String == "apps")

        // 3. Rejects ACCOUNT_HOLDER role
        do {
            _ = try await service1.inviteUser(
                email: "owner@example.com",
                firstName: "Owner",
                lastName: "One",
                roles: ["account-holder"]
            )
            Issue.record("Expected rejection for ACCOUNT_HOLDER role")
        } catch AppStoreServiceError.invalidResponse {
            // Expected
        }

        // 4. Rejects conflicting allAppsVisible == true with non-empty visibleAppIds
        do {
            _ = try await service1.inviteUser(
                email: "dev@example.com",
                firstName: "Dev",
                lastName: "User",
                roles: ["developer"],
                allAppsVisible: true,
                visibleAppIds: ["987654321"]
            )
            Issue.record("Expected rejection for conflicting allAppsVisible and visibleAppIds")
        } catch AppStoreServiceError.invalidResponse {
            // Expected
        }
    }

    @Test("fetchUserInvitations queries userInvitations_getCollection and decodes pending invitations")
    func fetchUserInvitations() async throws {
        let responseJSON = """
        {
            "data": [
                {
                    "type": "userInvitations",
                    "id": "inv-1",
                    "attributes": {
                        "email": "bob@example.com",
                        "firstName": "Bob",
                        "lastName": "Jones",
                        "expirationDate": "2026-12-01T00:00:00Z",
                        "roles": ["APP_MANAGER"],
                        "allAppsVisible": false,
                        "provisioningAllowed": true
                    }
                }
            ],
            "links": {
                "self": "https://api.appstoreconnect.apple.com/v1/userInvitations"
            }
        }
        """.data(using: .utf8)!

        let transport = CapturingTransport(statusCode: .ok, responseBody: responseJSON)
        let service = try makeService(transport: transport)

        let invitations = try await service.fetchUserInvitations(email: "bob@example.com", roles: ["app-manager"])
        #expect(invitations.count == 1)
        #expect(invitations.first?.id == "inv-1")
        #expect(invitations.first?.attributes?.email == "bob@example.com")
        #expect(invitations.first?.attributes?.roles == [.APP_MANAGER])
        #expect(transport.lastRequest?.operationID == "userInvitations_getCollection")
    }

    @Test("updateUser sends UserUpdateRequest and rejects empty updates")
    func updateUser() async throws {
        let updatedJSON = """
        {
            "data": {
                "type": "users",
                "id": "u-1",
                "attributes": {
                    "username": "alice@example.com",
                    "firstName": "Alice",
                    "lastName": "Smith",
                    "roles": ["DEVELOPER"],
                    "allAppsVisible": false,
                    "provisioningAllowed": true
                }
            },
            "links": {
                "self": "https://api.appstoreconnect.apple.com/v1/users/u-1"
            }
        }
        """.data(using: .utf8)!

        let transport = CapturingTransport(statusCode: .ok, responseBody: updatedJSON)
        let service = try makeService(transport: transport)

        let updated = try await service.updateUser(
            id: "u-1",
            roles: ["developer"],
            provisioningAllowed: true,
            visibleAppIds: ["111222333"]
        )
        #expect(updated.id == "u-1")
        #expect(updated.attributes?.roles == [.DEVELOPER])

        let captured = try #require(transport.lastRequest)
        #expect(captured.operationID == "users_updateInstance")
        #expect(captured.request.method == .patch)
        let json = try decodeJSON(captured.bodyData)
        let data = try #require(json["data"] as? [String: Any])
        #expect(data["id"] as? String == "u-1")
        #expect(data["type"] as? String == "users")
        let attrs = try #require(data["attributes"] as? [String: Any])
        #expect(attrs["roles"] as? [String] == ["DEVELOPER"])
        #expect(attrs["allAppsVisible"] as? Bool == false)
        #expect(attrs["provisioningAllowed"] as? Bool == true)

        do {
            _ = try await service.updateUser(id: "u-1")
            Issue.record("Expected rejection for empty updateUser request")
        } catch AppStoreServiceError.invalidResponse {
            // Expected
        }
    }

    @Test("deleteUser and cancelUserInvitation send DELETE requests and handle HTTP 204")
    func deleteUserAndCancelInvitation() async throws {
        let transportUser = CapturingTransport(statusCode: .noContent)
        let serviceUser = try makeService(transport: transportUser)
        let deleted = try await serviceUser.deleteUser(id: "u-99")
        #expect(deleted == true)
        #expect(transportUser.lastRequest?.operationID == "users_deleteInstance")
        #expect(transportUser.lastRequest?.request.method == .delete)
        #expect(transportUser.lastRequest?.request.path == "/v1/users/u-99")

        let transportInv = CapturingTransport(statusCode: .noContent)
        let serviceInv = try makeService(transport: transportInv)
        let canceled = try await serviceInv.cancelUserInvitation(id: "inv-99")
        #expect(canceled == true)
        #expect(transportInv.lastRequest?.operationID == "userInvitations_deleteInstance")
        #expect(transportInv.lastRequest?.request.method == .delete)
        #expect(transportInv.lastRequest?.request.path == "/v1/userInvitations/inv-99")
    }

    @Test("User service methods unwrap HTTP 403 and 409 errors into AppStoreServiceError directly")
    func unwrapsForbiddenAndConflictErrors() async throws {
        let forbiddenJSON = """
        {
            "errors": [
                {
                    "id": "ERR_403",
                    "status": "403",
                    "code": "FORBIDDEN_ERROR",
                    "title": "Forbidden",
                    "detail": "API key lacks Admin role"
                }
            ]
        }
        """.data(using: .utf8)!
        let service403 = try makeService(transport: CapturingTransport(statusCode: .forbidden, responseBody: forbiddenJSON))

        do {
            _ = try await service403.fetchUsers()
            Issue.record("Expected AppStoreServiceError on HTTP 403")
        } catch AppStoreServiceError.apiError(let status, let message) {
            #expect(status == 403)
            #expect(message == "Forbidden (FORBIDDEN_ERROR): API key lacks Admin role")
        }

        let conflictJSON = """
        {
            "errors": [
                {
                    "id": "ERR_409",
                    "status": "409",
                    "code": "ENTITY_ERROR.ATTRIBUTE.INVALID",
                    "title": "Conflict",
                    "detail": "Invitation already exists for this email"
                }
            ]
        }
        """.data(using: .utf8)!
        let service409 = try makeService(transport: CapturingTransport(statusCode: .conflict, responseBody: conflictJSON))

        do {
            _ = try await service409.inviteUser(
                email: "dup@example.com",
                firstName: "Dup",
                lastName: "User",
                roles: ["admin"]
            )
            Issue.record("Expected AppStoreServiceError on HTTP 409")
        } catch AppStoreServiceError.apiError(let status, let message) {
            #expect(status == 409)
            #expect(message == "Conflict (ENTITY_ERROR.ATTRIBUTE.INVALID): Invitation already exists for this email")
        }
    }

    @Test("resolveAppIds keeps numeric IDs and looks up bundle IDs via apps_getCollection")
    func resolveAppIds() async throws {
        let appsJSON = """
        {
            "data": [
                {
                    "type": "apps",
                    "id": "673000111",
                    "attributes": {
                        "name": "Example App",
                        "bundleId": "com.example.app"
                    }
                }
            ],
            "links": {
                "self": "https://api.appstoreconnect.apple.com/v1/apps"
            }
        }
        """.data(using: .utf8)!

        let emptyAppsJSON = """
        {
            "data": [],
            "links": {
                "self": "https://api.appstoreconnect.apple.com/v1/apps"
            }
        }
        """.data(using: .utf8)!

        let transport = CapturingTransport(statusCode: .ok, responseBody: appsJSON)
        let service = try makeService(transport: transport)
        let resolved = try await service.resolveAppIds(["111222333", "com.example.app", "673000111"])
        #expect(resolved == ["111222333", "673000111"])

        let missingService = try makeService(transport: CapturingTransport(statusCode: .ok, responseBody: emptyAppsJSON))
        do {
            _ = try await missingService.resolveAppIds(["com.missing.app"])
            Issue.record("Expected AppStoreServiceError.notFound for unknown bundle ID")
        } catch AppStoreServiceError.notFound {
            // Expected
        }
    }

    // MARK: - CLI Subcommand Parsing Tests

    @Test("AppleCommand parses all six Users & Invitations subcommands and options")
    func appleCommandUserSubcommandParsing() throws {
        #expect(AppleCommand.configuration.subcommands.contains { $0 == AppleListUsersCommand.self })
        #expect(AppleCommand.configuration.subcommands.contains { $0 == AppleInviteUserCommand.self })
        #expect(AppleCommand.configuration.subcommands.contains { $0 == AppleUpdateUserCommand.self })
        #expect(AppleCommand.configuration.subcommands.contains { $0 == AppleDeleteUserCommand.self })
        #expect(AppleCommand.configuration.subcommands.contains { $0 == AppleListInvitationsCommand.self })
        #expect(AppleCommand.configuration.subcommands.contains { $0 == AppleCancelInvitationCommand.self })

        let listUsers = try #require(
            try AppleCommand.parseAsRoot(["list-users", "--username", "alice@example.com", "-r", "admin,developer", "-l", "25"]) as? AppleListUsersCommand
        )
        #expect(listUsers.username == "alice@example.com")
        #expect(listUsers.roles == "admin,developer")
        #expect(listUsers.limit == 25)

        let inviteUser = try #require(
            try AppleCommand.parseAsRoot([
                "invite-user",
                "-e", "bob@example.com",
                "--first-name", "Bob",
                "--last-name", "Jones",
                "-r", "developer,app-manager",
                "--visible-apps", "com.example.app,123456",
                "--no-all-apps-visible",
                "--provisioning-allowed",
            ]) as? AppleInviteUserCommand
        )
        #expect(inviteUser.email == "bob@example.com")
        #expect(inviteUser.firstName == "Bob")
        #expect(inviteUser.lastName == "Jones")
        #expect(inviteUser.roles == "developer,app-manager")
        #expect(inviteUser.visibleApps == "com.example.app,123456")
        #expect(inviteUser.allAppsVisible == false)
        #expect(inviteUser.provisioningAllowed == true)

        let updateUser = try #require(
            try AppleCommand.parseAsRoot([
                "update-user",
                "--id", "u-1",
                "-r", "admin",
                "--all-apps-visible",
                "--no-provisioning-allowed",
            ]) as? AppleUpdateUserCommand
        )
        #expect(updateUser.id == "u-1")
        #expect(updateUser.roles == "admin")
        #expect(updateUser.allAppsVisible == true)
        #expect(updateUser.provisioningAllowed == false)

        let deleteUser = try #require(
            try AppleCommand.parseAsRoot(["delete-user", "--username", "alice@example.com"]) as? AppleDeleteUserCommand
        )
        #expect(deleteUser.username == "alice@example.com")
        #expect(deleteUser.id == nil)

        let listInvitations = try #require(
            try AppleCommand.parseAsRoot(["list-invitations", "-e", "bob@example.com", "-r", "developer", "-l", "10"]) as? AppleListInvitationsCommand
        )
        #expect(listInvitations.email == "bob@example.com")
        #expect(listInvitations.roles == "developer")
        #expect(listInvitations.limit == 10)

        let cancelInvitation = try #require(
            try AppleCommand.parseAsRoot(["cancel-invitation", "--id", "inv-1"]) as? AppleCancelInvitationCommand
        )
        #expect(cancelInvitation.id == "inv-1")
        #expect(cancelInvitation.email == nil)
    }
}
