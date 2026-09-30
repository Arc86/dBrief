import Foundation

/// Shared upper bound for tests that wait on asynchronous work.
///
/// The full suite runs ~1.5k tests in one process, many doing synchronous disk
/// work on the cooperative pool. On a loaded machine (or with endpoint security
/// inspecting file I/O) that pool stays saturated for tens of seconds, so short
/// wall-clock deadlines expire before the awaited work is ever scheduled. Waits
/// still return as soon as their condition holds; this only bounds a real hang.
enum TestTiming {
    static let asyncDeadline: Duration = .seconds(60)
    static var asyncDeadlineSeconds: TimeInterval { TimeInterval(asyncDeadline.components.seconds) }
}
