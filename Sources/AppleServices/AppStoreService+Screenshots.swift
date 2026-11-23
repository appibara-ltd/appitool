import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Crypto
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
                "No editable App Store version found on platform '\(platform.rawValue)' (available: \(available.isEmpty ? "none" : available)). Create a new version in App Store Connect or specify --app-version."
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

    // MARK: - Screenshot Sets & Screenshots

    /// Fetches screenshot sets under a version localization, optionally filtered by display type.
    package func fetchScreenshotSets(
        localizationId: String,
        displayType: Components.Schemas.ScreenshotDisplayType? = nil
    ) async throws -> [Components.Schemas.AppScreenshotSet] {
        let cleanId = localizationId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanId.isEmpty else {
            throw AppStoreServiceError.invalidResponse("Version localization ID cannot be empty.")
        }

        let typeFilter: [Operations.appStoreVersionLocalizations_appScreenshotSets_getToManyRelated.Input.Query.filter_lbrack_screenshotDisplayType_rbrack_PayloadPayload]?
        if let displayType,
           let payload = Operations.appStoreVersionLocalizations_appScreenshotSets_getToManyRelated.Input.Query.filter_lbrack_screenshotDisplayType_rbrack_PayloadPayload(rawValue: displayType.rawValue) {
            typeFilter = [payload]
        } else {
            typeFilter = nil
        }

        let response = try await execute {
            try await client.appStoreVersionLocalizations_appScreenshotSets_getToManyRelated(
                path: .init(id: cleanId),
                query: .init(
                    filter_lbrack_screenshotDisplayType_rbrack_: typeFilter,
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
        ) { (nextPage: Components.Schemas.AppScreenshotSetsResponse) in
            (nextPage.data, nextPage.links.next)
        }
    }

    /// Creates a new screenshot set for the given localization and display type.
    package func createScreenshotSet(
        localizationId: String,
        displayType: Components.Schemas.ScreenshotDisplayType
    ) async throws -> Components.Schemas.AppScreenshotSet {
        let payload = Components.Schemas.AppScreenshotSetCreateRequest(
            data: .init(
                _type: .appScreenshotSets,
                attributes: .init(screenshotDisplayType: displayType),
                relationships: .init(
                    appStoreVersionLocalization: .init(
                        data: .init(_type: .appStoreVersionLocalizations, id: localizationId)
                    )
                )
            )
        )

        let response = try await execute {
            try await client.appScreenshotSets_createInstance(body: .json(payload))
        }
        guard case .created(let createdResp) = response, case .json(let instance) = createdResp.body else {
            throw AppStoreServiceError.invalidResponse("Unexpected response when creating screenshot set.")
        }
        return instance.data
    }

    /// Returns the existing screenshot set for `displayType` under `localizationId`, or creates one if missing.
    package func findOrCreateScreenshotSet(
        localizationId: String,
        displayType: Components.Schemas.ScreenshotDisplayType
    ) async throws -> Components.Schemas.AppScreenshotSet {
        let existing = try await fetchScreenshotSets(localizationId: localizationId, displayType: displayType)
        if let match = existing.first(where: { $0.attributes?.screenshotDisplayType == displayType }) {
            return match
        }
        return try await createScreenshotSet(localizationId: localizationId, displayType: displayType)
    }

    /// Lists screenshots belonging to a screenshot set.
    package func fetchScreenshots(screenshotSetId: String) async throws -> [Components.Schemas.AppScreenshot] {
        let cleanId = screenshotSetId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanId.isEmpty else {
            throw AppStoreServiceError.invalidResponse("Screenshot set ID cannot be empty.")
        }

        let response = try await execute {
            try await client.appScreenshotSets_appScreenshots_getToManyRelated(
                path: .init(id: cleanId),
                query: .init(limit: 200)
            )
        }

        guard case .ok(let okResp) = response, case .json(let collection) = okResp.body else {
            return []
        }

        return try await paginate(
            initialItems: collection.data,
            initialNext: collection.links.next,
            limit: nil
        ) { (nextPage: Components.Schemas.AppScreenshotsResponse) in
            (nextPage.data, nextPage.links.next)
        }
    }

    /// Fetches a single App Store screenshot resource by ID.
    package func fetchScreenshot(id: String) async throws -> Components.Schemas.AppScreenshot {
        let cleanId = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanId.isEmpty else {
            throw AppStoreServiceError.invalidResponse("Screenshot ID cannot be empty.")
        }

        let response = try await execute {
            try await client.appScreenshots_getInstance(path: .init(id: cleanId))
        }
        guard case .ok(let okResp) = response, case .json(let instance) = okResp.body else {
            throw AppStoreServiceError.invalidResponse("Unexpected response when fetching screenshot '\(cleanId)'.")
        }
        return instance.data
    }

    /// Uploads a local image file to an App Store Connect screenshot set using reserve -> upload -> commit -> poll.
    package func uploadScreenshot(
        screenshotSetId: String,
        fileUrl: URL,
        waitForProcessing: Bool = true,
        pollInterval: TimeInterval = 2,
        processingTimeout: TimeInterval = 60
    ) async throws -> Components.Schemas.AppScreenshot {
        let cleanSetId = screenshotSetId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanSetId.isEmpty else {
            throw AppStoreServiceError.invalidResponse("Screenshot set ID cannot be empty.")
        }

        let fileData = try Data(contentsOf: fileUrl)
        guard !fileData.isEmpty else {
            throw AppStoreServiceError.invalidResponse("Screenshot file is empty (0 bytes): \(fileUrl.path)")
        }

        let md5Hex = Insecure.MD5.hash(data: fileData).map { String(format: "%02x", $0) }.joined()

        // 1. Reserve screenshot asset slot
        let createPayload = Components.Schemas.AppScreenshotCreateRequest(
            data: .init(
                _type: .appScreenshots,
                attributes: .init(fileSize: fileData.count, fileName: fileUrl.lastPathComponent),
                relationships: .init(
                    appScreenshotSet: .init(
                        data: .init(_type: .appScreenshotSets, id: cleanSetId)
                    )
                )
            )
        )

        let createResponse = try await execute {
            try await client.appScreenshots_createInstance(body: .json(createPayload))
        }
        guard case .created(let createdResp) = createResponse,
              case .json(let reservation) = createdResp.body else {
            throw AppStoreServiceError.invalidResponse("Unexpected response when reserving screenshot upload.")
        }

        let screenshotId = reservation.data.id
        let operations = reservation.data.attributes?.uploadOperations ?? []
        guard !operations.isEmpty else {
            throw AppStoreServiceError.invalidResponse("App Store Connect returned no upload operations for '\(fileUrl.lastPathComponent)'.")
        }

        // 2. Upload binary chunk(s) to Apple storage
        for (index, op) in operations.enumerated() {
            try await uploadScreenshotChunk(operation: op, index: index, fileData: fileData)
        }

        // 3. Commit uploaded file with MD5 checksum
        let updatePayload = Components.Schemas.AppScreenshotUpdateRequest(
            data: .init(
                _type: .appScreenshots,
                id: screenshotId,
                attributes: .init(sourceFileChecksum: md5Hex, uploaded: true)
            )
        )

        let updateResponse = try await execute {
            try await client.appScreenshots_updateInstance(
                path: .init(id: screenshotId),
                body: .json(updatePayload)
            )
        }
        guard case .ok(let okUpdate) = updateResponse, case .json(let updated) = okUpdate.body else {
            throw AppStoreServiceError.invalidResponse("Unexpected response when committing screenshot '\(screenshotId)'.")
        }

        var latest = updated.data

        func describeStateErrors(_ state: Components.Schemas.AppMediaAssetState?) -> String {
            let messages = (state?.errors ?? []).map { err in
                [err.code, err.description].compactMap { $0 }.joined(separator: ": ")
            }.filter { !$0.isEmpty }
            return messages.isEmpty ? "Asset processing failed without error details." : messages.joined(separator: "; ")
        }

        if latest.attributes?.assetDeliveryState?.state == .FAILED {
            throw AppStoreServiceError.apiError(status: nil, message: describeStateErrors(latest.attributes?.assetDeliveryState))
        }

        guard waitForProcessing else {
            return latest
        }

        // 4. Poll until COMPLETE or FAILED (or already COMPLETE)
        let deadline = Date().addingTimeInterval(processingTimeout)
        while latest.attributes?.assetDeliveryState?.state != .COMPLETE {
            if latest.attributes?.assetDeliveryState?.state == .FAILED {
                throw AppStoreServiceError.apiError(status: nil, message: describeStateErrors(latest.attributes?.assetDeliveryState))
            }
            guard Date() < deadline else {
                throw AppStoreServiceError.invalidResponse("Timed out waiting for App Store Connect to process screenshot '\(screenshotId)'.")
            }
            if pollInterval > 0 {
                try await _Concurrency.Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
            }
            latest = try await fetchScreenshot(id: screenshotId)
            if latest.attributes?.assetDeliveryState?.state == .FAILED {
                throw AppStoreServiceError.apiError(status: nil, message: describeStateErrors(latest.attributes?.assetDeliveryState))
            }
        }

        return latest
    }

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

    /// Downloads raw screenshot image bytes from the resolved Apple CDN URL.
    package func downloadScreenshotData(from url: URL) async throws -> (data: Data, contentType: String?) {
        var request = URLRequest(url: url, timeoutInterval: 120)
        request.httpMethod = "GET"

        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AppStoreServiceError.invalidResponse("Invalid HTTP response while downloading screenshot from \(url.absoluteString).")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw AppStoreServiceError.apiError(
                status: httpResponse.statusCode,
                message: "Failed to download screenshot from \(url.absoluteString) (HTTP \(httpResponse.statusCode))."
            )
        }

        return (data, httpResponse.value(forHTTPHeaderField: "Content-Type"))
    }

    /// Deletes an App Store Connect screenshot by resource ID.
    @discardableResult
    package func deleteScreenshot(id: String) async throws -> Bool {
        let cleanId = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanId.isEmpty else {
            throw AppStoreServiceError.invalidResponse("Screenshot ID cannot be empty.")
        }

        let response = try await execute {
            try await client.appScreenshots_deleteInstance(path: .init(id: cleanId))
        }
        switch response {
        case .noContent:
            return true
        case .notFound:
            return false
        default:
            return false
        }
    }

    // MARK: - Private Upload Helper

    private func uploadScreenshotChunk(
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
                    message: "Screenshot chunk #\(index + 1) upload failed."
                )
            } catch {
                lastError = error
            }

            if attempt < maxAttempts {
                try await _Concurrency.Task.sleep(nanoseconds: UInt64(attempt) * 200_000_000)
            }
        }

        throw lastError ?? AppStoreServiceError.invalidResponse("Screenshot chunk #\(index + 1) upload failed.")
    }
}
