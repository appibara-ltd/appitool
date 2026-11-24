import ArgumentParser
import Foundation
import GoogleServices
import Rainbow

/// Registers Play App Signing (and other) certificate fingerprints on a Firebase Android app.
struct FirebaseSyncFingerprintsCommand: BaseCommand {
    static let configuration = CommandConfiguration(
        commandName: "sync-fingerprints",
        abstract: "Adds the Play App Signing certificate fingerprints (SHA-1 and SHA-256) to a Firebase Android app."
    )

    @OptionGroup
    var projectOptions: FirebaseProjectOptions

    @Option(name: .customLong("firebase-app-id"), help: "Firebase Android App ID (defaults to FIREBASE_ANDROID_APP_ID in .env, then the app registered for --package-name).")
    var firebaseAppId: String?

    @Option(name: .long, help: "Android package name (defaults to GOOGLE_PACKAGE_NAME in .env or the local Android project).")
    var packageName: String?

    @Option(name: .long, help: "Version code whose Play-generated APKs are read (defaults to the highest version code on your tracks).")
    var versionCode: Int?

    @Flag(name: .long, inversion: .prefixedNo, help: "Read the Play App Signing certificates from Google Play (uses the same --google-key).")
    var play: Bool = true

    @Option(name: .shortAndLong, help: "Additional certificate file(s) or folder(s) to register (.der/.cer/.crt/.pem, e.g. an upload or debug certificate). Repeatable.")
    var file: [String] = []

    @Option(name: .long, help: "Additional SHA-1 fingerprint to register (repeatable; colons optional).")
    var sha1: [String] = []

    @Option(name: .long, help: "Additional SHA-256 fingerprint to register (repeatable; colons optional).")
    var sha256: [String] = []

    @Flag(name: .long, help: "Also remove registered fingerprints that are not in the synced set.")
    var replace: Bool = false

    @Flag(name: .long, help: "Show the changes without applying them.")
    var dryRun: Bool = false

    /// A fingerprint to register, with where it came from.
    struct Fingerprint: Equatable {
        let hash: String
        let type: FirebaseShaCertificate.CertType
        let source: String
    }

    func validate() throws {
        guard play || !file.isEmpty || !sha1.isEmpty || !sha256.isEmpty else {
            throw ValidationError("--no-play needs fingerprints from -f, --file, --sha1, or --sha256.")
        }
        try FirebaseAppSupport.validateFingerprints(sha1: sha1, sha256: sha256)
    }

    func execute() async throws {
        guard let key = projectOptions.resolveKey() else {
            throw ValidationError("Missing Google Service Account key. Provide -g, --google-key or set GOOGLE_KEY in .env.")
        }
        let firebase = try FirebaseService(key: key)
        let explicitAppId = AppIdentifierResolver.firebaseAppId(explicit: firebaseAppId, platform: .android)
        let project = try projectOptions.requireProject(fallbackAppId: explicitAppId)
        let resolvedPackage = AppIdentifierResolver.androidPackageName(explicit: packageName)

        // 1. Collect the fingerprints to register.
        var desired: [Fingerprint] = []
        if play {
            guard let packageName = resolvedPackage else {
                throw ValidationError("Missing Android package name. Provide --package-name, set GOOGLE_PACKAGE_NAME in .env, or run inside an Android project.")
            }
            desired += try await playFingerprints(packageName: packageName, service: try GooglePlayService(key: key))
        }
        for url in file.isEmpty ? [] : try GoogleSigningCertsCommand.certificateFiles(file) {
            let certificate = try APKSigningCertificates.certificate(fromFile: url)
            desired.append(Fingerprint(hash: certificate.sha1, type: .sha1, source: url.lastPathComponent))
            desired.append(Fingerprint(hash: certificate.sha256, type: .sha256, source: url.lastPathComponent))
        }
        desired += sha1.map { Fingerprint(hash: $0, type: .sha1, source: "--sha1") }
        desired += sha256.map { Fingerprint(hash: $0, type: .sha256, source: "--sha256") }

        // 2. Find the Firebase Android app.
        let appId = try await FirebaseAppSupport.resolveAndroidAppId(explicit: explicitAppId, packageName: resolvedPackage, project: project, service: firebase)

        // 3. Compare with what is registered and apply.
        let registered: [FirebaseShaCertificate]
        do {
            registered = try await firebase.listShaCertificates(project: project, appId: appId)
        } catch let error as FirebaseAppsError {
            throw CommandError("Failed to read the app's fingerprints: \(error.localizedDescription)", hint: FirebaseAppSupport.hint(for: error))
        }
        let plan = Self.plan(desired: desired, registered: registered, replace: replace)

        Log("\n🔐 Fingerprints for Firebase app \(appId):".bold)
        for fingerprint in plan.unchanged {
            Log("  ✔ ".green + "\(FirebaseAppSupport.label(fingerprint.type)) \(GoogleSigningCertsCommand.colonHex(fingerprint.hash.uppercased()))".dim + " already registered (\(fingerprint.source))".dim)
        }
        for fingerprint in plan.add {
            Log("  + ".green.bold + "\(FirebaseAppSupport.label(fingerprint.type)) \(GoogleSigningCertsCommand.colonHex(fingerprint.hash.uppercased()))" + " (\(fingerprint.source))".dim)
        }
        for certificate in plan.remove {
            Log("  - ".red.bold + "\(FirebaseAppSupport.label(certificate.certType ?? .unspecified)) \(GoogleSigningCertsCommand.colonHex(certificate.shaHash.uppercased()))" + " (not in the synced set)".dim)
        }
        let extra = registered.count - plan.unchanged.count
        if !replace, extra > 0 {
            Log("  \(extra) other registered fingerprint(s) kept (use --replace to remove them).".dim)
        }

        guard !plan.add.isEmpty || !plan.remove.isEmpty else {
            Log("\n🟢 Firebase already has every fingerprint.".green)
            return
        }
        guard !dryRun else {
            Log("\n🟡 Dry run: \(plan.add.count) to add, \(plan.remove.count) to remove; nothing changed.".yellow)
            return
        }
        do {
            for fingerprint in plan.add {
                try await firebase.addShaCertificate(project: project, appId: appId, hash: fingerprint.hash, type: fingerprint.type)
            }
            for certificate in plan.remove {
                guard let name = certificate.name else { continue }
                try await firebase.deleteShaCertificate(name: name)
            }
        } catch let error as FirebaseAppsError {
            throw CommandError("Failed to update fingerprints: \(error.localizedDescription)", hint: FirebaseAppSupport.hint(for: error))
        }
        Log("\n🟢 Added \(plan.add.count), removed \(plan.remove.count) fingerprint(s).".green.bold)
        Log("   Download a fresh google-services.json if your build embeds it.".dim)
    }

