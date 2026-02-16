import Foundation
import os

private let log = Logger(subsystem: "com.dbrief.app", category: "MemoryPressure")

/// Monitors system memory pressure and triggers cleanup callbacks when memory is constrained.
@MainActor
final class MemoryPressureMonitor {
    private var dispatchSource: DispatchSourceMemoryPressure?
    private var cleanupHandlers: [() async -> Void] = []
    private var isMonitoring = false

    init() {}

    /// Start monitoring memory pressure. Call this once during app initialization.
    func startMonitoring() {
        guard !isMonitoring else { return }
        isMonitoring = true

        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)

        source.setEventHandler { [weak self] in
            guard let self else { return }
            let event = source.data

            Task { @MainActor in
                if event.contains(.critical) {
                    log.warning("⚠️ CRITICAL memory pressure detected - forcing aggressive cleanup")
                    await self.triggerAggressiveCleanup()
                } else if event.contains(.warning) {
                    log.warning("⚠️ Memory pressure warning - triggering cleanup")
                    await self.triggerCleanup()
                }
            }
        }

        source.resume()
        self.dispatchSource = source

        log.info("Memory pressure monitoring started")
    }

    /// Stop monitoring memory pressure.
    func stopMonitoring() {
        dispatchSource?.cancel()
        dispatchSource = nil
        isMonitoring = false
        log.info("Memory pressure monitoring stopped")
    }

    /// Register a cleanup handler that will be called when memory pressure is detected.
    func registerCleanupHandler(_ handler: @escaping () async -> Void) {
        cleanupHandlers.append(handler)
    }

    /// Check if there's sufficient free memory before allocating a large object.
    /// - Parameter requiredBytes: Minimum free memory required in bytes
    /// - Returns: true if sufficient memory is available
    nonisolated static func hasSufficientMemory(requiredBytes: Int64) -> Bool {
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

        // Use sysctl to get page size (concurrency-safe alternative to vm_kernel_page_size)
        var pageSizeValue: Int = 0
        var size: size_t = MemoryLayout<Int>.size
        sysctlbyname("hw.pagesize", &pageSizeValue, &size, nil, 0)
        let pageSize = Int64(pageSizeValue > 0 ? pageSizeValue : 16384) // Default to 16KB
        let freePages = Int64(stats.free_count)
        let inactivePages = Int64(stats.inactive_count)
        let purgeable = Int64(stats.purgeable_count)

        // Available memory = free + inactive + purgeable
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

    /// Get current memory usage statistics
    nonisolated static func getMemoryStats() -> (used: Int64, free: Int64, total: Int64)? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)

        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }

        guard result == KERN_SUCCESS else { return nil }

        // Use sysctl to get page size (concurrency-safe alternative to vm_kernel_page_size)
        var pageSizeValue: Int = 0
        var size: size_t = MemoryLayout<Int>.size
        sysctlbyname("hw.pagesize", &pageSizeValue, &size, nil, 0)
        let pageSize = Int64(pageSizeValue > 0 ? pageSizeValue : 16384) // Default to 16KB

        var memSize: Int = MemoryLayout<UInt64>.size
        var total: UInt64 = 0
        sysctlbyname("hw.memsize", &total, &memSize, nil, 0)

        let freePages = Int64(stats.free_count)
        let activePages = Int64(stats.active_count)
        let wiredPages = Int64(stats.wire_count)
        let compressedPages = Int64(stats.compressor_page_count)

        let freeBytes = freePages * pageSize
        let usedBytes = (activePages + wiredPages + compressedPages) * pageSize

        return (used: usedBytes, free: freeBytes, total: Int64(total))
    }

    // MARK: - Private

    private func triggerCleanup() async {
        log.info("Executing \(self.cleanupHandlers.count) cleanup handlers")
        for handler in self.cleanupHandlers {
            await handler()
        }
    }

    private func triggerAggressiveCleanup() async {
        log.warning("Executing AGGRESSIVE cleanup")
        for handler in self.cleanupHandlers {
            await handler()
        }

        // Force NSCache and other system caches to purge
        URLCache.shared.removeAllCachedResponses()

        // Give system a moment to recover
        try? await Task.sleep(nanoseconds: 500_000_000) // 500ms
    }
}
