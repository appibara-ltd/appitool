import ArgumentParser
import Foundation
import GoogleServices
import Testing
@testable import appitool

@Suite("Firebase Apps Tests")
struct FirebaseAppsTests {
    @Test("Create request bodies carry only the fields of their platform")
    func createBodies() {
        let ios = FirebaseAppCreateRequest(platform: .ios, displayName: "My App", identifier: "com.example.app", appStoreId: "123", teamId: "ABCDE12345").body()
        #expect(ios["bundleId"] as? String == "com.example.app")
        #expect(ios["displayName"] as? String == "My App")
        #expect(ios["appStoreId"] as? String == "123")
        #expect(ios["teamId"] as? String == "ABCDE12345")
        #expect(ios["packageName"] == nil)

        let android = FirebaseAppCreateRequest(platform: .android, identifier: "com.example.app", sha1Hashes: ["AB:CD:EF"]).body()
        #expect(android["packageName"] as? String == "com.example.app")
        #expect(android["sha1Hashes"] as? [String] == ["abcdef"])
        #expect(android["sha256Hashes"] == nil)
        #expect(android["displayName"] == nil)

        let web = FirebaseAppCreateRequest(platform: .web, displayName: "Web", identifier: "ignored").body()
        #expect(web.count == 1)
        #expect(web["displayName"] as? String == "Web")
    }

    @Test("Created apps map to summaries with their platform identifier")
    func parseCreatedApp() throws {
        let json = #"{"name":"projects/p/androidApps/1:1:android:a","appId":"1:1:android:a","displayName":"App","packageName":"com.example.app","state":"ACTIVE"}"#
        let app = try FirebaseService.parseCreatedApp(Data(json.utf8), platform: .android)
        #expect(app == FirebaseAppSummary(appId: "1:1:android:a", displayName: "App", platform: "ANDROID", namespace: "com.example.app", state: "ACTIVE"))
        #expect(FirebaseAppSupport.appIdEnvVar(for: app.platform) == "FIREBASE_ANDROID_APP_ID")
        #expect(FirebaseAppSupport.appIdEnvVar(for: "WEB") == nil)
        let other = FirebaseAppSummary(appId: "1:1:ios:b", displayName: nil, platform: "IOS", namespace: nil, state: nil)
        #expect(FirebaseService.uniqueApps([app, other, app]) == [app, other])

        #expect(throws: FirebaseAppsError.self) {
            _ = try FirebaseService.parseCreatedApp(Data(#"{"displayName":"x"}"#.utf8), platform: .ios)
        }
    }

    @Test("sync-fingerprints adds missing fingerprints once and removes extras only with --replace")
    func syncPlan() {
        typealias F = FirebaseSyncFingerprintsCommand.Fingerprint
        let desired = [
            F(hash: "AB:CD", type: .sha1, source: "Play"),
            F(hash: "abcd", type: .sha1, source: "dup"),
            F(hash: "EE:FF", type: .sha256, source: "Play"),
        ]
        let registered = [
            FirebaseShaCertificate(name: "projects/p/androidApps/a/sha/1", shaHash: "eeff", certType: .sha256),
            FirebaseShaCertificate(name: "projects/p/androidApps/a/sha/2", shaHash: "1234", certType: .sha1),
        ]
        let keep = FirebaseSyncFingerprintsCommand.plan(desired: desired, registered: registered, replace: false)
        #expect(keep.add == [F(hash: "abcd", type: .sha1, source: "Play")])
        #expect(keep.unchanged == [F(hash: "eeff", type: .sha256, source: "Play")])
        #expect(keep.remove.isEmpty)

        let replace = FirebaseSyncFingerprintsCommand.plan(desired: desired, registered: registered, replace: true)
        #expect(replace.remove.map(\.shaHash) == ["1234"])
    }

    @Test("delete-app finds apps by App ID or platform identifier and ignores deleted apps")
    func deleteAppLookup() throws {
        let apps = [
            FirebaseAppSummary(appId: "1:1:ios:a", displayName: "iOS", platform: "IOS", namespace: "com.example.app", state: "ACTIVE"),
            FirebaseAppSummary(appId: "1:1:android:b", displayName: "Android", platform: "ANDROID", namespace: "com.example.app", state: "ACTIVE"),
            FirebaseAppSummary(appId: "1:1:android:c", displayName: "Old", platform: "ANDROID", namespace: "com.example.old", state: "DELETED"),
        ]
        #expect(try FirebaseDeleteAppCommand.findApp(in: apps, appId: "1:1:ios:a", platform: nil, identifier: nil, displayName: nil).appId == "1:1:ios:a")
        #expect(try FirebaseDeleteAppCommand.findApp(in: apps, appId: nil, platform: .android, identifier: "com.example.app", displayName: nil).appId == "1:1:android:b")
        #expect(throws: (any Error).self) {
            _ = try FirebaseDeleteAppCommand.findApp(in: apps, appId: nil, platform: .android, identifier: "com.example.old", displayName: nil)
        }
        #expect(throws: (any Error).self) { _ = try FirebaseDeleteAppCommand.parse(["-p", "ios"]) }
        #expect(throws: (any Error).self) { _ = try FirebaseDeleteAppCommand.parse(["--firebase-app-id", "1:1:ios:a", "-p", "ios"]) }
        #expect(throws: (any Error).self) { _ = try FirebaseDeleteAppCommand.parse(["-p", "ios", "--package-name", "com.example.app"]) }
        _ = try FirebaseDeleteAppCommand.parse(["-p", "ios", "-b", "com.example.app"])
        #expect(throws: (any Error).self) { _ = try FirebaseSyncFingerprintsCommand.parse(["--no-play"]) }
    }

    @Test("add-app rejects options of other platforms and malformed fingerprints")
    func addAppValidation() throws {
        #expect(throws: (any Error).self) { _ = try FirebaseAddAppCommand.parse(["-p", "android", "-b", "com.example.app"]) }
        #expect(throws: (any Error).self) { _ = try FirebaseAddAppCommand.parse(["-p", "ios", "--sha1", "AB"]) }
        #expect(throws: (any Error).self) { _ = try FirebaseAddAppCommand.parse(["-p", "web"]) }
        #expect(throws: (any Error).self) { _ = try FirebaseAddAppCommand.parse(["-p", "android", "--sha1", "AB:CD"]) }
        let sha1 = Array(repeating: "AB", count: 20).joined(separator: ":")
        _ = try FirebaseAddAppCommand.parse(["-p", "android", "--package-name", "com.example.app", "--sha1", sha1])
        _ = try FirebaseAddAppCommand.parse(["-p", "web", "-n", "Web"])
    }
}
