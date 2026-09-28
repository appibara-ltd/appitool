import Foundation
import Crypto

/// Parses and installs iOS and macOS provisioning profiles into Xcode's local provisioning profile repository.
public final class ProfileInstaller: Sendable {
    public init() {}

    /// Installs a provisioning profile from `sourcePath` into `~/Library/Developer/Xcode/UserData/Provisioning Profiles/`.
    public func installProfile(from sourcePath: String, expectedBundleId: String) throws -> MatchProfileInfo {
        guard let plist = parseProfilePlist(atPath: sourcePath) else {
            throw MatchError.profileParsingFailed("Failed to parse embedded plist in '\(sourcePath)'.")
        }

        guard let uuid = plist["UUID"] as? String, !uuid.isEmpty else {
            throw MatchError.profileParsingFailed("Missing UUID in provisioning profile '\(sourcePath)'.")
        }

        let name = (plist["Name"] as? String) ?? "Match Profile"
        let teamIds = plist["TeamIdentifier"] as? [String]
        let teamId = teamIds?.first

        // Destination directory (Xcode 16+):
        // ~/Library/Developer/Xcode/UserData/Provisioning Profiles/
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let profileDir = URL(fileURLWithPath: home)
            .appendingPathComponent("Library")
            .appendingPathComponent("Developer")
            .appendingPathComponent("Xcode")
            .appendingPathComponent("UserData")
            .appendingPathComponent("Provisioning Profiles")

        let fm = FileManager.default
        try fm.createDirectory(at: profileDir, withIntermediateDirectories: true)

        let ext = (sourcePath as NSString).pathExtension.isEmpty ? "mobileprovision" : (sourcePath as NSString).pathExtension
        let destinationUrl = profileDir.appendingPathComponent("\(uuid).\(ext)")

        if fm.fileExists(atPath: destinationUrl.path) {
            try? fm.removeItem(at: destinationUrl)
        }
        try fm.copyItem(at: URL(fileURLWithPath: sourcePath), to: destinationUrl)

        return MatchProfileInfo(
            name: name,
            uuid: uuid,
            path: destinationUrl.path,
            bundleId: expectedBundleId,
            teamId: teamId
        )
    }

    /// Reads the display name of a provisioning profile.
    public func profileName(atPath path: String) -> String {
        guard let plist = parseProfilePlist(atPath: path),
              let name = plist["Name"] as? String else {
            return (path as NSString).lastPathComponent
        }
        return name
    }

    /// Reads the UUID of a provisioning profile.
    public func profileUUID(atPath path: String) -> String? {
        guard let plist = parseProfilePlist(atPath: path) else { return nil }
        return plist["UUID"] as? String
    }

    /// Checks whether the provisioning profile at `path` contains the specified certificate.
    public func profileContainsCertificate(atPath path: String, certificateData: Data) -> Bool {
        guard let plist = parseProfilePlist(atPath: path),
              let devCerts = plist["DeveloperCertificates"] as? [Data] else {
            return false
        }

        let targetSha1 = Insecure.SHA1.hash(data: certificateData)
        for devCert in devCerts {
            if devCert == certificateData || Insecure.SHA1.hash(data: devCert) == targetSha1 {
                return true
            }
        }
        return false
    }

    /// Checks whether the provisioning profile at `path` is expired.
    public func isProfileExpired(atPath path: String) -> Bool {
        guard let plist = parseProfilePlist(atPath: path),
              let expirationDate = plist["ExpirationDate"] as? Date else {
            return false
        }
        return expirationDate < Date()
    }

    // MARK: - Private Helpers

    private func parseProfilePlist(atPath path: String) -> [String: Any]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let plistString = extractPlistString(from: data),
              let plistData = plistString.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any] else {
            return nil
        }
        return plist
    }

    private func extractPlistString(from data: Data) -> String? {
        guard let fullString = String(data: data, encoding: .isoLatin1) else { return nil }

        let startTag = "<?xml"
        let endTag = "</plist>"

        guard let startRange = fullString.range(of: startTag),
              let endRange = fullString.range(of: endTag, options: .backwards, range: startRange.lowerBound..<fullString.endIndex) else {
            return nil
        }

        // Half-open range from the beginning of <?xml up to the end of </plist>
        return String(fullString[startRange.lowerBound..<endRange.upperBound])
    }
}
