import Foundation
import Testing
@testable import appitool

@Suite("GitStorage Tests")
struct GitStorageTests {
    private static let samplePEM = """
    -----BEGIN OPENSSH PRIVATE KEY-----
    AAAA
    -----END OPENSSH PRIVATE KEY-----
    """

    private static var expectedNormalizedPEM: String {
        samplePEM + "\n"
    }

    @Test("Identifies SSH vs HTTPS and local Git repository URLs")
    func isSSHGitUrlDetection() {
        #expect(GitStorage.isSSHGitUrl("git@github.com:appibara-ltd/fastlane-match.git"))
        #expect(GitStorage.isSSHGitUrl("ssh://git@github.com/org/repo.git"))
        #expect(GitStorage.isSSHGitUrl("deploy@gitlab.com:group/repo.git"))

        #expect(!GitStorage.isSSHGitUrl("https://github.com/appibara-ltd/fastlane-match.git"))
        #expect(!GitStorage.isSSHGitUrl("http://github.com/appibara-ltd/fastlane-match.git"))
        #expect(!GitStorage.isSSHGitUrl("file:///tmp/repo.git"))
        #expect(!GitStorage.isSSHGitUrl("/tmp/repo.git"))
        #expect(!GitStorage.isSSHGitUrl("./repo.git"))
        #expect(!GitStorage.isSSHGitUrl("../repo.git"))
        #expect(!GitStorage.isSSHGitUrl("~/repo.git"))
        #expect(!GitStorage.isSSHGitUrl("   "))
    }

