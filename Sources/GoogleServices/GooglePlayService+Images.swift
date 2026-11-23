import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import GooglePlayStoreAPI
import OpenAPIRuntime

/// Supported store visual / image types in Google Play Developer API v3 (`edits.images`).
package enum GooglePlayImageType: String, Sendable, CaseIterable {
    case phoneScreenshots
    case sevenInchScreenshots
    case tenInchScreenshots
    case tvScreenshots
    case wearScreenshots
    case icon
    case featureGraphic
    case tvBanner

    /// Short CLI key for the image type.
    package var cliKey: String {
        switch self {
        case .phoneScreenshots: return "phone"
        case .sevenInchScreenshots: return "tablet7"
        case .tenInchScreenshots: return "tablet10"
        case .tvScreenshots: return "tv"
        case .wearScreenshots: return "wear"
        case .icon: return "icon"
        case .featureGraphic: return "feature-graphic"
        case .tvBanner: return "tv-banner"
        }
    }

    /// Additional CLI aliases accepted for this image type.
    package var aliases: [String] {
        switch self {
        case .phoneScreenshots:
            return ["phone", "phone-screenshots", "phone_screenshots"]
        case .sevenInchScreenshots:
            return ["tablet7", "seven-inch", "7-inch", "seven-inch-screenshots", "seven_inch_screenshots"]
        case .tenInchScreenshots:
            return ["tablet10", "ten-inch", "10-inch", "ten-inch-screenshots", "ten_inch_screenshots"]
        case .tvScreenshots:
            return ["tv", "tv-screenshots", "tv_screenshots"]
        case .wearScreenshots:
            return ["wear", "watch", "wear-screenshots", "wear_screenshots"]
        case .icon:
            return ["icon", "app-icon"]
        case .featureGraphic:
            return ["feature-graphic", "feature", "feature_graphic"]
        case .tvBanner:
            return ["tv-banner", "banner", "tv_banner"]
        }
    }

    package var description: String {
        switch self {
        case .phoneScreenshots: return "Phone screenshots (PNG/JPEG, 2–8 images)"
        case .sevenInchScreenshots: return "7-inch tablet screenshots (PNG/JPEG)"
        case .tenInchScreenshots: return "10-inch tablet screenshots (PNG/JPEG)"
        case .tvScreenshots: return "Android TV screenshots (PNG/JPEG)"
        case .wearScreenshots: return "Wear OS screenshots (PNG/JPEG)"
        case .icon: return "High-res app icon (512x512 PNG/JPEG)"
        case .featureGraphic: return "Feature graphic banner (1024x500 PNG/JPEG)"
        case .tvBanner: return "Android TV banner (1280x720 PNG/JPEG)"
        }
    }

    /// Parses a CLI key, alias, or exact Google Play `imageType` string.
    package static func parse(_ raw: String) throws -> GooglePlayImageType {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw GooglePlayImageError.unsupportedImageType(raw)
        }

        if let exact = GooglePlayImageType(rawValue: trimmed) {
            return exact
        }

        let lowered = trimmed.lowercased()
        if let caseInsensitive = GooglePlayImageType.allCases.first(where: { $0.rawValue.lowercased() == lowered }) {
            return caseInsensitive
        }

        for imageType in GooglePlayImageType.allCases {
            if imageType.aliases.contains(lowered) {
                return imageType
            }
        }

        throw GooglePlayImageError.unsupportedImageType(trimmed)
    }
}

/// Metadata returned by Google Play Console for an uploaded or existing store visual image.
package struct GooglePlayImage: Sendable, Equatable {
    package let id: String
    package let url: String?
    package let sha1: String?
    package let sha256: String?

    package init(id: String, url: String? = nil, sha1: String? = nil, sha256: String? = nil) {
        self.id = id
        self.url = url
        self.sha1 = sha1
        self.sha256 = sha256
    }

    init?(_ schema: Components.Schemas.Image) {
        guard let id = schema.id, !id.isEmpty else { return nil }
        self.id = id
        self.url = schema.url
        self.sha1 = schema.sha1
        self.sha256 = schema.sha256
    }
}

/// Errors thrown by Google Play store image operations.
package enum GooglePlayImageError: LocalizedError, Sendable, Equatable {
    case unsupportedImageType(String)
    case unsupportedFileExtension(String)
    case invalidResponse(String)
    case apiError(status: Int, message: String)

    package var errorDescription: String? {
        switch self {
        case .unsupportedImageType(let raw):
            let supported = GooglePlayImageType.allCases.map(\.cliKey).joined(separator: ", ")
            return "Unsupported Google Play image type '\(raw)'. Supported: \(supported) (or exact API names such as phoneScreenshots, featureGraphic)."
        case .unsupportedFileExtension(let ext):
            return "Unsupported image extension '.\(ext)'. Google Play Console accepts .png, .jpg, and .jpeg."
        case .invalidResponse(let message):
            return "Invalid Google Play image response: \(message)"
        case .apiError(let status, let message):
            return "Google Play API Error (HTTP \(status)): \(message)"
        }
    }
}

