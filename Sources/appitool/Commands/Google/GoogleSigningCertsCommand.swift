import ArgumentParser
import Foundation
import GoogleServices
import Rainbow

/// Shows SHA-1 and SHA-256 fingerprints of every certificate Play App Signing uses for a version code.
struct GoogleSigningCertsCommand: BaseCommand {
    static let configuration = CommandConfiguration(
        commandName: "signing-certs",
        abstract: "Shows SHA-1 and SHA-256 of Play App Signing certificates (from Play-generated APKs, or local certificate files with -f)."
    )

    @OptionGroup
    var app: GooglePlayAppOptions

    @Option(name: .long, help: "Version code to inspect (defaults to the highest version code on your tracks).")
    var versionCode: Int?

    @Flag(name: .long, help: "Only show the SHA-256 values reported by the API (no APK download; no SHA-1).")
    var sha256Only: Bool = false

    @Option(name: .shortAndLong, help: "Certificate file(s) or folder(s) to fingerprint locally instead of using the API (.der/.cer/.crt/.pem, e.g. Play Console's deployment_cert.der and hybrid certificates). Repeatable.")
    var file: [String] = []

    func execute() async throws {
        if !file.isEmpty {
            try fingerprintLocalFiles()
            return
        }
        let packageName = try app.requirePackageName()
        let service = try app.requireService()

        let resolvedVersionCode: Int
        if let versionCode {
            resolvedVersionCode = versionCode
        } else {
            Log("🔍 Finding the latest version code on your tracks...".dim)
            let latest = try await GetLatestBuildNumberTask().run(.init(target: .android(packageName: packageName, service: service), distribution: .appstore))
            guard let code = Int(latest.buildNumber) else {
                throw CommandError("Could not determine the latest version code (got '\(latest.buildNumber)').", hint: "Pass --version-code.")
            }
            guard code > 0 else {
                throw CommandError(
                    "\(packageName) has no releases on any track yet, so Play has no generated APKs to read certificates from.",
                    hint: "Upload an app bundle (AAB) first, e.g. to the internal track. Play App Signing certificates exist only after the first upload. If the bundle is uploaded but not in a release, pass its --version-code."
                )
            }
            resolvedVersionCode = code
        }

        Log("🔍 Reading Play-generated APKs for \(packageName) version code \(resolvedVersionCode)...".dim)
        let groups: [GooglePlaySigningKeyApks]
        do {
            groups = try await service.listGeneratedApks(packageName: packageName, versionCode: resolvedVersionCode)
        } catch let error as GooglePlayImageError {
            throw CommandError("Failed to read generated APKs: \(error.localizedDescription)", hint: Self.hint(for: error))
        }
        guard !groups.isEmpty else {
            throw CommandError(
                "Play has no generated APKs for version code \(resolvedVersionCode).",
                hint: "Generated APKs exist for app bundles (AAB) uploaded with Play App Signing; check the version code."
            )
        }

        Log("\n🔐 Play App Signing certificates for \(packageName) (version code \(resolvedVersionCode)):".bold)
        for (index, group) in groups.enumerated() {
            let apiSha256 = APKSigningCertificates.normalizeHex(group.certificateSha256Hash)
            Log("\n  Signing key \(index + 1)".cyan.bold)
            Log("    SHA-256 (API): ".dim + Self.colonHex(apiSha256))

            guard !sha256Only else { continue }
            guard let downloadId = group.downloadIds.first else {
                Log("    🟡 No downloadable APK for this key; SHA-1 unavailable.".yellow)
                continue
            }
            do {
                let apk = try await service.downloadGeneratedApk(packageName: packageName, versionCode: resolvedVersionCode, downloadId: downloadId)
                Log("    (read from a \(ByteCountFormatter.string(fromByteCount: Int64(apk.count), countStyle: .file)) Play-generated APK, kept in memory)".dim)
                let certificates = try APKSigningCertificates.certificates(in: apk)
                for certificate in certificates {
                    let matches = APKSigningCertificates.normalizeHex(certificate.sha256) == apiSha256
                    let note: String
                    if matches {
                        note = " ✔ matches API".green
                    } else if certificate.schemes.contains("hybrid") {
                        note = " (hybrid signing)".cyan
                    } else {
                        note = " (additional / rotated)".yellow
                    }
                    Log("    Certificate [\(certificate.schemes.joined(separator: ", "))] \(certificate.algorithm)".dim + note)
                    Log("      SHA-1:   " + certificate.sha1)
                    Log("      SHA-256: " + certificate.sha256)
                }
            } catch let error as GooglePlayImageError {
                Log("    🟡 APK download failed: \(error.localizedDescription)".yellow)
                if let hint = Self.hint(for: error) { Log("       \(hint)".dim) }
            } catch {
                Log("    🟡 Could not read the APK signature: \(error.localizedDescription)".yellow)
            }
        }
        Log("\n   Upload key certificate: not available through the API; it is your own keystore's certificate (see 'appitool match android').".dim + "\n")
    }

    /// Certificate files from `--file` paths: files as given, folders expanded to their certificate files (sorted).
    static func certificateFiles(_ paths: [String]) throws -> [URL] {
        let extensions: Set<String> = ["der", "cer", "crt", "pem"]
        var urls: [URL] = []
        for raw in paths {
            let url = ScreenshotFileResolver.expandPath(raw)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
                throw CommandError("Certificate file or folder not found: \(raw)")
            }
            if isDir.boolValue {
                let contents = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                urls += contents
                    .filter { extensions.contains($0.pathExtension.lowercased()) }
                    .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            } else {
                urls.append(url)
            }
        }
        guard !urls.isEmpty else {
            throw CommandError("No certificate files (.der, .cer, .crt, .pem) found in: \(paths.joined(separator: ", "))")
        }
        return urls
    }

    private func fingerprintLocalFiles() throws {
        let urls = try Self.certificateFiles(file)
        Log("\n🔐 Certificate fingerprints:".bold)
        for url in urls {
            let certificate = try APKSigningCertificates.certificate(fromFile: url)
            Log("\n  \(url.lastPathComponent)".cyan.bold + " \(certificate.algorithm)".dim)
            Log("    SHA-1:   " + certificate.sha1)
            Log("    SHA-256: " + certificate.sha256)
        }
        Log("")
    }

    /// `AABB…` → `AA:BB:…`
    static func colonHex(_ hex: String) -> String {
        guard !hex.isEmpty else { return "-" }
        var pairs: [String] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            pairs.append(String(hex[index..<next]))
            index = next
        }
        return pairs.joined(separator: ":")
    }

    static func hint(for error: GooglePlayImageError) -> String? {
        guard case .apiError(let status, _) = error else { return nil }
        switch status {
        case 403:
            return "The service account needs release access to the app in Play Console (generated APKs are a release-management feature)."
        case 404:
            return "Check --package-name and --version-code."
        default:
            return nil
        }
    }
}
