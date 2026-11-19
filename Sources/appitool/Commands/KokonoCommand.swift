import ArgumentParser
import Foundation
import Rainbow

struct KokonoCommand: BaseCommand {
    static let configuration = CommandConfiguration(
        commandName: "kokono",
        abstract: "Sends a push notification via KokoNo (with optional E2E encryption)."
    )

    @Option(name: .shortAndLong, help: "Notification title.")
    var title: String = "appitool"

    @Option(name: .shortAndLong, help: "Notification message.")
    var message: String

    @Option(name: [.customShort("u"), .customLong("url"), .long], help: "KokoNo notification URL (defaults to KOKONO_URL in .env).")
    var url: String?

    @Option(name: [.customShort("e"), .customLong("e2e"), .long], help: "Optional KokoNo public key for end-to-end (E2E) encryption (defaults to KOKONO_E2E_PUBLIC_KEY in .env).")
    var e2e: String?

    func execute() async throws {
        let resolvedUrl = url ?? EnvLoader.value(for: "KOKONO_URL")
        guard let resolvedUrl, !resolvedUrl.isEmpty else {
            throw CommandError("Missing KokoNo URL. Provide -u, --url or configure KOKONO_URL in .env.")
        }

        // Per-URL Keypair Isolation:
        // If URL is explicitly provided via option, public key must also be explicitly provided via option.
        // If not provided, it must NOT fall back to .env's key and should remain unencrypted.
        let resolvedPublicKey: String?
        if url != nil {
            resolvedPublicKey = e2e
        } else {
            resolvedPublicKey = e2e ?? EnvLoader.value(for: "KOKONO_E2E_PUBLIC_KEY")
        }

        let task = NotifyTask()

        do {
            try await task.run(.init(
                provider: .kokono,
                status: .success,
                title: title,
                message: message,
                kokonoUrl: resolvedUrl,
                kokonoPublicKey: resolvedPublicKey
            ))
            Log("🟢 KokoNo notification sent successfully.".bold)
        } catch {
            throw CommandError("Failed to send KokoNo notification: \(error.localizedDescription)")
        }
    }
}
