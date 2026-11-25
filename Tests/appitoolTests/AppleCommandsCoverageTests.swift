import ArgumentParser
import Foundation
import Testing
@testable import appitool
import AppStoreConnectAPI
import AppleServices

// MARK: - Helpers

/// Command-level stubbing: commands build their services with the default transport and session, which
/// `DefaultNetworkStub.with` points at the stub router (routes match by URL fragment).
enum CmdStub {
    static func appleCreds() -> [String] {
        ["--apple-key-id", "KID", "--apple-issuer-id", "ISS", "--apple-key=" + TestCredentials.appleKeyPEM()]
    }

    static func googleCreds() -> [String] {
        ["--google-key=" + TestCredentials.serviceAccountJSON()]
    }

    static func parse<T: ParsableCommand>(_ args: [String], as _: T.Type = T.self) throws -> T {
        let parsed = try appitool.parseAsRoot(args)
        guard let cmd = parsed as? T else { throw ValidationError("parsed \(type(of: parsed))") }
        return cmd
    }

    static func apple<T: BaseCommand>(_ router: StubRouter, _ args: [String], as _: T.Type = T.self) async throws {
        let cmd: T = try parse(args + appleCreds())
        try await DefaultNetworkStub.with(router) { _ in try await cmd.execute() }
    }

    static func google<T: BaseCommand>(_ router: StubRouter, _ args: [String], as _: T.Type = T.self) async throws {
        HTTPStub.googleTokenRoute(router)
        let cmd: T = try parse(args + googleCreds())
        try await DefaultNetworkStub.with(router) { _ in try await cmd.execute() }
    }

    static func has(_ router: StubRouter, _ method: String, _ fragment: String) -> Bool {
        router.log.requests.contains { $0.method == method && $0.url.absoluteString.contains(fragment) }
    }

    static func count(_ router: StubRouter, _ method: String, _ fragment: String) -> Int {
        router.log.requests.filter { $0.method == method && $0.url.absoluteString.contains(fragment) }.count
    }
}

