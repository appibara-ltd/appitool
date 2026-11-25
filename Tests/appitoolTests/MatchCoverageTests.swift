import CommonCrypto
import Foundation
import Testing
@testable import appitool

// MARK: - Helpers

private enum MatchFixtures {
    /// A minimal DER-looking payload (ASN.1 SEQUENCE header) that `isValidDecryptedPayload` accepts.
    static let derPayload = Data([0x30, 0x82, 0x01, 0x0A, 0x02, 0x01, 0x01, 0x05, 0x00, 0xAA, 0xBB])

    static func aes256CbcEncrypt(_ data: Data, key: Data, iv: Data) -> Data {
        var out = Data(count: data.count + kCCBlockSizeAES128)
        var moved: size_t = 0
        let outCount = out.count
        let status = key.withUnsafeBytes { k in
            iv.withUnsafeBytes { i in
                data.withUnsafeBytes { d in
                    out.withUnsafeMutableBytes { o in
                        CCCrypt(
                            CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                            k.baseAddress, key.count, i.baseAddress, d.baseAddress, data.count,
                            o.baseAddress, outCount, &moved
                        )
                    }
                }
            }
        }
        precondition(status == kCCSuccess)
        out.count = moved
        return out
    }

    enum V1Derivation { case md5, sha256, pbkdf2 }

    static func v1Encrypt(_ data: Data, password: String, derivation: V1Derivation) throws -> Data {
        let enc = MatchEncryption()
        let salt = Data([1, 2, 3, 4, 5, 6, 7, 8])
        let key: Data
        let iv: Data
        switch derivation {
        case .md5:
            (key, iv) = enc.evpBytesToKey(password: password, salt: salt, keyLen: 32, ivLen: 16, hash: .md5)
        case .sha256:
            (key, iv) = enc.evpBytesToKey(password: password, salt: salt, keyLen: 32, ivLen: 16, hash: .sha256)
        case .pbkdf2:
            let derived = try enc.pbkdf2HmacSha256(password: password, salt: salt, length: 48, iterations: 10_000)
            key = derived.subdata(in: 0..<32)
            iv = derived.subdata(in: 32..<48)
        }
        var payload = Data(MatchEncryption.v1Prefix.utf8)
        payload.append(salt)
        payload.append(aes256CbcEncrypt(data, key: key, iv: iv))
        return payload
    }

    static func profile(name: String? = "My Profile", uuid: String? = "UUID-1234", expiration: Date? = nil, certs: [Data]? = nil) throws -> Data {
        var dict: [String: Any] = ["TeamIdentifier": ["TEAM123"]]
        if let name { dict["Name"] = name }
        if let uuid { dict["UUID"] = uuid }
        if let expiration { dict["ExpirationDate"] = expiration }
        if let certs { dict["DeveloperCertificates"] = certs }
        let xml = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        // Wrap in fake CMS bytes so the extractor must locate the embedded plist.
        var data = Data([0x30, 0x80, 0x06, 0x09, 0xFF, 0x00])
        data.append(xml)
        data.append(Data([0x00, 0x00, 0xA0, 0x82]))
        return data
    }
}

// MARK: - Encryption

@Suite("Match Encryption Coverage")
struct MatchEncryptionCoverageTests {
    let enc = MatchEncryption()

