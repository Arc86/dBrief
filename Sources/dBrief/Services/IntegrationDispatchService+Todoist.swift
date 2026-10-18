import Foundation
import os
import dBriefWire

extension IntegrationDispatchService {
    /// One task per non-empty action item, sent as Sync API `item_add` commands
    /// (up to 100 per request). Each command's uuid is derived from the delivery
    /// and item index, and Todoist never runs a uuid twice, so a retry after a
    /// lost response cannot duplicate a task. Items in `createdItems` are skipped.
    func sendToTodoist(batch: IntegrationDeliveryBatch, delivery: IntegrationDeliveryBatch.Delivery,
                       config: IntegrationSettings) async -> IntegrationDispatchResult {
        let items = ActionItemText.deliverable(batch.bundle.actionItems)
        guard !items.isEmpty else {
            return .init(destination: .todoist, status: .skipped, message: String(localized: "No action items"), remoteID: nil)
        }
        var created = delivery.createdItems ?? [:]
        do {
            try Task.checkCancellation()
            guard try IntegrationDeliveryBatch.configurationDigests(config, available: available)[.todoist]
                    == delivery.configurationDigest else {
                throw IntegrationError.executionFailed(String(localized: "Integration settings changed. Restore the original destination before retrying."))
            }
            let token = try todoistToken()
            guard !token.isEmpty else { throw TodoistError.missingToken }
            let description = TodoistAPI.taskDescription(meetingTitle: batch.bundle.title, date: batch.bundle.createdAt)
            let pending = items.filter { created[$0.index] == nil }
            var failures: [String] = []
            var start = 0
            while start < pending.count {
                try Task.checkCancellation()
                let chunk = pending[start..<min(start + TodoistAPI.maxCommandsPerRequest, pending.count)]
                start += TodoistAPI.maxCommandsPerRequest
                let commands = chunk.map { item in
                    let uuid = TodoistAPI.commandUUID(deliveryID: delivery.id, digest: delivery.configurationDigest,
                                                      index: item.index)
                    return (item.index, uuid, TodoistAPI.itemAdd(uuid: uuid, tempID: uuid, content: item.title,
                                                                 description: description,
                                                                 projectID: config.todoist.projectID))
                }
                let result = try await todoistClient.sync(commands: commands.map(\.2), token: token)
                for (index, uuid, _) in commands {
                    if result.succeeded.contains(uuid) {
                        // A replayed uuid may come back "ok" without a new id.
                        created[index] = result.tempIDMapping[uuid] ?? ""
                    } else {
                        failures.append(result.errors[uuid] ?? "Todoist didn't confirm this task.")
                    }
                }
            }
            if let first = failures.first {
                throw IntegrationError.executionFailed(String(localized: "\(failures.count) tasks weren't added to Todoist: \(first)"))
            }
            let remoteID = items.compactMap { created[$0.index] }.filter { !$0.isEmpty }.joined(separator: ",")
            Logger.integrations.info("Integration success: todoist (\(items.count, privacy: .public) items)")
            return .init(destination: .todoist, status: .success, message: "Sent",
                         remoteID: remoteID.isEmpty ? nil : remoteID, createdItems: created)
        } catch {
            Logger.integrations.error("Integration failure: todoist")
            return .init(destination: .todoist, status: .failed, message: error.localizedDescription,
                         remoteID: nil, createdItems: created.isEmpty ? nil : created)
        }
    }
}
