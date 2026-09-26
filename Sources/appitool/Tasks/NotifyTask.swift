import Crypto
import Foundation
import Rainbow

/// A task that dispatches notifications to configured webhook channels (Slack, KokoNo).
struct NotifyTask: Task {
    enum Provider: String, Sendable, CaseIterable {
        case slack
        case kokono

        var displayName: String {
            switch self {
            case .slack: return "Slack"
            case .kokono: return "KokoNo"
            }
        }
    }

    enum Status: String, Sendable {
        case success
        case failure

        var emoji: String {
            switch self {
            case .success: return "🎉"
            case .failure: return "💥"
            }
        }

        var colorHex: String {
            switch self {
            case .success: return "#2EB67D" // Slack green
            case .failure: return "#E01E5A" // Slack red
            }
        }
    }

    struct Input: Sendable {
        let provider: Provider
        let status: Status
        let title: String
        let message: String
        let metadata: [String: String]
        let kokonoUrl: String?
        let kokonoPublicKey: String?

        init(
            provider: Provider,
            status: Status,
            title: String,
            message: String,
            metadata: [String: String] = [:],
            kokonoUrl: String? = nil,
            kokonoPublicKey: String? = nil
        ) {
            self.provider = provider
            self.status = status
            self.title = title
            self.message = message
            self.metadata = metadata
            self.kokonoUrl = kokonoUrl
            self.kokonoPublicKey = kokonoPublicKey
        }
    }

    enum NotifyError: LocalizedError, Sendable {
        case missingWebhookUrl(String)
        case invalidWebhookUrl(String)
        case invalidPublicKey(String)
        case requestFailed(statusCode: Int, response: String)

        var errorDescription: String? {
            switch self {
            case .missingWebhookUrl(let provider):
                return "Missing URL for \(provider). Check your .env configuration."
            case .invalidWebhookUrl(let url):
                return "Invalid URL: \(url)"
            case .invalidPublicKey(let reason):
                return "Invalid KokoNo public key: \(reason)"
            case .requestFailed(let code, let response):
                return "Notification request failed with HTTP \(code): \(response)"
            }
        }
    }

    // MARK: - Task Runner

    func run(_ input: Input) async throws {
        switch input.provider {
        case .slack:
            try await sendSlackNotification(input)
        case .kokono:
            try await sendKokoNoNotification(input)
        }
    }

    /// Dispatches notification to all providers that have their webhook URL configured in environment.
    func notifyAllConfigured(
        status: Status,
        title: String,
        message: String,
        metadata: [String: String] = [:],
        kokonoUrl: String? = nil,
        kokonoPublicKey: String? = nil
    ) async {
        let env = ProcessInfo.processInfo.environment

        if env["SLACK_URL"] != nil {
            do {
                try await run(.init(
                    provider: .slack,
                    status: status,
                    title: title,
                    message: message,
                    metadata: metadata
                ))
                print("   ✓ ".green.bold + "Slack notification sent successfully.".dim)
            } catch {
                print("   ⚠️  Failed to send Slack notification: \(error.localizedDescription)".yellow)
            }
        }

        let resolvedUrl = kokonoUrl ?? env["KOKONO_URL"]
        if let resolvedUrl, !resolvedUrl.isEmpty {
            // Per-URL Keypair Isolation:
            // If URL is explicitly provided via option, public key MUST also be provided via option.
            // If not provided, it must NOT fall back to .env's key and should remain unencrypted.
            let resolvedKey: String?
            if kokonoUrl != nil {
                resolvedKey = kokonoPublicKey
            } else {
                resolvedKey = kokonoPublicKey ?? env["KOKONO_E2E_PUBLIC_KEY"]
            }

            do {
                try await run(.init(
                    provider: .kokono,
                    status: status,
                    title: title,
                    message: message,
                    metadata: metadata,
                    kokonoUrl: resolvedUrl,
                    kokonoPublicKey: resolvedKey
                ))
                print("   ✓ ".green.bold + "KokoNo notification sent successfully.".dim)
            } catch {
                print("   ⚠️  Failed to send KokoNo notification: \(error.localizedDescription)".yellow)
            }
        }
    }

    // MARK: - Slack Provider

