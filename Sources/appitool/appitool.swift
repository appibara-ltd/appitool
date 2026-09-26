import ArgumentParser
import Foundation
import AppStoreConnectAPI
import GooglePlayStoreAPI
import Rainbow

@main
struct appitool: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "appitool",
        abstract: "A unified CLI utility for Apple App Store Connect and Google Play operations.",
        version: "0.1.0",
        subcommands: [
            StatusCommand.self,
            BuildCommand.self
        ]
    )

    // MARK: - App Store Connect Options

    @Option(help: "App Store Connect Key ID.")
    var keyId: String?

    @Option(help: "App Store Connect Issuer ID.")
    var issuerId: String?

    @Option(help: "App Store Connect Key (file path, raw PEM, or Base64 string).")
    var key: String?

    // MARK: - Google Play Options

    @Option(name: [.customLong("google-key")], help: "Google Service Account Key (file path, raw JSON, or Base64 string).")
    var googleKey: String?

    @Option(name: [.customLong("google-package-name"), .customLong("package-name")], help: "Target Android application package name (e.g. com.example.app).")
    var packageName: String?

    func run() async throws {
        // Load .env file into ProcessInfo
        _ = try? EnvLoader.loadEnv()

        // Resolve App Store credentials
        let resolvedKeyId = keyId ?? ProcessInfo.processInfo.environment["APPLE_KEY_ID"]
        let resolvedIssuerId = issuerId ?? ProcessInfo.processInfo.environment["APPLE_ISSUER_ID"]
        let resolvedKey = key ?? ProcessInfo.processInfo.environment["APPLE_KEY"]

        // Resolve Google Play credentials & options
        let resolvedGoogleKey = googleKey ?? ProcessInfo.processInfo.environment["GOOGLE_KEY"] ?? ProcessInfo.processInfo.environment["GOOGLE_APPLICATION_CREDENTIALS"]
        let resolvedPackageName = packageName ?? ProcessInfo.processInfo.environment["GOOGLE_PACKAGE_NAME"]

        let hasAppleCredentials = (resolvedKeyId?.isEmpty == false) && (resolvedIssuerId?.isEmpty == false) && (resolvedKey?.isEmpty == false)
        let hasGoogleCredentials = (resolvedGoogleKey?.isEmpty == false)

        guard hasAppleCredentials || hasGoogleCredentials else {
            print("Error: ".red.bold + "No credentials found for App Store Connect or Google Play.")
            print("Please configure them in your .env file or pass them as CLI arguments:".dim)
            print("  App Store:   ".cyan + "appitool --key-id <KEY_ID> --issuer-id <ISSUER_ID> --key <KEY_PATH_OR_BASE64>")
            print("  Google Play: ".cyan + "appitool --google-key <KEY_PATH_OR_BASE64> --package-name <PACKAGE_NAME>")
            return
        }

        // 1. App Store Connect operations
        if hasAppleCredentials, let resolvedKeyId, let resolvedIssuerId, let resolvedKey {
            let appStoreService = try AppStoreService(
                keyId: resolvedKeyId,
                issuerId: resolvedIssuerId,
                key: resolvedKey
            )
            print("AppStoreService successfully initialized".green + " (Key ID: \(resolvedKeyId)).".dim)

            let response = try await appStoreService.client.apps_getCollection(.init())
            switch response {
            case .ok(let okResponse):
                switch okResponse.body {
                case .json(let appsResponse):
                    print("\nApp Store Connect Apps (\(appsResponse.data.count) total):".cyan.bold)
                    for app in appsResponse.data {
                        let name = app.attributes?.name ?? "Unnamed"
                        let bundleId = app.attributes?.bundleId ?? "Unknown"
                        print("  • ".cyan + "\(name)".bold + " (Bundle ID: \(bundleId), ID: \(app.id))".dim)
                    }
                }
            case .unauthorized:
                print("Error: ".red.bold + "App Store Connect authorization failed (401 Unauthorized). Please check your keys and credentials.")
            default:
                print("App Store Connect response: \(response)")
            }
        }

        // 2. Google Play operations
        if hasGoogleCredentials, let resolvedGoogleKey {
            let googlePlayService = try GooglePlayService(key: resolvedGoogleKey)
            print("\nGooglePlayService successfully initialized.".green)

            if let resolvedPackageName, !resolvedPackageName.isEmpty {
                print("Fetching Google Play data for package: ".blue + "\(resolvedPackageName)".bold + "...")

                // Fetch recent user reviews via GET /androidpublisher/v3/applications/{packageName}/reviews
                let reviewsResponse = try await googlePlayService.client.androidpublisher_period_reviews_period_list(.init(
                    path: .init(packageName: resolvedPackageName),
                    query: .init(maxResults: 5)
                ))

                switch reviewsResponse {
                case .ok(let okResponse):
                    switch okResponse.body {
                    case .json(let reviewsList):
                        let reviews = reviewsList.reviews ?? []
                        print("\nGoogle Play Reviews for \(resolvedPackageName) (\(reviews.count) retrieved):".cyan.bold)
                        if reviews.isEmpty {
                            print("  (No recent reviews found for this app)".dim)
                        } else {
                            for review in reviews {
                                let author = review.authorName ?? "Anonymous"
                                let userComment = review.comments?.first?.userComment
                                let text = userComment?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "No text"
                                let rating = userComment?.starRating.map { String($0) } ?? "?"
                                print("  • [★\(rating)]".yellow.bold + " \(author): ".bold + "\"\(text)\"")
                            }
                        }
                    }
                case .undocumented(let statusCode, _):
                    if statusCode == 401 || statusCode == 403 {
                        print("Error: ".red.bold + "Google Play authorization failed (HTTP \(statusCode)). Please check permissions in Google Play Console.")
                    } else if statusCode == 404 {
                        print("Error: ".red.bold + "Application '\(resolvedPackageName)' not found in this Google Play account (HTTP 404).")
                    } else {
                        print("Google Play reviews response status code: \(statusCode)")
                    }
                }

                // Fetch release tracks via Edits API
                let editResponse = try await googlePlayService.client.androidpublisher_period_edits_period_insert(.init(
                    path: .init(packageName: resolvedPackageName),
                    body: .json(.init())
                ))

                if case .ok(let okEdit) = editResponse, case .json(let appEdit) = okEdit.body, let editId = appEdit.id {
                    let tracksResponse = try await googlePlayService.client.androidpublisher_period_edits_period_tracks_period_list(.init(
                        path: .init(packageName: resolvedPackageName, editId: editId)
                    ))

                    if case .ok(let okTracks) = tracksResponse, case .json(let tracksList) = okTracks.body {
                        let tracks = tracksList.tracks ?? []
                        print("\nGoogle Play Tracks for \(resolvedPackageName) (\(tracks.count) total):".cyan.bold)
                        for t in tracks {
                            let trackName = t.track ?? "Unknown"
                            let releases = t.releases ?? []
                            print("  • Track: [\(trackName)]".magenta.bold)
                            if releases.isEmpty {
                                print("     - (No active releases)".dim)
                            } else {
                                for rel in releases {
                                    let relName = rel.name ?? "Unnamed"
                                    let status = rel.status?.rawValue ?? "unknown"
                                    let versionCodes = rel.versionCodes?.joined(separator: ", ") ?? "None"
                                    print("     - Release: ".dim + "\"\(relName)\"".bold + " (Status: ".dim + "\(status)".green + ", Version Codes: [\(versionCodes)])".dim)
                                }
                            }
                        }
                    }

                    // Clean up / delete the read-only edit session
                    _ = try? await googlePlayService.client.androidpublisher_period_edits_period_delete(.init(
                        path: .init(packageName: resolvedPackageName, editId: editId)
                    ))
                }
            } else {
                print("Note: ".yellow.bold + "No GOOGLE_PACKAGE_NAME specified (set via .env or --package-name).")
            }
        }
    }
}
