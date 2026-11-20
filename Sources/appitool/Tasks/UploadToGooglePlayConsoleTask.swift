import Foundation
import GooglePlayStoreAPI
import GoogleServices
import Rainbow

/// Result of an upload operation to Google Play Console.
struct UploadToGooglePlayConsoleResult: Sendable {
    let packageName: String
    let editId: String
    let versionCode: Int64
    let track: String
    let releaseStatus: String
    let releaseName: String?
    let sha256: String?

    init(
        packageName: String,
        editId: String,
        versionCode: Int64,
        track: String,
        releaseStatus: String,
        releaseName: String? = nil,
        sha256: String? = nil
    ) {
        self.packageName = packageName
        self.editId = editId
        self.versionCode = versionCode
        self.track = track
        self.releaseStatus = releaseStatus
        self.releaseName = releaseName
        self.sha256 = sha256
    }
}

/// Supported Google Play release statuses for track releases.
enum GooglePlayReleaseStatus: String, Sendable, CaseIterable {
    case completed
    case draft
    case inProgress
    case halted
}

/// Errors thrown by `UploadToGooglePlayConsoleTask`.
enum UploadToGooglePlayConsoleError: LocalizedError, Sendable {
    case fileNotFound(String)
    case unsupportedFileType(String)
    case missingPackageName
    case editCreationFailed(String)
    case uploadFailed(String)
    case trackUpdateFailed(String)
    case commitFailed(String)

    var errorDescription: String? {
        switch self {
        case .fileNotFound(let path):
            return "Binary file not found at path: \(path)"
        case .unsupportedFileType(let ext):
            return "Unsupported binary file extension '.\(ext)'. Expected .aab or .apk."
        case .missingPackageName:
            return "Application package name could not be resolved from input or android project."
        case .editCreationFailed(let message):
            return "Failed to create Google Play edit session: \(message)"
        case .uploadFailed(let message):
            return "Failed to upload binary to Google Play Console: \(message)"
        case .trackUpdateFailed(let message):
            return "Failed to update track in Google Play Console: \(message)"
        case .commitFailed(let message):
            return "Failed to commit Google Play edit session: \(message)"
        }
    }
}

/// A task that uploads an Android App Bundle (.aab) or APK (.apk) to Google Play Console,
/// assigns it to a release track (internal, alpha, beta, production), adds release notes, and commits the edit.
struct UploadToGooglePlayConsoleTask: Task {
    struct Input: Sendable {
        /// File path to the `.aab` or `.apk` binary.
        let binaryPath: String

        /// Initialized GooglePlayService client.
        let service: GooglePlayService

        /// Target package name (e.g. `com.example.app`). If nil, resolved automatically via AndroidTasks.
        let packageName: String?

        /// Target release track (e.g. `internal`, `alpha`, `beta`, `production`). Defaults to `internal`.
        let track: String

        /// Target release status (`completed`, `draft`, `inProgress`, `halted`). Defaults to `completed`.
        let releaseStatus: GooglePlayReleaseStatus

        /// Optional release name (e.g. `1.0.0 (42)`).
        let releaseName: String?

        /// Optional release notes text.
        let releaseNotes: String?

        /// Language code for release notes (e.g. `en-US`). Defaults to `en-US`.
        let releaseNotesLanguage: String

        /// Fraction of users for staged rollout (0.0 < fraction < 1.0; used when status is `inProgress` or `halted`).
        let userFraction: Double?

        /// Whether changes should not be sent for review until explicitly sent from the Play Console UI.
        let changesNotSentForReview: Bool

        /// Whether to acknowledge installation warning for large bundles.
        let ackBundleInstallationWarning: Bool

        /// Whether to only validate the edit without committing.
        let validateOnly: Bool

        init(
            binaryPath: String,
            service: GooglePlayService,
            packageName: String? = nil,
            track: String = "internal",
            releaseStatus: GooglePlayReleaseStatus = .completed,
            releaseName: String? = nil,
            releaseNotes: String? = nil,
            releaseNotesLanguage: String = "en-US",
            userFraction: Double? = nil,
            changesNotSentForReview: Bool = false,
            ackBundleInstallationWarning: Bool = false,
            validateOnly: Bool = false
        ) {
            self.binaryPath = binaryPath
            self.service = service
            self.packageName = packageName
            self.track = track
            self.releaseStatus = releaseStatus
            self.releaseName = releaseName
            self.releaseNotes = releaseNotes
            self.releaseNotesLanguage = releaseNotesLanguage
            self.userFraction = userFraction
            self.changesNotSentForReview = changesNotSentForReview
            self.ackBundleInstallationWarning = ackBundleInstallationWarning
            self.validateOnly = validateOnly
        }
    }

    init() {}

