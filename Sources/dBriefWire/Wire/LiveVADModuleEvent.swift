import Foundation

/// Ordered metadata inside a full lane scope. A producer may announce ready
/// only after validating its owned model and creating the source window. These
/// statuses never certify acoustic silence, common credits or actual cleanup.
public enum LiveVADModuleEvent: Codable, Sendable, Equatable {
    case preparing(identity: LiveVADIdentity)
    case ready(identity: LiveVADIdentity, contextID: UUID, originSample: Int64)
    case processed(identity: LiveVADIdentity, contextID: UUID, sampleEnd: Int64)
    case degraded(identity: LiveVADIdentity, contextID: UUID?, sampleEnd: Int64)
    case retired(identity: LiveVADIdentity, contextID: UUID?, sampleEnd: Int64)

    public var identity: LiveVADIdentity {
        switch self {
        case .preparing(let identity), .ready(let identity,_,_), .processed(let identity,_,_),
             .degraded(let identity,_,_), .retired(let identity,_,_): identity
        }
    }
}