extension GooglePlayService {
    // MARK: - Edit Lifecycle Wrapper

    /// Executes an operation inside a Google Play edit session, committing, validating, or discarding the edit cleanly.
    package func withEditSession<T>(
        packageName: String,
        commit: Bool,
        validateOnly: Bool = false,
        changesNotSentForReview: Bool? = nil,
        _ operation: (String) async throws -> T
    ) async throws -> T {
        let editId = try await createEdit(packageName: packageName)
        do {
            let result = try await operation(editId)
            if validateOnly {
                _ = try await validateEdit(packageName: packageName, editId: editId)
                _ = try? await deleteEdit(packageName: packageName, editId: editId)
            } else if commit {
                _ = try await commitEdit(
                    packageName: packageName,
                    editId: editId,
                    changesNotSentForReview: changesNotSentForReview
                )
            } else {
                _ = try? await deleteEdit(packageName: packageName, editId: editId)
            }
            return result
        } catch {
            _ = try? await deleteEdit(packageName: packageName, editId: editId)
            throw error
        }
    }

    // MARK: - Store Listings & Images

    /// Lists all configured BCP-47 store listing languages in the active edit.
    package func listListingLanguages(packageName: String, editId: String) async throws -> [String] {
        let response = try await client.androidpublisher_period_edits_period_listings_period_list(
            .init(path: .init(packageName: packageName, editId: editId))
        )

        switch response {
        case .ok(let ok):
            guard case .json(let payload) = ok.body else {
                return []
            }
            return (payload.listings ?? []).compactMap { $0.language }
        case .undocumented(let status, let undocumented):
            let msg = await Self.readGoogleError(from: undocumented.body) ?? "HTTP \(status) while listing store listings."
            throw GooglePlayImageError.apiError(status: status, message: msg)
        }
    }

    /// Lists existing images for a package, edit, language, and image type.
    package func listImages(
        packageName: String,
        editId: String,
        language: String,
        imageType: GooglePlayImageType
    ) async throws -> [GooglePlayImage] {
        guard let apiType = Operations.androidpublisher_period_edits_period_images_period_list.Input.Path.imageTypePayload(rawValue: imageType.rawValue) else {
            throw GooglePlayImageError.unsupportedImageType(imageType.rawValue)
        }

        let response = try await client.androidpublisher_period_edits_period_images_period_list(
            .init(path: .init(
                packageName: packageName,
                editId: editId,
                language: language,
                imageType: apiType
            ))
        )

        switch response {
        case .ok(let ok):
            guard case .json(let payload) = ok.body else {
                return []
            }
            return (payload.images ?? []).compactMap(GooglePlayImage.init)
        case .undocumented(let status, let undocumented):
            let msg = await Self.readGoogleError(from: undocumented.body) ?? "HTTP \(status) while listing images."
            throw GooglePlayImageError.apiError(status: status, message: msg)
        }
    }

    /// Uploads a local PNG/JPEG image to a Google Play store listing edit session via the media upload endpoint.
    package func uploadImage(
        packageName: String,
        editId: String,
        language: String,
        imageType: GooglePlayImageType,
        fileUrl: URL
    ) async throws -> GooglePlayImage {
        let ext = fileUrl.pathExtension.lowercased()
        let contentType: String
        switch ext {
        case "png":
            contentType = "image/png"
        case "jpg", "jpeg":
            contentType = "image/jpeg"
        default:
            throw GooglePlayImageError.unsupportedFileExtension(fileUrl.pathExtension)
        }

        let fileData = try Data(contentsOf: fileUrl)
        guard !fileData.isEmpty else {
            throw GooglePlayImageError.invalidResponse("Image file is empty (0 bytes): \(fileUrl.path)")
        }

        let encodedPackage = Self.encodePathSegment(packageName)
        let encodedEdit = Self.encodePathSegment(editId)
        let encodedLanguage = Self.encodePathSegment(language)
        let urlString = "https://androidpublisher.googleapis.com/upload/androidpublisher/v3/applications/\(encodedPackage)/edits/\(encodedEdit)/listings/\(encodedLanguage)/\(imageType.rawValue)?uploadType=media"

        guard let uploadUrl = URL(string: urlString) else {
            throw GooglePlayImageError.invalidResponse("Invalid image upload URL: \(urlString)")
        }

        let token = try await getAccessToken()
        var request = URLRequest(url: uploadUrl, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")

        let (data, response) = try await urlSession.upload(for: request, from: fileData)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GooglePlayImageError.invalidResponse("Invalid HTTP response received during image upload.")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let msg = Self.parseGoogleErrorMessage(from: data) ?? "HTTP \(httpResponse.statusCode)"
            throw GooglePlayImageError.apiError(status: httpResponse.statusCode, message: msg)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GooglePlayImageError.invalidResponse("Failed to parse JSON response from image upload.")
        }

        let imageDict = (json["image"] as? [String: Any]) ?? json
        guard let id = imageDict["id"] as? String, !id.isEmpty else {
            throw GooglePlayImageError.invalidResponse("Image upload response missing image ID.")
        }

        return GooglePlayImage(
            id: id,
            url: imageDict["url"] as? String,
            sha1: imageDict["sha1"] as? String,
            sha256: imageDict["sha256"] as? String
        )
    }

