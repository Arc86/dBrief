import Foundation
import Testing
@testable import dBrief

@Suite("Integration retry plan")
struct IntegrationRetryPlanTests {
    private typealias Delivery = IntegrationDeliveryBatch.Delivery

    private func delivery(_ destination: IntegrationDestination, _ status: Delivery.Status = .pending,
                          digest: String = "same") -> Delivery {
        Delivery(id: UUID(), destination: destination, configurationDigest: digest, status: status)
    }

    @Test func sendsEveryEnabledDestinationWithoutConfirmationWhenNothingIsRisky() {
        let plan = IntegrationRetryPlan(selected: [delivery(.notion), delivery(.tickTick)],
                                        currentDigests: [.notion: "same", .tickTick: "same"])
        #expect(plan.destinations == [.notion, .tickTick])
        #expect(plan.disabled.isEmpty)
        #expect(!plan.needsConfirmation)
        #expect(!plan.allowUncertainRetry && !plan.acceptConfigurationChange)
    }

    @Test func leavesDisabledDestinationsOutAndNamesThem() {
        let plan = IntegrationRetryPlan(selected: [delivery(.notion), delivery(.tickTick)],
                                        currentDigests: [.notion: "same"])
        #expect(plan.destinations == [.notion])
        #expect(plan.disabled == [.tickTick])
    }

    @Test func collectsDuplicateRiskAndChangedSettingsInDeliveryOrder() {
        let plan = IntegrationRetryPlan(
            selected: [delivery(.todoist, .uncertain), delivery(.notion, digest: "old"), delivery(.tickTick, .inFlight)],
            currentDigests: [.todoist: "same", .notion: "new", .tickTick: "same"])
        #expect(plan.duplicateRisk == [.todoist, .tickTick])
        #expect(plan.configurationChanged == [.notion])
        #expect(plan.needsConfirmation)
        #expect(plan.allowUncertainRetry && plan.acceptConfigurationChange)
    }

    @Test func disabledDestinationsRaiseNoWarnings() {
        let plan = IntegrationRetryPlan(selected: [delivery(.todoist, .uncertain, digest: "old")], currentDigests: [:])
        #expect(plan.destinations.isEmpty)
        #expect(plan.duplicateRisk.isEmpty && plan.configurationChanged.isEmpty)
        #expect(!plan.needsConfirmation)
    }

    @Test func deliveryAttentionErrorsAreRecognisedButOtherErrorsAreNot() {
        for message in IntegrationRetryPlan.attentionMessages {
            #expect(IntegrationRetryPlan.isAttentionError(message))
        }
        #expect(!IntegrationRetryPlan.isAttentionError("Server error (502)"))
        #expect(!IntegrationRetryPlan.isAttentionError(nil))
    }
}
