import CoreAudio
import Foundation

/// Decides whether the current audio *output* route creates an acoustic echo
/// path (speaker → air → microphone) that echo cancellation is meant to fight.
///
/// Echo cancellation (real-time Voice Processing in mic-only mode, or the
/// offline sidechain duck in mixed mode) only helps when sound played through a
/// speaker bleeds back into the mic. When the user wears earphones/headphones —
/// or routes output to any non-built-in device — that path doesn't exist, so the
/// processing is pure downside: Voice Processing ducks system output and applies
/// AGC, making the audio the user hears noticeably quieter for no benefit.
enum AudioOutputRoute {
    /// Headphones plugged into the built-in jack report a `BuiltIn` transport but
    /// a `'hdpn'` data source. FourCharCode for "hdpn".
    static let headphonesDataSource: UInt32 = 0x6864_706E  // 'hdpn'

    /// Pure decision: does an acoustic echo path plausibly exist for this output?
    ///
    /// - Only the built-in speakers create a speaker→mic echo path.
    /// - Any headphone/earphone/Bluetooth/USB/HDMI route does not.
    /// - Headphones in the built-in jack (`BuiltIn` transport, `'hdpn'` source)
    ///   are treated as no echo path.
    static func echoPathExists(transportType: UInt32, dataSource: UInt32?) -> Bool {
        if dataSource == headphonesDataSource { return false }
        return transportType == kAudioDeviceTransportTypeBuiltIn
    }

    /// Queries CoreAudio for the current default output device and returns whether
    /// it forms an echo path. Conservatively returns `true` (keep echo
    /// cancellation) when the route can't be determined.
    static func currentOutputHasEchoPath() -> Bool {
        guard let outputID = defaultOutputDeviceID() else { return true }
        let transport = transportType(deviceID: outputID) ?? kAudioDeviceTransportTypeUnknown
        let source = outputDataSource(deviceID: outputID)
        return echoPathExists(transportType: transport, dataSource: source)
    }

    // MARK: - CoreAudio glue

    private static func defaultOutputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        guard status == noErr, deviceID != 0 else { return nil }
        return deviceID
    }

    private static func transportType(deviceID: AudioDeviceID) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &transport)
        guard status == noErr else { return nil }
        return transport
    }

    /// The active data source for the output (e.g. internal speakers vs. headphones
    /// for the built-in device). `nil` when the device exposes no data sources.
    private static func outputDataSource(deviceID: AudioDeviceID) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDataSource,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }
        var source: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &source)
        guard status == noErr else { return nil }
        return source
    }
}
