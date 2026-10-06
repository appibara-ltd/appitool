import Foundation
import AppStoreConnectAPI

/// Target platform of a build upload.
package enum BuildUploadPlatform: String, Sendable {
    case ios = "IOS"
    case macOS = "MAC_OS"
    case tvOS = "TV_OS"
    case visionOS = "VISION_OS"
}

/// A single HTTP operation (typically one chunk PUT) returned by App Store Connect for uploading a file.
package struct BuildUploadOperation: Sendable {
    package let method: String
    package let url: String
    package let offset: Int64
    package let length: Int64
    package let headers: [(name: String, value: String)]
}

/// A reserved build upload file together with the operations required to upload its content.
package struct BuildUploadFileReservation: Sendable {
    package let id: String
    package let operations: [BuildUploadOperation]
}

/// Processing state of a build upload.
package struct BuildUploadStatus: Sendable {
    package enum State: String, Sendable {
        case awaitingUpload = "AWAITING_UPLOAD"
        case processing = "PROCESSING"
        case failed = "FAILED"
        case complete = "COMPLETE"
        case unknown = "UNKNOWN"
    }

    package let id: String
    package let state: State
    package let errors: [String]
    package let warnings: [String]
    /// The resulting build resource ID, available once processing completed.
    package let buildId: String?
}

extension AppStoreService {
    // MARK: - Build Upload Operations

    /// Creates a build upload for the given app and version/build number pair. Returns the build upload ID.
    package func createBuildUpload(
        appId: String,
        version: String,
        buildNumber: String,
        platform: BuildUploadPlatform = .ios
    ) async throws -> String {
        let payload = Components.Schemas.BuildUploadCreateRequest(
            data: .init(
                _type: .buildUploads,
                attributes: .init(
                    cfBundleShortVersionString: version,
                    cfBundleVersion: buildNumber,
                    platform: .init(rawValue: platform.rawValue)!
                ),
                relationships: .init(
                    app: .init(data: .init(_type: .apps, id: appId))
                )
            )
        )

        let response = try await client.buildUploads_createInstance(body: .json(payload))
        switch response {
        case .created(let created):
            guard case .json(let instance) = created.body else {
                throw AppStoreServiceError.invalidResponse("App Store Connect returned invalid build upload body.")
            }
            return instance.data.id
        case .badRequest(let r):
            throw AppStoreServiceError.apiError(status: 400, message: formatAppleErrors(try? r.body.json.errors))
        case .unauthorized(let r):
            throw AppStoreServiceError.apiError(status: 401, message: formatAppleErrors(try? r.body.json.errors))
        case .forbidden(let r):
            throw AppStoreServiceError.apiError(status: 403, message: formatAppleErrors(try? r.body.json.errors))
        case .conflict(let r):
            throw AppStoreServiceError.apiError(status: 409, message: formatAppleErrors(try? r.body.json.errors))
        case .unprocessableContent(let r):
            throw AppStoreServiceError.apiError(status: 422, message: formatAppleErrors(try? r.body.json.errors))
        case .tooManyRequests(let r):
            throw AppStoreServiceError.apiError(status: 429, message: formatAppleErrors(try? r.body.json.errors))
        case .undocumented(let statusCode, _):
            throw AppStoreServiceError.apiError(status: statusCode, message: "Unexpected status code")
        }
    }

    /// Reserves an `.ipa` file slot on the given build upload and returns the upload operations to perform.
    package func createBuildUploadFile(
        buildUploadId: String,
        fileName: String,
        fileSize: Int64
    ) async throws -> BuildUploadFileReservation {
        let payload = Components.Schemas.BuildUploadFileCreateRequest(
            data: .init(
                _type: .buildUploadFiles,
                attributes: .init(
                    assetType: .init(rawValue: "ASSET")!,
                    fileName: fileName,
                    fileSize: fileSize,
                    uti: .init(rawValue: "com.apple.ipa")!
                ),
                relationships: .init(
                    buildUpload: .init(data: .init(_type: .buildUploads, id: buildUploadId))
                )
            )
        )

        let response = try await client.buildUploadFiles_createInstance(body: .json(payload))
        switch response {
        case .created(let created):
            guard case .json(let instance) = created.body else {
                throw AppStoreServiceError.invalidResponse("App Store Connect returned invalid build upload file body.")
            }
            let operations = (instance.data.attributes?.uploadOperations ?? []).compactMap { op -> BuildUploadOperation? in
                guard let method = op.method, let url = op.url, let length = op.length else { return nil }
                return BuildUploadOperation(
                    method: method,
                    url: url,
                    offset: op.offset ?? 0,
                    length: length,
                    headers: (op.requestHeaders ?? []).compactMap { header in
                        guard let name = header.name, let value = header.value else { return nil }
                        return (name, value)
                    }
                )
            }
            guard !operations.isEmpty else {
                throw AppStoreServiceError.invalidResponse("App Store Connect returned no upload operations.")
            }
            return BuildUploadFileReservation(id: instance.data.id, operations: operations)
        case .badRequest(let r):
            throw AppStoreServiceError.apiError(status: 400, message: formatAppleErrors(try? r.body.json.errors))
        case .unauthorized(let r):
            throw AppStoreServiceError.apiError(status: 401, message: formatAppleErrors(try? r.body.json.errors))
        case .forbidden(let r):
            throw AppStoreServiceError.apiError(status: 403, message: formatAppleErrors(try? r.body.json.errors))
        case .conflict(let r):
            throw AppStoreServiceError.apiError(status: 409, message: formatAppleErrors(try? r.body.json.errors))
        case .unprocessableContent(let r):
            throw AppStoreServiceError.apiError(status: 422, message: formatAppleErrors(try? r.body.json.errors))
        case .tooManyRequests(let r):
            throw AppStoreServiceError.apiError(status: 429, message: formatAppleErrors(try? r.body.json.errors))
        case .undocumented(let statusCode, _):
            throw AppStoreServiceError.apiError(status: statusCode, message: "Unexpected status code")
        }
    }