    @Test("Resolves SSH private keys from Base64, PEM, escaped newlines, quotes, and files")
    func resolveSSHPrivateKeyFormats() throws {
        let base64Padded = Data(Self.samplePEM.utf8).base64EncodedString()
        #expect(base64Padded.hasSuffix("="))
        let base64Unpadded = base64Padded.replacingOccurrences(of: "=", with: "")
        let base64Wrapped = "  \(base64Padded.prefix(24))\n\(base64Padded.dropFirst(24))  "

        #expect(GitStorage.resolveSSHPrivateKey(from: base64Padded) == Self.expectedNormalizedPEM)
        #expect(GitStorage.resolveSSHPrivateKey(from: base64Unpadded) == Self.expectedNormalizedPEM)
        #expect(GitStorage.resolveSSHPrivateKey(from: base64Wrapped) == Self.expectedNormalizedPEM)
        #expect(GitStorage.resolveSSHPrivateKey(from: Self.samplePEM) == Self.expectedNormalizedPEM)

        let escapedPEM = "-----BEGIN OPENSSH PRIVATE KEY-----\\nAAAA\\n-----END OPENSSH PRIVATE KEY-----"
        #expect(GitStorage.resolveSSHPrivateKey(from: escapedPEM) == Self.expectedNormalizedPEM)
        #expect(GitStorage.resolveSSHPrivateKey(from: "\"\(escapedPEM)\"") == Self.expectedNormalizedPEM)
        #expect(GitStorage.resolveSSHPrivateKey(from: "'\(Self.samplePEM)'") == Self.expectedNormalizedPEM)

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("GitStorageTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let pemFile = tempDir.appendingPathComponent("deploy_pem.key")
        try Self.samplePEM.write(to: pemFile, atomically: true, encoding: .utf8)
        #expect(GitStorage.resolveSSHPrivateKey(from: pemFile.path) == Self.expectedNormalizedPEM)

        let base64File = tempDir.appendingPathComponent("deploy_b64.key")
        try base64Padded.write(to: base64File, atomically: true, encoding: .utf8)
        #expect(GitStorage.resolveSSHPrivateKey(from: base64File.path) == Self.expectedNormalizedPEM)

        #expect(GitStorage.resolveSSHPrivateKey(from: "ghp_1234567890abcdef") == nil)
        #expect(GitStorage.resolveSSHPrivateKey(from: "github_pat_1234567890") == nil)
        #expect(GitStorage.resolveSSHPrivateKey(from: "") == nil)
        #expect(GitStorage.resolveSSHPrivateKey(from: nil) == nil)
        let randomBase64 = Data("not a private key payload".utf8).base64EncodedString()
        #expect(GitStorage.resolveSSHPrivateKey(from: randomBase64) == nil)
    }

    @Test("Prepares temporary 0600 SSH key outside working directory and cleans it up")
    func sshKeyLifecycleAndEnvironment() throws {
        let base64Key = Data(Self.samplePEM.utf8).base64EncodedString()
        let sshUrl = "git@github.com:appibara-ltd/fastlane-match.git"
        let storage = GitStorage(gitUrl: sshUrl, gitBranch: "master", gitToken: base64Key)
        defer { storage.cleanup() }

        let keyPath = try #require(storage.sshKeyPath)
        #expect(keyPath == "\(storage.workingDirectory).ssh_key")
        #expect(!keyPath.hasPrefix(storage.workingDirectory + "/"))
        #expect(storage.resolveAuthenticatedGitUrl() == sshUrl)

        try storage.prepareSSHKeyIfNeeded()
        #expect(FileManager.default.fileExists(atPath: keyPath))

        let attributes = try FileManager.default.attributesOfItem(atPath: keyPath)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
        #expect(permissions == 0o600)

        let writtenKey = try String(contentsOfFile: keyPath, encoding: .utf8)
        #expect(writtenKey == Self.expectedNormalizedPEM)

        let env = storage.gitEnvironment()
        #expect(env["GIT_TERMINAL_PROMPT"] == "0")
        let sshCommand = try #require(env["GIT_SSH_COMMAND"])
        #expect(sshCommand.contains("-i \(GitStorage.shellSingleQuote(keyPath))"))
        #expect(sshCommand.contains("-o IdentitiesOnly=yes"))
        #expect(sshCommand.contains("-o IdentityAgent=none"))
        #expect(sshCommand.contains("-o BatchMode=yes"))
        #expect(sshCommand.contains("-o StrictHostKeyChecking=accept-new"))

        storage.cleanup()
        #expect(!FileManager.default.fileExists(atPath: keyPath))
    }

    @Test("Keeps PAT HTTPS injection intact and isolates SSH URLs with PAT or HTTPS URLs with SSH keys")
    func tokenAndUrlIsolationAndQuoting() {
        let sshWithPat = GitStorage(
            gitUrl: "git@github.com:appibara-ltd/fastlane-match.git",
            gitToken: "ghp_1234567890"
        )
        #expect(sshWithPat.sshKeyPath == nil)
        #expect(sshWithPat.gitEnvironment()["GIT_TERMINAL_PROMPT"] == "0")
        #expect(sshWithPat.gitEnvironment()["GIT_SSH_COMMAND"] == nil)
        #expect(sshWithPat.resolveAuthenticatedGitUrl() == "git@github.com:appibara-ltd/fastlane-match.git")

        let httpsWithPat = GitStorage(
            gitUrl: "https://github.com/appibara-ltd/fastlane-match.git",
            gitToken: "ghp_1234567890"
        )
        #expect(httpsWithPat.sshKeyPath == nil)
        #expect(httpsWithPat.resolveAuthenticatedGitUrl() == "https://x-access-token:ghp_1234567890@github.com/appibara-ltd/fastlane-match.git")

        let httpsWithSSHKey = GitStorage(
            gitUrl: "https://github.com/appibara-ltd/fastlane-match.git",
            gitToken: Data(Self.samplePEM.utf8).base64EncodedString()
        )
        #expect(httpsWithSSHKey.sshKeyPath == nil)
        #expect(httpsWithSSHKey.resolveAuthenticatedGitUrl() == "https://github.com/appibara-ltd/fastlane-match.git")

        #expect(GitStorage.shellSingleQuote("/tmp/o'hara/key") == "'/tmp/o'\\''hara/key'")
    }
}
