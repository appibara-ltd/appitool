import Foundation
import AppStoreConnectAPI
import GooglePlayStoreAPI
import FirebaseAppDistributionAPI
import Rainbow
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Result containing the latest version and build number retrieved from the remote store.
struct LatestBuildInfo: Sendable, Equatable {
    /// The marketing version string (e.g., "1.2.0" on iOS, or release name on Android).
    let version: String

    /// The build number string (e.g., "42" / CFBundleVersion on iOS, or versionCode on Android).
    let buildNumber: String

    init(version: String, buildNumber: String) {
        self.version = version
        self.buildNumber = buildNumber
    }
}

/// An error thrown during `GetLatestBuildNumberTask` execution.
enum GetLatestBuildNumberError: LocalizedError, Sendable {
    case appNotFound(identifier: String)
    case apiError(String)
    case unauthorized(String)
    case developmentNotSupported
    case missingConfiguration(String)

    var errorDescription: String? {
        switch self {
        case .appNotFound(let identifier):
            return "Application not found for identifier: \(identifier)"
        case .apiError(let message):
            return "API request failed: \(message)"
        case .unauthorized(let message):
            return "Authorization failed: \(message)"
        case .developmentNotSupported:
            return "Development distribution cannot be checked remotely (development builds are not distributed remotely)."
        case .missingConfiguration(let message):
            return "Configuration missing: \(message)"
        }
    }
}

/// A task that retrieves the latest uploaded build version and build number from TestFlight (App Store Connect),
/// Google Play Console, or Firebase App Distribution based on the distribution method.
struct GetLatestBuildNumberTask: Task {
    struct Input: Sendable {
        enum Target: Sendable {
            case ios(bundleId: String? = nil, service: AppStoreService? = nil, firebaseAppId: String? = nil, firebaseService: FirebaseService? = nil)
            case android(packageName: String? = nil, service: GooglePlayService? = nil, track: String? = nil, firebaseAppId: String? = nil, firebaseService: FirebaseService? = nil)
        }

        let target: Target
        let distribution: BuildCommand.Distribution

        init(target: Target, distribution: BuildCommand.Distribution = .appstore) {
            self.target = target
            self.distribution = distribution
        }
    }

    typealias Output = LatestBuildInfo

    init() {}

    @discardableResult
    func run(_ input: Input) async throws -> LatestBuildInfo {
        switch input.distribution {
        case .development:
            return try handleDevelopmentDistribution()

        case .appstore:
            switch input.target {
            case .ios(let bundleId, let service, _, _):
                guard let bundleId, !bundleId.isEmpty else {
                    throw GetLatestBuildNumberError.missingConfiguration("Bundle ID is required for App Store distribution.")
                }
                guard let service else {
                    throw GetLatestBuildNumberError.missingConfiguration("AppStoreService is required for App Store distribution.")
                }
                return try await fetchLatestTestFlightBuild(bundleId: bundleId, service: service)
            case .android(let packageName, let service, let track, _, _):
                guard let packageName, !packageName.isEmpty else {
                    throw GetLatestBuildNumberError.missingConfiguration("Package name is required for Google Play distribution.")
                }
                guard let service else {
                    throw GetLatestBuildNumberError.missingConfiguration("GooglePlayService is required for Google Play distribution.")
                }
                return try await fetchLatestGooglePlayBuild(packageName: packageName, service: service, trackFilter: track)
            }

        case .adhoc:
            switch input.target {
            case .ios(_, _, let firebaseAppId, let firebaseService):
                guard let firebaseAppId, !firebaseAppId.isEmpty else {
                    throw GetLatestBuildNumberError.missingConfiguration("Missing Firebase App ID for iOS.")
                }
                guard let firebaseService else {
                    throw GetLatestBuildNumberError.unauthorized("Missing Firebase credentials.")
                }
                return try await fetchLatestFirebaseAppDistributionBuild(appId: firebaseAppId, service: firebaseService)

            case .android(_, _, _, let firebaseAppId, let firebaseService):
                guard let firebaseAppId, !firebaseAppId.isEmpty else {
                    throw GetLatestBuildNumberError.missingConfiguration("Missing Firebase App ID for Android.")
                }
                guard let firebaseService else {
                    throw GetLatestBuildNumberError.unauthorized("Missing Firebase credentials.")
                }
                return try await fetchLatestFirebaseAppDistributionBuild(appId: firebaseAppId, service: firebaseService)
            }
        }
    }

    // MARK: - Development

    private func handleDevelopmentDistribution() throws -> LatestBuildInfo {
        print("⚠️  Warning: ".yellow.bold + "Development distribution cannot be checked remotely (development builds are not distributed).")
        throw GetLatestBuildNumberError.developmentNotSupported
    }

    // MARK: - iOS (TestFlight / App Store Connect)

