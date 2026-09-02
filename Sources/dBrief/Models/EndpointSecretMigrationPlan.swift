import Foundation

struct EndpointSecretMigrationCandidate: Equatable, Sendable {
    let endpointID: UUID
    let secret: String
}

/// Pure migration contract used to move legacy endpoint secrets to Keychain.
/// Phase 3 will perform the actual Keychain writes; this type guarantees that
/// plaintext is scrubbed only for writes the caller verified as successful.
struct EndpointSecretMigrationPlan: Equatable, Sendable {
    private let legacyEndpoints: [Endpoint]
    let candidates: [EndpointSecretMigrationCandidate]

    init(legacyEndpoints: [Endpoint]) {
        self.legacyEndpoints = legacyEndpoints
        self.candidates = legacyEndpoints.compactMap { endpoint in
            guard !endpoint.apiKey.isEmpty else { return nil }
            return EndpointSecretMigrationCandidate(
                endpointID: endpoint.id,
                secret: endpoint.apiKey
            )
        }
    }

    /// Returns endpoints safe to persist after the supplied Keychain writes.
    /// Failed or unattempted secrets remain in their legacy location so a
    /// transient Keychain error cannot destroy a user's credentials.
    func endpointsAfterPersisting(successfulEndpointIDs: Set<UUID>) -> [Endpoint] {
        legacyEndpoints.map { endpoint in
            guard successfulEndpointIDs.contains(endpoint.id), !endpoint.apiKey.isEmpty else {
                return endpoint
            }
            var scrubbed = endpoint
            scrubbed.apiKey = ""
            return scrubbed
        }
    }
}
