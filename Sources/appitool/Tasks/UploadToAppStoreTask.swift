import AppleServices
import Foundation
import Rainbow
import Subprocess
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Result of an upload to App Store Connect (TestFlight / App Store).
struct UploadToAppStoreResult: Sendable {
    let buildUploadId: String
    let version: String
    let buildNumber: String
    let state: BuildUploadStatus.State
    /// Resulting build resource ID (only available once processing completed).
    let buildId: String?
    let warnings: [String]
}

/// Errors thrown by `UploadToAppStoreTask`.
enum UploadToAppStoreError: LocalizedError, Sendable {
    case fileNotFound(String)
    case unsupportedFileType(String)
    case missingAppIdentifier
    case appNotFound(bundleId: String)
    case missingVersionInfo(String)
    case chunkUploadFailed(index: Int, status: Int?, message: String)
    case processingFailed(errors: [String])
    case processingTimeout(buildUploadId: String)

    var errorDescription: String? {
        switch self {
        case .fileNotFound(let path):
            return "IPA file not found at path: \(path)"
        case .unsupportedFileType(let ext):
            return "Unsupported file extension '.\(ext)'. Expected .ipa."
        case .missingAppIdentifier:
            return "Either an App Store Connect app ID or a bundle ID must be provided."
        case .appNotFound(let bundleId):
            return "No app with bundle ID '\(bundleId)' was found in App Store Connect."
        case .missingVersionInfo(let reason):
            return "Could not determine version/build number from IPA: \(reason)"
        case .chunkUploadFailed(let index, let status, let message):
            let code = status.map { " (HTTP \($0))" } ?? ""
            return "Uploading chunk #\(index + 1) failed\(code): \(message)"
        case .processingFailed(let errors):
            let details = errors.isEmpty ? "No details provided." : errors.joined(separator: "; ")
            return "App Store Connect failed to process the build: \(details)"
        case .processingTimeout(let id):
            return "Timed out waiting for App Store Connect to process build upload '\(id)'."
        }
    }
}

/// A task that uploads an `.ipa` to App Store Connect using the build upload API
/// (`buildUploads` → `buildUploadFiles` → chunk uploads → commit) via `AppStoreService`.
struct UploadToAppStoreTask: Task {
    struct Input: Sendable {
        /// Path to the `.ipa` file.
        let ipaPath: String

        /// Initialized App Store Connect client.
        let service: AppStoreService

        /// App Store Connect app ID (numeric). Takes precedence over `bundleId`.
        let appId: String?

        /// Bundle identifier used to resolve the app when `appId` is not provided.
        let bundleId: String?

        /// `CFBundleShortVersionString`. Read from the IPA's Info.plist when nil.
        let version: String?

        /// `CFBundleVersion`. Read from the IPA's Info.plist when nil.
        let buildNumber: String?

        let platform: BuildUploadPlatform

        /// TestFlight "What to Test" text. When provided, it is applied once the build finished processing
        /// (this forces waiting for processing, since the build must exist first).
        let changelog: String?

        /// Locale of the changelog (e.g. `en-US`, `tr`).
        let changelogLocale: String

        /// Whether to wait until App Store Connect finished processing the upload.
        let waitForProcessing: Bool

        /// Seconds between processing state polls.
        let pollInterval: TimeInterval

        /// Maximum seconds to wait for processing.
        let processingTimeout: TimeInterval

        init(
            ipaPath: String,
            service: AppStoreService,
            appId: String? = nil,
            bundleId: String? = nil,
            version: String? = nil,
            buildNumber: String? = nil,
            platform: BuildUploadPlatform = .ios,
            changelog: String? = nil,
            changelogLocale: String = "en-US",
            waitForProcessing: Bool = false,
            pollInterval: TimeInterval = 15,
            processingTimeout: TimeInterval = 30 * 60
        ) {
            self.ipaPath = ipaPath
            self.service = service
            self.appId = appId
            self.bundleId = bundleId
            self.version = version
            self.buildNumber = buildNumber
            self.platform = platform
            self.changelog = changelog
            self.changelogLocale = changelogLocale
            self.waitForProcessing = waitForProcessing
            self.pollInterval = pollInterval
            self.processingTimeout = processingTimeout
        }
    }

    init() {}

