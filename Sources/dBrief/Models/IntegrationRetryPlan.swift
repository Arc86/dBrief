import Foundation

/// What a History retry of saved deliveries sends, and what the user must
/// confirm first. Destinations turned off in Settings are left out.
struct IntegrationRetryPlan: Equatable, Sendable {
    let destinations: Set<IntegrationDestination>
    let disabled: [IntegrationDestination]
    /// A previous attempt may already have reached the destination.
    let duplicateRisk: [IntegrationDestination]
    /// Current settings would route the saved content somewhere else.
    let configurationChanged: [IntegrationDestination]

    init(selected: [IntegrationDeliveryBatch.Delivery], currentDigests: [IntegrationDestination: String]) {
        var destinations = Set<IntegrationDestination>()
        var disabled: [IntegrationDestination] = []
        var duplicateRisk: [IntegrationDestination] = []
        var configurationChanged: [IntegrationDestination] = []
        for delivery in selected {
            guard let digest = currentDigests[delivery.destination] else {
                disabled.append(delivery.destination)
                continue
            }
            destinations.insert(delivery.destination)
            if delivery.needsDuplicateConfirmation { duplicateRisk.append(delivery.destination) }
            if digest != delivery.configurationDigest { configurationChanged.append(delivery.destination) }
        }
        self.destinations = destinations
        self.disabled = disabled
        self.duplicateRisk = duplicateRisk
        self.configurationChanged = configurationChanged
    }

    var needsConfirmation: Bool { !duplicateRisk.isEmpty || !configurationChanged.isEmpty }
    var allowUncertainRetry: Bool { !duplicateRisk.isEmpty }
    var acceptConfigurationChange: Bool { !configurationChanged.isEmpty }

    static let processingAttentionMessage =
        "Some integrations need attention. Open Integrations in History to review or retry individual sends."
    static let retryAttentionMessage =
        "Some deliveries still need attention. Open Integrations in History to review them."
    static let attentionMessages = [processingAttentionMessage, retryAttentionMessage]

    /// Only these errors are cleared once every delivery has gone out; any
    /// other error stays until the user dismisses it.
    static func isAttentionError(_ message: String?) -> Bool {
        message.map(attentionMessages.contains) ?? false
    }
}
