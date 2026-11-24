import Foundation
import GoogleServices

/// Play App Signing certificates of a version code, read from Play-generated APKs.
/// Shared by `google signing-certs` and `firebase sync-fingerprints`.
enum PlaySigningCertificates {
    /// One Play signing key and the certificates read from its smallest generated APK.
    struct Key: Sendable {
        /// SHA-256 of the key's certificate as reported by the API (normalized hex, no colons).
        let apiSha256: String
        /// Certificates from the APK Signing Block (empty when skipped or failed).
        let certificates: [APKSigningCertificate]
        /// Why the certificates could not be read, if they were not.
        let failure: String?
    }

    /// Highest version code on any track of the app; throws a clear error when there is no release yet.
    static func latestVersionCode(packageName: String, service: GooglePlayService) async throws -> Int {
        let latest = try await GetLatestBuildNumberTask().run(.init(target: .android(packageName: packageName, service: service), distribution: .appstore))
        guard let code = Int(latest.buildNumber) else {
            throw CommandError("Could not determine the latest version code (got '\(latest.buildNumber)').", hint: "Pass --version-code.")
        }
        guard code > 0 else {
            throw CommandError(
                "\(packageName) has no releases on any track yet, so Play has no generated APKs to read certificates from.",
                hint: "Upload an app bundle (AAB) first, e.g. to the internal track. Play App Signing certificates exist only after the first upload. If the bundle is uploaded but not in a release, pass its --version-code."
            )
        }
        return code
    }

    /// Reads every signing key of a version code; with `downloadApks`, also the certificates (SHA-1 needs the APK).
    static func fetch(packageName: String, versionCode: Int, service: GooglePlayService, downloadApks: Bool = true) async throws -> [Key] {
        let groups: [GooglePlaySigningKeyApks]
        do {
            groups = try await service.listGeneratedApks(packageName: packageName, versionCode: versionCode)
        } catch let error as GooglePlayImageError {
            throw CommandError("Failed to read generated APKs: \(error.localizedDescription)", hint: hint(for: error))
        }
        guard !groups.isEmpty else {
            throw CommandError(
                "Play has no generated APKs for version code \(versionCode).",
                hint: "Generated APKs exist for app bundles (AAB) uploaded with Play App Signing; check the version code."
            )
        }

        var keys: [Key] = []
        for group in groups {
            let apiSha256 = APKSigningCertificates.normalizeHex(group.certificateSha256Hash)
            guard downloadApks else {
                keys.append(Key(apiSha256: apiSha256, certificates: [], failure: nil))
                continue
            }
            guard let downloadId = group.downloadIds.first else {
                keys.append(Key(apiSha256: apiSha256, certificates: [], failure: "No downloadable APK for this key; SHA-1 unavailable."))
                continue
            }
            do {
                let apk = try await service.downloadGeneratedApk(packageName: packageName, versionCode: versionCode, downloadId: downloadId)
                Log("    (read a \(ByteCountFormatter.string(fromByteCount: Int64(apk.count), countStyle: .file)) Play-generated APK, kept in memory)".dim)
                keys.append(Key(apiSha256: apiSha256, certificates: try APKSigningCertificates.certificates(in: apk), failure: nil))
            } catch let error as GooglePlayImageError {
                let detail = hint(for: error).map { " \($0)" } ?? ""
                keys.append(Key(apiSha256: apiSha256, certificates: [], failure: "APK download failed: \(error.localizedDescription).\(detail)"))
            } catch {
                keys.append(Key(apiSha256: apiSha256, certificates: [], failure: "Could not read the APK signature: \(error.localizedDescription)"))
            }
        }
        return keys
    }

    static func hint(for error: GooglePlayImageError) -> String? {
        guard case .apiError(let status, _) = error else { return nil }
        switch status {
        case 403:
            return "The service account needs release access to the app in Play Console (generated APKs are a release-management feature)."
        case 404:
            return "Check --package-name and --version-code."
        default:
            return nil
        }
    }
}
