import Foundation
import GoogleServices
import Rainbow

/// Result of an upload operation to Firebase App Distribution.
struct UploadToFirebaseResult: Sendable {
    let releaseName: String
    let displayVersion: String?
    let buildVersion: String?
    let binaryDownloadUri: String?
    let firebaseConsoleUri: String?
    let testingUri: String?

    init(
        releaseName: String,
        displayVersion: String?,
        buildVersion: String?,
        binaryDownloadUri: String?,
        firebaseConsoleUri: String?,
        testingUri: String?
    ) {
        self.releaseName = releaseName
        self.displayVersion = displayVersion
        self.buildVersion = buildVersion
        self.binaryDownloadUri = binaryDownloadUri
        self.firebaseConsoleUri = firebaseConsoleUri
        self.testingUri = testingUri
    }
}

/// Errors thrown by `UploadToFirebaseTask`.
enum UploadToFirebaseError: LocalizedError, Sendable {
    case fileNotFound(String)
    case unsupportedFileType(String)
    case missingReleaseName

    var errorDescription: String? {
        switch self {
        case .fileNotFound(let path):
            return "Binary file not found at path: \(path)"
        case .unsupportedFileType(let ext):
            return "Unsupported binary file extension '.\(ext)'. Expected .apk, .aab, or .ipa."
        case .missingReleaseName:
            return "Firebase upload completed but release resource name is missing."
        }
    }
}

/// A task that uploads an APK, AAB, or IPA binary to Firebase App Distribution,
/// attaches release notes, and distributes to test groups via `FirebaseService`.
struct UploadToFirebaseTask: Task {
    struct Input: Sendable {
        /// The file path to the APK, AAB, or IPA binary.
        let binaryPath: String

        /// The Firebase App ID (format: `1:1234567890:ios:abcdef...`).
        let firebaseAppId: String

        /// Initialized FirebaseService client.
        let service: FirebaseService

        /// Optional release notes string for testers.
        let releaseNotes: String?

        /// Optional tester group aliases (e.g. `qa-team`, `testers`).
        let testGroups: [String]?

        /// Optional individual tester email addresses.
        let testerEmails: [String]?

        init(
            binaryPath: String,
            firebaseAppId: String,
            service: FirebaseService,
            releaseNotes: String? = nil,
            testGroups: [String]? = nil,
            testerEmails: [String]? = nil
        ) {
            self.binaryPath = binaryPath
            self.firebaseAppId = firebaseAppId
            self.service = service
            self.releaseNotes = releaseNotes
            self.testGroups = testGroups
            self.testerEmails = testerEmails
        }

        /// Convenience initializer accepting a single test group alias.
        init(
            binaryPath: String,
            firebaseAppId: String,
            service: FirebaseService,
            releaseNotes: String? = nil,
            testGroup: String?,
            testerEmails: [String]? = nil
        ) {
            self.init(
                binaryPath: binaryPath,
                firebaseAppId: firebaseAppId,
                service: service,
                releaseNotes: releaseNotes,
                testGroups: testGroup.flatMap { $0.isEmpty ? nil : [$0] },
                testerEmails: testerEmails
            )
        }
    }

    init() {}

    @discardableResult
    func run(_ input: Input) async throws -> UploadToFirebaseResult {
        let binaryUrl = URL(fileURLWithPath: input.binaryPath)
        guard FileManager.default.fileExists(atPath: binaryUrl.path) else {
            throw UploadToFirebaseError.fileNotFound(input.binaryPath)
        }

        let ext = binaryUrl.pathExtension.lowercased()
        guard ["apk", "aab", "ipa"].contains(ext) else {
            throw UploadToFirebaseError.unsupportedFileType(binaryUrl.pathExtension)
        }

        // 1. Upload binary via FirebaseService
        Log("📤 Uploading \(binaryUrl.lastPathComponent) to Firebase App Distribution...".dim)
        let release = try await input.service.upload(
            fileUrl: binaryUrl,
            firebaseAppId: input.firebaseAppId
        )

        guard let releaseResourceName = release.name else {
            throw UploadToFirebaseError.missingReleaseName
        }

        let versionDisplay = release.displayVersion ?? "unknown"
        let buildDisplay = release.buildVersion ?? "unknown"
        Log("✓ Release created: v\(versionDisplay) (\(buildDisplay)) [\(releaseResourceName)]".green)

        // 2. Attach release notes via FirebaseService
        if let notes = input.releaseNotes, !notes.isEmpty {
            Log("   📝 Adding release notes...".dim)
            try await input.service.addReleaseNotes(
                releaseName: releaseResourceName,
                releaseNotes: notes
            )
            Log("✓ Release notes attached.".green)
        }

        // 3. Distribute release to test groups and/or testers via FirebaseService
        let hasGroups = input.testGroups != nil && input.testGroups?.isEmpty == false
        let hasTesters = input.testerEmails != nil && input.testerEmails?.isEmpty == false

        if hasGroups || hasTesters {
            let groupsDisplay = input.testGroups?.joined(separator: ", ") ?? "none"
            Log("👥 Distributing release to groups: [\(groupsDisplay)]...".dim)
            try await input.service.distribute(
                releaseName: releaseResourceName,
                groupAliases: input.testGroups,
                testerEmails: input.testerEmails
            )
            Log("✓ Distributed release successfully.".green)
        }

        return UploadToFirebaseResult(
            releaseName: releaseResourceName,
            displayVersion: release.displayVersion,
            buildVersion: release.buildVersion,
            binaryDownloadUri: release.binaryDownloadUri,
            firebaseConsoleUri: release.firebaseConsoleUri,
            testingUri: release.testingUri
        )
    }
}
