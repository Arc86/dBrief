import AVFoundation
import CoreAudio
import Foundation

struct AudioInputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String

    var displayName: String { name }
}

enum AudioInputDeviceManager {
    static func availableInputDevices() -> [AudioInputDevice] {
        let deviceIDs = allDeviceIDs()
        var devices: [AudioInputDevice] = []

        for id in deviceIDs {
            guard hasInputStreams(deviceID: id) else { continue }
            guard let uid = stringProperty(
                selector: kAudioDevicePropertyDeviceUID,
                deviceID: id
            ) else { continue }
            let name = stringProperty(
                selector: kAudioObjectPropertyName,
                deviceID: id
            ) ?? "Unknown Device"
            devices.append(AudioInputDevice(id: id, uid: uid, name: name))
        }

        return devices.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// True when macOS has the device's input muted or its input volume at zero.
    /// Such a device still delivers buffers — of exact digital silence — so
    /// capture health can't see it; it has to be read from the device.
    static func isInputSilenced(uid: String) -> Bool {
        guard let id = deviceID(forUID: uid) else { return false }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var muted: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        if AudioObjectHasProperty(id, &address),
           AudioObjectGetPropertyData(id, &address, 0, nil, &size, &muted) == noErr, muted != 0 {
            return true
        }
        address.mSelector = kAudioDevicePropertyVolumeScalar
        var volume: Float32 = 1
        size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectHasProperty(id, &address)
            && AudioObjectGetPropertyData(id, &address, 0, nil, &size, &volume) == noErr
            && volume <= 0
    }

    /// UID of the current macOS default input device, if any.
    static func defaultInputDeviceUID() -> String? {
        guard let id = defaultInputDeviceID() else { return nil }
        return stringProperty(selector: kAudioDevicePropertyDeviceUID, deviceID: id)
    }

    static func defaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &id) == noErr, id != 0 else { return nil }
        return id
    }

    /// Name of the current system default input device (e.g. "MacBook Pro Microphone"),
    /// for user-facing status notes. `nil` if it can't be resolved.
    static func defaultInputDeviceName() -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        )
        guard status == noErr, deviceID != 0 else { return nil }
        return stringProperty(selector: kAudioObjectPropertyName, deviceID: deviceID)
    }

    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        let deviceIDs = allDeviceIDs()
        for id in deviceIDs {
            let deviceUID = stringProperty(
                selector: kAudioDevicePropertyDeviceUID,
                deviceID: id
            )
            if deviceUID == uid {
                return id
            }
        }
        return nil
    }

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var size: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size
        )
        guard status == noErr else { return [] }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)

        let statusData = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceIDs
        )

        guard statusData == noErr else { return [] }
        return deviceIDs
    }

    private static func hasInputStreams(deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        var size: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(
            deviceID,
            &address,
            0,
            nil,
            &size
        )
        guard status == noErr else { return false }

        let rawPointer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawPointer.deallocate() }
        let bufferListPointer = rawPointer.bindMemory(to: AudioBufferList.self, capacity: 1)

        let statusData = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &size,
            bufferListPointer
        )
        guard statusData == noErr else { return false }

        let bufferList = UnsafeMutableAudioBufferListPointer(bufferListPointer)
        for buffer in bufferList {
            if buffer.mNumberChannels > 0 {
                return true
            }
        }
        return false
    }

    private static func stringProperty(
        selector: AudioObjectPropertySelector,
        deviceID: AudioDeviceID
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var size = UInt32(MemoryLayout<CFString?>.size)
        var result: CFString?
        let status = withUnsafeMutablePointer(to: &result) { resultPtr in
            resultPtr.withMemoryRebound(to: UInt8.self, capacity: Int(size)) { rawPtr in
                AudioObjectGetPropertyData(
                    deviceID,
                    &address,
                    0,
                    nil,
                    &size,
                    rawPtr
                )
            }
        }
        guard status == noErr else { return nil }
        return result as String?
    }
}