    @discardableResult
    func run(_ input: Input) async throws -> UploadToGooglePlayConsoleResult {
        let binaryUrl = URL(fileURLWithPath: input.binaryPath)
        guard FileManager.default.fileExists(atPath: binaryUrl.path) else {
            throw UploadToGooglePlayConsoleError.fileNotFound(input.binaryPath)
        }

        let ext = binaryUrl.pathExtension.lowercased()
        guard ["aab", "apk"].contains(ext) else {
            throw UploadToGooglePlayConsoleError.unsupportedFileType(binaryUrl.pathExtension)
        }

        // 1. Resolve package name
        let packageName = try resolvePackageName(input)

        // 2. Create edit session
        Log("📝 Creating Google Play edit session for '\(packageName)'...".dim)
        let editId: String
        do {
            editId = try await input.service.createEdit(packageName: packageName)
        } catch {
            throw UploadToGooglePlayConsoleError.editCreationFailed(error.localizedDescription)
        }
        Log("   ✓ Edit session created: \(editId)".dim)

        var isCommitted = false
        defer {
            if !isCommitted {
                _Concurrency.Task {
                    _ = try? await input.service.deleteEdit(packageName: packageName, editId: editId)
                }
            }
        }

        // 3. Upload binary
        Log("📤 Uploading \(binaryUrl.lastPathComponent) to Google Play Console...".dim)
        let versionCode: Int64
        let sha256: String?

        do {
            if ext == "aab" {
                let result = try await input.service.uploadBundle(
                    packageName: packageName,
                    editId: editId,
                    fileUrl: binaryUrl,
                    ackBundleInstallationWarning: input.ackBundleInstallationWarning
                )
                versionCode = result.versionCode
                sha256 = result.sha256
                Log("   ✓ Android App Bundle uploaded (versionCode: \(versionCode))".green)
            } else {
                let result = try await input.service.uploadApk(
                    packageName: packageName,
                    editId: editId,
                    fileUrl: binaryUrl
                )
                versionCode = result.versionCode
                sha256 = result.sha256
                Log("   ✓ APK uploaded (versionCode: \(versionCode))".green)
            }
        } catch {
            throw UploadToGooglePlayConsoleError.uploadFailed(error.localizedDescription)
        }

        // 4. Update release track
        Log("🎯 Assigning release to track '\(input.track)' (\(input.releaseStatus.rawValue))...".dim)

        var releaseNotesList: [Components.Schemas.LocalizedText]?
        if let notes = input.releaseNotes, !notes.isEmpty {
            releaseNotesList = [
                Components.Schemas.LocalizedText(
                    language: input.releaseNotesLanguage,
                    text: notes
                )
            ]
        }

        let releaseName = input.releaseName ?? "\(versionCode)"
        let statusPayload = Components.Schemas.TrackRelease.statusPayload(rawValue: input.releaseStatus.rawValue)

        let trackRelease = Components.Schemas.TrackRelease(
            name: releaseName,
            releaseNotes: releaseNotesList,
            status: statusPayload,
            userFraction: input.userFraction,
            versionCodes: [String(versionCode)]
        )

        do {
            _ = try await input.service.updateTrack(
                packageName: packageName,
                editId: editId,
                track: input.track,
                releases: [trackRelease]
            )
            Log("   ✓ Track '\(input.track)' updated successfully".green)
        } catch {
            throw UploadToGooglePlayConsoleError.trackUpdateFailed(error.localizedDescription)
        }

        // 5. Commit or validate edit session
        do {
            if input.validateOnly {
                Log("🔍 Validating edit session without committing...".dim)
                _ = try await input.service.validateEdit(packageName: packageName, editId: editId)
                Log("   ✓ Google Play edit session validated successfully.".green)
            } else {
                Log("🚀 Committing Google Play edit session...".dim)
                _ = try await input.service.commitEdit(
                    packageName: packageName,
                    editId: editId,
                    changesNotSentForReview: input.changesNotSentForReview
                )
                isCommitted = true
                Log("   ✓ Edit session committed. Release published to track '\(input.track)'!".green.bold)
            }
        } catch {
            throw UploadToGooglePlayConsoleError.commitFailed(error.localizedDescription)
        }

        return UploadToGooglePlayConsoleResult(
            packageName: packageName,
            editId: editId,
            versionCode: versionCode,
            track: input.track,
            releaseStatus: input.releaseStatus.rawValue,
            releaseName: releaseName,
            sha256: sha256
        )
    }

    // MARK: - Private Helpers

    private func resolvePackageName(_ input: Input) throws -> String {
        if let packageName = input.packageName, !packageName.isEmpty {
            return packageName
        }
        if let detected = AndroidTasks.resolvePackageName() {
            return detected
        }
        throw UploadToGooglePlayConsoleError.missingPackageName
    }
}
