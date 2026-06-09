import Foundation
import os

private let log = Logger(subsystem: "com.dbrief.app", category: "SystemMemory")

/// Pure mach-based memory queries shared by the app's MemoryPressureMonitor
/// (UI) and the ML helper process (allocation gate before loading a model).
public enum SystemMemory {
    /// Check if there's sufficient free memory before allocating a large object.
    /// - Parameter requiredBytes: Minimum free memory required in bytes
    /// - Returns: true if sufficient memory is available
    public static func hasSufficientMemory(requiredBytes: Int64) -> Bool {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)

        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }

        guard result == KERN_SUCCESS else {
            log.warning("Failed to get memory statistics")
            return false // Fail safe: don't allow allocation if we can't check
        }

        var pageSizeValue: Int = 0
        var size: size_t = MemoryLayout<Int>.size
        sysctlbyname("hw.pagesize", &pageSizeValue, &size, nil, 0)
        let pageSize = Int64(pageSizeValue > 0 ? pageSizeValue : 16384) // Default to 16KB
        let freePages = Int64(stats.free_count)
        let inactivePages = Int64(stats.inactive_count)
        let purgeable = Int64(stats.purgeable_count)

        let availableBytes = (freePages + inactivePages + purgeable) * pageSize
        let availableGB = Double(availableBytes) / 1_073_741_824.0
        let requiredGB = Double(requiredBytes) / 1_073_741_824.0
        let hasEnough = availableBytes >= requiredBytes

        if hasEnough {
            log.info("Memory check: \(String(format: "%.1f", availableGB))GB available, \(String(format: "%.1f", requiredGB))GB required - OK")
        } else {
            log.warning("Memory check: \(String(format: "%.1f", availableGB))GB available, \(String(format: "%.1f", requiredGB))GB required - INSUFFICIENT")
        }
        return hasEnough
    }
}
