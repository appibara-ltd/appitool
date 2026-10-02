import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import OpenAPIURLSession
import OpenAPIRuntime
import AppStoreConnectAPI
import Rainbow

/// Errors originating from App Store Connect API operations.
package enum AppStoreServiceError: LocalizedError, Sendable {
    case apiError(status: Int?, message: String)
    case notFound(String)
    case invalidResponse(String)

    package var errorDescription: String? {
        switch self {
        case .apiError(let status, let message):
            if let status {
                return "Apple API Error (HTTP \(status)): \(message)"
            }
            return "Apple API Error: \(message)"
        case .notFound(let message):
            return "Not Found: \(message)"
        case .invalidResponse(let message):
            return "Invalid Response: \(message)"
        }
    }
}

/// Service providing access to the Apple App Store Connect API.
package struct AppStoreService: Sendable {
    package static let sharedTransport = URLSessionTransport()

    /// The underlying OpenAPI client for the App Store Connect API.
    package let client: Client

    /// The authentication middleware used for signed JWT generation.
    package let authMiddleware: AppStoreConnectAuthMiddleware

    /// Initializes AppStoreService with credentials (key can be a .p8 file path, raw PEM string, or Base64).
    package init(
        keyId: String,
        issuerId: String,
        key: String,
        transport: any ClientTransport = Self.sharedTransport
    ) throws {
        let authMiddleware = try AppStoreConnectAuthMiddleware(
            keyId: keyId,
            issuerId: issuerId,
            key: key
        )
        self.authMiddleware = authMiddleware
        let configuration = Configuration(dateTranscoder: FlexibleDateTranscoder())
        self.client = Client(
            serverURL: try Servers.Server1.url(),
            configuration: configuration,
            transport: transport,
            middlewares: [authMiddleware]
        )
    }

    // MARK: - Auto-Pagination Helper

    private func fetchNextPage<T: Decodable>(from urlString: String) async throws -> T {
        guard let url = URL(string: urlString) else {
            throw AppStoreServiceError.invalidResponse("Invalid next page URL: \(urlString)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let token = try authMiddleware.validToken()
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AppStoreServiceError.invalidResponse("Invalid HTTP response from \(urlString)")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let errorResponse = try? JSONDecoder().decode(Components.Schemas.ErrorResponse.self, from: data)
            let msg = formatAppleErrors(errorResponse?.errors)
            throw AppStoreServiceError.apiError(status: httpResponse.statusCode, message: msg)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let dateStr = try container.decode(String.self)
            return try FlexibleDateTranscoder().decode(dateStr)
        }
        return try decoder.decode(T.self, from: data)
    }

    // MARK: - Certificate Operations

    /// Fetches all active certificate IDs from Apple Developer Portal with auto-pagination.
    package func fetchActiveCertificateIds(limit: Int? = nil) async throws -> Set<String> {
        let certs = try await fetchCertificates(limit: limit)
        return Set(certs.map(\.id))
    }

    /// Fetches certificates optionally filtered by certificate types, with auto-pagination.
    package func fetchCertificates(
        types: [Operations.certificates_getCollection.Input.Query.filter_lbrack_certificateType_rbrack_PayloadPayload]? = nil,
        limit: Int? = nil
    ) async throws -> [Components.Schemas.Certificate] {
        let pageLimit = min(limit ?? 200, 200)
        let response = try await client.certificates_getCollection(query: .init(
            filter_lbrack_certificateType_rbrack_: types,
            limit: pageLimit
        ))
        guard case .ok(let okCert) = response, case .json(let certCollection) = okCert.body else {
            return []
        }

        var allItems = certCollection.data
        var nextUrl = certCollection.links.next

        while let currentNext = nextUrl {
            if let limit, allItems.count >= limit { break }
            let nextPage: Components.Schemas.CertificatesResponse = try await fetchNextPage(from: currentNext)
            allItems.append(contentsOf: nextPage.data)
            nextUrl = nextPage.links.next
        }

        if let limit, allItems.count > limit {
            return Array(allItems.prefix(limit))
        }
        return allItems
    }

    /// Submits a CSR and creates a new certificate on Apple Developer Portal.
    package func createCertificate(
        csrContent: String,
        certificateType: Components.Schemas.CertificateType
    ) async throws -> Components.Schemas.Certificate {
        let createPayload = Components.Schemas.CertificateCreateRequest(
            data: .init(
                _type: .certificates,
                attributes: .init(
                    csrContent: csrContent,
                    certificateType: certificateType
                )
            )
        )

        let response = try await client.certificates_createInstance(body: .json(createPayload))
        switch response {
        case .created(let createdResponse):
            guard case .json(let createdInstance) = createdResponse.body else {
                throw AppStoreServiceError.invalidResponse("Apple Developer Portal returned invalid certificate response.")
            }
            return createdInstance.data
        case .badRequest(let badReq):
            let msg = formatAppleErrors(try? badReq.body.json.errors)
            throw AppStoreServiceError.apiError(status: 400, message: msg)
        case .forbidden(let forbidden):
            let msg = formatAppleErrors(try? forbidden.body.json.errors)
            throw AppStoreServiceError.apiError(status: 403, message: msg)
        case .conflict(let conflict):
            let msg = formatAppleErrors(try? conflict.body.json.errors)
            throw AppStoreServiceError.apiError(status: 409, message: msg)
        case .unprocessableContent(let unproc):
            let msg = formatAppleErrors(try? unproc.body.json.errors)
            throw AppStoreServiceError.apiError(status: 422, message: msg)
        case .unauthorized(let unauth):
            let msg = formatAppleErrors(try? unauth.body.json.errors)
            throw AppStoreServiceError.apiError(status: 401, message: msg)
        case .tooManyRequests(let tmr):
            let msg = formatAppleErrors(try? tmr.body.json.errors)
            throw AppStoreServiceError.apiError(status: 429, message: msg)
        case .undocumented(let statusCode, _):
            throw AppStoreServiceError.apiError(status: statusCode, message: "Unexpected status code")
        }
    }

    /// Deletes (revokes) a certificate on Apple Developer Portal.
    package func deleteCertificate(id: String) async throws -> Bool {
        let response = try await client.certificates_deleteInstance(path: .init(id: id))
        switch response {
        case .noContent:
            return true
        case .notFound:
            return false
        case .badRequest(let badReq):
            let msg = formatAppleErrors(try? badReq.body.json.errors)
            throw AppStoreServiceError.apiError(status: 400, message: msg)
        case .forbidden(let forbidden):
            let msg = formatAppleErrors(try? forbidden.body.json.errors)
            throw AppStoreServiceError.apiError(status: 403, message: msg)
        case .unauthorized(let unauth):
            let msg = formatAppleErrors(try? unauth.body.json.errors)
            throw AppStoreServiceError.apiError(status: 401, message: msg)
        case .tooManyRequests(let tmr):
            let msg = formatAppleErrors(try? tmr.body.json.errors)
            throw AppStoreServiceError.apiError(status: 429, message: msg)
        case .undocumented(let statusCode, _):
            throw AppStoreServiceError.apiError(status: statusCode, message: "Unexpected status code")
        }
    }

    // MARK: - Bundle ID Operations

    /// Fetches bundle identifiers from Apple Developer Portal, optionally filtered by identifier, with auto-pagination.
    package func fetchBundleIds(
        limit: Int? = nil,
        identifier: String? = nil
    ) async throws -> [Components.Schemas.BundleId] {
        let pageLimit = min(limit ?? 200, 200)
        let response = try await client.bundleIds_getCollection(query: .init(
            filter_lbrack_identifier_rbrack_: identifier.map { [$0] },
            limit: pageLimit
        ))
        switch response {
        case .ok(let okResponse):
            guard case .json(let collection) = okResponse.body else { return [] }
            var allItems = collection.data
            var nextUrl = collection.links.next

            while let currentNext = nextUrl {
                if let limit, allItems.count >= limit { break }
                let nextPage: Components.Schemas.BundleIdsResponse = try await fetchNextPage(from: currentNext)
                allItems.append(contentsOf: nextPage.data)
                nextUrl = nextPage.links.next
            }

            if let limit, allItems.count > limit {
                return Array(allItems.prefix(limit))
            }
            return allItems
        case .badRequest(let badReq):
            let msg = formatAppleErrors(try? badReq.body.json.errors)
            throw AppStoreServiceError.apiError(status: 400, message: msg)
        case .forbidden(let forbidden):
            let msg = formatAppleErrors(try? forbidden.body.json.errors)
            throw AppStoreServiceError.apiError(status: 403, message: msg)
        case .unauthorized(let unauth):
            let msg = formatAppleErrors(try? unauth.body.json.errors)
            throw AppStoreServiceError.apiError(status: 401, message: msg)
        case .tooManyRequests(let tmr):
            let msg = formatAppleErrors(try? tmr.body.json.errors)
            throw AppStoreServiceError.apiError(status: 429, message: msg)
        case .undocumented(let statusCode, _):
            throw AppStoreServiceError.apiError(status: statusCode, message: "Unexpected status code")
        }
    }

    /// Resolves an existing bundle ID or creates a new one on Apple Developer Portal.
    package func resolveOrCreateBundleId(bundleId: String) async throws -> String {
        let response = try await client.bundleIds_getCollection(query: .init(
            filter_lbrack_identifier_rbrack_: [bundleId]
        ))

        if case .ok(let okResp) = response, case .json(let collection) = okResp.body {
            if let matched = collection.data.first(where: { $0.attributes?.identifier == bundleId && $0.attributes?.platform != .SERVICES })
                ?? collection.data.first(where: { $0.attributes?.identifier == bundleId })
                ?? collection.data.first {
                return matched.id
            }
        }

        let created = try await createBundleId(identifier: bundleId)
        return created.id
    }

    /// Creates a new bundle identifier on Apple Developer Portal.
    package func createBundleId(
        identifier: String,
        name: String? = nil,
        platform: Components.Schemas.BundleIdPlatform = .UNIVERSAL
    ) async throws -> Components.Schemas.BundleId {
        let appName = name ?? identifier.replacingOccurrences(of: ".", with: " ")
        let createPayload = Components.Schemas.BundleIdCreateRequest(
            data: .init(
                _type: .bundleIds,
                attributes: .init(
                    name: appName,
                    platform: platform,
                    identifier: identifier
                )
            )
        )

        let response = try await client.bundleIds_createInstance(body: .json(createPayload))
        switch response {
        case .created(let createdResp):
            guard case .json(let instance) = createdResp.body else {
                throw AppStoreServiceError.invalidResponse("Apple Developer Portal returned invalid bundle ID response.")
            }
            return instance.data
        case .badRequest(let badReq):
            let msg = formatAppleErrors(try? badReq.body.json.errors)
            throw AppStoreServiceError.apiError(status: 400, message: msg)
        case .conflict(let conflict):
            let msg = formatAppleErrors(try? conflict.body.json.errors)
            throw AppStoreServiceError.apiError(status: 409, message: msg)
        case .forbidden(let forbidden):
            let msg = formatAppleErrors(try? forbidden.body.json.errors)
            throw AppStoreServiceError.apiError(status: 403, message: msg)
        case .unauthorized(let unauth):
            let msg = formatAppleErrors(try? unauth.body.json.errors)
            throw AppStoreServiceError.apiError(status: 401, message: msg)
        case .tooManyRequests(let tmr):
            let msg = formatAppleErrors(try? tmr.body.json.errors)
            throw AppStoreServiceError.apiError(status: 429, message: msg)
        case .unprocessableContent(let unproc):
            let msg = formatAppleErrors(try? unproc.body.json.errors)
            throw AppStoreServiceError.apiError(status: 422, message: msg)
        case .undocumented(let statusCode, _):
            throw AppStoreServiceError.apiError(status: statusCode, message: "Unexpected status code")
        }
    }

    /// Adds a capability to a bundle identifier on Apple Developer Portal.
    package func addCapability(
        bundleIdPortalId: String,
        capabilityType: Components.Schemas.CapabilityType
    ) async throws {
        var settings: [Components.Schemas.CapabilitySetting]? = nil
        switch capabilityType {
        case .APPLE_ID_AUTH:
            settings = [.init(key: .APPLE_ID_AUTH_APP_CONSENT, options: [.init(key: .PRIMARY_APP_CONSENT)])]
        default:
            settings = nil
        }
        let createPayload = Components.Schemas.BundleIdCapabilityCreateRequest(
            data: .init(
                _type: .bundleIdCapabilities,
                attributes: .init(
                    capabilityType: capabilityType,
                    settings: settings
                ),
                relationships: .init(
                    bundleId: .init(data: .init(_type: .bundleIds, id: bundleIdPortalId))
                )
            )
        )

        let response = try await client.bundleIdCapabilities_createInstance(body: .json(createPayload))
        switch response {
        case .created:
            return
        case .badRequest(let badReq):
            let msg = formatAppleErrors(try? badReq.body.json.errors)
            throw AppStoreServiceError.apiError(status: 400, message: msg)
        case .conflict(let conflict):
            let msg = formatAppleErrors(try? conflict.body.json.errors)
            throw AppStoreServiceError.apiError(status: 409, message: msg)
        case .forbidden(let forbidden):
            let msg = formatAppleErrors(try? forbidden.body.json.errors)
            throw AppStoreServiceError.apiError(status: 403, message: msg)
        case .unauthorized(let unauth):
            let msg = formatAppleErrors(try? unauth.body.json.errors)
            throw AppStoreServiceError.apiError(status: 401, message: msg)
        case .tooManyRequests(let tmr):
            let msg = formatAppleErrors(try? tmr.body.json.errors)
            throw AppStoreServiceError.apiError(status: 429, message: msg)
        case .unprocessableContent(let unproc):
            let msg = formatAppleErrors(try? unproc.body.json.errors)
            throw AppStoreServiceError.apiError(status: 422, message: msg)
        case .undocumented(let statusCode, _):
            throw AppStoreServiceError.apiError(status: statusCode, message: "Unexpected status code")
        }
    }

    /// Fetches all enabled capabilities for a given bundle ID.
    package func fetchCapabilities(bundleIdPortalId: String) async throws -> [Components.Schemas.BundleIdCapability] {
        let response = try await client.bundleIds_bundleIdCapabilities_getToManyRelated(path: .init(id: bundleIdPortalId))
        switch response {
        case .ok(let okResp):
            guard case .json(let collection) = okResp.body else { return [] }
            return collection.data
        default:
            return []
        }
    }

    /// Deletes a bundle identifier from Apple Developer Portal.
    package func deleteBundleId(id: String) async throws -> Bool {
        let response = try await client.bundleIds_deleteInstance(path: .init(id: id))
        switch response {
        case .noContent:
            return true
        case .notFound:
            return false
        case .badRequest(let badReq):
            let msg = formatAppleErrors(try? badReq.body.json.errors)
            throw AppStoreServiceError.apiError(status: 400, message: msg)
        case .forbidden(let forbidden):
            let msg = formatAppleErrors(try? forbidden.body.json.errors)
            throw AppStoreServiceError.apiError(status: 403, message: msg)
        case .unauthorized(let unauth):
            let msg = formatAppleErrors(try? unauth.body.json.errors)
            throw AppStoreServiceError.apiError(status: 401, message: msg)
        case .tooManyRequests(let tmr):
            let msg = formatAppleErrors(try? tmr.body.json.errors)
            throw AppStoreServiceError.apiError(status: 429, message: msg)
        case .undocumented(let statusCode, _):
            throw AppStoreServiceError.apiError(status: statusCode, message: "Unexpected status code")
        }
    }

    // MARK: - App Operations

    /// Fetches applications from App Store Connect, optionally filtered by bundle ID or name, with auto-pagination.
    package func fetchApps(
        limit: Int? = nil,
        bundleId: String? = nil,
        name: String? = nil
    ) async throws -> [Components.Schemas.App] {
        let pageLimit = min(limit ?? 200, 200)
        let response = try await client.apps_getCollection(query: .init(
            filter_lbrack_name_rbrack_: name.map { [$0] },
            filter_lbrack_bundleId_rbrack_: bundleId.map { [$0] },
            limit: pageLimit
        ))
        switch response {
        case .ok(let okResponse):
            guard case .json(let collection) = okResponse.body else { return [] }
            var allItems = collection.data
            var nextUrl = collection.links.next

            while let currentNext = nextUrl {
                if let limit, allItems.count >= limit { break }
                let nextPage: Components.Schemas.AppsResponse = try await fetchNextPage(from: currentNext)
                allItems.append(contentsOf: nextPage.data)
                nextUrl = nextPage.links.next
            }

            if let limit, allItems.count > limit {
                return Array(allItems.prefix(limit))
            }
            return allItems
        case .badRequest(let badReq):
            let msg = formatAppleErrors(try? badReq.body.json.errors)
            throw AppStoreServiceError.apiError(status: 400, message: msg)
        case .forbidden(let forbidden):
            let msg = formatAppleErrors(try? forbidden.body.json.errors)
            throw AppStoreServiceError.apiError(status: 403, message: msg)
        case .unauthorized(let unauth):
            let msg = formatAppleErrors(try? unauth.body.json.errors)
            throw AppStoreServiceError.apiError(status: 401, message: msg)
        case .tooManyRequests(let tmr):
            let msg = formatAppleErrors(try? tmr.body.json.errors)
            throw AppStoreServiceError.apiError(status: 429, message: msg)
        case .undocumented(let statusCode, _):
            throw AppStoreServiceError.apiError(status: statusCode, message: "Unexpected status code")
        }
    }

    // MARK: - Device Operations

    /// Fetches registered devices from Apple Developer Portal with optional filtering and auto-pagination.
    package func fetchDevices(
        platform: Operations.devices_getCollection.Input.Query.filter_lbrack_platform_rbrack_PayloadPayload? = nil,
        status: Operations.devices_getCollection.Input.Query.filter_lbrack_status_rbrack_PayloadPayload? = nil,
        udid: String? = nil,
        limit: Int? = nil
    ) async throws -> [Components.Schemas.Device] {
        let pageLimit = min(limit ?? 200, 200)
        let response = try await client.devices_getCollection(query: .init(
            filter_lbrack_platform_rbrack_: platform.map { [$0] },
            filter_lbrack_udid_rbrack_: udid.map { [$0] },
            filter_lbrack_status_rbrack_: status.map { [$0] },
            limit: pageLimit
        ))
        guard case .ok(let okResp) = response, case .json(let collection) = okResp.body else {
            switch response {
            case .badRequest(let badReq):
                let msg = formatAppleErrors(try? badReq.body.json.errors)
                throw AppStoreServiceError.apiError(status: 400, message: msg)
            case .forbidden(let forbidden):
                let msg = formatAppleErrors(try? forbidden.body.json.errors)
                throw AppStoreServiceError.apiError(status: 403, message: msg)
            case .unauthorized(let unauth):
                let msg = formatAppleErrors(try? unauth.body.json.errors)
                throw AppStoreServiceError.apiError(status: 401, message: msg)
            case .tooManyRequests(let tmr):
                let msg = formatAppleErrors(try? tmr.body.json.errors)
                throw AppStoreServiceError.apiError(status: 429, message: msg)
            default:
                return []
            }
        }

        var allItems = collection.data
        var nextUrl = collection.links.next

        while let currentNext = nextUrl {
            if let limit, allItems.count >= limit { break }
            let nextPage: Components.Schemas.DevicesResponse = try await fetchNextPage(from: currentNext)
            allItems.append(contentsOf: nextPage.data)
            nextUrl = nextPage.links.next
        }

        if let limit, allItems.count > limit {
            return Array(allItems.prefix(limit))
        }
        return allItems
    }

    /// Fetches devices with string-based platform, status, and name filters.
    package func fetchDevices(
        matchingName: String? = nil,
        platform: String? = nil,
        status: String? = nil,
        udid: String? = nil,
        limit: Int? = nil
    ) async throws -> [Components.Schemas.Device] {
        let parsedPlatform = platform.flatMap { AppleTypeMapper.parseDevicePlatformFilter($0) }
        let parsedStatus = status.flatMap { AppleTypeMapper.parseDeviceStatusFilter($0) }

        var devices = try await fetchDevices(
            platform: parsedPlatform,
            status: parsedStatus,
            udid: udid,
            limit: matchingName != nil ? nil : limit
        )

        if let matchingName, !matchingName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let filter = matchingName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            devices = devices.filter { ($0.attributes?.name ?? "").localizedCaseInsensitiveContains(filter) }
            if let limit, devices.count > limit {
                devices = Array(devices.prefix(limit))
            }
        }

        return devices
    }

    /// Registers a new device on Apple Developer Portal.
    package func registerDevice(
        name: String,
        udid: String,
        platform: String = "ios"
    ) async throws -> Components.Schemas.Device {
        let parsedPlatform = try AppleTypeMapper.parseBundleIdPlatform(platform)
        let requestBody = Components.Schemas.DeviceCreateRequest(
            data: .init(
                _type: .devices,
                attributes: .init(
                    name: name,
                    platform: parsedPlatform,
                    udid: udid
                )
            )
        )

        let response = try await client.devices_createInstance(body: .json(requestBody))
        switch response {
        case .created(let createdResp):
            guard case .json(let deviceResp) = createdResp.body else {
                throw AppStoreServiceError.invalidResponse("Invalid response format when creating device.")
            }
            return deviceResp.data
        case .badRequest(let badReq):
            let msg = formatAppleErrors(try? badReq.body.json.errors)
            throw AppStoreServiceError.apiError(status: 400, message: msg)
        case .forbidden(let forbidden):
            let msg = formatAppleErrors(try? forbidden.body.json.errors)
            throw AppStoreServiceError.apiError(status: 403, message: msg)
        case .unauthorized(let unauth):
            let msg = formatAppleErrors(try? unauth.body.json.errors)
            throw AppStoreServiceError.apiError(status: 401, message: msg)
        case .conflict(let conflict):
            let msg = formatAppleErrors(try? conflict.body.json.errors)
            throw AppStoreServiceError.apiError(status: 409, message: msg)
        case .unprocessableContent(let unproc):
            let msg = formatAppleErrors(try? unproc.body.json.errors)
            throw AppStoreServiceError.apiError(status: 422, message: msg)
        case .tooManyRequests(let tmr):
            let msg = formatAppleErrors(try? tmr.body.json.errors)
            throw AppStoreServiceError.apiError(status: 429, message: msg)
        case .undocumented(let statusCode, _):
            throw AppStoreServiceError.apiError(status: statusCode, message: "Unexpected status code")
        }
    }

    /// Disables a device on Apple Developer Portal.
    /// Note: Apple Developer Portal REST API does not allow deleting devices; disabling prevents inclusion in provisioning profiles.
    package func disableDevice(id: String) async throws -> Components.Schemas.Device {
        let requestBody = Components.Schemas.DeviceUpdateRequest(
            data: .init(
                _type: .devices,
                id: id,
                attributes: .init(
                    status: .DISABLED
                )
            )
        )

        let response = try await client.devices_updateInstance(
            path: .init(id: id),
            body: .json(requestBody)
        )
        switch response {
        case .ok(let okResp):
            guard case .json(let deviceResp) = okResp.body else {
                throw AppStoreServiceError.invalidResponse("Invalid response format when updating device.")
            }
            return deviceResp.data
        case .badRequest(let badReq):
            let msg = formatAppleErrors(try? badReq.body.json.errors)
            throw AppStoreServiceError.apiError(status: 400, message: msg)
        case .forbidden(let forbidden):
            let msg = formatAppleErrors(try? forbidden.body.json.errors)
            throw AppStoreServiceError.apiError(status: 403, message: msg)
        case .unauthorized(let unauth):
            let msg = formatAppleErrors(try? unauth.body.json.errors)
            throw AppStoreServiceError.apiError(status: 401, message: msg)
        case .notFound(let notFound):
            let msg = formatAppleErrors(try? notFound.body.json.errors)
            throw AppStoreServiceError.apiError(status: 404, message: msg)
        case .conflict(let conflict):
            let msg = formatAppleErrors(try? conflict.body.json.errors)
            throw AppStoreServiceError.apiError(status: 409, message: msg)
        case .unprocessableContent(let unproc):
            let msg = formatAppleErrors(try? unproc.body.json.errors)
            throw AppStoreServiceError.apiError(status: 422, message: msg)
        case .tooManyRequests(let tmr):
            let msg = formatAppleErrors(try? tmr.body.json.errors)
            throw AppStoreServiceError.apiError(status: 429, message: msg)
        case .undocumented(let statusCode, _):
            throw AppStoreServiceError.apiError(status: statusCode, message: "Unexpected status code")
        }
    }

    /// Finds a device by UDID using portal query filter.
    package func findDevice(udid: String) async throws -> Components.Schemas.Device? {
        let trimmed = udid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let devices = try await fetchDevices(udid: trimmed)
        for dev in devices {
            if let devUdid = dev.attributes?.udid, devUdid.caseInsensitiveCompare(trimmed) == .orderedSame {
                return dev
            }
        }
        return nil
    }

    /// Finds a device by ID, UDID, or exact name.
    package func findDevice(identifier: String) async throws -> Components.Schemas.Device? {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let allDevices = try await fetchDevices(limit: 200)
        for device in allDevices {
            if device.id == trimmed { return device }
            if let udid = device.attributes?.udid, udid.caseInsensitiveCompare(trimmed) == .orderedSame {
                return device
            }
            if let name = device.attributes?.name, name.caseInsensitiveCompare(trimmed) == .orderedSame {
                return device
            }
        }
        return nil
    }

    // MARK: - Provisioning Profile Operations

    /// Fetches all provisioning profiles, optionally filtered by name, with auto-pagination.
    package func fetchProfiles(
        limit: Int? = nil,
        name: String? = nil
    ) async throws -> [Components.Schemas.Profile] {
        let pageLimit = min(limit ?? 200, 200)
        let response = try await client.profiles_getCollection(query: .init(
            filter_lbrack_name_rbrack_: name.map { [$0] },
            limit: pageLimit
        ))
        guard case .ok(let okProf) = response, case .json(let profCollection) = okProf.body else {
            switch response {
            case .badRequest(let badReq):
                let msg = formatAppleErrors(try? badReq.body.json.errors)
                throw AppStoreServiceError.apiError(status: 400, message: msg)
            case .forbidden(let forbidden):
                let msg = formatAppleErrors(try? forbidden.body.json.errors)
                throw AppStoreServiceError.apiError(status: 403, message: msg)
            case .unauthorized(let unauth):
                let msg = formatAppleErrors(try? unauth.body.json.errors)
                throw AppStoreServiceError.apiError(status: 401, message: msg)
            case .tooManyRequests(let tmr):
                let msg = formatAppleErrors(try? tmr.body.json.errors)
                throw AppStoreServiceError.apiError(status: 429, message: msg)
            case .undocumented(let statusCode, _):
                throw AppStoreServiceError.apiError(status: statusCode, message: "Unexpected status code")
            default:
                return []
            }
        }

        var allItems = profCollection.data
        var nextUrl = profCollection.links.next

        while let currentNext = nextUrl {
            if let limit, allItems.count >= limit { break }
            let nextPage: Components.Schemas.ProfilesResponse = try await fetchNextPage(from: currentNext)
            allItems.append(contentsOf: nextPage.data)
            nextUrl = nextPage.links.next
        }

        if let limit, allItems.count > limit {
            return Array(allItems.prefix(limit))
        }
        return allItems
    }

    /// Creates a provisioning profile with automatic conflict retry and base64 decoding.
    package func createProfile(
        name: String,
        profileType: Components.Schemas.ProfileCreateRequest.dataPayload.attributesPayload.profileTypePayload,
        bundleIdPortalId: String,
        certificateId: String,
        deviceIds: [String] = []
    ) async throws -> (id: String, name: String, uuid: String, profileData: Data) {
        let createPayload = Components.Schemas.ProfileCreateRequest(
            data: .init(
                _type: .profiles,
                attributes: .init(
                    name: name,
                    profileType: profileType
                ),
                relationships: .init(
                    bundleId: .init(data: .init(_type: .bundleIds, id: bundleIdPortalId)),
                    devices: deviceIds.isEmpty ? nil : .init(data: deviceIds.map { .init(_type: .devices, id: $0) }),
                    certificates: .init(data: [.init(_type: .certificates, id: certificateId)])
                )
            )
        )

        var finalName = name
        var response = try await client.profiles_createInstance(body: .json(createPayload))

        // Fastlane Match parity: If profile name is already taken (HTTP 409 Conflict),
        // retry creating with Unix timestamp appended to make the name globally unique
        if case .conflict = response {
            let timestamp = Int(Date().timeIntervalSince1970)
            finalName = "\(name) \(timestamp)"
            let retryPayload = Components.Schemas.ProfileCreateRequest(
                data: .init(
                    _type: .profiles,
                    attributes: .init(
                        name: finalName,
                        profileType: profileType
                    ),
                    relationships: .init(
                        bundleId: .init(data: .init(_type: .bundleIds, id: bundleIdPortalId)),
                        devices: deviceIds.isEmpty ? nil : .init(data: deviceIds.map { .init(_type: .devices, id: $0) }),
                        certificates: .init(data: [.init(_type: .certificates, id: certificateId)])
                    )
                )
            )
            response = try await client.profiles_createInstance(body: .json(retryPayload))
        }

        switch response {
        case .created(let createdResponse):
            guard case .json(let instance) = createdResponse.body else {
                throw AppStoreServiceError.invalidResponse("Apple Developer Portal returned invalid response body.")
            }
            let uuid = instance.data.attributes?.uuid ?? UUID().uuidString
            guard let base64Profile = instance.data.attributes?.profileContent,
                  let profileData = Data(base64Encoded: base64Profile, options: [.ignoreUnknownCharacters]) else {
                throw AppStoreServiceError.invalidResponse("Apple Developer Portal returned invalid profile content.")
            }
            return (instance.data.id, finalName, uuid, profileData)
        case .badRequest(let badReq):
            let msg = formatAppleErrors(try? badReq.body.json.errors)
            throw AppStoreServiceError.apiError(status: 400, message: msg)
        case .forbidden(let forbidden):
            let msg = formatAppleErrors(try? forbidden.body.json.errors)
            throw AppStoreServiceError.apiError(status: 403, message: msg)
        case .conflict(let conflict):
            let msg = formatAppleErrors(try? conflict.body.json.errors)
            throw AppStoreServiceError.apiError(status: 409, message: msg)
        case .unprocessableContent(let unproc):
            let msg = formatAppleErrors(try? unproc.body.json.errors)
            throw AppStoreServiceError.apiError(status: 422, message: msg)
        case .unauthorized(let unauth):
            let msg = formatAppleErrors(try? unauth.body.json.errors)
            throw AppStoreServiceError.apiError(status: 401, message: msg)
        case .tooManyRequests(let tmr):
            let msg = formatAppleErrors(try? tmr.body.json.errors)
            throw AppStoreServiceError.apiError(status: 429, message: msg)
        case .undocumented(let statusCode, _):
            throw AppStoreServiceError.apiError(status: statusCode, message: "Unexpected status code")
        }
    }

    /// Deletes a provisioning profile on Apple Developer Portal.
    package func deleteProfile(id: String) async throws -> Bool {
        let response = try await client.profiles_deleteInstance(path: .init(id: id))
        switch response {
        case .noContent:
            return true
        case .notFound:
            return false
        case .badRequest(let badReq):
            let msg = formatAppleErrors(try? badReq.body.json.errors)
            throw AppStoreServiceError.apiError(status: 400, message: msg)
        case .forbidden(let forbidden):
            let msg = formatAppleErrors(try? forbidden.body.json.errors)
            throw AppStoreServiceError.apiError(status: 403, message: msg)
        case .unauthorized(let unauth):
            let msg = formatAppleErrors(try? unauth.body.json.errors)
            throw AppStoreServiceError.apiError(status: 401, message: msg)
        case .tooManyRequests(let tmr):
            let msg = formatAppleErrors(try? tmr.body.json.errors)
            throw AppStoreServiceError.apiError(status: 429, message: msg)
        case .undocumented(let statusCode, _):
            throw AppStoreServiceError.apiError(status: statusCode, message: "Unexpected status code")
        }
    }

    // MARK: - Nuke Operations

    /// Revokes all certificates and deletes all provisioning profiles of the given type and platform from Apple Developer Portal.
    @discardableResult
    package func nuke(
        type: String,
        platform: String = "ios"
    ) async throws -> (revokedCertIds: [String], deletedProfileIds: [String]) {
        var revokedCerts: [String] = []
        var deletedProfiles: [String] = []

        // 1. Revoke certificates matching the profile type and platform
        let certTypes = AppleTypeMapper.appleCertificateTypesForProfile(type: type, platform: platform)
        let certs = try await fetchCertificates(types: certTypes)
        for cert in certs {
            if try await deleteCertificate(id: cert.id) {
                revokedCerts.append(cert.id)
            }
        }

        // 2. Delete provisioning profiles matching the profile type and platform
        let profiles = try await fetchProfiles()
        for profile in profiles {
            let profTypeStr = profile.attributes?.profileType?.rawValue ?? ""
            if AppleTypeMapper.matchesProfileType(profTypeStr: profTypeStr, targetType: type, platform: platform) {
                if try await deleteProfile(id: profile.id) {
                    deletedProfiles.append(profile.id)
                }
            }
        }

        return (revokedCerts, deletedProfiles)
    }

    // MARK: - Error Formatting

    /// Formats errors from Apple Developer Portal API into a readable string.
    package func formatAppleErrors(_ errors: [Components.Schemas.ErrorResponse.errorsPayloadPayload]?) -> String {
        guard let errors, !errors.isEmpty else { return "No detailed error provided by Apple" }
        return errors.map { "\($0.title) (\($0.code)): \($0.detail)" }.joined(separator: " | ")
    }
}