    /// Converts a Google Play image-serving URL into a full-resolution (`=s0`) download URL.
    package static func fullResolutionImageURL(from rawUrl: String) -> URL? {
        let trimmed = rawUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var components = URLComponents(string: trimmed) else {
            return nil
        }

        if let host = components.host?.lowercased(),
           host == "googleusercontent.com"
            || host.hasSuffix(".googleusercontent.com")
            || host == "ggpht.com"
            || host.hasSuffix(".ggpht.com") {
            let path = components.path
            let lastSlash = path.lastIndex(of: "/")
            let prefix = lastSlash.map { String(path[...$0]) } ?? ""
            let tail = lastSlash.map { String(path[path.index(after: $0)...]) } ?? path

            let updatedTail: String
            if let eqIndex = tail.firstIndex(of: "=") {
                updatedTail = "\(tail[..<eqIndex])=s0"
            } else if !tail.isEmpty {
                updatedTail = "\(tail)=s0"
            } else {
                updatedTail = tail
            }
            components.path = prefix + updatedTail
        }

        return components.url
    }

    /// Downloads raw store image bytes from a Google Play CDN URL.
    package func downloadImageData(from url: URL) async throws -> (data: Data, contentType: String?) {
        var request = URLRequest(url: url, timeoutInterval: 120)
        request.httpMethod = "GET"

        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GooglePlayImageError.invalidResponse("Invalid HTTP response while downloading image from \(url.absoluteString).")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw GooglePlayImageError.apiError(
                status: httpResponse.statusCode,
                message: "Failed to download image from \(url.absoluteString) (HTTP \(httpResponse.statusCode))."
            )
        }

        return (data, httpResponse.value(forHTTPHeaderField: "Content-Type"))
    }

    /// Deletes a single image by ID from a Google Play store listing edit session.
    package func deleteImage(
        packageName: String,
        editId: String,
        language: String,
        imageType: GooglePlayImageType,
        imageId: String
    ) async throws {
        guard let apiType = Operations.androidpublisher_period_edits_period_images_period_delete.Input.Path.imageTypePayload(rawValue: imageType.rawValue) else {
            throw GooglePlayImageError.unsupportedImageType(imageType.rawValue)
        }

        let response = try await client.androidpublisher_period_edits_period_images_period_delete(
            .init(path: .init(
                packageName: packageName,
                editId: editId,
                language: language,
                imageType: apiType,
                imageId: imageId
            ))
        )

        switch response {
        case .ok:
            return
        case .undocumented(let status, let undocumented):
            let msg = await Self.readGoogleError(from: undocumented.body) ?? "HTTP \(status) while deleting image '\(imageId)'."
            throw GooglePlayImageError.apiError(status: status, message: msg)
        }
    }

    /// Deletes all images of a given image type for a language in a Google Play edit session.
    @discardableResult
    package func deleteAllImages(
        packageName: String,
        editId: String,
        language: String,
        imageType: GooglePlayImageType
    ) async throws -> [GooglePlayImage] {
        guard let apiType = Operations.androidpublisher_period_edits_period_images_period_deleteall.Input.Path.imageTypePayload(rawValue: imageType.rawValue) else {
            throw GooglePlayImageError.unsupportedImageType(imageType.rawValue)
        }

        let response = try await client.androidpublisher_period_edits_period_images_period_deleteall(
            .init(path: .init(
                packageName: packageName,
                editId: editId,
                language: language,
                imageType: apiType
            ))
        )

        switch response {
        case .ok(let ok):
            guard case .json(let payload) = ok.body else {
                return []
            }
            return (payload.deleted ?? []).compactMap(GooglePlayImage.init)
        case .undocumented(let status, let undocumented):
            let msg = await Self.readGoogleError(from: undocumented.body) ?? "HTTP \(status) while deleting images."
            throw GooglePlayImageError.apiError(status: status, message: msg)
        }
    }

    // MARK: - Private Helpers

    private static func encodePathSegment(_ raw: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        return raw.addingPercentEncoding(withAllowedCharacters: allowed) ?? raw
    }

    private static func readGoogleError(from body: HTTPBody?) async -> String? {
        guard let body else { return nil }
        guard let data = try? await Data(collecting: body, upTo: 256 * 1024), !data.isEmpty else {
            return nil
        }
        return parseGoogleErrorMessage(from: data)
    }

    private static func parseGoogleErrorMessage(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return text?.isEmpty == false ? text : nil
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
