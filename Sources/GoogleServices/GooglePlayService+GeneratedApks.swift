import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The APKs Play generated for one signing key of a version code (`GeneratedApksPerSigningKey`).
package struct GooglePlaySigningKeyApks: Sendable, Equatable {
    /// SHA-256 of the signing certificate, as returned by the API (hex).
    package let certificateSha256Hash: String
    /// Download IDs of APKs signed by this key, smallest candidate first (config splits, other splits, standalone, universal).
    package let downloadIds: [String]
}

extension GooglePlayService {
    // MARK: - Generated APKs (Play App Signing)

    private static let generatedApksBase = "https://androidpublisher.googleapis.com/androidpublisher/v3/applications"

    /// Lists Play-generated APKs of a version code grouped by signing key
    /// (`GET applications/{package}/generatedApks/{versionCode}`).
    package func listGeneratedApks(packageName: String, versionCode: Int) async throws -> [GooglePlaySigningKeyApks] {
        let url = "\(Self.generatedApksBase)/\(Self.encodePathSegment(packageName))/generatedApks/\(versionCode)"
        let data = try await generatedApksGet(url)
        return try Self.parseGeneratedApks(data)
    }

    /// Parses a `generatedApks` list response. Download IDs are ordered smallest-first: config splits (language /
    /// density / ABI APKs, usually a few KB), other splits, standalone APKs, then the universal APK. Every APK of a
    /// signing key carries the same signature block, so the first one is enough to read the certificates.
    package static func parseGeneratedApks(_ data: Data) throws -> [GooglePlaySigningKeyApks] {
        struct Download: Decodable {
            let downloadId: String?
            let splitId: String?
        }
        struct Group: Decodable {
            let certificateSha256Hash: String?
            let generatedUniversalApk: Download?
            let generatedStandaloneApks: [Download]?
            let generatedSplitApks: [Download]?
        }
        struct Response: Decodable { let generatedApks: [Group]? }

        let groups = try JSONDecoder().decode(Response.self, from: data).generatedApks ?? []
        return groups.map { group in
            let splits = group.generatedSplitApks ?? []
            let configSplits = splits.filter { !($0.splitId ?? "").isEmpty }
            let otherSplits = splits.filter { ($0.splitId ?? "").isEmpty }
            let ids = configSplits.map(\.downloadId)
                + otherSplits.map(\.downloadId)
                + (group.generatedStandaloneApks ?? []).map(\.downloadId)
                + [group.generatedUniversalApk?.downloadId]
            return GooglePlaySigningKeyApks(
                certificateSha256Hash: group.certificateSha256Hash ?? "",
                downloadIds: ids.compactMap { $0 }.filter { !$0.isEmpty }
            )
        }
    }

    /// Downloads one Play-generated APK (`…/downloads/{downloadId}:download?alt=media`).
    package func downloadGeneratedApk(packageName: String, versionCode: Int, downloadId: String) async throws -> Data {
        let url = "\(Self.generatedApksBase)/\(Self.encodePathSegment(packageName))/generatedApks/\(versionCode)/downloads/\(Self.encodePathSegment(downloadId)):download?alt=media"
        return try await generatedApksGet(url, timeout: 300)
    }

    private func generatedApksGet(_ urlString: String, timeout: TimeInterval = 60) async throws -> Data {
        guard let url = URL(string: urlString) else {
            throw GooglePlayImageError.invalidResponse("Invalid generated APKs URL: \(urlString)")
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.setValue("Bearer \(try await getAccessToken())", forHTTPHeaderField: "Authorization")
        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GooglePlayImageError.invalidResponse("Invalid HTTP response from \(url.path)")
        }
        guard (200...299).contains(http.statusCode) else {
            let message = Self.parseGoogleErrorMessage(from: data) ?? "HTTP \(http.statusCode)"
            throw GooglePlayImageError.apiError(status: http.statusCode, message: message)
        }
        return data
    }
}