    @Test("V2 encrypt/decrypt round trip and wrong password")
    func v2RoundTrip() throws {
        let plain = Data("hello match v2".utf8)
        let encrypted = try enc.encryptV2(data: plain, password: "pw")
        #expect(encrypted.starts(with: MatchEncryption.v2Prefix.utf8))
        #expect(try enc.decryptV2(encryptedPayload: encrypted, password: "pw", fileName: "a.cer") == plain)
        #expect(throws: MatchError.self) {
            try enc.decryptV2(encryptedPayload: encrypted, password: "wrong", fileName: "a.cer")
        }
        #expect(throws: MatchError.self) {
            try enc.decryptV2(encryptedPayload: Data(MatchEncryption.v2Prefix.utf8), password: "pw", fileName: "a.cer")
        }
    }

    @Test("V1 decrypts MD5, SHA256, and PBKDF2 derived payloads")
    func v1Derivations() async throws {
        for derivation in [MatchFixtures.V1Derivation.md5, .sha256, .pbkdf2] {
            let encrypted = try MatchFixtures.v1Encrypt(MatchFixtures.derPayload, password: "secret", derivation: derivation)
            let decrypted = try await enc.decryptV1(encryptedPayload: encrypted, password: "secret", fileName: "x.p12")
            #expect(decrypted == MatchFixtures.derPayload)
        }
    }

    @Test("V1 rejects wrong password and truncated payloads")
    func v1Failures() async throws {
        let encrypted = try MatchFixtures.v1Encrypt(MatchFixtures.derPayload, password: "secret", derivation: .md5)
        await #expect(throws: MatchError.self) {
            _ = try await enc.decryptV1(encryptedPayload: encrypted, password: "nope", fileName: "x.p12")
        }
        await #expect(throws: MatchError.self) {
            _ = try await enc.decryptV1(encryptedPayload: Data("Salted__".utf8), password: "secret", fileName: "x.p12")
        }
        await #expect(throws: MatchError.self) {
            _ = try await enc.decryptAes256Cbc(data: Data(count: 16), key: Data(count: 5), iv: Data(count: 16))
        }
    }

    @Test("isValidDecryptedPayload accepts DER, XML, PEM and rejects others")
    func validPayloads() {
        #expect(enc.isValidDecryptedPayload(MatchFixtures.derPayload))
        #expect(enc.isValidDecryptedPayload(Data("<?xml version=\"1.0\"?>".utf8)))
        #expect(enc.isValidDecryptedPayload(Data("<!DOCTYPE plist>".utf8)))
        #expect(enc.isValidDecryptedPayload(Data("-----BEGIN CERT".utf8)))
        #expect(!enc.isValidDecryptedPayload(Data("abc".utf8)))
        #expect(!enc.isValidDecryptedPayload(Data("random text".utf8)))
    }

    @Test("evpBytesToKey is deterministic and sized")
    func evp() {
        let a = enc.evpBytesToKey(password: "p", salt: Data(count: 8), keyLen: 32, ivLen: 16, hash: .md5)
        let b = enc.evpBytesToKey(password: "p", salt: Data(count: 8), keyLen: 32, ivLen: 16, hash: .md5)
        let c = enc.evpBytesToKey(password: "p", salt: Data(count: 8), keyLen: 32, ivLen: 16, hash: .sha256)
        #expect(a.key == b.key && a.iv == b.iv)
        #expect(a.key.count == 32 && a.iv.count == 16)
        #expect(a.key != c.key)
    }

    @Test("detectFormat recognizes raw, base64, plain, and unknown data")
    func detect() throws {
        let v2 = try enc.encryptV2(data: Data("x".utf8), password: "p")
        #expect(enc.detectFormat(data: v2).format == .v2)
        let v1 = try MatchFixtures.v1Encrypt(MatchFixtures.derPayload, password: "p", derivation: .md5)
        #expect(enc.detectFormat(data: v1).format == .v1)

        let b64v2 = v2.base64EncodedData(options: .lineLength64Characters)
        let r2 = enc.detectFormat(data: b64v2)
        #expect(r2.format == .v2)
        #expect(r2.payload == v2)
        #expect(enc.detectFormat(data: v1.base64EncodedData()).format == .v1)

        #expect(enc.detectFormat(data: Data([0x30, 0x82, 0x00, 0x01])).format == .unencrypted)
        #expect(enc.detectFormat(data: Data([0x30, 0x81, 0x00])).format == .unencrypted)
        #expect(enc.detectFormat(data: Data([0xFE, 0xED, 0xFE, 0xED, 0x00])).format == .unencrypted)
        #expect(enc.detectFormat(data: Data("  {\"a\":1}".utf8)).format == .unencrypted)
        #expect(enc.detectFormat(data: Data("-----BEGIN PRIVATE KEY-----".utf8)).format == .unencrypted)
        #expect(enc.detectFormat(data: Data([0x01, 0x02, 0xFF])).format == .unknown)

        #expect(MatchEncryption.EncryptionFormat.v2.isV2)
        #expect(MatchEncryption.EncryptionFormat.v1.isV1)
        #expect(!MatchEncryption.EncryptionFormat.unknown.isEncrypted)
        #expect(MatchEncryption.EncryptionFormat.v1.isEncrypted)
    }

    @Test("File and directory encrypt/decrypt round trip")
    func directoryRoundTrip() async throws {
        let dir = try TestFiles.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fm = FileManager.default
        let certs = dir.appendingPathComponent("certs/distribution")
        try fm.createDirectory(at: certs, withIntermediateDirectories: true)
        let cer = certs.appendingPathComponent("ABC.cer")
        let pem = certs.appendingPathComponent("key.pem")
        let txt = certs.appendingPathComponent("readme.txt")
        let hidden = certs.appendingPathComponent(".hidden.cer")
        let gitDir = dir.appendingPathComponent(".git")
        try fm.createDirectory(at: gitDir, withIntermediateDirectories: true)
        let gitFile = gitDir.appendingPathComponent("x.json")
        try MatchFixtures.derPayload.write(to: cer)
        try Data("-----BEGIN PRIVATE KEY-----\nabc".utf8).write(to: pem)
        try Data("plain".utf8).write(to: txt)
        try Data("hidden".utf8).write(to: hidden)
        try Data("{}".utf8).write(to: gitFile)

        try enc.encryptDirectory(dir.path, password: "pw")
        #expect(enc.detectFormat(atPath: cer.path) == .v2)
        #expect(enc.detectFormat(atPath: pem.path) == .v2)
        #expect(try Data(contentsOf: txt) == Data("plain".utf8))
        #expect(try Data(contentsOf: gitFile) == Data("{}".utf8))

        // Encrypting again is a no-op for already-encrypted files.
        let before = try Data(contentsOf: cer)
        try enc.encryptFile(atPath: cer.path, password: "pw")
        #expect(try Data(contentsOf: cer) == before)

        try await enc.decryptDirectory(dir.path, password: "pw")
        #expect(try Data(contentsOf: cer) == MatchFixtures.derPayload)
        #expect(enc.detectFormat(atPath: cer.path) == .unencrypted)

        // Decrypting an unencrypted file is a no-op; empty/missing files are ignored.
        try await enc.decryptFile(atPath: cer.path, password: "pw")
        try await enc.decryptFile(atPath: dir.appendingPathComponent("missing.cer").path, password: "pw")
        #expect(enc.detectFormat(atPath: dir.appendingPathComponent("missing.cer").path) == .unknown)

        // V1 file decrypts in place.
        let v1File = certs.appendingPathComponent("legacy.p12")
        try MatchFixtures.v1Encrypt(MatchFixtures.derPayload, password: "pw", derivation: .sha256).write(to: v1File)
        try await enc.decryptFile(atPath: v1File.path, password: "pw")
        #expect(try Data(contentsOf: v1File) == MatchFixtures.derPayload)

        // Unknown content throws.
        let junk = certs.appendingPathComponent("junk.p12")
        try Data([0x01, 0x02, 0x03]).write(to: junk)
        await #expect(throws: MatchError.self) {
            try await enc.decryptFile(atPath: junk.path, password: "pw")
        }

        // Missing directory yields no files.
        try enc.encryptDirectory(dir.appendingPathComponent("nope").path, password: "pw")
    }
}

