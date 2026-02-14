import AVFoundation
import CoreAudio
import Foundation

struct AudioInputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String

    var displayName: String { name }
}

enum AudioInputDeviceError: LocalizedError {
    case deviceNotFound(String)
    case failedToSetDevice(OSStatus)

    var errorDescription: String? {
        switch self {
        case .deviceNotFound(let uid):
            return "Audio input device not found (\(uid))."
        case .failedToSetDevice(let status):
            return "Failed to set audio input device (OSStatus \(status))."
        }
    }
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

    static func applyInputDevice(uid: String?, to engine: AVAudioEngine) throws {
        let trimmed = (uid ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        guard let deviceID = deviceID(forUID: trimmed) else {
            throw AudioInputDeviceError.deviceNotFound(trimmed)
        }

        guard let audioUnit = engine.inputNode.audioUnit else {
            return
        }

        var mutableDeviceID = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &mutableDeviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )

        guard status == noErr else {
            throw AudioInputDeviceError.failedToSetDevice(status)
        }
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
