import Foundation
import AppStoreConnectAPI

/// Utilities for parsing and mapping CLI string representations to App Store Connect API types and schemas.
package struct AppleTypeMapper: Sendable {

    // MARK: - Bundle ID Platforms

    /// Parses a string representation into a `BundleIdPlatform`.
    package static func parseBundleIdPlatform(_ raw: String) throws -> Components.Schemas.BundleIdPlatform {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "universal":
            return .UNIVERSAL
        case "ios":
            return .IOS
        case "macos", "mac":
            return .MAC_OS
        default:
            throw AppStoreServiceError.invalidResponse(
                "Unsupported platform '\(raw)'. Supported: universal, ios, macos."
            )
        }
    }

    // MARK: - Capabilities

    package struct CapabilityDescriptor: Sendable {
        package let category: String
        package let key: String
        package let enumName: String
        package let description: String

        package init(category: String, key: String, enumName: String, description: String) {
            self.category = category
            self.key = key
            self.enumName = enumName
            self.description = description
        }
    }

    /// Complete catalog of supported capabilities with categories, CLI keys, and descriptions.
    package static let supportedCapabilities: [CapabilityDescriptor] = [
        CapabilityDescriptor(category: "Push & Communication", key: "push-notifications", enumName: "PUSH_NOTIFICATIONS", description: "APNs remote push notifications (alias: push)"),
        CapabilityDescriptor(category: "Push & Communication", key: "inter-app-audio", enumName: "INTER_APP_AUDIO", description: "Real-time audio streaming with host apps"),
        CapabilityDescriptor(category: "Push & Communication", key: "coremedia-hls-low-latency", enumName: "COREMEDIA_HLS_LOW_LATENCY", description: "Low-Latency HTTP Live Streaming (HLS)"),
        CapabilityDescriptor(category: "Authentication & Security", key: "sign-in-with-apple", enumName: "APPLE_ID_AUTH", description: "Sign in with Apple authentication (aliases: apple-sign-in, apple-id-auth)"),
        CapabilityDescriptor(category: "Authentication & Security", key: "data-protection", enumName: "DATA_PROTECTION", description: "Hardware-based file-level encryption"),
        CapabilityDescriptor(category: "Authentication & Security", key: "autofill-credential-provider", enumName: "AUTOFILL_CREDENTIAL_PROVIDER", description: "AutoFill password manager extensions"),
        CapabilityDescriptor(category: "App Integration & Domains", key: "associated-domains", enumName: "ASSOCIATED_DOMAINS", description: "Universal Links, App Clips, Web Credentials"),
        CapabilityDescriptor(category: "App Integration & Domains", key: "app-groups", enumName: "APP_GROUPS", description: "Shared container access for App Extensions & Widgets"),
        CapabilityDescriptor(category: "App Integration & Domains", key: "icloud", enumName: "ICLOUD", description: "CloudKit database and iCloud document storage"),
        CapabilityDescriptor(category: "App Integration & Domains", key: "game-center", enumName: "GAME_CENTER", description: "Game Center leaderboards, achievements & multiplayer"),
        CapabilityDescriptor(category: "App Integration & Domains", key: "in-app-purchase", enumName: "IN_APP_PURCHASE", description: "In-App Purchases & StoreKit (alias: iap)"),
        CapabilityDescriptor(category: "Payments & Wallet", key: "apple-pay", enumName: "APPLE_PAY", description: "Apple Pay in-app payment processing"),
        CapabilityDescriptor(category: "Payments & Wallet", key: "wallet", enumName: "WALLET", description: "Passes, tickets, and boarding passes in Apple Wallet (alias: passbook)"),
        CapabilityDescriptor(category: "Hardware & Networking", key: "nfc-tag-reading", enumName: "NFC_TAG_READING", description: "Near Field Communication (NFC) tag reading (alias: nfc)"),
        CapabilityDescriptor(category: "Hardware & Networking", key: "access-wifi-information", enumName: "ACCESS_WIFI_INFORMATION", description: "Access current Wi-Fi network SSID/BSSID (alias: wifi-info)"),
        CapabilityDescriptor(category: "Hardware & Networking", key: "hot-spot", enumName: "HOT_SPOT", description: "Wi-Fi HotSpot network configuration"),
        CapabilityDescriptor(category: "Hardware & Networking", key: "personal-vpn", enumName: "PERSONAL_VPN", description: "Personal VPN tunnels and connections"),
        CapabilityDescriptor(category: "Hardware & Networking", key: "network-extensions", enumName: "NETWORK_EXTENSIONS", description: "Custom network tunnels, DNS proxies, and content filters"),
        CapabilityDescriptor(category: "Hardware & Networking", key: "network-custom-protocol", enumName: "NETWORK_CUSTOM_PROTOCOL", description: "Custom network protocol extensions"),
        CapabilityDescriptor(category: "Hardware & Networking", key: "multipath", enumName: "MULTIPATH", description: "Multipath TCP for concurrent Wi-Fi and Cellular data"),
        CapabilityDescriptor(category: "Hardware & Networking", key: "wireless-accessory-configuration", enumName: "WIRELESS_ACCESSORY_CONFIGURATION", description: "MFi accessory Wi-Fi configuration"),
        CapabilityDescriptor(category: "Health & Home", key: "healthkit", enumName: "HEALTHKIT", description: "HealthKit health and fitness records"),
        CapabilityDescriptor(category: "Health & Home", key: "homekit", enumName: "HOMEKIT", description: "HomeKit smart home automation & accessories"),
        CapabilityDescriptor(category: "Siri & Maps & System", key: "sirikit", enumName: "SIRIKIT", description: "SiriKit voice shortcuts and intents"),
        CapabilityDescriptor(category: "Siri & Maps & System", key: "maps", enumName: "MAPS", description: "MapKit turn-by-turn routing and directions"),
        CapabilityDescriptor(category: "Siri & Maps & System", key: "classkit", enumName: "CLASSKIT", description: "ClassKit student progress & educational activities"),
        CapabilityDescriptor(category: "Siri & Maps & System", key: "system-extension-install", enumName: "SYSTEM_EXTENSION_INSTALL", description: "macOS system extensions & driver extensions"),
        CapabilityDescriptor(category: "Siri & Maps & System", key: "user-management", enumName: "USER_MANAGEMENT", description: "Multi-user management on Shared iPad"),
    ]

    /// Parses a CLI string representation into a `CapabilityType`.
    package static func parseCapability(_ raw: String) -> Components.Schemas.CapabilityType? {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "push", "push-notifications", "push_notifications":
            return .PUSH_NOTIFICATIONS
        case "iap", "in-app-purchase", "in_app_purchase":
            return .IN_APP_PURCHASE
        case "game-center", "game_center":
            return .GAME_CENTER
        case "icloud":
            return .ICLOUD
        case "sign-in-with-apple", "apple-id-auth", "apple_id_auth", "apple-sign-in":
            return .APPLE_ID_AUTH
        case "app-groups", "app_groups":
            return .APP_GROUPS
        case "associated-domains", "associated_domains":
            return .ASSOCIATED_DOMAINS
        case "apple-pay", "apple_pay":
            return .APPLE_PAY
        case "healthkit":
            return .HEALTHKIT
        case "homekit":
            return .HOMEKIT
        case "sirikit":
            return .SIRIKIT
        case "wallet", "passbook":
            return .WALLET
        case "nfc", "nfc-tag-reading", "nfc_tag_reading":
            return .NFC_TAG_READING
        case "maps":
            return .MAPS
        case "personal-vpn", "personal_vpn":
            return .PERSONAL_VPN
        case "network-extensions", "network_extensions":
            return .NETWORK_EXTENSIONS
        case "access-wifi-information", "wifi-info", "access_wifi_information":
            return .ACCESS_WIFI_INFORMATION
        case "data-protection", "data_protection":
            return .DATA_PROTECTION
        case "autofill-credential-provider", "autofill_credential_provider":
            return .AUTOFILL_CREDENTIAL_PROVIDER
        case "classkit":
            return .CLASSKIT
        case "multipath":
            return .MULTIPATH
        case "inter-app-audio", "inter_app_audio":
            return .INTER_APP_AUDIO
        case "wireless-accessory-configuration", "wireless_accessory_configuration":
            return .WIRELESS_ACCESSORY_CONFIGURATION
        case "system-extension-install", "system_extension_install":
            return .SYSTEM_EXTENSION_INSTALL
        case "user-management", "user_management":
            return .USER_MANAGEMENT
        case "coremedia-hls-low-latency", "coremedia_hls_low_latency":
            return .COREMEDIA_HLS_LOW_LATENCY
        case "network-custom-protocol", "network_custom_protocol":
            return .NETWORK_CUSTOM_PROTOCOL
        case "hot-spot", "hot_spot":
            return .HOT_SPOT
        default:
            let rawEnum = raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "-", with: "_").uppercased()
            return Components.Schemas.CapabilityType(rawValue: rawEnum)
        }
    }

    // MARK: - Provisioning Profile Types

    /// Maps platform and distribution type strings to `ProfileCreateRequest...profileTypePayload`.
    package static func mapProfileType(
        type: String,
        platform: String
    ) throws -> Components.Schemas.ProfileCreateRequest.dataPayload.attributesPayload.profileTypePayload {
        let normalizedType = type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedPlatform = platform.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        switch normalizedPlatform {
        case "ios":
            switch normalizedType {
            case "appstore", "app-store": return .IOS_APP_STORE
            case "adhoc", "ad-hoc": return .IOS_APP_ADHOC
            case "development", "dev": return .IOS_APP_DEVELOPMENT
            case "enterprise", "inhouse": return .IOS_APP_INHOUSE
            default:
                throw AppStoreServiceError.invalidResponse("Unsupported profile type '\(type)' for iOS. Supported: appstore, development, adhoc, enterprise")
            }
        case "tvos":
            switch normalizedType {
            case "appstore", "app-store": return .TVOS_APP_STORE
            case "adhoc", "ad-hoc": return .TVOS_APP_ADHOC
            case "development", "dev": return .TVOS_APP_DEVELOPMENT
            case "enterprise", "inhouse": return .TVOS_APP_INHOUSE
            default:
                throw AppStoreServiceError.invalidResponse("Unsupported profile type '\(type)' for tvOS. Supported: appstore, development, adhoc, enterprise")
            }
        case "macos", "mac":
            switch normalizedType {
            case "appstore", "app-store": return .MAC_APP_STORE
            case "adhoc", "ad-hoc", "development", "dev": return .MAC_APP_DEVELOPMENT
            case "enterprise", "developer-id", "developer_id", "direct": return .MAC_APP_DIRECT
            default:
                throw AppStoreServiceError.invalidResponse("Unsupported profile type '\(type)' for macOS. Supported: appstore, development, adhoc, developer_id")
            }
        case "catalyst":
            switch normalizedType {
            case "appstore", "app-store": return .MAC_CATALYST_APP_STORE
            case "adhoc", "ad-hoc", "development", "dev": return .MAC_CATALYST_APP_DEVELOPMENT
            case "enterprise", "developer-id", "developer_id", "direct": return .MAC_CATALYST_APP_DIRECT
            default:
                throw AppStoreServiceError.invalidResponse("Unsupported profile type '\(type)' for Catalyst. Supported: appstore, development, adhoc, developer_id")
            }
        default:
            throw AppStoreServiceError.invalidResponse("Unsupported platform '\(platform)'. Supported: ios, macos, tvos, catalyst")
        }
    }

    /// Resolves certificate types matching a profile distribution type and platform.
    package static func appleCertificateTypesForProfile(
        type: String,
        platform: String
    ) -> [Operations.certificates_getCollection.Input.Query.filter_lbrack_certificateType_rbrack_PayloadPayload] {
        let normalizedType = type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedPlatform = platform.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        switch normalizedType {
        case "development", "dev":
            if normalizedPlatform == "macos" || normalizedPlatform == "mac" {
                return [.DEVELOPMENT, .MAC_APP_DEVELOPMENT]
            }
            return [.DEVELOPMENT, .IOS_DEVELOPMENT]
        case "adhoc", "ad-hoc", "appstore", "app-store", "enterprise", "inhouse":
            if normalizedPlatform == "macos" || normalizedPlatform == "mac" {
                return [.DISTRIBUTION, .MAC_APP_DISTRIBUTION]
            }
            return [.DISTRIBUTION, .IOS_DISTRIBUTION]
        case "developer-id", "developer_id", "direct":
            return [.DEVELOPER_ID_APPLICATION]
        default:
            return [.DISTRIBUTION, .IOS_DISTRIBUTION]
        }
    }

    /// Filters device IDs matching a target platform.
    package static func filterDeviceIds(_ devices: [Components.Schemas.Device], for platform: String) -> [String] {
        let normalizedPlatform = platform.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return devices.compactMap { device in
            guard let cls = device.attributes?.deviceClass else { return device.id }
            switch normalizedPlatform {
            case "ios":
                // Only iPhones, iPads, iPods, and Apple Vision Pro (exclude Macs, TVs, Watches)
                if cls == .MAC || cls == .APPLE_TV || cls == .APPLE_WATCH { return nil }
            case "tvos":
                if cls != .APPLE_TV { return nil }
            case "macos", "mac", "catalyst":
                if cls != .MAC { return nil }
            default:
                break
            }
            return device.id
        }
    }

    /// Checks whether a raw profile type string from the portal matches the requested target profile type and platform.
    package static func matchesProfileType(profTypeStr: String, targetType: String, platform: String) -> Bool {
        let normPlatform = platform.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normTarget = targetType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        let prefixMatches: Bool
        switch normPlatform {
        case "ios": prefixMatches = profTypeStr.hasPrefix("IOS_")
        case "tvos": prefixMatches = profTypeStr.hasPrefix("TVOS_")
        case "macos", "mac": prefixMatches = profTypeStr.hasPrefix("MAC_APP_")
        case "catalyst": prefixMatches = profTypeStr.hasPrefix("MAC_CATALYST_")
        default: prefixMatches = false
        }
        guard prefixMatches else { return false }

        switch normTarget {
        case "appstore", "app-store":
            return profTypeStr.contains("APP_STORE") || profTypeStr.contains("STORE")
        case "adhoc", "ad-hoc":
            return profTypeStr.contains("ADHOC")
        case "development", "dev":
            return profTypeStr.contains("DEVELOPMENT")
        case "enterprise", "inhouse":
            return profTypeStr.contains("INHOUSE") || profTypeStr.contains("DIRECT")
        case "developer-id", "developer_id", "direct":
            return profTypeStr.contains("DIRECT")
        default:
            return false
        }
    }

    // MARK: - Device Filters

    /// Parses string representation to Device Platform query filter.
    package static func parseDevicePlatformFilter(
        _ raw: String
    ) -> Operations.devices_getCollection.Input.Query.filter_lbrack_platform_rbrack_PayloadPayload? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "ios": return .IOS
        case "macos", "mac": return .MAC_OS
        case "universal": return .UNIVERSAL
        default: return nil
        }
    }

    /// Parses string representation to Device Status query filter.
    package static func parseDeviceStatusFilter(
        _ raw: String
    ) -> Operations.devices_getCollection.Input.Query.filter_lbrack_status_rbrack_PayloadPayload? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "enabled", "active", "enable": return .ENABLED
        case "disabled", "inactive", "disable": return .DISABLED
        default: return nil
        }
    }

    // MARK: - Certificate Types

    /// Parses a certificate type string to `CertificateType` and human-readable label.
    package static func parseCertificateType(_ raw: String) throws -> (certType: Components.Schemas.CertificateType, label: String) {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "development", "dev":
            return (.DEVELOPMENT, "Development")
        case "distribution", "dist":
            return (.DISTRIBUTION, "Distribution")
        case "developer-id", "developer_id", "developerid":
            return (.DEVELOPER_ID_APPLICATION, "Developer ID Application")
        case "ios-development":
            return (.IOS_DEVELOPMENT, "iOS Development")
        case "ios-distribution":
            return (.IOS_DISTRIBUTION, "iOS Distribution")
        case "mac-development":
            return (.MAC_APP_DEVELOPMENT, "Mac Development")
        case "mac-distribution":
            return (.MAC_APP_DISTRIBUTION, "Mac App Distribution")
        case "mac-installer":
            return (.MAC_INSTALLER_DISTRIBUTION, "Mac Installer Distribution")
        default:
            throw AppStoreServiceError.invalidResponse(
                "Unsupported certificate type '\(raw)'. Supported: development, distribution, developer-id, ios-development, ios-distribution, mac-development, mac-distribution, mac-installer"
            )
        }
    }

    /// Parses a certificate query filter string to array of API certificate types.
    package static func parseCertificateQueryFilter(
        _ raw: String
    ) -> [Operations.certificates_getCollection.Input.Query.filter_lbrack_certificateType_rbrack_PayloadPayload]? {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }

        switch normalized {
        case "distribution", "dist":
            return [.DISTRIBUTION, .IOS_DISTRIBUTION, .MAC_APP_DISTRIBUTION]
        case "development", "dev":
            return [.DEVELOPMENT, .IOS_DEVELOPMENT, .MAC_APP_DEVELOPMENT]
        case "developer-id", "developer_id", "direct":
            return [.DEVELOPER_ID_APPLICATION]
        case "ios-distribution":
            return [.IOS_DISTRIBUTION, .DISTRIBUTION]
        case "ios-development":
            return [.IOS_DEVELOPMENT, .DEVELOPMENT]
        case "mac-distribution":
            return [.MAC_APP_DISTRIBUTION]
        case "mac-development":
            return [.MAC_APP_DEVELOPMENT]
        default:
            return nil
        }
    }

    // MARK: - User Roles

    /// Assignable App Store Connect user roles (excluding `ACCOUNT_HOLDER`, which cannot be assigned via API).
    package static let supportedUserRoles: [String] = [
        "admin",
        "app-manager",
        "developer",
        "finance",
        "sales",
        "marketing",
        "customer-support",
        "access-to-reports",
        "create-apps",
        "cloud-managed-developer-id",
        "cloud-managed-app-distribution",
        "generate-individual-keys",
    ]

    /// Parses a CLI user role string (kebab-case, snake_case, uppercase, or convenience alias) into a `UserRole`.
    package static func parseUserRole(_ raw: String) throws -> Components.Schemas.UserRole {
        let normalized = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
            .uppercased()

        let resolvedRaw: String
        switch normalized {
        case "SUPPORT":
            resolvedRaw = "CUSTOMER_SUPPORT"
        case "REPORTS":
            resolvedRaw = "ACCESS_TO_REPORTS"
        default:
            resolvedRaw = normalized
        }

        guard let role = Components.Schemas.UserRole(rawValue: resolvedRaw) else {
            throw AppStoreServiceError.invalidResponse(
                "Unsupported user role '\(raw)'. Supported: \(supportedUserRoles.joined(separator: ", "))."
            )
        }
        return role
    }

    /// Parses and deduplicates a list of CLI user role strings while preserving order.
    package static func parseUserRoles(_ rawList: [String]) throws -> [Components.Schemas.UserRole] {
        var result: [Components.Schemas.UserRole] = []
        var seen = Set<String>()

        for raw in rawList {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let role = try parseUserRole(trimmed)
            if seen.insert(role.rawValue).inserted {
                result.append(role)
            }
        }

        guard !result.isEmpty else {
            throw AppStoreServiceError.invalidResponse("At least one user role is required.")
        }
        return result
    }

    /// Parses a CLI user role string into the query filter enum for `GET /v1/users`.
    package static func parseUserRoleQueryFilter(
        _ raw: String
    ) throws -> Operations.users_getCollection.Input.Query.filter_lbrack_roles_rbrack_PayloadPayload {
        let role = try parseUserRole(raw)
        guard let filterRole = Operations.users_getCollection.Input.Query.filter_lbrack_roles_rbrack_PayloadPayload(rawValue: role.rawValue) else {
            throw AppStoreServiceError.invalidResponse(
                "Unsupported user role filter '\(raw)'."
            )
        }
        return filterRole
    }

    /// Parses a CLI user role string into the query filter enum for `GET /v1/userInvitations`.
    package static func parseUserInvitationRoleQueryFilter(
        _ raw: String
    ) throws -> Operations.userInvitations_getCollection.Input.Query.filter_lbrack_roles_rbrack_PayloadPayload {
        let role = try parseUserRole(raw)
        guard let filterRole = Operations.userInvitations_getCollection.Input.Query.filter_lbrack_roles_rbrack_PayloadPayload(rawValue: role.rawValue) else {
            throw AppStoreServiceError.invalidResponse(
                "Unsupported user invitation role filter '\(raw)'."
            )
        }
        return filterRole
    }

    // MARK: - App Store Versions & Screenshots

    package struct ScreenshotDisplayTypeDescriptor: Sendable {
        package let category: String
        package let key: String
        package let enumName: String
        package let aliases: [String]
        package let description: String

        package init(
            category: String,
            key: String,
            enumName: String,
            aliases: [String] = [],
            description: String
        ) {
            self.category = category
            self.key = key
            self.enumName = enumName
            self.aliases = aliases
            self.description = description
        }
    }

    /// Complete catalog of supported App Store Connect screenshot display types.
    package static let supportedScreenshotDisplayTypes: [ScreenshotDisplayTypeDescriptor] = [
        // iPhone
        ScreenshotDisplayTypeDescriptor(category: "iPhone", key: "iphone-67", enumName: "APP_IPHONE_67", aliases: ["iphone-6.7", "iphone-69", "iphone-6.9"], description: "iPhone 6.7\" / 6.9\" Display (Pro Max / Plus)"),
        ScreenshotDisplayTypeDescriptor(category: "iPhone", key: "iphone-65", enumName: "APP_IPHONE_65", aliases: ["iphone-6.5"], description: "iPhone 6.5\" Display"),
        ScreenshotDisplayTypeDescriptor(category: "iPhone", key: "iphone-61", enumName: "APP_IPHONE_61", aliases: ["iphone-6.1"], description: "iPhone 6.1\" / 6.3\" Display"),
        ScreenshotDisplayTypeDescriptor(category: "iPhone", key: "iphone-58", enumName: "APP_IPHONE_58", aliases: ["iphone-5.8"], description: "iPhone 5.8\" Display"),
        ScreenshotDisplayTypeDescriptor(category: "iPhone", key: "iphone-55", enumName: "APP_IPHONE_55", aliases: ["iphone-5.5"], description: "iPhone 5.5\" Display"),
        ScreenshotDisplayTypeDescriptor(category: "iPhone", key: "iphone-47", enumName: "APP_IPHONE_47", aliases: ["iphone-4.7"], description: "iPhone 4.7\" Display"),
        ScreenshotDisplayTypeDescriptor(category: "iPhone", key: "iphone-40", enumName: "APP_IPHONE_40", aliases: ["iphone-4.0"], description: "iPhone 4.0\" Display"),
        ScreenshotDisplayTypeDescriptor(category: "iPhone", key: "iphone-35", enumName: "APP_IPHONE_35", aliases: ["iphone-3.5"], description: "iPhone 3.5\" Display"),
        // iPad
        ScreenshotDisplayTypeDescriptor(category: "iPad", key: "ipad-pro-129", enumName: "APP_IPAD_PRO_3GEN_129", aliases: ["ipad-pro-3gen-129", "ipad-13"], description: "iPad Pro 12.9\" (3rd+ Gen) / 13\" Display"),
        ScreenshotDisplayTypeDescriptor(category: "iPad", key: "ipad-pro-11", enumName: "APP_IPAD_PRO_3GEN_11", aliases: ["ipad-pro-3gen-11", "ipad-11"], description: "iPad Pro 11\" Display"),
        ScreenshotDisplayTypeDescriptor(category: "iPad", key: "ipad-pro-129-2gen", enumName: "APP_IPAD_PRO_129", aliases: ["ipad-129", "ipad-12.9"], description: "iPad Pro 12.9\" (2nd Gen) Display"),
        ScreenshotDisplayTypeDescriptor(category: "iPad", key: "ipad-105", enumName: "APP_IPAD_105", aliases: ["ipad-10.5"], description: "iPad 10.5\" Display"),
        ScreenshotDisplayTypeDescriptor(category: "iPad", key: "ipad-97", enumName: "APP_IPAD_97", aliases: ["ipad-9.7"], description: "iPad 9.7\" Display"),
        // Mac, Watch, TV, Vision
        ScreenshotDisplayTypeDescriptor(category: "Mac", key: "mac", enumName: "APP_DESKTOP", aliases: ["desktop", "macos"], description: "Mac Desktop Display"),
        ScreenshotDisplayTypeDescriptor(category: "Apple Watch", key: "watch-ultra", enumName: "APP_WATCH_ULTRA", aliases: [], description: "Apple Watch Ultra Display"),
        ScreenshotDisplayTypeDescriptor(category: "Apple Watch", key: "watch-10", enumName: "APP_WATCH_SERIES_10", aliases: ["watch-series-10"], description: "Apple Watch Series 10 Display"),
        ScreenshotDisplayTypeDescriptor(category: "Apple Watch", key: "watch-7", enumName: "APP_WATCH_SERIES_7", aliases: ["watch-series-7"], description: "Apple Watch Series 7 / 8 / 9 Display"),
        ScreenshotDisplayTypeDescriptor(category: "Apple Watch", key: "watch-4", enumName: "APP_WATCH_SERIES_4", aliases: ["watch-series-4"], description: "Apple Watch Series 4 / 5 / 6 Display"),
        ScreenshotDisplayTypeDescriptor(category: "Apple Watch", key: "watch-3", enumName: "APP_WATCH_SERIES_3", aliases: ["watch-series-3"], description: "Apple Watch Series 3 Display"),
        ScreenshotDisplayTypeDescriptor(category: "Apple TV", key: "apple-tv", enumName: "APP_APPLE_TV", aliases: ["tv"], description: "Apple TV Display"),
        ScreenshotDisplayTypeDescriptor(category: "Apple Vision Pro", key: "vision-pro", enumName: "APP_APPLE_VISION_PRO", aliases: ["vision", "visionos"], description: "Apple Vision Pro Display"),
        // iMessage
        ScreenshotDisplayTypeDescriptor(category: "iMessage", key: "imessage-iphone-67", enumName: "IMESSAGE_APP_IPHONE_67", aliases: [], description: "iMessage iPhone 6.7\" Display"),
        ScreenshotDisplayTypeDescriptor(category: "iMessage", key: "imessage-iphone-65", enumName: "IMESSAGE_APP_IPHONE_65", aliases: [], description: "iMessage iPhone 6.5\" Display"),
        ScreenshotDisplayTypeDescriptor(category: "iMessage", key: "imessage-iphone-61", enumName: "IMESSAGE_APP_IPHONE_61", aliases: [], description: "iMessage iPhone 6.1\" Display"),
        ScreenshotDisplayTypeDescriptor(category: "iMessage", key: "imessage-iphone-58", enumName: "IMESSAGE_APP_IPHONE_58", aliases: [], description: "iMessage iPhone 5.8\" Display"),
        ScreenshotDisplayTypeDescriptor(category: "iMessage", key: "imessage-iphone-55", enumName: "IMESSAGE_APP_IPHONE_55", aliases: [], description: "iMessage iPhone 5.5\" Display"),
        ScreenshotDisplayTypeDescriptor(category: "iMessage", key: "imessage-iphone-47", enumName: "IMESSAGE_APP_IPHONE_47", aliases: [], description: "iMessage iPhone 4.7\" Display"),
        ScreenshotDisplayTypeDescriptor(category: "iMessage", key: "imessage-iphone-40", enumName: "IMESSAGE_APP_IPHONE_40", aliases: [], description: "iMessage iPhone 4.0\" Display"),
        ScreenshotDisplayTypeDescriptor(category: "iMessage", key: "imessage-ipad-pro-129", enumName: "IMESSAGE_APP_IPAD_PRO_3GEN_129", aliases: ["imessage-ipad-pro-3gen-129"], description: "iMessage iPad Pro 12.9\" (3rd+ Gen) Display"),
        ScreenshotDisplayTypeDescriptor(category: "iMessage", key: "imessage-ipad-pro-11", enumName: "IMESSAGE_APP_IPAD_PRO_3GEN_11", aliases: ["imessage-ipad-pro-3gen-11"], description: "iMessage iPad Pro 11\" Display"),
        ScreenshotDisplayTypeDescriptor(category: "iMessage", key: "imessage-ipad-pro-129-2gen", enumName: "IMESSAGE_APP_IPAD_PRO_129", aliases: ["imessage-ipad-129"], description: "iMessage iPad Pro 12.9\" (2nd Gen) Display"),
        ScreenshotDisplayTypeDescriptor(category: "iMessage", key: "imessage-ipad-105", enumName: "IMESSAGE_APP_IPAD_105", aliases: [], description: "iMessage iPad 10.5\" Display"),
        ScreenshotDisplayTypeDescriptor(category: "iMessage", key: "imessage-ipad-97", enumName: "IMESSAGE_APP_IPAD_97", aliases: [], description: "iMessage iPad 9.7\" Display"),
    ]

    /// Parses a CLI platform string into `Components.Schemas.Platform`.
    package static func parsePlatform(_ raw: String) throws -> Components.Schemas.Platform {
        let normalized = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "_")
            .uppercased()
        switch normalized {
        case "IOS":
            return .IOS
        case "MACOS", "MAC", "MAC_OS":
            return .MAC_OS
        case "TVOS", "TV", "TV_OS":
            return .TV_OS
        case "VISIONOS", "VISION", "VISION_PRO", "VISION_OS":
            return .VISION_OS
        default:
            throw AppStoreServiceError.invalidResponse(
                "Unsupported App Store platform '\(raw)'. Supported: ios, macos, tvos, visionos."
            )
        }
    }

    /// Parses a CLI display type key, alias, or raw enum string into `Components.Schemas.ScreenshotDisplayType`.
    package static func parseScreenshotDisplayType(_ raw: String) throws -> Components.Schemas.ScreenshotDisplayType {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AppStoreServiceError.invalidResponse(
                "Screenshot display type cannot be empty. Run 'appitool apple assets types' to see supported values."
            )
        }

        let lowered = trimmed.lowercased().replacingOccurrences(of: "_", with: "-")
        for descriptor in supportedScreenshotDisplayTypes {
            if descriptor.key == lowered || descriptor.aliases.contains(lowered) {
                if let matched = Components.Schemas.ScreenshotDisplayType(rawValue: descriptor.enumName) {
                    return matched
                }
            }
        }

        let upper = trimmed
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
            .uppercased()

        if let direct = Components.Schemas.ScreenshotDisplayType(rawValue: upper) {
            return direct
        }
        if !upper.hasPrefix("APP_") && !upper.hasPrefix("IMESSAGE_"),
           let prefixed = Components.Schemas.ScreenshotDisplayType(rawValue: "APP_\(upper)") {
            return prefixed
        }

        throw AppStoreServiceError.invalidResponse(
            "Unsupported type '\(raw)'. Run 'appitool apple assets types' to see supported values (screenshot display types, header, search)."
        )
    }

    /// Returns the preferred friendly CLI key for a `ScreenshotDisplayType` (falling back to kebab-case).
    package static func cliKey(for displayType: Components.Schemas.ScreenshotDisplayType) -> String {
        if let match = supportedScreenshotDisplayTypes.first(where: { $0.enumName == displayType.rawValue }) {
            return match.key
        }
        return displayType.rawValue.lowercased().replacingOccurrences(of: "_", with: "-")
    }
}
