import CoreAudio
import Foundation
import Testing
@testable import dBrief

struct AudioOutputRouteTests {
    @Test
    func builtInSpeakersHaveEchoPath() {
        // Internal speakers ('ispk' data source) on the built-in device → echo path.
        #expect(AudioOutputRoute.echoPathExists(
            transportType: kAudioDeviceTransportTypeBuiltIn,
            dataSource: 0x6973_706B  // 'ispk'
        ))
    }

    @Test
    func builtInWithoutDataSourceHasEchoPath() {
        // No data source reported, but built-in transport → assume speakers.
        #expect(AudioOutputRoute.echoPathExists(
            transportType: kAudioDeviceTransportTypeBuiltIn,
            dataSource: nil
        ))
    }

    @Test
    func wiredHeadphonesInJackHaveNoEchoPath() {
        // Headphones in the built-in jack: BuiltIn transport but 'hdpn' source.
        #expect(!AudioOutputRoute.echoPathExists(
            transportType: kAudioDeviceTransportTypeBuiltIn,
            dataSource: AudioOutputRoute.headphonesDataSource
        ))
    }

    @Test
    func bluetoothHasNoEchoPath() {
        // AirPods / Bluetooth headphones → no speaker→mic bleed.
        #expect(!AudioOutputRoute.echoPathExists(
            transportType: kAudioDeviceTransportTypeBluetooth,
            dataSource: nil
        ))
        #expect(!AudioOutputRoute.echoPathExists(
            transportType: kAudioDeviceTransportTypeBluetoothLE,
            dataSource: nil
        ))
    }

    @Test
    func usbAndHdmiHaveNoEchoPath() {
        #expect(!AudioOutputRoute.echoPathExists(
            transportType: kAudioDeviceTransportTypeUSB,
            dataSource: nil
        ))
        #expect(!AudioOutputRoute.echoPathExists(
            transportType: kAudioDeviceTransportTypeHDMI,
            dataSource: nil
        ))
    }

    @Test
    func headphonesDataSourceOverridesAnyTransport() {
        // Defensive: a 'hdpn' source always wins, regardless of transport.
        #expect(!AudioOutputRoute.echoPathExists(
            transportType: kAudioDeviceTransportTypeUnknown,
            dataSource: AudioOutputRoute.headphonesDataSource
        ))
    }
}
