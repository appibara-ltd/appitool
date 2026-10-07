import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import GooglePlayStoreAPI
import OpenAPIRuntime

/// Result of an Android App Bundle (.aab) upload.
package struct GooglePlayBundleUploadResult: Sendable {
    package let versionCode: Int64
    package let sha1: String?
    package let sha256: String?

    package init(versionCode: Int64, sha1: String? = nil, sha256: String? = nil) {
        self.versionCode = versionCode
        self.sha1 = sha1
        self.sha256 = sha256
    }
}

/// Result of an APK (.apk) upload.
package struct GooglePlayApkUploadResult: Sendable {
    package let versionCode: Int64
    package let sha1: String?
    package let sha256: String?

    package init(versionCode: Int64, sha1: String? = nil, sha256: String? = nil) {
        self.versionCode = versionCode
        self.sha1 = sha1
        self.sha256 = sha256
    }
}

extension GooglePlayService {
    // MARK: - Edit Management

    /// Creates a new edit session for an application in Google Play Developer Console.
    package func createEdit(packageName: String) async throws -> String {
        let response = try await client.androidpublisher_period_edits_period_insert(.init(
            path: .init(packageName: packageName),
            body: .json(.init())
        ))

        guard case .ok(let ok) = response,
              case .json(let appEdit) = ok.body,
              let editId = appEdit.id else {
            throw NSError(
                domain: "GooglePlayService",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to create Google Play edit session for package: \(packageName)"]
            )
        }
        return editId
    }

    /// Deletes an active edit session.
    package func deleteEdit(packageName: String, editId: String) async throws {
        _ = try await client.androidpublisher_period_edits_period_delete(.init(
            path: .init(packageName: packageName, editId: editId)
        ))
    }

    // MARK: - Binary Uploads