enum AppleJSON {
    static func app(_ id: String = "123", bundleId: String = "com.a") -> String {
        ASCStub.res("apps", id, #"{"name":"App","bundleId":"\#(bundleId)","sku":"S","primaryLocale":"en-US"}"#)
    }

    static func user(_ id: String = "u1", username: String = "a@b.c", roles: String = #"["ADMIN"]"#) -> String {
        ASCStub.res("users", id, #"{"username":"\#(username)","firstName":"A","lastName":"B","roles":\#(roles),"allAppsVisible":true,"provisioningAllowed":false}"#)
    }

    static func invitation(_ id: String = "i1", email: String = "a@b.c") -> String {
        ASCStub.res("userInvitations", id, #"{"email":"\#(email)","firstName":"A","lastName":"B","roles":["DEVELOPER"],"allAppsVisible":false,"provisioningAllowed":true,"expirationDate":"2030-01-01T00:00:00Z"}"#)
    }

    static func version(_ id: String = "v1", _ string: String = "1.0", state: String = "PREPARE_FOR_SUBMISSION") -> String {
        ASCStub.res("appStoreVersions", id, #"{"versionString":"\#(string)","appVersionState":"\#(state)","platform":"IOS"}"#)
    }

    static func localization(_ id: String = "loc1", locale: String = "en-US") -> String {
        ASCStub.res("appStoreVersionLocalizations", id, #"{"locale":"\#(locale)"}"#)
    }

    static func capability(_ id: String, _ type: String) -> String {
        ASCStub.res("bundleIdCapabilities", id, #"{"capabilityType":"\#(type)"}"#)
    }
}

// MARK: - Basic resources

@Suite("Apple Commands Coverage", .serialized)
struct AppleCommandsCoverageTests {
    @Test("apple apps list reaches the stub router through the default transport")
    func appsList() async throws {
        let router = StubRouter().on("GET", "/v1/apps", .ok(ASCStub.list([AppleJSON.app(), ASCStub.res("apps", "2")])))
        try await CmdStub.apple(router, ["apple", "apps", "list", "-l", "5"], as: AppleListAppsCommand.self)
        #expect(CmdStub.has(router, "GET", "/v1/apps"))

        let empty = StubRouter().on("GET", "/v1/apps", .ok(ASCStub.list([])))
        try await CmdStub.apple(empty, ["apple", "apps", "list"], as: AppleListAppsCommand.self)
        try await CmdStub.apple(empty, ["apple", "apps", "list", "-b", "com.x"], as: AppleListAppsCommand.self)
        #expect(empty.log.requests.last?.query.contains("com.x") == true)

        let failing = StubRouter().on("GET", "/v1/apps", .status(401, ASCStub.errors(401, code: "NOT_AUTHORIZED")))
        await #expect(throws: AppStoreServiceError.self) {
            try await CmdStub.apple(failing, ["apple", "apps", "list"], as: AppleListAppsCommand.self)
        }
    }

    @Test("run() maps API failures to ExitCode.failure")
    func runMapsErrors() async throws {
        let failing = StubRouter().on("GET", "/v1/apps", .status(500, ASCStub.errors(500)))
        let cmd: AppleListAppsCommand = try CmdStub.parse(["apple", "apps", "list"] + CmdStub.appleCreds())
        await #expect(throws: ExitCode.self) {
            try await DefaultNetworkStub.with(failing) { _ in try await cmd.run() }
        }
    }

    @Test("certificates list prints active/expired and handles empty results")
    func certificatesList() async throws {
        let router = StubRouter().on("GET", "/v1/certificates", .ok(ASCStub.list([
            ASCStub.cert("c1", name: "Old", serial: "S1", expiration: "2001-01-01T00:00:00Z"),
            ASCStub.cert("c2", name: "New", expiration: "2999-01-01T00:00:00Z"),
            ASCStub.cert("c3"),
        ])))
        try await CmdStub.apple(router, ["apple", "certificates", "list", "-t", "distribution", "-l", "10"], as: AppleListCertificatesCommand.self)
        let empty = StubRouter().on("GET", "/v1/certificates", .ok(ASCStub.list([])))
        try await CmdStub.apple(empty, ["apple", "certificates", "list"], as: AppleListCertificatesCommand.self)
        try await CmdStub.apple(empty, ["apple", "certificates", "list", "-t", "development"], as: AppleListCertificatesCommand.self)
        #expect(empty.log.count == 2)
    }

    @Test("certificates create rejects unsupported types and rolls back when Apple returns no content")
    func certificatesCreate() async throws {
        await #expect(throws: CommandError.self) {
            try await CmdStub.apple(StubRouter(), ["apple", "certificates", "create", "-t", "bogus"], as: AppleCreateCertificateCommand.self)
        }
        let dir = try TestFiles.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let router = StubRouter()
            .on("POST", "/v1/certificates", ASCStub.created(ASCStub.single(ASCStub.cert("c1", name: "N"))))
            .on("DELETE", "/v1/certificates/c1", ASCStub.noContent)
        await #expect(throws: AppStoreServiceError.self) {
            try await CmdStub.apple(router, ["apple", "certificates", "create", "-t", "development", "-n", "CN", "-o", dir.path], as: AppleCreateCertificateCommand.self)
        }
        #expect(CmdStub.has(router, "DELETE", "/v1/certificates/c1"))
    }

    @Test("certificates delete validates target, deletes, and reports absent certificates")
    func certificatesDelete() async throws {
        await #expect(throws: CommandError.self) {
            try await CmdStub.apple(StubRouter(), ["apple", "certificates", "delete", "--portal-id", " "], as: AppleDeleteCertificateCommand.self)
        }
        let router = StubRouter()
            .on("DELETE", "/v1/certificates/", ASCStub.noContent)
            .on("GET", "/v1/certificates", .ok(ASCStub.list([ASCStub.cert("c1", name: "Mine", serial: "SER")])))
        try await CmdStub.apple(router, ["apple", "certificates", "delete", "--serial-number", "SER"], as: AppleDeleteCertificateCommand.self)
        #expect(CmdStub.has(router, "DELETE", "/v1/certificates/c1"))
        try await CmdStub.apple(router, ["apple", "certificates", "delete", "-n", "Missing"], as: AppleDeleteCertificateCommand.self)
        #expect(CmdStub.count(router, "DELETE", "/v1/certificates/") == 1)
    }

    @Test("certificates prune covers clean, dry-run, and real deletions with failures")
    func certificatesPrune() async throws {
        let clean = StubRouter().on("GET", "/v1/certificates", .ok(ASCStub.list([])))
        try await CmdStub.apple(clean, ["apple", "certificates", "prune", "-t", "distribution"], as: ApplePruneCertificatesCommand.self)
        try await CmdStub.apple(clean, ["apple", "certificates", "prune"], as: ApplePruneCertificatesCommand.self)

        let list = ASCStub.list([
            ASCStub.cert("c1", name: "Old1", serial: "1", expiration: "2001-01-01T00:00:00Z"),
            ASCStub.cert("c2", name: "Old2", expiration: "2002-01-01T00:00:00Z"),
        ])
        let dry = StubRouter().on("GET", "/v1/certificates", .ok(list))
        try await CmdStub.apple(dry, ["apple", "certificates", "prune", "--dry-run"], as: ApplePruneCertificatesCommand.self)
        #expect(CmdStub.count(dry, "DELETE", "/v1/certificates") == 0)

        let real = StubRouter()
            .on("DELETE", "/v1/certificates/c1", ASCStub.noContent)
            .on("DELETE", "/v1/certificates/c2", ASCStub.serverError)
            .on("GET", "/v1/certificates", .ok(list))
        try await CmdStub.apple(real, ["apple", "certificates", "prune"], as: ApplePruneCertificatesCommand.self)
        #expect(CmdStub.count(real, "DELETE", "/v1/certificates/") == 2)
    }

    @Test("profiles list, delete, and prune")
    func profiles() async throws {
        let router = StubRouter().on("GET", "/v1/profiles", .ok(ASCStub.list([
            ASCStub.profile("p1", name: "A", uuid: "U1", expiration: "2030-01-01T00:00:00Z"),
            ASCStub.profile("p2", name: "B", state: "INVALID"),
            ASCStub.res("profiles", "p3"),
        ])))
        try await CmdStub.apple(router, ["apple", "profiles", "list", "-l", "3"], as: AppleListProfilesCommand.self)
        let empty = StubRouter().on("GET", "/v1/profiles", .ok(ASCStub.list([])))
        try await CmdStub.apple(empty, ["apple", "profiles", "list"], as: AppleListProfilesCommand.self)
        try await CmdStub.apple(empty, ["apple", "profiles", "list", "-n", "X"], as: AppleListProfilesCommand.self)

        await #expect(throws: CommandError.self) {
            try await CmdStub.apple(StubRouter(), ["apple", "profiles", "delete", "-n", " "], as: AppleDeleteProfileCommand.self)
        }
        let del = StubRouter()
            .on("DELETE", "/v1/profiles/", ASCStub.noContent)
            .on("GET", "/v1/profiles", .ok(ASCStub.list([ASCStub.profile("p1", name: "A", uuid: "U1")])))
        try await CmdStub.apple(del, ["apple", "profiles", "delete", "--uuid", "U1"], as: AppleDeleteProfileCommand.self)
        try await CmdStub.apple(del, ["apple", "profiles", "delete", "-n", "Nope"], as: AppleDeleteProfileCommand.self)
        #expect(CmdStub.count(del, "DELETE", "/v1/profiles/p1") == 1)

        try await CmdStub.apple(empty, ["apple", "profiles", "prune"], as: ApplePruneProfilesCommand.self)
        try await CmdStub.apple(empty, ["apple", "profiles", "prune", "--include-expired"], as: ApplePruneProfilesCommand.self)
        let pruneList = ASCStub.list([
            ASCStub.profile("p1", name: "Bad", state: "INVALID"),
            ASCStub.profile("p2", name: "Old", expiration: "2001-01-01T00:00:00Z"),
        ])
        let dry = StubRouter().on("GET", "/v1/profiles", .ok(pruneList))
        try await CmdStub.apple(dry, ["apple", "profiles", "prune", "--include-expired", "--dry-run"], as: ApplePruneProfilesCommand.self)
        #expect(CmdStub.count(dry, "DELETE", "/v1/profiles") == 0)
        let real = StubRouter()
            .on("DELETE", "/v1/profiles/p1", ASCStub.noContent)
            .on("DELETE", "/v1/profiles/p2", ASCStub.serverError)
            .on("GET", "/v1/profiles", .ok(pruneList))
        try await CmdStub.apple(real, ["apple", "profiles", "prune", "--include-expired"], as: ApplePruneProfilesCommand.self)
        #expect(CmdStub.count(real, "DELETE", "/v1/profiles/") == 2)
    }