    private func fetchLatestTestFlightBuild(bundleId: String, service: AppStoreService) async throws -> LatestBuildInfo {
        // 1. Fetch App by bundle ID
        let appsResponse = try await service.client.apps_getCollection(.init(
            query: .init(filter_lbrack_bundleId_rbrack_: [bundleId])
        ))

        guard case .ok(let okApps) = appsResponse, case .json(let appsPayload) = okApps.body else {
            throw GetLatestBuildNumberError.apiError("Failed to fetch app details for bundle ID: \(bundleId)")
        }

        guard let app = appsPayload.data.first else {
            throw GetLatestBuildNumberError.appNotFound(identifier: bundleId)
        }

        let appId = app.id

        // 2. Fetch the latest build for this app sorted by upload date descending
        let buildsResponse = try await service.client.builds_getCollection(.init(
            query: .init(
                filter_lbrack_app_rbrack_: [appId],
                sort: [._hyphen_uploadedDate],
                limit: 1,
                include: [.preReleaseVersion]
            )
        ))

        guard case .ok(let okBuilds) = buildsResponse, case .json(let buildsPayload) = okBuilds.body else {
            throw GetLatestBuildNumberError.apiError("Failed to fetch builds for App ID: \(appId)")
        }

        guard let latestBuild = buildsPayload.data.first else {
            // No builds have been uploaded yet; return initial defaults
            return LatestBuildInfo(version: "1.0.0", buildNumber: "0")
        }

        let buildNumber = latestBuild.attributes?.version ?? "0"

        // Resolve marketing version from included preReleaseVersion relationship if present
        var marketingVersion: String?
        if let included = buildsPayload.included {
            for item in included {
                switch item {
                case .preReleaseVersions(let preRelease):
                    marketingVersion = preRelease.attributes?.version
                default:
                    break
                }
            }
        }

        let version = marketingVersion ?? latestBuild.attributes?.minOsVersion ?? "1.0.0"
        return LatestBuildInfo(version: version, buildNumber: buildNumber)
    }

    // MARK: - Android (Google Play Console)

    private func fetchLatestGooglePlayBuild(
        packageName: String,
        service: GooglePlayService,
        trackFilter: String?
    ) async throws -> LatestBuildInfo {
        // 1. Insert a read-only edit session
        let editResponse = try await service.client.androidpublisher_period_edits_period_insert(.init(
            path: .init(packageName: packageName),
            body: .json(.init())
        ))

        guard case .ok(let okEdit) = editResponse,
              case .json(let appEdit) = okEdit.body,
              let editId = appEdit.id else {
            throw GetLatestBuildNumberError.apiError("Failed to create Google Play edit session for package: \(packageName)")
        }

        // Defer deleting the edit session when done
        defer {
            _Concurrency.Task {
                _ = try? await service.client.androidpublisher_period_edits_period_delete(.init(
                    path: .init(packageName: packageName, editId: editId)
                ))
            }
        }

        // 2. Fetch all tracks
        let tracksResponse = try await service.client.androidpublisher_period_edits_period_tracks_period_list(.init(
            path: .init(packageName: packageName, editId: editId)
        ))

        guard case .ok(let okTracks) = tracksResponse,
              case .json(let tracksPayload) = okTracks.body else {
            throw GetLatestBuildNumberError.apiError("Failed to fetch release tracks for package: \(packageName)")
        }

        let tracks = tracksPayload.tracks ?? []
        var maxVersionCode: Int64 = 0
        var resolvedVersionName: String = "1.0.0"

        for t in tracks {
            // Apply track filter if specified (e.g. "production", "internal")
            if let trackFilter, let trackName = t.track, trackName.lowercased() != trackFilter.lowercased() {
                continue
            }

            guard let releases = t.releases else { continue }
            for release in releases {
                guard let versionCodes = release.versionCodes else { continue }
                for codeString in versionCodes {
                    if let code = Int64(codeString), code > maxVersionCode {
                        maxVersionCode = code
                        if let name = release.name, !name.isEmpty {
                            resolvedVersionName = name
                        }
                    }
                }
            }
        }

        return LatestBuildInfo(
            version: resolvedVersionName,
            buildNumber: String(maxVersionCode)
        )
    }

    // MARK: - AdHoc (Firebase App Distribution)

    private func fetchLatestFirebaseAppDistributionBuild(appId: String, service: FirebaseService) async throws -> LatestBuildInfo {
        let segments = appId.split(separator: ":")
        let projectNumber = segments.count >= 2 ? String(segments[1]) : "-"

        let response = try await service.appDistribution.firebaseappdistribution_period_projects_period_apps_period_releases_period_list(.init(
            path: .init(parent: "projects/\(projectNumber)/apps/\(appId)"),
            query: .init(pageSize: 1)
        ))

        switch response {
        case .ok(let okResponse):
            guard case .json(let payload) = okResponse.body else {
                throw GetLatestBuildNumberError.apiError("Failed to decode JSON response from Firebase App Distribution.")
            }
            guard let latestRelease = payload.releases?.first else {
                return LatestBuildInfo(version: "1.0.0", buildNumber: "0")
            }
            return LatestBuildInfo(
                version: latestRelease.displayVersion ?? "1.0.0",
                buildNumber: latestRelease.buildVersion ?? "0"
            )
        case .undocumented(let statusCode, _):
            throw GetLatestBuildNumberError.apiError("Firebase App Distribution API returned HTTP \(statusCode)")
        }
    }
}