// MARK: - Models

@Suite("Match Models Coverage")
struct MatchModelsCoverageTests {
    @Test("Profile type directory names, prefixes, and file names")
    func profileTypes() {
        let expected: [(MatchProfileType, String, String, String)] = [
            (.development, "development", "development", "Development"),
            (.adhoc, "distribution", "adhoc", "AdHoc"),
            (.appstore, "distribution", "appstore", "AppStore"),
            (.enterprise, "enterprise", "enterprise", "InHouse"),
            (.developerId, "developer_id", "developer_id", "DeveloperID"),
        ]
        for (type, cert, profile, prefix) in expected {
            #expect(type.certDirectoryName == cert)
            #expect(type.profileDirectoryName == profile)
            #expect(type.profilePrefix == prefix)
        }
        #expect(MatchProfileType.appstore.profileFileName(bundleId: "com.a") == "AppStore_com.a.mobileprovision")
        #expect(MatchProfileType.adhoc.profileFileName(bundleId: "com.a", platform: .tvos) == "AdHoc_com.a_tvos.mobileprovision")
        #expect(MatchProfileType.development.profileFileName(bundleId: "com.a", platform: .catalyst) == "Development_com.a_catalyst.provisionprofile")
        #expect(MatchProfileType.developerId.profileFileName(bundleId: "com.a", platform: .macos) == "DeveloperID_com.a.provisionprofile")
    }

