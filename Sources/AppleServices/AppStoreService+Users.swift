import Foundation
import AppStoreConnectAPI

extension AppStoreService {
    // MARK: - App ID Resolution

    /// Resolves mixed App Store Connect App IDs (numeric strings) and bundle identifiers into unique App IDs.
    package func resolveAppIds(_ identifiers: [String]) async throws -> [String] {
        var resolved: [String] = []
        var seen = Set<String>()

        for raw in identifiers {
            let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { continue }

            let appId: String
            if clean.allSatisfy({ $0.isASCII && $0.isNumber }) {
                appId = clean
            } else {
                let apps = try await fetchApps(limit: 5, bundleId: clean)
                guard let matched = apps.first(where: { $0.attributes?.bundleId == clean }) else {
                    throw AppStoreServiceError.notFound("App with bundle ID '\(clean)' was not found in App Store Connect.")
                }
                appId = matched.id
            }

            if seen.insert(appId).inserted {
                resolved.append(appId)
            }
        }

        return resolved
    }

    // MARK: - Users Operations

    /// Fetches active App Store Connect team users with optional filters and auto-pagination.
    package func fetchUsers(
        username: String? = nil,
        roles: [String] = [],
        visibleAppIds: [String] = [],
        limit: Int? = nil
    ) async throws -> [Components.Schemas.User] {
        let cleanUsername = username?.trimmingCharacters(in: .whitespacesAndNewlines)
        let roleFilters = try roles
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { try AppleTypeMapper.parseUserRoleQueryFilter($0) }
        let cleanAppIds = visibleAppIds
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let pageLimit = min(limit ?? 200, 200)
        let response = try await execute {
            try await client.users_getCollection(query: .init(
                filter_lbrack_username_rbrack_: (cleanUsername?.isEmpty == false) ? [cleanUsername!] : nil,
                filter_lbrack_roles_rbrack_: roleFilters.isEmpty ? nil : roleFilters,
                filter_lbrack_visibleApps_rbrack_: cleanAppIds.isEmpty ? nil : cleanAppIds,
                limit: pageLimit
            ))
        }
        guard case .ok(let okResp) = response, case .json(let collection) = okResp.body else {
            return []
        }

        return try await paginate(
            initialItems: collection.data,
            initialNext: collection.links.next,
            limit: limit
        ) { (nextPage: Components.Schemas.UsersResponse) in
            (nextPage.data, nextPage.links.next)
        }
    }

    /// Finds an active team user by resource ID or username (Apple ID email).
    package func findUser(identifier: String) async throws -> Components.Schemas.User? {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.contains("@") {
            let filtered = try await fetchUsers(username: trimmed)
            if let matched = filtered.first(where: {
                $0.attributes?.username?.caseInsensitiveCompare(trimmed) == .orderedSame
            }) {
                return matched
            }
        }

        let allUsers = try await fetchUsers()
        for user in allUsers {
            if user.id == trimmed {
                return user
            }
            if let username = user.attributes?.username,
               username.caseInsensitiveCompare(trimmed) == .orderedSame {
                return user
            }
        }
        return nil
    }

    /// Updates an active team user's roles, app visibility, or provisioning permission.
    package func updateUser(
        id: String,
        roles: [String]? = nil,
        allAppsVisible: Bool? = nil,
        provisioningAllowed: Bool? = nil,
        visibleAppIds: [String]? = nil
    ) async throws -> Components.Schemas.User {
        let cleanId = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanId.isEmpty else {
            throw AppStoreServiceError.invalidResponse("User ID cannot be empty.")
        }

        let parsedRoles: [Components.Schemas.UserRole]?
        if let roles {
            let parsed = try AppleTypeMapper.parseUserRoles(roles)
            if parsed.contains(.ACCOUNT_HOLDER) {
                throw AppStoreServiceError.invalidResponse("ACCOUNT_HOLDER role cannot be assigned via user update.")
            }
            parsedRoles = parsed
        } else {
            parsedRoles = nil
        }

        let cleanVisibleAppIds: [String]? = visibleAppIds.map { ids in
            var seen = Set<String>()
            return ids
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && seen.insert($0).inserted }
        }

        if allAppsVisible == true, let cleanVisibleAppIds, !cleanVisibleAppIds.isEmpty {
            throw AppStoreServiceError.invalidResponse("Cannot specify visibleApps when allAppsVisible is true.")
        }

        let resolvedAllAppsVisible: Bool? = allAppsVisible
            ?? ((cleanVisibleAppIds?.isEmpty == false) ? false : nil)

        let hasAttributes = parsedRoles != nil || resolvedAllAppsVisible != nil || provisioningAllowed != nil
        guard hasAttributes || cleanVisibleAppIds != nil else {
            throw AppStoreServiceError.invalidResponse(
                "At least one update parameter (roles, allAppsVisible, provisioningAllowed, or visibleApps) must be provided."
            )
        }

        let payload = Components.Schemas.UserUpdateRequest(
            data: .init(
                _type: .users,
                id: cleanId,
                attributes: hasAttributes ? .init(
                    roles: parsedRoles,
                    allAppsVisible: resolvedAllAppsVisible,
                    provisioningAllowed: provisioningAllowed
                ) : nil,
                relationships: cleanVisibleAppIds.map { ids in
                    .init(visibleApps: .init(data: ids.map { .init(_type: .apps, id: $0) }))
                }
            )
        )

