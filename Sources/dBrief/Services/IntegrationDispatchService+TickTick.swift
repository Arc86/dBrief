import Foundation
import os
import dBriefWire

/// Records an expired TickTick sign-in: TickTick documents no refresh token, so
/// a 401 removes the stored token and Settings asks the user to sign in again.
enum TickTickSession {
    static let expiredKey = "ticktick.sessionExpired"

    static func markExpired() {
        do {
            try KeychainHelper.set("", for: .tickTickAccessToken)
        } catch {
            Logger.integrations.error("TickTick token removal failed: \(error.localizedDescription, privacy: .public)")
        }
        UserDefaults.standard.set(true, forKey: expiredKey)
    }
}

extension IntegrationDispatchService {
    /// One task per non-empty action item. Items already in `createdItems` are
    /// skipped, and a retry first matches existing tasks (same title and meeting
    /// line), so a lost response or a crash mid-attempt cannot create duplicates.
    func sendToTickTick(batch: IntegrationDeliveryBatch, delivery: IntegrationDeliveryBatch.Delivery,
                        config: IntegrationSettings) async -> IntegrationDispatchResult {
        let items = batch.bundle.actionItems.enumerated().compactMap { index, text -> (index: Int, title: String)? in
            let title = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return title.isEmpty ? nil : (index, title)
        }
        guard !items.isEmpty else {
            return .init(destination: .tickTick, status: .skipped, message: "No action items", remoteID: nil)
        }
        var created = delivery.createdItems ?? [:]
        do {
            try Task.checkCancellation()
            guard try IntegrationDeliveryBatch.configurationDigests(config, available: available)[.tickTick]
                    == delivery.configurationDigest else {
                throw IntegrationError.executionFailed("Integration settings changed. Restore the original destination before retrying.")
            }
            let token = try tickTickToken()
            guard !token.isEmpty else { throw TickTickError.notSignedIn }
            let projectID = config.tickTick.projectID ?? TickTickAPI.inboxProjectID
            let content = TickTickAPI.taskContent(meetingTitle: batch.bundle.title, date: batch.bundle.createdAt)
            var existing: [TickTickTask]?
            var claimed = Set(created.values.filter { !$0.isEmpty })
            for item in items where created[item.index] == nil {
                try Task.checkCancellation()
                if delivery.attempts > 1 {
                    if existing == nil {
                        existing = try await tickTickClient.projectTasks(projectID: projectID, token: token)
                    }
                    if let match = existing?.first(where: { task in
                        !claimed.contains(task.id)
                            && task.title?.trimmingCharacters(in: .whitespacesAndNewlines) == item.title
                            && task.content?.trimmingCharacters(in: .whitespacesAndNewlines) == content
                    }) {
                        created[item.index] = match.id
                        claimed.insert(match.id)
                        continue
                    }
                }
                let id = try await tickTickClient.createTask(title: item.title, content: content,
                                                             projectID: projectID, token: token)
                created[item.index] = id
                if !id.isEmpty { claimed.insert(id) }
            }
            let remoteID = items.compactMap { created[$0.index] }.filter { !$0.isEmpty }.joined(separator: ",")
            Logger.integrations.info("Integration success: tickTick (\(items.count, privacy: .public) items)")
            return .init(destination: .tickTick, status: .success, message: "Sent",
                         remoteID: remoteID.isEmpty ? nil : remoteID, createdItems: created)
        } catch {
            if error as? TickTickError == .unauthorized { tickTickSessionExpired() }
            Logger.integrations.error("Integration failure: tickTick")
            return .init(destination: .tickTick, status: .failed, message: error.localizedDescription,
                         remoteID: nil, createdItems: created.isEmpty ? nil : created)
        }
    }
}
