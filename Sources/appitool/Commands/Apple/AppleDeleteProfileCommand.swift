import ArgumentParser
import Foundation
import AppleServices
import Rainbow

struct AppleDeleteProfileCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete-profile",
        abstract: "Deletes a single provisioning profile from Apple Developer Portal."
    )

    @OptionGroup
    var appleCredentials: AppleCredentialsOptions

    @Option(name: .shortAndLong, help: "Provisioning profile name to delete.")
    var name: String?

    @Option(name: .shortAndLong, help: "Provisioning profile UUID to delete.")
    var uuid: String?

    @Option(name: .shortAndLong, help: "Provisioning profile Portal ID to delete.")
    var portalId: String?

    func run() async throws {
        _ = try? EnvLoader.loadEnv()

        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUUID = uuid?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedId = portalId?.trimmingCharacters(in: .whitespacesAndNewlines)

        guard (trimmedName != nil && !trimmedName!.isEmpty) ||
              (trimmedUUID != nil && !trimmedUUID!.isEmpty) ||
              (trimmedId != nil && !trimmedId!.isEmpty) else {
            print("Error: ".red.bold + "Missing target profile. Provide -n, --name, -u, --uuid, or -p, --portal-id.")
            return
        }

        guard let service = try appleCredentials.makeService() else {
            print("Error: ".red.bold + "Missing App Store Connect credentials (configure APPLE_KEY, APPLE_KEY_ID, APPLE_ISSUER_ID).")
            return
        }

        let targetDescription = trimmedName ?? trimmedUUID ?? trimmedId ?? "unknown"

        // If direct portal ID is provided without name/UUID search
        if let directId = trimmedId, trimmedName == nil, trimmedUUID == nil {
            print("🗑️ Deleting provisioning profile by ID ".red + "\(directId)".bold + "...".dim)
            do {
                let deleted = try await service.deleteProfile(id: directId)
                if deleted {
                    print("✓ Successfully deleted provisioning profile (ID: \(directId)).".green.bold)
                } else {
                    print("ℹ️ Provisioning profile (ID: '\(directId)') was not found on Apple Developer Portal (already absent).".yellow)
                }
            } catch {
                print("Error: ".red.bold + "Failed to delete provisioning profile: \(error.localizedDescription)")
            }
            return
        }

        print("🔍 Searching for provisioning profile '\(targetDescription)' on Apple Developer Portal...".dim)
        let profiles = try await service.fetchProfiles(limit: 200, name: trimmedName)

        let matched = profiles.first { profile in
            if let targetUUID = trimmedUUID, profile.attributes?.uuid == targetUUID {
                return true
            }
            if let targetName = trimmedName, profile.attributes?.name == targetName {
                return true
            }
            if let targetId = trimmedId, profile.id == targetId {
                return true
            }
            return false
        }

        guard let targetProfile = matched else {
            print("ℹ️ Provisioning profile '\(targetDescription)' does not exist on Apple Developer Portal (already absent).".yellow)
            return
        }

        let matchedName = targetProfile.attributes?.name ?? "unnamed"
        let matchedUUID = targetProfile.attributes?.uuid ?? "-"
        let portalId = targetProfile.id

        print("🗑️ Deleting provisioning profile ".red + "\(matchedName)".bold + " [UUID: \(matchedUUID), Portal ID: \(portalId)]...".dim)

        do {
            let deleted = try await service.deleteProfile(id: portalId)
            if deleted {
                print("✓ Successfully deleted provisioning profile '\(matchedName)'.".green.bold)
            } else {
                print("ℹ️ Provisioning profile '\(matchedName)' was not found or already deleted on Apple Developer Portal.".yellow)
            }
        } catch {
            print("Error: ".red.bold + "Failed to delete provisioning profile: \(error.localizedDescription)")
        }
    }
}
