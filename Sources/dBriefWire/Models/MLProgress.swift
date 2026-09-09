import Foundation

/// Request-scoped state delivery. Capture `sink` when installing SDK callbacks;
/// those callbacks may execute outside the task that originated the request.
/// The helper binds this sink to an envelope ID; the app binds it to a UI owner.
public enum MLProgress {
    public typealias Sink = @Sendable (LocalAIPluginState) -> Void
    @TaskLocal public static var sink: Sink?
}