    @Test("profiles create saves to a file or prints a hint, and rejects empty bundle IDs")
    func profilesCreate() async throws {
        await #expect(throws: CommandError.self) {
            try await CmdStub.apple(StubRouter(), ["apple", "profiles", "create", "-b", "  "], as: AppleCreateProfileCommand.self)
        }
        let dir = try TestFiles.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("p.mobileprovision")
        let router = StubRouter()
            .on("GET", "/v1/bundleIds", .ok(ASCStub.list([ASCStub.bundle("b1", identifier: "com.a")])))
            .on("GET", "/v1/certificates", .ok(ASCStub.list([ASCStub.cert("c1", name: "Dist")])))
            .on("GET", "/v1/devices", .ok(ASCStub.list([ASCStub.device("d1")])))
            .on("POST", "/v1/profiles", ASCStub.created(ASCStub.single(ASCStub.profile("p1", uuid: "U", content: "cHJvZg=="))))
        try await CmdStub.apple(router, ["apple", "profiles", "create", "-b", "com.a", "-o", out.path], as: AppleCreateProfileCommand.self)
        #expect(FileManager.default.fileExists(atPath: out.path))
        try await CmdStub.apple(router, ["apple", "profiles", "create", "-b", "com.a", "-t", "development", "--certificate-id", "c1", "--device-ids", "d1"], as: AppleCreateProfileCommand.self)
        #expect(CmdStub.count(router, "POST", "/v1/profiles") == 2)
    }

    @Test("identifiers list, create (with capabilities), and delete")
    func identifiers() async throws {
        let list = StubRouter().on("GET", "/v1/bundleIds", .ok(ASCStub.list([ASCStub.bundle("b1", identifier: "com.a"), ASCStub.res("bundleIds", "b2")])))
        try await CmdStub.apple(list, ["apple", "identifiers", "list", "-l", "2"], as: AppleListIdentifiersCommand.self)
        let empty = StubRouter().on("GET", "/v1/bundleIds", .ok(ASCStub.list([])))
        try await CmdStub.apple(empty, ["apple", "identifiers", "list"], as: AppleListIdentifiersCommand.self)
        try await CmdStub.apple(empty, ["apple", "identifiers", "list", "-b", "com.z"], as: AppleListIdentifiersCommand.self)

        await #expect(throws: CommandError.self) {
            try await CmdStub.apple(StubRouter(), ["apple", "identifiers", "create"], as: AppleCreateIdentifierCommand.self)
        }
        let create = StubRouter()
            .on("POST", "/v1/bundleIdCapabilities", ASCStub.created(ASCStub.single(AppleJSON.capability("cap1", "PUSH_NOTIFICATIONS"))), .status(409, ASCStub.errors(409)))
            .on("POST", "/v1/bundleIds", ASCStub.created(ASCStub.single(ASCStub.bundle("b1", identifier: "com.a"))))
        try await CmdStub.apple(create, ["apple", "identifiers", "create", "-b", "com.a", "-n", "App", "-p", "ios", "--capabilities", "push-notifications,in-app-purchase"], as: AppleCreateIdentifierCommand.self)
        #expect(CmdStub.count(create, "POST", "/v1/bundleIdCapabilities") == 2)
        try await CmdStub.apple(create, ["apple", "identifiers", "create", "-b", "com.b"], as: AppleCreateIdentifierCommand.self)

        await #expect(throws: CommandError.self) {
            try await CmdStub.apple(StubRouter(), ["apple", "identifiers", "delete", "-b", " "], as: AppleDeleteIdentifierCommand.self)
        }
        let del = StubRouter()
            .on("DELETE", "/v1/bundleIds/b1", ASCStub.noContent)
            .on("GET", "/v1/bundleIds", .ok(ASCStub.list([ASCStub.bundle("b1", identifier: "com.a")])))
        try await CmdStub.apple(del, ["apple", "identifiers", "delete", "-b", "com.a"], as: AppleDeleteIdentifierCommand.self)
        #expect(CmdStub.has(del, "DELETE", "/v1/bundleIds/b1"))
        try await CmdStub.apple(empty, ["apple", "identifiers", "delete", "-b", "com.none"], as: AppleDeleteIdentifierCommand.self)
        let failing = StubRouter()
            .on("DELETE", "/v1/bundleIds/b1", .status(409, ASCStub.errors(409)))
            .on("GET", "/v1/bundleIds", .ok(ASCStub.list([ASCStub.bundle("b1", identifier: "com.a")])))
        await #expect(throws: CommandError.self) {
            try await CmdStub.apple(failing, ["apple", "identifiers", "delete", "-b", "com.a"], as: AppleDeleteIdentifierCommand.self)
        }
    }

    @Test("capabilities list: catalog, enabled capabilities, none enabled, and lookup failures")
    func capabilities() async throws {
        try await CmdStub.apple(StubRouter(), ["apple", "capabilities", "list"], as: AppleListCapabilitiesCommand.self)
        let router = StubRouter()
            .on("GET", "bundleIdCapabilities", .ok(ASCStub.list([AppleJSON.capability("cap1", "PUSH_NOTIFICATIONS"), ASCStub.res("bundleIdCapabilities", "cap2")])))
            .on("GET", "/v1/bundleIds", .ok(ASCStub.list([ASCStub.bundle("b1", identifier: "com.a")])))
        try await CmdStub.apple(router, ["apple", "capabilities", "list", "-b", "com.a"], as: AppleListCapabilitiesCommand.self)
        #expect(CmdStub.has(router, "GET", "/v1/bundleIds/b1/bundleIdCapabilities"))
        let none = StubRouter()
            .on("GET", "bundleIdCapabilities", .ok(ASCStub.list([])))
            .on("GET", "/v1/bundleIds", .ok(ASCStub.list([ASCStub.bundle("b1", identifier: "com.a")])))
        try await CmdStub.apple(none, ["apple", "capabilities", "list", "-b", "com.a"], as: AppleListCapabilitiesCommand.self)
        let missing = StubRouter().on("GET", "/v1/bundleIds", .ok(ASCStub.list([])))
        try await CmdStub.apple(missing, ["apple", "capabilities", "list", "-b", "com.a"], as: AppleListCapabilitiesCommand.self)
    }

    @Test("devices list, create, and disable")
    func devices() async throws {
        let list = StubRouter().on("GET", "/v1/devices", .ok(ASCStub.list([
            ASCStub.device("d1"),
            ASCStub.res("devices", "d2", #"{"name":"Off","status":"DISABLED"}"#),
            ASCStub.res("devices", "d3"),
        ])))
        try await CmdStub.apple(list, ["apple", "devices", "list", "-l", "5"], as: AppleListDevicesCommand.self)
        let empty = StubRouter().on("GET", "/v1/devices", .ok(ASCStub.list([])))
        try await CmdStub.apple(empty, ["apple", "devices", "list"], as: AppleListDevicesCommand.self)
        try await CmdStub.apple(empty, ["apple", "devices", "list", "-p", "ios"], as: AppleListDevicesCommand.self)

        let create = StubRouter().on("POST", "/v1/devices", ASCStub.created(ASCStub.single(ASCStub.device("d9"))))
        try await CmdStub.apple(create, ["apple", "devices", "create", "-n", "Phone", "--udid", "U9"], as: AppleAddDeviceCommand.self)
        #expect(ASCStub.dataAttrs(create.log.requests.last)["udid"] as? String == "U9")

        let disable = StubRouter()
            .on("PATCH", "/v1/devices/d1", .ok(ASCStub.single(ASCStub.device("d1"))))
            .on("GET", "/v1/devices", .ok(ASCStub.list([ASCStub.device("d1", udid: "UD1")])))
        try await CmdStub.apple(disable, ["apple", "devices", "disable", "--udid", "UD1"], as: AppleDisableDeviceCommand.self)
        #expect(CmdStub.has(disable, "PATCH", "/v1/devices/d1"))
        await #expect(throws: CommandError.self) {
            try await CmdStub.apple(empty, ["apple", "devices", "disable", "--udid", "nope"], as: AppleDisableDeviceCommand.self)
        }
    }
}

