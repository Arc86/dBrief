import CoreAudio
import Foundation
import os

/// Watches the system default **output** device and fires `onChange` whenever it
/// changes, so acoustic echo cancellation (Voice Processing) can be re-evaluated
/// for the new route (e.g. the user moves from laptop speakers to headphones
/// mid-recording).
///
/// Listens on `kAudioObjectSystemObject` rather than a specific device, so it
/// keeps working across device-set changes without re-targeting. The CoreAudio
/// listener fires on the supplied queue; `onChange` is `@Sendable` and the caller
/// is expected to hop to its own actor.
final class DefaultOutputDeviceMonitor: @unchecked Sendable {
    private let onChange: @Sendable () -> Void
    private var isListening = false
    /// The exact block handed to `AudioObjectAddPropertyListenerBlock`. It MUST be
    /// the same reference passed to the remove call, otherwise the listener is
    /// never unregistered (a latent leak in the older `MicActivityMonitor`).
    private var listenerBlock: AudioObjectPropertyListenerBlock?

    private var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    init(onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
    }

    func start() {
        guard !isListening else { return }

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.onChange()
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            block
        )
        if status == noErr {
            listenerBlock = block
            isListening = true
            Logger.audio.info("Default-output-device monitoring started")
        } else {
            Logger.audio.error("Failed to add default-output listener: \(status)")
        }
    }

    func stop() {
        guard isListening, let block = listenerBlock else { return }
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            block
        )
        listenerBlock = nil
        isListening = false
    }

    deinit { stop() }
}