    /// SHA-1 and SHA-256 of every Play App Signing certificate (deployment and hybrid);
    /// only the API's SHA-256 when an APK could not be read.
    private func playFingerprints(packageName: String, service: GooglePlayService) async throws -> [Fingerprint] {
        let code: Int
        if let versionCode {
            code = versionCode
        } else {
            Log("🔍 Finding the latest version code on your tracks...".dim)
            code = try await PlaySigningCertificates.latestVersionCode(packageName: packageName, service: service)
        }
        Log("🔍 Reading Play App Signing certificates for \(packageName) version code \(code)...".dim)
        let keys = try await PlaySigningCertificates.fetch(packageName: packageName, versionCode: code, service: service)
        var result: [Fingerprint] = []
        for key in keys {
            if let failure = key.failure {
                Log("    🟡 \(failure) Only the SHA-256 from the API is synced for this key.".yellow)
            }
            guard !key.certificates.isEmpty else {
                if !key.apiSha256.isEmpty { result.append(Fingerprint(hash: key.apiSha256, type: .sha256, source: "Play App Signing")) }
                continue
            }
            for certificate in key.certificates {
                let source = certificate.schemes.contains("hybrid") && APKSigningCertificates.normalizeHex(certificate.sha256) != key.apiSha256
                    ? "Play hybrid \(certificate.algorithm)"
                    : "Play App Signing"
                result.append(Fingerprint(hash: certificate.sha1, type: .sha1, source: source))
                result.append(Fingerprint(hash: certificate.sha256, type: .sha256, source: source))
            }
        }
        return result
    }

    /// Fingerprints to add (not yet registered, de-duplicated), already registered, and — with `replace` — to remove.
    static func plan(
        desired: [Fingerprint],
        registered: [FirebaseShaCertificate],
        replace: Bool
    ) -> (add: [Fingerprint], unchanged: [Fingerprint], remove: [FirebaseShaCertificate]) {
        let registeredHashes = Set(registered.map { FirebaseShaCertificate.normalize($0.shaHash) })
        var seen: Set<String> = []
        var add: [Fingerprint] = []
        var unchanged: [Fingerprint] = []
        for fingerprint in desired {
            let hash = FirebaseShaCertificate.normalize(fingerprint.hash)
            guard seen.insert(hash).inserted else { continue }
            let normalized = Fingerprint(hash: hash, type: fingerprint.type, source: fingerprint.source)
            if registeredHashes.contains(hash) { unchanged.append(normalized) } else { add.append(normalized) }
        }
        let remove = replace ? registered.filter { !seen.contains(FirebaseShaCertificate.normalize($0.shaHash)) } : []
        return (add, unchanged, remove)
    }
}
