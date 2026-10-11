import Foundation
import os
import dBriefWire

extension IntegrationDispatchService {
    /// One Notion page per meeting: a child page under the chosen page, or an
    /// entry in the chosen database. The page is created with its first 100
    /// blocks and the rest appended in batches. Progress lives in
    /// `createdItems` as `[0: page id, 1: blocks written]`, so a retry appends
    /// only what's missing. Notion has no idempotency key: when an earlier
    /// attempt may have created the page without us learning its id, a retry
    /// first looks for a same-titled page under the parent whose first line
    /// carries this meeting's "(ref …)".
    func sendToNotion(batch: IntegrationDeliveryBatch, delivery: IntegrationDeliveryBatch.Delivery,
                      config: IntegrationSettings) async -> IntegrationDispatchResult {
        var created = delivery.createdItems ?? [:]
        do {
            try Task.checkCancellation()
            guard try IntegrationDeliveryBatch.configurationDigests(config, available: available)[.notion]
                    == delivery.configurationDigest else {
                throw IntegrationError.executionFailed("Integration settings changed. Restore the original destination before retrying.")
            }
            let token = try notionToken()
            guard !token.isEmpty else { throw NotionError.missingToken }
            let notion = config.notion
            let parentID = notion.parentID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !parentID.isEmpty else { throw NotionError.missingDestination }
            let bundle = batch.bundle
            let reference = NotionAPI.reference(for: batch.id)
            let blocks = NotionAPI.blocks(for: bundle, fields: notion.fields, reference: reference)

            var pageID = created[0]
            var written = Int(created[1] ?? "") ?? 0
            if pageID == nil, delivery.attempts > 1 {
                for candidate in try await notionClient.pages(titled: bundle.title, under: parentID, token: token) {
                    let existing = try await notionClient.children(of: candidate, token: token)
                    if existing.firstText?.contains("(ref \(reference))") == true {
                        pageID = candidate
                        written = existing.count
                        break
                    }
                }
            }
            if pageID == nil {
                let schema = notion.parentType == .dataSource
                    ? try await notionClient.schema(dataSourceID: parentID, token: token) : nil
                let first = Array(blocks.prefix(NotionAPI.maxBlocksPerRequest))
                pageID = try await notionClient.createPage(
                    parentType: notion.parentType, parentID: parentID,
                    properties: NotionAPI.properties(title: bundle.title, schema: schema,
                                                     date: bundle.createdAt, tags: bundle.tags),
                    children: first, token: token)
                written = first.count
            }
            guard let pageID else { throw NotionError.invalidResponse }
            created[0] = pageID
            created[1] = String(written)
            while written < blocks.count {
                try Task.checkCancellation()
                let next = Array(blocks[written..<min(written + NotionAPI.maxBlocksPerRequest, blocks.count)])
                try await notionClient.append(next, to: pageID, token: token)
                written += next.count
                created[1] = String(written)
            }
            Logger.integrations.info("Integration success: notion (\(blocks.count, privacy: .public) blocks)")
            return .init(destination: .notion, status: .success, message: "Sent", remoteID: pageID, createdItems: created)
        } catch {
            Logger.integrations.error("Integration failure: notion")
            return .init(destination: .notion, status: .failed, message: error.localizedDescription,
                         remoteID: nil, createdItems: created.isEmpty ? nil : created)
        }
    }
}
