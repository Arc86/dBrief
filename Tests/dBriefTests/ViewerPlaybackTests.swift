import AppKit
import AVFoundation
import Foundation
import Observation
import SwiftUI
import Testing
@testable import dBrief

@MainActor
@Suite("Viewer audio playback", .serialized)
struct ViewerPlaybackTests {
    @Test("The real player supports play, pause, seek, and rate changes on silent WAV audio")
    func silentWaveTransportControls() throws {
        let url = try makeSilentWAV(duration: 8)
        let player = AudioPlayer()
        defer {
            player.stop()
            try? FileManager.default.removeItem(at: url)
        }

        player.play(url: url)
        #expect(player.isPlaying)
        #expect(player.currentFileURL == url)
        #expect(abs(player.duration - 8) < 0.1)

        player.pause()
        #expect(!player.isPlaying)
        player.seek(to: 3.25)
        #expect(player.currentTime == 3.25)
        player.setRate(1.5)
        #expect(player.playbackRate == 1.5)

        player.resume()
        #expect(player.isPlaying)
        player.stop()
        #expect(!player.isPlaying)
        #expect(player.currentFileURL == nil)
        #expect(player.currentTime == 0)
        #expect(player.duration == 0)
    }

    @Test("Unmounting and remounting the transcript controls preserves playback ownership")
    func playerBarRemountPreservesActivePlayback() async throws {
        _ = NSApplication.shared
        let url = try makeSilentWAV(duration: 30)
        let player = AudioPlayer()
        defer {
            player.stop()
            try? FileManager.default.removeItem(at: url)
        }

        player.play(url: url)
        player.seek(to: 4.25)
        player.setRate(1.25)
        let ownedTime = player.currentTime

        let state = PlayerMountState()
        let host = NSHostingView(rootView: PlayerMountFixture(state: state, audioURL: url).environment(player))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        #expect(player.isPlaying)
        #expect(player.currentFileURL == url)

        state.isMounted = false
        host.rootView = PlayerMountFixture(state: state, audioURL: url).environment(player)
        host.layoutSubtreeIfNeeded()
        #expect(player.isPlaying)
        #expect(player.currentFileURL == url)
        #expect(player.currentTime >= ownedTime)
        #expect(player.currentTime < player.duration)
        #expect(player.playbackRate == 1.25)

        state.isMounted = true
        host.rootView = PlayerMountFixture(state: state, audioURL: url).environment(player)
        host.layoutSubtreeIfNeeded()
        #expect(player.isPlaying)
        #expect(player.currentFileURL == url)
        #expect(player.currentTime >= ownedTime)
        #expect(player.currentTime < player.duration)
        #expect(player.playbackRate == 1.25)

        state.isMounted = false
        host.rootView = PlayerMountFixture(state: state, audioURL: url).environment(player)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
    }

    private func makeSilentWAV(duration: TimeInterval) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("viewer-playback-silent-\(UUID().uuidString).wav")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let frameCount = Int(format.sampleRate * duration)
        let buffer = try #require(AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(frameCount)
        ))
        buffer.frameLength = AVAudioFrameCount(frameCount)
        let channelData = try #require(buffer.floatChannelData)
        channelData[0].initialize(repeating: 0, count: frameCount)
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }
}

@MainActor
@Observable
private final class PlayerMountState {
    var isMounted = true
}

@MainActor
private struct PlayerMountFixture: View {
    @Bindable var state: PlayerMountState
    let audioURL: URL

    var body: some View {
        Group {
            if state.isMounted {
                TranscriptPlayerBar(
                    audioURL: audioURL,
                    recordingDuration: 30,
                    segments: [],
                    speakerLabels: []
                )
            } else {
                Color.clear.frame(width: 1, height: 1)
            }
        }
    }
}