        let response = try await execute {
            try await client.users_updateInstance(path: .init(id: cleanId), body: .json(payload))
        }
        switch response {
        case .ok(let okResp):
            guard case .json(let userResp) = okResp.body else {
                throw AppStoreServiceError.invalidResponse("Invalid response format when updating user.")
            }
            return userResp.data
        default:
            throw AppStoreServiceError.invalidResponse("Unexpected response when updating user.")
        }
    }

    /// Removes a user from the App Store Connect team.
    package func deleteUser(id: String) async throws -> Bool {
        let cleanId = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanId.isEmpty else {
            throw AppStoreServiceError.invalidResponse("User ID cannot be empty.")
        }

        let response = try await execute {
            try await client.users_deleteInstance(path: .init(id: cleanId))
        }
        switch response {
        case .noContent:
            return true
        case .notFound:
            return false
        default:
            return false
        }
    }

    // MARK: - User Invitations Operations

    /// Fetches pending App Store Connect user invitations with optional filters and auto-pagination.
    package func fetchUserInvitations(
        email: String? = nil,
        roles: [String] = [],
        visibleAppIds: [String] = [],
        limit: Int? = nil
    ) async throws -> [Components.Schemas.UserInvitation] {
        let cleanEmail = email?.trimmingCharacters(in: .whitespacesAndNewlines)
        let roleFilters = try roles
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { try AppleTypeMapper.parseUserInvitationRoleQueryFilter($0) }
        let cleanAppIds = visibleAppIds
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let pageLimit = min(limit ?? 200, 200)
        let response = try await execute {
            try await client.userInvitations_getCollection(query: .init(
                filter_lbrack_email_rbrack_: (cleanEmail?.isEmpty == false) ? [cleanEmail!] : nil,
                filter_lbrack_roles_rbrack_: roleFilters.isEmpty ? nil : roleFilters,
                filter_lbrack_visibleApps_rbrack_: cleanAppIds.isEmpty ? nil : cleanAppIds,
                limit: pageLimit
            ))
        }
        guard case .ok(let okResp) = response, case .json(let collection) = okResp.body else {
            return []
        }

        return try await paginate(
            initialItems: collection.data,
            initialNext: collection.links.next,
            limit: limit
        ) { (nextPage: Components.Schemas.UserInvitationsResponse) in
            (nextPage.data, nextPage.links.next)
        }
    }

    /// Finds a pending user invitation by resource ID or email address.
    package func findUserInvitation(identifier: String) async throws -> Components.Schemas.UserInvitation? {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.contains("@") {
            let filtered = try await fetchUserInvitations(email: trimmed)
            if let matched = filtered.first(where: {
                $0.attributes?.email?.caseInsensitiveCompare(trimmed) == .orderedSame
            }) {
                return matched
            }
        }

        let allInvitations = try await fetchUserInvitations()
        for invitation in allInvitations {
            if invitation.id == trimmed {
                return invitation
            }
            if let email = invitation.attributes?.email,
               email.caseInsensitiveCompare(trimmed) == .orderedSame {
                return invitation
            }
        }
        return nil
    }

    /// Sends an email invitation to join the App Store Connect team with the given roles and app access.
    package func inviteUser(
        email: String,
        firstName: String,
        lastName: String,
        roles: [String],
        allAppsVisible: Bool? = nil,
        provisioningAllowed: Bool? = nil,
        visibleAppIds: [String] = []
    ) async throws -> Components.Schemas.UserInvitation {
        let cleanEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanFirstName = firstName.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanLastName = lastName.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleanEmail.isEmpty else {
            throw AppStoreServiceError.invalidResponse("Email cannot be empty.")
        }
        guard !cleanFirstName.isEmpty else {
            throw AppStoreServiceError.invalidResponse("First name cannot be empty.")
        }
        guard !cleanLastName.isEmpty else {
            throw AppStoreServiceError.invalidResponse("Last name cannot be empty.")
        }

        let parsedRoles = try AppleTypeMapper.parseUserRoles(roles)
        if parsedRoles.contains(.ACCOUNT_HOLDER) {
            throw AppStoreServiceError.invalidResponse("ACCOUNT_HOLDER role cannot be assigned via user invitation.")
        }

        var seenApps = Set<String>()
        let cleanAppIds = visibleAppIds
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seenApps.insert($0).inserted }

        if allAppsVisible == true && !cleanAppIds.isEmpty {
            throw AppStoreServiceError.invalidResponse("Cannot specify visibleApps when allAppsVisible is true.")
        }

        let resolvedAllAppsVisible = allAppsVisible ?? cleanAppIds.isEmpty
        let payload = Components.Schemas.UserInvitationCreateRequest(
            data: .init(
                _type: .userInvitations,
                attributes: .init(
                    email: cleanEmail,
                    firstName: cleanFirstName,
                    lastName: cleanLastName,
                    roles: parsedRoles,
                    allAppsVisible: resolvedAllAppsVisible,
                    provisioningAllowed: provisioningAllowed
                ),
                relationships: cleanAppIds.isEmpty ? nil : .init(
                    visibleApps: .init(data: cleanAppIds.map { .init(_type: .apps, id: $0) })
                )
            )
        )

        let response = try await execute {
            try await client.userInvitations_createInstance(body: .json(payload))
        }
        switch response {
        case .created(let createdResp):
            guard case .json(let invitationResp) = createdResp.body else {
                throw AppStoreServiceError.invalidResponse("Invalid response format when creating user invitation.")
            }
            return invitationResp.data
        default:
            throw AppStoreServiceError.invalidResponse("Unexpected response when creating user invitation.")
        }
    }

    /// Cancels (revokes) a pending user invitation in App Store Connect.
    package func cancelUserInvitation(id: String) async throws -> Bool {
        let cleanId = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanId.isEmpty else {
            throw AppStoreServiceError.invalidResponse("Invitation ID cannot be empty.")
        }

        let response = try await execute {
            try await client.userInvitations_deleteInstance(path: .init(id: cleanId))
        }
        switch response {
        case .noContent:
            return true
        case .notFound:
            return false
        default:
            return false
        }
    }
}