    /// Uploads an Android App Bundle (.aab) to an active edit session.
    package func uploadBundle(
        packageName: String,
        editId: String,
        fileUrl: URL,
        ackBundleInstallationWarning: Bool = false
    ) async throws -> GooglePlayBundleUploadResult {
        let token = try await getAccessToken()
        var urlString = "https://androidpublisher.googleapis.com/upload/androidpublisher/v3/applications/\(packageName)/edits/\(editId)/bundles?uploadType=media"
        if ackBundleInstallationWarning {
            urlString += "&ackBundleInstallationWarning=true"
        }

        guard let uploadUrl = URL(string: urlString) else {
            throw NSError(
                domain: "GooglePlayService",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Invalid bundle upload URL: \(urlString)"]
            )
        }

        var request = URLRequest(url: uploadUrl, timeoutInterval: 300)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await URLSession.shared.upload(for: request, fromFile: fileUrl)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(
                domain: "GooglePlayService",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Invalid response received during bundle upload."]
            )
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let errorMsg = Self.parseErrorMessage(from: data) ?? "HTTP \(httpResponse.statusCode)"
            throw NSError(
                domain: "GooglePlayService",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "Bundle upload failed (HTTP \(httpResponse.statusCode)): \(errorMsg)"]
            )
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(
                domain: "GooglePlayService",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Failed to parse JSON response from bundle upload."]
            )
        }

        let versionCode: Int64
        if let vc = json["versionCode"] as? Int64 {
            versionCode = vc
        } else if let vc = json["versionCode"] as? Int {
            versionCode = Int64(vc)
        } else if let vcStr = json["versionCode"] as? String, let vc = Int64(vcStr) {
            versionCode = vc
        } else {
            throw NSError(
                domain: "GooglePlayService",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "Bundle upload response missing versionCode."]
            )
        }

        let sha1 = json["sha1"] as? String
        let sha256 = json["sha256"] as? String

        return GooglePlayBundleUploadResult(versionCode: versionCode, sha1: sha1, sha256: sha256)
    }

    /// Uploads an APK (.apk) to an active edit session.
    package func uploadApk(
        packageName: String,
        editId: String,
        fileUrl: URL
    ) async throws -> GooglePlayApkUploadResult {
        let token = try await getAccessToken()
        let urlString = "https://androidpublisher.googleapis.com/upload/androidpublisher/v3/applications/\(packageName)/edits/\(editId)/apks?uploadType=media"

        guard let uploadUrl = URL(string: urlString) else {
            throw NSError(
                domain: "GooglePlayService",
                code: 6,
                userInfo: [NSLocalizedDescriptionKey: "Invalid APK upload URL: \(urlString)"]
            )
        }

        var request = URLRequest(url: uploadUrl, timeoutInterval: 300)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.android.package-archive", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await URLSession.shared.upload(for: request, fromFile: fileUrl)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(
                domain: "GooglePlayService",
                code: 7,
                userInfo: [NSLocalizedDescriptionKey: "Invalid response received during APK upload."]
            )
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let errorMsg = Self.parseErrorMessage(from: data) ?? "HTTP \(httpResponse.statusCode)"
            throw NSError(
                domain: "GooglePlayService",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "APK upload failed (HTTP \(httpResponse.statusCode)): \(errorMsg)"]
            )
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(
                domain: "GooglePlayService",
                code: 8,
                userInfo: [NSLocalizedDescriptionKey: "Failed to parse JSON response from APK upload."]
            )
        }

        let versionCode: Int64
        if let vc = json["versionCode"] as? Int64 {
            versionCode = vc
        } else if let vc = json["versionCode"] as? Int {
            versionCode = Int64(vc)
        } else if let vcStr = json["versionCode"] as? String, let vc = Int64(vcStr) {
            versionCode = vc
        } else {
            throw NSError(
                domain: "GooglePlayService",
                code: 9,
                userInfo: [NSLocalizedDescriptionKey: "APK upload response missing versionCode."]
            )
        }

        let binaryDict = json["binary"] as? [String: Any]
        let sha1 = binaryDict?["sha1"] as? String ?? json["sha1"] as? String
        let sha256 = binaryDict?["sha256"] as? String ?? json["sha256"] as? String

        return GooglePlayApkUploadResult(versionCode: versionCode, sha1: sha1, sha256: sha256)
    }

    // MARK: - Tracks & Commits

    /// Updates track configuration with new releases.
    package func updateTrack(
        packageName: String,
        editId: String,
        track: String,
        releases: [Components.Schemas.TrackRelease]
    ) async throws -> Components.Schemas.Track {
        let response = try await client.androidpublisher_period_edits_period_tracks_period_update(
            path: .init(packageName: packageName, editId: editId, track: track),
            body: .json(.init(releases: releases, track: track))
        )

        guard case .ok(let ok) = response, case .json(let updatedTrack) = ok.body else {
            throw NSError(
                domain: "GooglePlayService",
                code: 10,
                userInfo: [NSLocalizedDescriptionKey: "Failed to update track '\(track)' for package: \(packageName)"]
            )
        }
        return updatedTrack
    }

    /// Commits all changes in the edit session.
    package func commitEdit(
        packageName: String,
        editId: String,
        changesNotSentForReview: Bool? = nil
    ) async throws -> Components.Schemas.AppEdit {
        let response = try await client.androidpublisher_period_edits_period_commit(
            path: .init(packageName: packageName, editId: editId),
            query: .init(changesNotSentForReview: changesNotSentForReview)
        )

        guard case .ok(let ok) = response, case .json(let appEdit) = ok.body else {
            throw NSError(
                domain: "GooglePlayService",
                code: 11,
                userInfo: [NSLocalizedDescriptionKey: "Failed to commit edit session '\(editId)' for package: \(packageName)"]
            )
        }
        return appEdit
    }

    /// Validates an edit session without committing changes.
    package func validateEdit(
        packageName: String,
        editId: String
    ) async throws -> Components.Schemas.AppEdit {
        let response = try await client.androidpublisher_period_edits_period_validate(
            path: .init(packageName: packageName, editId: editId)
        )

        guard case .ok(let ok) = response, case .json(let appEdit) = ok.body else {
            throw NSError(
                domain: "GooglePlayService",
                code: 12,
                userInfo: [NSLocalizedDescriptionKey: "Failed to validate edit session '\(editId)' for package: \(packageName)"]
            )
        }
        return appEdit
    }

    // MARK: - Private Helpers

    private static func parseErrorMessage(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return String(data: data, encoding: .utf8)
        }
        if let err = json["error"] as? [String: Any], let msg = err["message"] as? String {
            return msg
        }
        if let msg = json["message"] as? String {
            return msg
        }
        return String(data: data, encoding: .utf8)
    }
}