// MARK: - Users & invitations

@Suite("Apple User Commands Coverage", .serialized)
struct AppleUserCommandsCoverageTests {
    @Test("users list prints users and handles empty filters")
    func usersList() async throws {
        let router = StubRouter().on("GET", "/v1/users", .ok(ASCStub.list([AppleJSON.user(), ASCStub.res("users", "u2")])))
        try await CmdStub.apple(router, ["apple", "users", "list", "-r", "admin", "-l", "5"], as: AppleListUsersCommand.self)
        let empty = StubRouter().on("GET", "/v1/users", .ok(ASCStub.list([])))
        try await CmdStub.apple(empty, ["apple", "users", "list"], as: AppleListUsersCommand.self)
        try await CmdStub.apple(empty, ["apple", "users", "list", "--username", "x@y.z"], as: AppleListUsersCommand.self)
        #expect(empty.log.count == 2)
    }

    @Test("users invite resolves visible apps and validates roles")
    func usersInvite() async throws {
        await #expect(throws: CommandError.self) {
            try await CmdStub.apple(StubRouter(), ["apple", "users", "invite", "-e", "a@b.c", "--first-name", "A", "--last-name", "B", "-r", " , "], as: AppleInviteUserCommand.self)
        }
        let router = StubRouter()
            .on("GET", "/v1/apps", .ok(ASCStub.list([AppleJSON.app("555", bundleId: "com.a")])))
            .on("POST", "/v1/userInvitations", ASCStub.created(ASCStub.single(AppleJSON.invitation())))
        try await CmdStub.apple(router, ["apple", "users", "invite", "-e", "a@b.c", "--first-name", "A", "--last-name", "B", "-r", "developer", "--visible-apps", "com.a,777", "--provisioning-allowed"], as: AppleInviteUserCommand.self)
        #expect(CmdStub.has(router, "POST", "/v1/userInvitations"))
        let plain = StubRouter().on("POST", "/v1/userInvitations", ASCStub.created(ASCStub.single(ASCStub.res("userInvitations", "i2"))))
        try await CmdStub.apple(plain, ["apple", "users", "invite", "-e", "a@b.c", "--first-name", "A", "--last-name", "B", "-r", "admin"], as: AppleInviteUserCommand.self)
    }

    @Test("users update validates input, resolves users, and patches")
    func usersUpdate() async throws {
        await #expect(throws: CommandError.self) {
            try await CmdStub.apple(StubRouter(), ["apple", "users", "update", "-r", "admin"], as: AppleUpdateUserCommand.self)
        }
        await #expect(throws: CommandError.self) {
            try await CmdStub.apple(StubRouter(), ["apple", "users", "update", "--id", "u1"], as: AppleUpdateUserCommand.self)
        }
        let router = StubRouter()
            .on("PATCH", "/v1/users/u1", .ok(ASCStub.single(AppleJSON.user())))
            .on("GET", "/v1/users", .ok(ASCStub.list([AppleJSON.user()])))
            .on("GET", "/v1/apps", .ok(ASCStub.list([AppleJSON.app("555", bundleId: "com.a")])))
        try await CmdStub.apple(router, ["apple", "users", "update", "--username", "a@b.c", "-r", "admin,developer", "--visible-apps", "com.a", "--no-all-apps-visible"], as: AppleUpdateUserCommand.self)
        try await CmdStub.apple(router, ["apple", "users", "update", "--id", "u1", "--provisioning-allowed"], as: AppleUpdateUserCommand.self)
        #expect(CmdStub.count(router, "PATCH", "/v1/users/u1") == 2)
        let empty = StubRouter().on("GET", "/v1/users", .ok(ASCStub.list([])))
        await #expect(throws: CommandError.self) {
            try await CmdStub.apple(empty, ["apple", "users", "update", "--username", "x@y.z", "-r", "admin"], as: AppleUpdateUserCommand.self)
        }
    }

    @Test("users delete by id, by username, missing, and already absent")
    func usersDelete() async throws {
        await #expect(throws: CommandError.self) {
            try await CmdStub.apple(StubRouter(), ["apple", "users", "delete"], as: AppleDeleteUserCommand.self)
        }
        let router = StubRouter()
            .on("DELETE", "/v1/users/u1", ASCStub.noContent, ASCStub.notFound)
            .on("GET", "/v1/users", .ok(ASCStub.list([AppleJSON.user()])))
        try await CmdStub.apple(router, ["apple", "users", "delete", "--username", "a@b.c"], as: AppleDeleteUserCommand.self)
        try await CmdStub.apple(router, ["apple", "users", "delete", "--id", "u1"], as: AppleDeleteUserCommand.self)
        #expect(CmdStub.count(router, "DELETE", "/v1/users/u1") == 2)
        let empty = StubRouter().on("GET", "/v1/users", .ok(ASCStub.list([])))
        try await CmdStub.apple(empty, ["apple", "users", "delete", "--username", "x@y.z"], as: AppleDeleteUserCommand.self)
    }

    @Test("invitations list and cancel")
    func invitations() async throws {
        let router = StubRouter().on("GET", "/v1/userInvitations", .ok(ASCStub.list([AppleJSON.invitation(), ASCStub.res("userInvitations", "i2")])))
        try await CmdStub.apple(router, ["apple", "invitations", "list", "-r", "developer"], as: AppleListInvitationsCommand.self)
        let empty = StubRouter().on("GET", "/v1/userInvitations", .ok(ASCStub.list([])))
        try await CmdStub.apple(empty, ["apple", "invitations", "list"], as: AppleListInvitationsCommand.self)
        try await CmdStub.apple(empty, ["apple", "invitations", "list", "-e", "x@y.z"], as: AppleListInvitationsCommand.self)

        await #expect(throws: CommandError.self) {
            try await CmdStub.apple(StubRouter(), ["apple", "invitations", "cancel"], as: AppleCancelInvitationCommand.self)
        }
        let cancel = StubRouter()
            .on("DELETE", "/v1/userInvitations/i1", ASCStub.noContent, ASCStub.notFound)
            .on("GET", "/v1/userInvitations", .ok(ASCStub.list([AppleJSON.invitation()])))
        try await CmdStub.apple(cancel, ["apple", "invitations", "cancel", "-e", "a@b.c"], as: AppleCancelInvitationCommand.self)
        try await CmdStub.apple(cancel, ["apple", "invitations", "cancel", "--id", "i1"], as: AppleCancelInvitationCommand.self)
        #expect(CmdStub.count(cancel, "DELETE", "/v1/userInvitations/i1") == 2)
        try await CmdStub.apple(empty, ["apple", "invitations", "cancel", "-e", "x@y.z"], as: AppleCancelInvitationCommand.self)
    }
}