    private func sendSlackNotification(_ input: Input) async throws {
        guard let urlString = ProcessInfo.processInfo.environment["SLACK_URL"], !urlString.isEmpty else {
            throw NotifyError.missingWebhookUrl("Slack (SLACK_URL)")
        }

        guard let url = URL(string: urlString) else {
            throw NotifyError.invalidWebhookUrl(urlString)
        }

        // Format metadata fields
        let fields = input.metadata.map { key, value in
            [
                "title": key,
                "value": value,
                "short": true
            ] as [String: Any]
        }

        let payload: [String: Any] = [
            "attachments": [
                [
                    "color": input.status.colorHex,
                    "title": "\(input.status.emoji) \(input.title)",
                    "text": input.message,
                    "fields": fields,
                    "footer": "appitool flow",
                    "ts": Int(Date().timeIntervalSince1970)
                ] as [String: Any]
            ]
        ]

        let jsonData = try JSONSerialization.data(withJSONObject: payload, options: [])

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData

        let (data, response) = try await URLSession.shared.data(for: request)
        if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
            let respStr = String(data: data, encoding: .utf8) ?? ""
            throw NotifyError.requestFailed(statusCode: httpResponse.statusCode, response: respStr)
        }
    }

    // MARK: - KokoNo Provider

    struct KokoNoEncryptedData: Sendable {
        let key: String // Base64 encoded raw X25519 public key (32 bytes)
        let iv: String // Base64 encoded 12-byte IV
        let ciphertext: String // Base64 encoded ciphertext
        let tag: String // Base64 encoded 16-byte authentication tag
    }

    /// Encrypts a message using ECIES Curve25519 (X25519) + HKDF-SHA256 + AES-256-GCM (matching KokoNo protocol).
    private func encryptKokoNo(message: String, recipientPublicKeyB64: String) throws -> KokoNoEncryptedData {
        guard let recipientKeyData = Data(base64Encoded: recipientPublicKeyB64) else {
            throw NotifyError.invalidPublicKey("Recipient public key is not valid Base64.")
        }

        let recipientPublicKey: Curve25519.KeyAgreement.PublicKey
        do {
            recipientPublicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: recipientKeyData)
        } catch {
            throw NotifyError.invalidPublicKey("Failed to parse X25519 public key: \(error.localizedDescription)")
        }

        // 1. Generate ephemeral key pair
        let ephemeralPrivateKey = Curve25519.KeyAgreement.PrivateKey()
        let ephemeralPublicKeyRaw = ephemeralPrivateKey.publicKey.rawRepresentation

        // 2. Compute shared secret via Diffie-Hellman
        let sharedSecret: SharedSecret
        do {
            sharedSecret = try ephemeralPrivateKey.sharedSecretFromKeyAgreement(with: recipientPublicKey)
        } catch {
            throw NotifyError.invalidPublicKey("Key agreement failed: \(error.localizedDescription)")
        }

        // 3. Derive symmetric key using HKDF-SHA256
        guard let salt = "kokono-salt-v1".data(using: .utf8),
              let info = "kokono-info-v1".data(using: .utf8) else {
            throw NotifyError.invalidPublicKey("Failed to encode HKDF salt/info.")
        }

        let derivedKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt,
            sharedInfo: info,
            outputByteCount: 32
        )

        // 4. Generate random 12-byte IV / nonce
        let nonce = AES.GCM.Nonce()

        // 5. Encrypt message using AES-256-GCM
        guard let messageData = message.data(using: .utf8) else {
            throw NotifyError.invalidPublicKey("Failed to encode message as UTF-8.")
        }

        let sealedBox: AES.GCM.SealedBox
        do {
            sealedBox = try AES.GCM.seal(messageData, using: derivedKey, nonce: nonce)
        } catch {
            throw NotifyError.invalidPublicKey("AES-GCM encryption failed: \(error.localizedDescription)")
        }

        return KokoNoEncryptedData(
            key: ephemeralPublicKeyRaw.base64EncodedString(),
            iv: Data(sealedBox.nonce).base64EncodedString(),
            ciphertext: sealedBox.ciphertext.base64EncodedString(),
            tag: sealedBox.tag.base64EncodedString()
        )
    }

    private func sendKokoNoNotification(_ input: Input) async throws {
        guard let urlString = input.kokonoUrl ?? ProcessInfo.processInfo.environment["KOKONO_URL"], !urlString.isEmpty else {
            throw NotifyError.missingWebhookUrl("KokoNo (KOKONO_URL)")
        }

        guard let components = URLComponents(string: urlString), let _ = components.url else {
            throw NotifyError.invalidWebhookUrl(urlString)
        }

        // Extract token from query parameter "?token=..." or URL
        guard let token = components.queryItems?.first(where: { $0.name == "token" })?.value, !token.isEmpty else {
            throw NotifyError.missingWebhookUrl("KokoNo token in KOKONO_URL (expected ?token=<token>)")
        }

        // Endpoint URL without query parameters (defaults to https://kokono.me/notify)
        var endpointComponents = components
        endpointComponents.query = nil
        guard let endpointUrl = endpointComponents.url else {
            throw NotifyError.invalidWebhookUrl(urlString)
        }

        // Per-URL Keypair Isolation:
        // If kokonoUrl is explicitly provided, public key MUST also be explicitly provided via option.
        // It must NOT fall back to .env's key because keys are strictly tied to specific URLs.
        let publicKey: String?
        if input.kokonoUrl != nil {
            publicKey = input.kokonoPublicKey
        } else {
            publicKey = input.kokonoPublicKey ?? ProcessInfo.processInfo.environment["KOKONO_E2E_PUBLIC_KEY"]
        }

        let payload: [String: Any]
        if let publicKey, !publicKey.isEmpty {
            // E2E Encrypted Payload
            let encryptedTitle = try encryptKokoNo(message: input.title, recipientPublicKeyB64: publicKey)
            let encryptedMessage = try encryptKokoNo(message: input.message, recipientPublicKeyB64: publicKey)

            payload = [
                "token": token,
                "encrypted": 1,
                "title": [
                    "key": encryptedTitle.key,
                    "iv": encryptedTitle.iv,
                    "ciphertext": encryptedTitle.ciphertext,
                    "tag": encryptedTitle.tag
                ],
                "message": [
                    "key": encryptedMessage.key,
                    "iv": encryptedMessage.iv,
                    "ciphertext": encryptedMessage.ciphertext,
                    "tag": encryptedMessage.tag
                ]
            ]
        } else {
            // Plaintext Payload
            payload = [
                "token": token,
                "title": input.title,
                "message": input.message
            ]
        }

        let jsonData = try JSONSerialization.data(withJSONObject: payload, options: [])

        var request = URLRequest(url: endpointUrl)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData

        let (data, response) = try await URLSession.shared.data(for: request)
        if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
            let respStr = String(data: data, encoding: .utf8) ?? ""
            throw NotifyError.requestFailed(statusCode: httpResponse.statusCode, response: respStr)
        }

        // Verify JSON response success flag if present
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let success = json["success"] as? Bool, !success {
            let message = (json["message"] as? String) ?? "Unknown KokoNo error"
            throw NotifyError.requestFailed(statusCode: 200, response: message)
        }
    }
}