    @discardableResult
    func run(_ input: Input) async throws -> UploadToAppStoreResult {
        let ipaUrl = URL(fileURLWithPath: input.ipaPath)
        guard FileManager.default.fileExists(atPath: ipaUrl.path) else {
            throw UploadToAppStoreError.fileNotFound(input.ipaPath)
        }
        guard ipaUrl.pathExtension.lowercased() == "ipa" else {
            throw UploadToAppStoreError.unsupportedFileType(ipaUrl.pathExtension)
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: ipaUrl.path)
        let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0

        // 1. Resolve app and version info
        let appId = try await resolveAppId(input)
        let (version, buildNumber) = try await resolveVersionInfo(input, ipaUrl: ipaUrl)

        // 2. Reserve build upload + file
        Log("📤 Creating App Store Connect build upload (\(version) (\(buildNumber)))...".dim)
        let buildUploadId = try await input.service.createBuildUpload(
            appId: appId,
            version: version,
            buildNumber: buildNumber,
            platform: input.platform
        )
        let reservation = try await input.service.createBuildUploadFile(
            buildUploadId: buildUploadId,
            fileName: ipaUrl.lastPathComponent,
            fileSize: fileSize
        )

        // 3. Upload content chunk by chunk
        Log(
            "📤 Uploading \(ipaUrl.lastPathComponent) (\(Self.formatBytes(fileSize))) in \(reservation.operations.count) part(s)..."
                .dim)
        try await uploadAll(operations: reservation.operations, from: ipaUrl)

        // 4. Commit
        try await commitWithRetry(
            service: input.service,
            fileId: reservation.id,
            buildUploadId: buildUploadId
        )
        Log("   ✓ Upload committed, App Store Connect is processing the build.".green)

        guard input.waitForProcessing else {
            return UploadToAppStoreResult(
                buildUploadId: buildUploadId,
                version: version,
                buildNumber: buildNumber,
                state: .processing,
                buildId: nil,
                warnings: []
            )
        }

        // 5. Wait for processing
        let status = try await waitForProcessing(
            buildUploadId: buildUploadId,
            service: input.service,
            pollInterval: input.pollInterval,
            timeout: input.processingTimeout
        )
        return UploadToAppStoreResult(
            buildUploadId: buildUploadId,
            version: version,
            buildNumber: buildNumber,
            state: status.state,
            buildId: status.buildId,
            warnings: status.warnings
        )
    }

    // MARK: - Resolution

    private func resolveAppId(_ input: Input) async throws -> String {
        if let appId = input.appId, !appId.isEmpty { return appId }
        guard let bundleId = input.bundleId, !bundleId.isEmpty else {
            throw UploadToAppStoreError.missingAppIdentifier
        }
        let apps = try await input.service.fetchApps(limit: 1, bundleId: bundleId)
        guard let app = apps.first else {
            throw UploadToAppStoreError.appNotFound(bundleId: bundleId)
        }
        return app.id
    }

    /// Uses explicit values when provided, otherwise reads them from the IPA's embedded Info.plist
    /// (the values App Store Connect will validate against).
    private func resolveVersionInfo(_ input: Input, ipaUrl: URL) async throws -> (
        version: String, buildNumber: String
    ) {
        if let version = input.version, let buildNumber = input.buildNumber {
            return (version, buildNumber)
        }
        let embedded = try await Self.readInfoPlist(fromIpa: ipaUrl)
        guard let version = input.version ?? embedded["CFBundleShortVersionString"] as? String
        else {
            throw UploadToAppStoreError.missingVersionInfo("CFBundleShortVersionString not found")
        }
        guard let buildNumber = input.buildNumber ?? embedded["CFBundleVersion"] as? String else {
            throw UploadToAppStoreError.missingVersionInfo("CFBundleVersion not found")
        }
        return (version, buildNumber)
    }