    @Test("Platform properties")
    func platforms() {
        #expect(MatchPlatform.ios.portalNameSuffix == "")
        #expect(MatchPlatform.tvos.portalNameSuffix == " tvos")
        #expect(MatchPlatform.macos.portalNameSuffix == " macos")
        #expect(MatchPlatform.catalyst.portalNameSuffix == " catalyst")
        #expect(MatchPlatform.macos.profileFilenameSuffix == "")
        #expect(MatchPlatform.tvos.defaultProfileExtension == "mobileprovision")
        #expect(MatchAction.allCases.count == 3)
    }

    @Test("MatchConfig defaults and shallow clone derivation")
    func config() {
        let c = MatchConfig(gitUrl: "u", appIdentifiers: ["a"], password: "p")
        #expect(c.gitBranch == "master")
        #expect(c.type == .appstore)
        #expect(c.platform == .ios)
        #expect(c.action == .sync)
        #expect(c.readonly)
        #expect(c.shallowClone)
        #expect(!c.force && !c.silent && !c.allTypes)
        let c2 = MatchConfig(
            gitUrl: "u", gitBranch: "main", gitToken: "t", type: .development, platform: .macos,
            appIdentifiers: [], password: "p", action: .nuke, readonly: false, allTypes: true,
            teamId: "T", teamName: "N", apiKeyId: "K", apiIssuerId: "I", apiKey: "KEY",
            keychainName: "kc", keychainPassword: "kp", force: true, shallowClone: nil, silent: true
        )
        #expect(!c2.shallowClone)
        #expect(c2.teamName == "N" && c2.apiKey == "KEY" && c2.keychainPassword == "kp")
        let c3 = MatchConfig(gitUrl: "u", appIdentifiers: [], password: "p", readonly: false, shallowClone: true)
        #expect(c3.shallowClone)

        let r = MatchResult()
        #expect(r.installedCertificates.isEmpty && r.installedProfiles.isEmpty && r.envVariables.isEmpty)
        let cert = MatchCertificateInfo(id: "1", name: "n", cerPath: "c", p12Path: "p")
        let profile = MatchProfileInfo(name: "n", uuid: "u", path: "p", bundleId: "b")
        #expect(cert.sha1 == nil && profile.teamId == nil)
    }

    @Test("MatchError descriptions are non-empty and include context")
    func errors() {
        let errors: [MatchError] = [
            .invalidGitUrl("x"), .gitCloneFailed("x"), .gitOperationFailed("x"), .decryptionFailed("x"),
            .encryptionFailed("x"), .certificateNotFound(type: .appstore, expectedDir: "x"),
            .profileNotFound(bundleId: "x", type: .adhoc, expectedPath: "p"),
            .profileCertificateMismatch(bundleId: "x", profileName: "n", certificateId: "c"),
            .profileRevokedOnPortal(bundleId: "x", profileName: "n"), .keychainError("x"),
            .profileParsingFailed("x"), .missingPassword, .portalAuthenticationRequired("x"),
            .keystoreNotFound(packageName: "x", buildType: "release", expectedPath: "p"),
            .missingKeystorePath, .missingKeystoreCredentials("x"),
        ]
        for error in errors {
            let description = error.errorDescription ?? ""
            #expect(!description.isEmpty)
        }
        #expect(MatchError.missingPassword.errorDescription?.contains("MATCH_PASSWORD") == true)
        #expect(MatchError.certificateNotFound(type: .appstore, expectedDir: "d").errorDescription?.contains("appstore") == true)
    }

