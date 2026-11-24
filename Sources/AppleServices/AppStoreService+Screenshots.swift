import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import AppStoreConnectAPI

extension AppStoreService {
    // MARK: - App Store Versions & Localizations

    /// App Store version states that allow creating, uploading, or deleting store screenshots.
    package static let editableVersionStates: Set<String> = [
        "PREPARE_FOR_SUBMISSION",
        "DEVELOPER_REJECTED",
        "REJECTED",
        "WAITING_FOR_REVIEW",
        "INVALID_BINARY",
        "METADATA_REJECTED",
    ]

    /// Fetches App Store versions for the given app ID, optionally filtered by platform and version string.
    package func fetchAppStoreVersions(
        appId: String,
        platform: Components.Schemas.Platform? = nil,
        versionString: String? = nil,
        limit: Int? = nil
    ) async throws -> [Components.Schemas.AppStoreVersion] {
        let cleanAppId = appId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanAppId.isEmpty else {
            throw AppStoreServiceError.invalidResponse("App ID cannot be empty.")
        }

        let platformFilter: [Operations.apps_appStoreVersions_getToManyRelated.Input.Query.filter_lbrack_platform_rbrack_PayloadPayload]?
        if let platform,
           let payload = Operations.apps_appStoreVersions_getToManyRelated.Input.Query.filter_lbrack_platform_rbrack_PayloadPayload(rawValue: platform.rawValue) {
            platformFilter = [payload]
        } else {
            platformFilter = nil
        }

        let cleanVersion = versionString?.trimmingCharacters(in: .whitespacesAndNewlines)
        let versionFilter: [String]? = (cleanVersion?.isEmpty == false) ? [cleanVersion!] : nil

        let pageLimit = min(limit ?? 200, 200)
        let response = try await execute {
            try await client.apps_appStoreVersions_getToManyRelated(
                path: .init(id: cleanAppId),
                query: .init(
                    filter_lbrack_platform_rbrack_: platformFilter,
                    filter_lbrack_versionString_rbrack_: versionFilter,
                    limit: pageLimit
                )
            )
        }

        guard case .ok(let okResp) = response, case .json(let collection) = okResp.body else {
            return []
        }

        return try await paginate(
            initialItems: collection.data,
            initialNext: collection.links.next,
            limit: limit
        ) { (nextPage: Components.Schemas.AppStoreVersionsResponse) in
            (nextPage.data, nextPage.links.next)
        }
    }

    /// Resolves the target App Store version for an app, preferring editable versions when `versionString` is omitted.
    package func resolveAppStoreVersion(
        appId: String,
        platform: Components.Schemas.Platform = .IOS,
        versionString: String? = nil,
        requireEditable: Bool
    ) async throws -> Components.Schemas.AppStoreVersion {
        let cleanVersion = versionString?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let cleanVersion, !cleanVersion.isEmpty {
            let versions = try await fetchAppStoreVersions(
                appId: appId,
                platform: platform,
                versionString: cleanVersion
            )
            if let matched = versions.first(where: { $0.attributes?.versionString == cleanVersion }) {
                return matched
            }
            throw AppStoreServiceError.notFound(
                "App Store version '\(cleanVersion)' for platform '\(platform.rawValue)' was not found."
            )
        }

        let versions = try await fetchAppStoreVersions(appId: appId, platform: platform)
        guard !versions.isEmpty else {
            throw AppStoreServiceError.notFound(
                "No App Store versions found for app ID '\(appId)' on platform '\(platform.rawValue)'."
            )
        }

        if let editable = versions.first(where: { version in
            let state = version.attributes?.appVersionState?.rawValue
                ?? version.attributes?.appStoreState?.rawValue
            return state.map(Self.editableVersionStates.contains) ?? false
        }) {
            return editable
        }

        if requireEditable {
            let available = versions
                .compactMap { v -> String? in
                    guard let ver = v.attributes?.versionString else { return nil }
                    let state = v.attributes?.appVersionState?.rawValue
                        ?? v.attributes?.appStoreState?.rawValue
                        ?? "UNKNOWN"
                    return "\(ver) (\(state))"
                }
                .joined(separator: ", ")
            throw AppStoreServiceError.notFound(
                "No editable App Store version found on platform '\(platform.rawValue)' (available: \(available.isEmpty ? "none" : available)). Create one with 'appitool apple versions create' or specify --app-version."
            )
        }

        return versions[0]
    }

    /// Fetches App Store version localizations for a version ID.
    package func fetchAppStoreVersionLocalizations(
        versionId: String,
        locale: String? = nil
    ) async throws -> [Components.Schemas.AppStoreVersionLocalization] {
        let cleanVersionId = versionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanVersionId.isEmpty else {
            throw AppStoreServiceError.invalidResponse("App Store version ID cannot be empty.")
        }

        let cleanLocale = locale?.trimmingCharacters(in: .whitespacesAndNewlines)
        let localeFilter: [String]? = (cleanLocale?.isEmpty == false) ? [cleanLocale!] : nil

        let response = try await execute {
            try await client.appStoreVersions_appStoreVersionLocalizations_getToManyRelated(
                path: .init(id: cleanVersionId),
                query: .init(
                    filter_lbrack_locale_rbrack_: localeFilter,
                    limit: 200
                )
            )
        }

        guard case .ok(let okResp) = response, case .json(let collection) = okResp.body else {
            return []
        }

        return try await paginate(
            initialItems: collection.data,
            initialNext: collection.links.next,
            limit: nil
        ) { (nextPage: Components.Schemas.AppStoreVersionLocalizationsResponse) in
            (nextPage.data, nextPage.links.next)
        }
    }