// MARK: - Versions

@Suite("Apple Version Commands Coverage", .serialized)
struct AppleVersionCommandsCoverageTests {
    @Test("versions create: release type parsing and validation")
    func createValidation() throws {
        #expect(try AppleCreateVersionCommand.releaseTypeValue(nil) == nil)
        #expect(try AppleCreateVersionCommand.releaseTypeValue("manual") == "MANUAL")
        #expect(try AppleCreateVersionCommand.releaseTypeValue("after_approval") == "AFTER_APPROVAL")
        #expect(try AppleCreateVersionCommand.releaseTypeValue("automatic") == "AFTER_APPROVAL")
        #expect(try AppleCreateVersionCommand.releaseTypeValue("Scheduled") == "SCHEDULED")
        #expect(throws: ValidationError.self) { try AppleCreateVersionCommand.releaseTypeValue("never") }
        #expect(throws: (any Error).self) { _ = try CmdStub.parse(["apple", "versions", "create", "--release-type", "scheduled"] + CmdStub.appleCreds(), as: AppleCreateVersionCommand.self) }
        #expect(throws: (any Error).self) { _ = try CmdStub.parse(["apple", "versions", "create", "--release-date", "2030-01-01T00:00:00Z"] + CmdStub.appleCreds(), as: AppleCreateVersionCommand.self) }
        #expect(throws: (any Error).self) { _ = try CmdStub.parse(["apple", "versions", "create", "--release-type", "scheduled", "--release-date", "tomorrow"] + CmdStub.appleCreds(), as: AppleCreateVersionCommand.self) }
        _ = try CmdStub.parse(["apple", "versions", "create", "--release-type", "scheduled", "--release-date", "2030-01-01T00:00:00Z"] + CmdStub.appleCreds(), as: AppleCreateVersionCommand.self)

        #expect(AppleCreateVersionCommand.hint(for: .apiError(status: 409, message: "")) != nil)
        #expect(AppleCreateVersionCommand.hint(for: .apiError(status: 422, message: "")) != nil)
        #expect(AppleCreateVersionCommand.hint(for: .apiError(status: 403, message: "")) != nil)
        #expect(AppleCreateVersionCommand.hint(for: .apiError(status: 500, message: "")) == nil)
        #expect(AppleCreateVersionCommand.hint(for: .notFound("x")) == nil)
    }

