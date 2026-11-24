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
            resolvedVersionCode = try await PlaySigningCertificates.latestVersionCode(packageName: packageName, service: service)
        }

        Log("🔍 Reading Play-generated APKs for \(packageName) version code \(resolvedVersionCode)...".dim)
        let keys = try await PlaySigningCertificates.fetch(
            packageName: packageName, versionCode: resolvedVersionCode, service: service, downloadApks: !sha256Only
        )

        Log("\n🔐 Play App Signing certificates for \(packageName) (version code \(resolvedVersionCode)):".bold)
        for (index, key) in keys.enumerated() {
            Log("\n  Signing key \(index + 1)".cyan.bold)
            Log("    SHA-256 (API): ".dim + Self.colonHex(key.apiSha256))
            if let failure = key.failure {
                Log("    🟡 \(failure)".yellow)
            }
            for certificate in key.certificates {
                let note: String
                if APKSigningCertificates.normalizeHex(certificate.sha256) == key.apiSha256 {
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
}