    /// Marks the build upload file as fully uploaded so App Store Connect starts processing it.
    package func commitBuildUploadFile(id: String) async throws {
        let payload = Components.Schemas.BuildUploadFileUpdateRequest(
            data: .init(
                _type: .buildUploadFiles,
                id: id,
                attributes: .init(uploaded: true)
            )
        )

        let response = try await client.buildUploadFiles_updateInstance(path: .init(id: id), body: .json(payload))
        switch response {
        case .ok:
            return
        case .badRequest(let r):
            throw AppStoreServiceError.apiError(status: 400, message: formatAppleErrors(try? r.body.json.errors))
        case .unauthorized(let r):
            throw AppStoreServiceError.apiError(status: 401, message: formatAppleErrors(try? r.body.json.errors))
        case .forbidden(let r):
            throw AppStoreServiceError.apiError(status: 403, message: formatAppleErrors(try? r.body.json.errors))
        case .notFound(let r):
            throw AppStoreServiceError.apiError(status: 404, message: formatAppleErrors(try? r.body.json.errors))
        case .conflict(let r):
            throw AppStoreServiceError.apiError(status: 409, message: formatAppleErrors(try? r.body.json.errors))
        case .unprocessableContent(let r):
            throw AppStoreServiceError.apiError(status: 422, message: formatAppleErrors(try? r.body.json.errors))
        case .tooManyRequests(let r):
            throw AppStoreServiceError.apiError(status: 429, message: formatAppleErrors(try? r.body.json.errors))
        case .undocumented(let statusCode, _):
            throw AppStoreServiceError.apiError(status: statusCode, message: "Unexpected status code")
        }
    }

    /// Fetches the current processing state of a build upload.
    package func fetchBuildUpload(id: String) async throws -> BuildUploadStatus {
        let response = try await client.buildUploads_getInstance(path: .init(id: id))
        switch response {
        case .ok(let ok):
            guard case .json(let instance) = ok.body else {
                throw AppStoreServiceError.invalidResponse("App Store Connect returned invalid build upload body.")
            }
            let state = instance.data.attributes?.state
            func describe(_ details: [Components.Schemas.StateDetail]?) -> [String] {
                (details ?? []).map { detail in
                    [detail.code, detail.description].compactMap { $0 }.joined(separator: ": ")
                }
            }
            return BuildUploadStatus(
                id: instance.data.id,
                state: state?.state.flatMap { BuildUploadStatus.State(rawValue: $0.rawValue) } ?? .unknown,
                errors: describe(state?.errors),
                warnings: describe(state?.warnings),
                buildId: instance.data.relationships?.build?.data?.id
            )
        case .badRequest(let r):
            throw AppStoreServiceError.apiError(status: 400, message: formatAppleErrors(try? r.body.json.errors))
        case .unauthorized(let r):
            throw AppStoreServiceError.apiError(status: 401, message: formatAppleErrors(try? r.body.json.errors))
        case .forbidden(let r):
            throw AppStoreServiceError.apiError(status: 403, message: formatAppleErrors(try? r.body.json.errors))
        case .notFound(let r):
            throw AppStoreServiceError.apiError(status: 404, message: formatAppleErrors(try? r.body.json.errors))
        case .tooManyRequests(let r):
            throw AppStoreServiceError.apiError(status: 429, message: formatAppleErrors(try? r.body.json.errors))
        case .undocumented(let statusCode, _):
            throw AppStoreServiceError.apiError(status: statusCode, message: "Unexpected status code")
        }
    }
}
