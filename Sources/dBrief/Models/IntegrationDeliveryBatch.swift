import Foundation
import CryptoKit

/// Contains private meeting content, but never credentials or raw error responses.
/// Persisted independently of processing checkpoints so cancellation cannot erase
/// a successful send or an attempt with an unknown outcome.
struct IntegrationDeliveryBatch: Codable, Equatable, Sendable {
    static let currentVersion = 1
    var version = currentVersion
    let id: UUID
    let recordingID: UUID
    let createdAt: Date
    let bundle: IntegrationContentBundle
    var deliveries: [Delivery]
    var dismissedFromQueue: Bool? = nil
    /// Set only after an observed, warning-free processing prefix. Nil on legacy
    /// or delivery-only batches; sending saved content cannot backfill that proof.
    var processingSucceededBeforeDeliveryAt: Date? = nil

    var successfulWorkflowCompletion: ProcessingCompletionStamp? {
        guard let processingSucceededBeforeDeliveryAt, isComplete,
              deliveries.allSatisfy({ $0.updatedAt != nil }) else { return nil }
        return ProcessingCompletionStamp(jobID: id,
            completedAt: max(processingSucceededBeforeDeliveryAt, deliveries.compactMap(\.updatedAt).max() ?? processingSucceededBeforeDeliveryAt))
    }

    struct Delivery: Codable, Equatable, Sendable, Identifiable {
        enum Status: String, Codable, Sendable {
            case pending, inFlight, succeeded, skipped, uncertain, blocked
        }
        let id: UUID
        let destination: IntegrationDestination
        var configurationDigest: String
        var status: Status = .pending
        var attempts = 0
        var remoteID: String?
        var updatedAt: Date?

        var isComplete: Bool { status == .succeeded || status == .skipped }
        var needsDuplicateConfirmation: Bool { status == .inFlight || status == .uncertain }
        var statusDescription: String {
            switch status {
            case .pending: "Not sent"
            case .inFlight, .uncertain: "Delivery unconfirmed — retry may create duplicates"
            case .succeeded: "Sent"
            case .skipped: "Skipped — no content to send"
            case .blocked: "Not sent — integration settings changed or are disabled"
            }
        }
    }

    var isComplete: Bool { deliveries.allSatisfy(\.isComplete) }

    func validate() throws {
        guard version == Self.currentVersion,
              Set(deliveries.map(\.id)).count == deliveries.count,
              Set(deliveries.map(\.destination)).count == deliveries.count,
              deliveries.allSatisfy({ $0.attempts >= 0 && !$0.configurationDigest.isEmpty }) else {
            throw IntegrationDeliveryStore.StoreError.invalidRecord
        }
    }

    /// Hash only the selected destination; unrelated settings cannot invalidate a
    /// retry. Credentials are read at send time and never copied into the journal.
    static func configurationDigests(_ settings: IntegrationSettings) throws -> [IntegrationDestination: String] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var values: [IntegrationDestination: String] = [:]
        func add<T: Encodable>(_ destination: IntegrationDestination, _ config: T, enabled: Bool) throws {
            guard enabled, IntegrationDestination.available.contains(destination) else { return }
            values[destination] = SHA256.hash(data: try encoder.encode(config))
                .map { String(format: "%02x", $0) }.joined()
        }
        try add(.appleNotes, settings.appleNotes, enabled: settings.appleNotes.enabled)
        try add(.appleReminders, settings.appleReminders, enabled: settings.appleReminders.enabled)
        // Timeout changes and credential rotation do not redirect content. Header
        // row UUIDs are UI identity, not part of the remote destination.
        let authenticationHeaders: Set<String> = ["authorization", "proxy-authorization", "x-api-key", "api-key"]
        var routingHeaders: [String: String] = [:]
        for header in settings.webhook.headers {
            let key = header.key.lowercased()
            if !key.isEmpty, !authenticationHeaders.contains(key),
               key != "idempotency-key", key != "content-type" {
                routingHeaders[key] = header.value
            }
        }
        let webhookRouting = WebhookRouting(url: settings.webhook.url.trimmingCharacters(in: .whitespacesAndNewlines),
                                            fields: settings.webhook.fields, headers: routingHeaders)
        try add(.webhook, webhookRouting, enabled: settings.webhook.enabled)
        return values
    }

    private struct WebhookRouting: Encodable {
        let url: String
        let fields: [DeliveryField]
        let headers: [String: String]
    }
}
