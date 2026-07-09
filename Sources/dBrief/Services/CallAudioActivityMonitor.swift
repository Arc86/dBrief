import CoreAudio
import Foundation
import os

private let log = Logger.callDetection

/// Watches per-process microphone **input** usage for a set of call-app bundle ids.
///
/// This is the only reliable "call ended" signal while dBrief is recording: dBrief holds the
/// microphone open for the whole recording, so the aggregate `DeviceIsRunningSomewhere` signal
/// (used to detect a call *starting*) never goes inactive. Per-process input state, however,
/// reflects the meeting app alone — when Teams/Zoom/Slack/a browser stops using the mic, its
/// process's `kAudioProcessPropertyIsRunningInput` flips to `false` even though the app stays alive.
///
/// Uses CoreAudio audio process objects (macOS 14.2+). Reports `(bundleId, isRunningInput)`
/// transitions on the main queue. No microphone permission is needed to observe.
@available(macOS 14.2, *)
final class CallAudioActivityMonitor: @unchecked Sendable {
    private let monitoredBundleIds: Set<String>
    private let onChange: @Sendable (_ bundleId: String, _ isRunningInput: Bool) -> Void

    private var isListening = false
    /// Attached input listeners, keyed by process AudioObjectID.
    private var processListeners: [AudioObjectID: (bundleId: String, block: AudioObjectPropertyListenerBlock)] = [:]
    /// Last reported input state per process, keyed by AudioObjectID (not bundleId — an app can
    /// own more than one audio process object).
    private var lastInputState: [AudioObjectID: Bool] = [:]
    /// Listener on the system-wide process list, so newly launched apps get input listeners.
    private var listListenerBlock: AudioObjectPropertyListenerBlock?

    init(
        monitoredBundleIds: Set<String>,
        onChange: @escaping @Sendable (_ bundleId: String, _ isRunningInput: Bool) -> Void
    ) {
        self.monitoredBundleIds = monitoredBundleIds
        self.onChange = onChange
    }

    func start() {
        guard !isListening else { return }
        isListening = true

        var address = Self.processListAddress
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.refreshProcessListeners()
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block)
        if status == noErr {
            listListenerBlock = block
            log.info("Per-process call-audio monitoring started")
        } else {
            log.error("Failed to add process-list listener: \(status)")
        }

        refreshProcessListeners()
    }

    func stop() {
        guard isListening else { return }
        isListening = false

        if let block = listListenerBlock {
            var address = Self.processListAddress
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block)
            listListenerBlock = nil
        }

        for (processID, entry) in processListeners {
            removeInputListener(processID: processID, block: entry.block)
        }
        processListeners.removeAll()
        lastInputState.removeAll()
    }

    /// Enumerate process objects, attach input listeners to monitored apps we haven't seen yet,
    /// and drop listeners for processes that have gone away.
    private func refreshProcessListeners() {
        guard isListening else { return }

        let processes = Self.processObjectList()
        var seen = Set<AudioObjectID>()

        for processID in processes {
            guard let bundleId = Self.bundleID(of: processID),
                  monitoredBundleIds.contains(bundleId) else { continue }
            seen.insert(processID)
            if processListeners[processID] == nil {
                // Record the current state as a silent baseline — we only fire on later
                // transitions, so an app that's merely running (input off) can't be mistaken
                // for a call that just ended.
                lastInputState[processID] = Self.isRunningInput(processID)
                attachInputListener(processID: processID, bundleId: bundleId)
            }
        }

        // A monitored process that vanished means its input stopped.
        for (processID, entry) in processListeners where !seen.contains(processID) {
            removeInputListener(processID: processID, block: entry.block)
            processListeners[processID] = nil
            if lastInputState[processID] == true {
                onChange(entry.bundleId, false)
            }
            lastInputState[processID] = nil
        }
    }

    private func attachInputListener(processID: AudioObjectID, bundleId: String) {
        var address = Self.isRunningInputAddress
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.reportInputState(processID: processID, bundleId: bundleId)
        }
        let status = AudioObjectAddPropertyListenerBlock(processID, &address, DispatchQueue.main, block)
        if status == noErr {
            processListeners[processID] = (bundleId, block)
        } else {
            log.error("Failed to add input listener for \(bundleId, privacy: .public): \(status)")
        }
    }

    private func removeInputListener(processID: AudioObjectID, block: @escaping AudioObjectPropertyListenerBlock) {
        var address = Self.isRunningInputAddress
        AudioObjectRemovePropertyListenerBlock(processID, &address, DispatchQueue.main, block)
    }

    private func reportInputState(processID: AudioObjectID, bundleId: String) {
        let running = Self.isRunningInput(processID)
        if lastInputState[processID] != running {
            lastInputState[processID] = running
            onChange(bundleId, running)
        }
    }

    // MARK: - CoreAudio reads

    private static let processListAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyProcessObjectList,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    private static let isRunningInputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioProcessPropertyIsRunningInput,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    private static func processObjectList() -> [AudioObjectID] {
        var address = processListAddress
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize) == noErr,
            dataSize > 0 else { return [] }
        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: 0, count: count)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &ids)
        guard status == noErr else { return [] }
        return ids
    }

    private static func bundleID(of processID: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize = UInt32(MemoryLayout<CFString>.size)
        var value: CFString = "" as CFString
        let status = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(processID, &address, 0, nil, &dataSize, ptr)
        }
        guard status == noErr else { return nil }
        let str = value as String
        return str.isEmpty ? nil : str
    }

    private static func isRunningInput(_ processID: AudioObjectID) -> Bool {
        var address = isRunningInputAddress
        var value: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(processID, &address, 0, nil, &dataSize, &value)
        guard status == noErr else { return false }
        return value != 0
    }
}