    private static func readInfoPlist(fromIpa ipaUrl: URL) async throws -> [String: Any] {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent(
            "appitool-ipa-\(UUID().uuidString)")
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        let result = try await Subprocess.run(
            .name("unzip"),
            arguments: ["-o", "-q", ipaUrl.path, "Payload/*.app/Info.plist", "-d", tempDir.path],
            output: .discarded,
            error: .discarded
        )
        guard case .exited(0) = result.terminationStatus else {
            throw UploadToAppStoreError.missingVersionInfo("unzip failed to extract Info.plist")
        }

        let payloadDir = tempDir.appendingPathComponent("Payload")
        guard
            let appName = (try? fm.contentsOfDirectory(atPath: payloadDir.path))?.first(where: {
                $0.hasSuffix(".app")
            }),
            let data = fm.contents(
                atPath: payloadDir.appendingPathComponent(appName).appendingPathComponent(
                    "Info.plist"
                ).path),
            let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil))
                as? [String: Any]
        else {
            throw UploadToAppStoreError.missingVersionInfo(
                "Payload/*.app/Info.plist not found or unreadable")
        }
        return plist
    }

    // MARK: - Chunk Upload
    private func uploadAll(
        operations: [BuildUploadOperation],
        from fileUrl: URL,
        maxConcurrent: Int = 6
    ) async throws {
        let total = operations.count
        let width = String(total).count
        var completed = 0
        var iterator = operations.enumerated().makeIterator()

        try await withThrowingTaskGroup(of: Int.self) { group in
            // İlk dalga
            for _ in 0..<min(max(1, maxConcurrent), total) {
                guard let (index, operation) = iterator.next() else { break }
                group.addTask {
                    try await self.upload(operation: operation, index: index, from: fileUrl)
                    return index
                }
            }

            // Biri bitince sıradakini başlat
            while try await group.next() != nil {
                completed += 1
                let done = String(completed).leftPad(to: width)
                let all = String(total).leftPad(to: width)
                Log("   Part \(done)/\(all) uploaded".dim)

                if let (index, operation) = iterator.next() {
                    group.addTask {
                        try await self.upload(operation: operation, index: index, from: fileUrl)
                        return index
                    }
                }
            }
        }
    }

    private func upload(operation: BuildUploadOperation, index: Int, from fileUrl: URL) async throws
    {
        guard let url = URL(string: operation.url) else {
            throw UploadToAppStoreError.chunkUploadFailed(
                index: index, status: nil, message: "Invalid upload URL.")
        }

        let handle = try FileHandle(forReadingFrom: fileUrl)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(operation.offset))
        guard let chunk = try handle.read(upToCount: Int(operation.length)),
            chunk.count == Int(operation.length)
        else {
            throw UploadToAppStoreError.chunkUploadFailed(
                index: index, status: nil,
                message: "Could not read \(operation.length) bytes at offset \(operation.offset).")
        }

        var request = URLRequest(url: url)
        request.httpMethod = operation.method
        for header in operation.headers {
            request.setValue(header.value, forHTTPHeaderField: header.name)
        }

        let maxAttempts = 3
        var lastError: UploadToAppStoreError?
        for attempt in 1...maxAttempts {
            do {
                let (_, response) = try await URLSession.shared.upload(for: request, from: chunk)
                let status = (response as? HTTPURLResponse)?.statusCode
                if let status, (200...299).contains(status) { return }
                lastError = .chunkUploadFailed(
                    index: index, status: status, message: "Unexpected response.")
            } catch {
                lastError = .chunkUploadFailed(
                    index: index, status: nil, message: error.localizedDescription)
            }
            if attempt < maxAttempts {
                try await _Concurrency.Task.sleep(nanoseconds: UInt64(attempt) * 2_000_000_000)
            }
        }
        throw lastError
            ?? UploadToAppStoreError.chunkUploadFailed(
                index: index, status: nil, message: "Unknown error.")
    }

    // MARK: - Commit

    private func commitWithRetry(
        service: AppStoreService,
        fileId: String,
        buildUploadId: String,
        maxAttempts: Int = 4
    ) async throws {
        for attempt in 1...maxAttempts {
            do {
                try await service.commitBuildUploadFile(id: fileId)
                return
            } catch AppStoreServiceError.apiError(let status, let message)
                where (status ?? 0) >= 500 || status == 429
            {

                // İstek sunucuda işlenmiş olabilir; durumu kontrol et
                if let s = try? await service.fetchBuildUpload(id: buildUploadId),
                    s.state == .processing || s.state == .complete
                {
                    return
                }
                guard attempt < maxAttempts else {
                    throw AppStoreServiceError.apiError(
                        status: status,
                        message: "Commit failed after \(maxAttempts) attempts: \(message)"
                    )
                }
                Log(
                    "   🟡  Commit failed (HTTP \(status.map(String.init) ?? "?")), retrying (\(attempt)/\(maxAttempts - 1))..."
                        .yellow)
                try await _Concurrency.Task.sleep(
                    nanoseconds: UInt64(attempt * attempt) * 3_000_000_000)
            }
        }
    }

    // MARK: - Processing

    private func waitForProcessing(
        buildUploadId: String,
        service: AppStoreService,
        pollInterval: TimeInterval,
        timeout: TimeInterval
    ) async throws -> BuildUploadStatus {
        Log("⏳ Waiting for App Store Connect to process the build...".dim)
        let deadline = Date().addingTimeInterval(timeout)
        var lastState: BuildUploadStatus.State?

        while true {
            let status = try await service.fetchBuildUpload(id: buildUploadId)
            if status.state != lastState {
                Log("   • State: \(status.state.rawValue)".dim)
                lastState = status.state
            }

            switch status.state {
            case .complete:
                for warning in status.warnings {
                    Log("   🟡  \(warning)".yellow)
                }
                return status
            case .failed:
                throw UploadToAppStoreError.processingFailed(errors: status.errors)
            case .awaitingUpload, .processing, .unknown:
                break
            }

            guard Date() < deadline else {
                throw UploadToAppStoreError.processingTimeout(buildUploadId: buildUploadId)
            }
            try await _Concurrency.Task.sleep(
                nanoseconds: UInt64(max(1, pollInterval) * 1_000_000_000))
        }
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}


private extension String {
    func leftPad(to width: Int, with pad: Character = "0") -> String {
        count >= width ? self : String(repeating: pad, count: width - count) + self
    }
}