    /// Resolves a localization matching `locale` (case-insensitive) for the given App Store version ID.
    package func resolveVersionLocalization(
        versionId: String,
        locale: String
    ) async throws -> Components.Schemas.AppStoreVersionLocalization {
        let trimmedLocale = locale.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLocale.isEmpty else {
            throw AppStoreServiceError.invalidResponse("Locale cannot be empty.")
        }

        let localizations = try await fetchAppStoreVersionLocalizations(versionId: versionId)
        if let matched = localizations.first(where: {
            $0.attributes?.locale?.caseInsensitiveCompare(trimmedLocale) == .orderedSame
        }) {
            return matched
        }

        let available = localizations.compactMap { $0.attributes?.locale }.sorted().joined(separator: ", ")
        throw AppStoreServiceError.notFound(
            "Localization '\(trimmedLocale)' was not found on version ID '\(versionId)' (available locales: \(available.isEmpty ? "none" : available))."
        )
    }

    // MARK: - Image CDN Downloads

    /// Resolves an App Store Connect `ImageAsset` template URL into a concrete full-resolution CDN download URL.
    package static func resolveScreenshotDownloadURL(
        templateUrl: String?,
        width: Int?,
        height: Int?,
        fileName: String?
    ) -> (url: URL, fileExtension: String)? {
        guard let rawTemplate = templateUrl?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawTemplate.isEmpty else {
            return nil
        }

        let cleanName = fileName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let fileExtension = (cleanName.hasSuffix(".jpg") || cleanName.hasSuffix(".jpeg")) ? "jpg" : "png"

        var resolved = rawTemplate
        if resolved.contains("{w}") {
            guard let width, width > 0 else { return nil }
            resolved = resolved.replacingOccurrences(of: "{w}", with: String(width))
        }
        if resolved.contains("{h}") {
            guard let height, height > 0 else { return nil }
            resolved = resolved.replacingOccurrences(of: "{h}", with: String(height))
        }
        if resolved.contains("{f}") {
            resolved = resolved.replacingOccurrences(of: "{f}", with: fileExtension)
        }

        guard !resolved.contains("{w}"),
              !resolved.contains("{h}"),
              !resolved.contains("{f}"),
              let url = URL(string: resolved) else {
            return nil
        }

        return (url, fileExtension)
    }

    /// Downloads raw image bytes from the resolved Apple CDN URL.
    package func downloadScreenshotData(from url: URL) async throws -> (data: Data, contentType: String?) {
        var request = URLRequest(url: url, timeoutInterval: 120)
        request.httpMethod = "GET"

        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AppStoreServiceError.invalidResponse("Invalid HTTP response while downloading image from \(url.absoluteString).")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw AppStoreServiceError.apiError(
                status: httpResponse.statusCode,
                message: "Failed to download image from \(url.absoluteString) (HTTP \(httpResponse.statusCode))."
            )
        }

        return (data, httpResponse.value(forHTTPHeaderField: "Content-Type"))
    }

    // MARK: - Upload Helper

    /// Uploads one `UploadOperation` part of an Asset Library image upload.
    func uploadScreenshotChunk(
        operation: Components.Schemas.UploadOperation,
        index: Int,
        fileData: Data
    ) async throws {
        guard let urlString = operation.url, let url = URL(string: urlString) else {
            throw AppStoreServiceError.invalidResponse("Invalid upload operation URL for chunk #\(index + 1).")
        }

        let offset = operation.offset ?? 0
        let length = operation.length ?? (fileData.count - offset)
        guard offset >= 0, length >= 0, offset + length <= fileData.count else {
            throw AppStoreServiceError.invalidResponse("Upload chunk bounds (offset: \(offset), length: \(length)) exceed file size (\(fileData.count)).")
        }

        let start = fileData.index(fileData.startIndex, offsetBy: offset)
        let end = fileData.index(start, offsetBy: length)
        let chunkData = Data(fileData[start..<end])

        var request = URLRequest(url: url, timeoutInterval: 120)
        request.httpMethod = operation.method ?? "PUT"
        for header in operation.requestHeaders ?? [] {
            if let name = header.name, let value = header.value {
                request.setValue(value, forHTTPHeaderField: name)
            }
        }

        let maxAttempts = 3
        var lastError: Error?
        for attempt in 1...maxAttempts {
            do {
                let (_, response) = try await urlSession.upload(for: request, from: chunkData)
                if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                    return
                }
                let code = (response as? HTTPURLResponse)?.statusCode
                lastError = AppStoreServiceError.apiError(
                    status: code,
                    message: "Image chunk #\(index + 1) upload failed."
                )
            } catch {
                lastError = error
            }

            if attempt < maxAttempts {
                try await _Concurrency.Task.sleep(nanoseconds: UInt64(attempt) * 200_000_000)
            }
        }

        throw lastError ?? AppStoreServiceError.invalidResponse("Image chunk #\(index + 1) upload failed.")
    }
}