    @Test("Android config, metadata coding, and signing config")
    func android() throws {
        let c = MatchAndroidConfig(gitUrl: "u", password: "p", packageName: "com.a")
        #expect(c.gitBranch == "master" && c.action == .sync && c.buildType == .release && !c.silent)
        #expect(c.keystorePath == nil && c.alias == nil)
        let c2 = MatchAndroidConfig(
            gitUrl: "u", gitBranch: "b", gitToken: "t", password: "p", action: .add, packageName: "com.a",
            buildType: .debug, keystorePath: "k", alias: "a", storePassword: "s", keyPassword: "kp", silent: true
        )
        #expect(c2.action == .add && c2.buildType == .debug && c2.keyPassword == "kp" && c2.gitToken == "t")

        let meta = AndroidKeystoreMetadata(packageName: "com.a", buildType: "release", alias: "up", storePassword: "s", keyPassword: "k")
        let json = try JSONEncoder().encode(meta)
        let obj = try JSONSerialization.jsonObject(with: json) as? [String: String]
        #expect(obj?["package_name"] == "com.a")
        #expect(obj?["store_password"] == "s")
        #expect(try JSONDecoder().decode(AndroidKeystoreMetadata.self, from: json) == meta)

        let result = MatchAndroidResult(keystorePath: "/k", alias: "up", storePassword: "s", keyPassword: "k")
        #expect(result.tempUrl == nil)
        let signing = result.signingConfig
        #expect(signing.storeFile == "/k" && signing.keyAlias == "up" && signing.storePassword == "s" && signing.keyPassword == "k")
    }
}

// MARK: - Profile parsing

@Suite("ProfileInstaller Parsing Coverage")
struct ProfileInstallerCoverageTests {
    @Test("Reads name, UUID, certificates, and expiry from an embedded plist")
    func parsing() throws {
        let dir = try TestFiles.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cert = Data([0x30, 0x82, 0x01, 0x02, 0x03])
        let other = Data([0x30, 0x82, 0x09, 0x09])
        let path = dir.appendingPathComponent("p.mobileprovision")
        try MatchFixtures.profile(expiration: Date().addingTimeInterval(-60), certs: [other, cert]).write(to: path)
        let installer = ProfileInstaller()
        #expect(installer.profileName(atPath: path.path) == "My Profile")
        #expect(installer.profileUUID(atPath: path.path) == "UUID-1234")
        #expect(installer.profileContainsCertificate(atPath: path.path, certificateData: cert))
        #expect(!installer.profileContainsCertificate(atPath: path.path, certificateData: Data([0x01])))
        #expect(installer.isProfileExpired(atPath: path.path))

        let future = dir.appendingPathComponent("f.mobileprovision")
        try MatchFixtures.profile(name: nil, expiration: Date().addingTimeInterval(3600)).write(to: future)
        #expect(!installer.isProfileExpired(atPath: future.path))
        #expect(installer.profileName(atPath: future.path) == "f.mobileprovision")
        #expect(!installer.profileContainsCertificate(atPath: future.path, certificateData: cert))

        let junk = dir.appendingPathComponent("junk.mobileprovision")
        try Data("no plist here".utf8).write(to: junk)
        #expect(installer.profileUUID(atPath: junk.path) == nil)
        #expect(!installer.isProfileExpired(atPath: junk.path))
        #expect(installer.profileName(atPath: junk.path) == "junk.mobileprovision")
    }

    @Test("installProfile rejects unparseable or UUID-less profiles before touching disk")
    func installFailures() throws {
        let dir = try TestFiles.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let junk = dir.appendingPathComponent("junk.mobileprovision")
        try Data("nothing".utf8).write(to: junk)
        let noUUID = dir.appendingPathComponent("nouuid.mobileprovision")
        try MatchFixtures.profile(uuid: nil).write(to: noUUID)
        let installer = ProfileInstaller()
        #expect(throws: MatchError.self) { try installer.installProfile(from: junk.path, expectedBundleId: "a") }
        #expect(throws: MatchError.self) { try installer.installProfile(from: noUUID.path, expectedBundleId: "a") }
    }
}
