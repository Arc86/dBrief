import Foundation

extension FileManager {
    func ensureDirectoryExists(at url: URL) throws {
        if !fileExists(atPath: url.path) {
            try createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    func availableDiskSpace() -> Int64? {
        guard let attrs = try? attributesOfFileSystem(forPath: NSHomeDirectory()),
              let freeSpace = attrs[.systemFreeSize] as? Int64
        else { return nil }
        return freeSpace
    }

    /// Returns true if available disk space is below threshold (in bytes)
    func isDiskSpaceLow(threshold: Int64 = 500 * 1024 * 1024) -> Bool {
        guard let available = availableDiskSpace() else { return false }
        return available < threshold
    }
}