    @Test("versions create with an explicit version: dry run, success, and rejection")
    func createExplicit() async throws {
        let base = ["apple", "versions", "create", "--app-id", "123", "--app-version", "2.0"]
        try await CmdStub.apple(StubRouter(), base + ["--dry-run"], as: AppleCreateVersionCommand.self)
        let router = StubRouter().on("POST", "/v1/appStoreVersions", ASCStub.created(ASCStub.single(AppleJSON.version("v2", "2.0"))))
        try await CmdStub.apple(router, base + ["--release-type", "scheduled", "--release-date", "2030-01-01T00:00:00Z", "--copyright", "2026 X"], as: AppleCreateVersionCommand.self)
        let attrs = ASCStub.dataAttrs(router.log.requests.last)
        #expect(attrs["versionString"] as? String == "2.0")
        #expect(attrs["releaseType"] as? String == "SCHEDULED")
        let rejected = StubRouter().on("POST", "/v1/appStoreVersions", .status(409, ASCStub.errors(409)))
        await #expect(throws: CommandError.self) {
            try await CmdStub.apple(rejected, base, as: AppleCreateVersionCommand.self)
        }
    }

    @Test("versions create refuses when an editable version already exists")
    func createEditableExists() async throws {
        let router = StubRouter().on("GET", "/appStoreVersions", .ok(ASCStub.list([AppleJSON.version()])))
        await #expect(throws: CommandError.self) {
            try await CmdStub.apple(router, ["apple", "versions", "create", "--app-id", "123"], as: AppleCreateVersionCommand.self)
        }
    }

    @Test("versions delete: selection, dry run, deletion, absent, and refusal")
    func delete() throws {
        let editable = AppleDeleteVersionCommand.Candidate(id: "v1", versionString: "1.1", state: "PREPARE_FOR_SUBMISSION")
        let live = AppleDeleteVersionCommand.Candidate(id: "v0", versionString: "1.0", state: "READY_FOR_SALE")
        #expect(try AppleDeleteVersionCommand.selectTarget(versions: [live, editable], explicit: nil) == editable)
        #expect(try AppleDeleteVersionCommand.selectTarget(versions: [live], explicit: nil) == nil)
        #expect(try AppleDeleteVersionCommand.selectTarget(versions: [live, editable], explicit: "1.1") == editable)
        #expect(throws: CommandError.self) { try AppleDeleteVersionCommand.selectTarget(versions: [live], explicit: "1.0") }
        #expect(throws: CommandError.self) { try AppleDeleteVersionCommand.selectTarget(versions: [], explicit: "9.9") }
        #expect(throws: CommandError.self) { try AppleDeleteVersionCommand.selectTarget(versions: [live], explicit: "9.9") }
        #expect(AppleDeleteVersionCommand.hint(for: .apiError(status: 409, message: "")) != nil)
        #expect(AppleDeleteVersionCommand.hint(for: .apiError(status: 401, message: "")) != nil)
        #expect(AppleDeleteVersionCommand.hint(for: .apiError(status: 500, message: "")) == nil)
        #expect(AppleDeleteVersionCommand.hint(for: .invalidResponse("x")) == nil)
    }

    @Test("versions delete executes against the API")
    func deleteExecute() async throws {
        let base = ["apple", "versions", "delete", "--app-id", "123"]
        let versions = ASCStub.list([AppleJSON.version("v1", "1.1"), AppleJSON.version("v0", "1.0", state: "READY_FOR_DISTRIBUTION")])
        let none = StubRouter().on("GET", "/appStoreVersions", .ok(ASCStub.list([AppleJSON.version("v0", "1.0", state: "READY_FOR_DISTRIBUTION")])))
        try await CmdStub.apple(none, base, as: AppleDeleteVersionCommand.self)

        let dry = StubRouter().on("GET", "/appStoreVersions", .ok(versions))
        try await CmdStub.apple(dry, base + ["--dry-run"], as: AppleDeleteVersionCommand.self)
        #expect(CmdStub.count(dry, "DELETE", "/v1/appStoreVersions") == 0)

        let real = StubRouter()
            .on("DELETE", "/v1/appStoreVersions/v1", ASCStub.noContent, ASCStub.notFound, .status(409, ASCStub.errors(409)))
            .on("GET", "/appStoreVersions", .ok(versions))
        try await CmdStub.apple(real, base, as: AppleDeleteVersionCommand.self)
        try await CmdStub.apple(real, base + ["--app-version", "1.1"], as: AppleDeleteVersionCommand.self)
        await #expect(throws: CommandError.self) {
            try await CmdStub.apple(real, base, as: AppleDeleteVersionCommand.self)
        }
    }
}
