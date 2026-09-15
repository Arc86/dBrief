import Foundation
import dBriefWire
import Speech
import os

/// Readiness is distinct from locale support: macOS can advertise a locale whose
/// actual transcription asset is unavailable. Shared by file and live recognition.
enum AppleSpeechAssetPreparation {
    enum State: String, Sendable {
        case unsupported, supported, downloading, installed
    }

    struct Failure: LocalizedError, Sendable {
        let locale: String
        let state: State
        let underlying: String?

        var errorDescription: String? {
            let name = Locale(identifier: "en").localizedString(forLanguageCode:
                Locale(identifier: locale).language.languageCode?.identifier ?? locale) ?? locale
            if state == .unsupported {
                return "Apple’s \(name) transcription model is currently unavailable on this Mac. macOS lists the language but cannot provide its speech model."
            }
            return "Apple’s \(name) transcription model is not ready. The download did not finish; try again when connected to the internet."
        }

        var diagnostic: String {
            "locale=\(locale); assetState=\(state.rawValue); os=\(ProcessInfo.processInfo.operatingSystemVersionString); error=\(underlying ?? "none")"
        }
    }

    /// A maximum of two attempts, with a fresh installation request on retry.
    /// Apple consolidates these requests. Never release reservations here: other
    /// live channels or transcription jobs may still be using the same locale.
    static func ensureInstalled(
        locale: String,
        state: @Sendable () async -> State,
        install: @Sendable () async throws -> Void,
        pause: @Sendable () async throws -> Void,
        report: @Sendable (String) -> Void
    ) async throws {
        try Task.checkCancellation()
        var current = await state()
        try Task.checkCancellation()
        if current == .installed { return }
        if current == .unsupported { throw Failure(locale: locale, state: current, underlying: nil) }

        var detail: String?
        for attempt in 0..<2 {
            try Task.checkCancellation()
            report(attempt == 0 ? "Preparing language…" : "Retrying language download…")
            do {
                try await install()
                detail = nil
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                let error = error as NSError
                detail = "\(error.domain) (\(error.code)): \(error.localizedDescription)"
            }
            try Task.checkCancellation()
            current = await state()
            try Task.checkCancellation()
            if current == .installed { return }
            if current == .unsupported { break }
            if attempt == 0 { try await pause() }
        }
        throw Failure(locale: locale, state: current, underlying: detail)
    }

    @available(macOS 26, *)
    static func prepare(_ transcriber: SpeechTranscriber, locale: Locale,
                        report: @escaping @Sendable (String) -> Void) async throws {
        let id = locale.identifier(.bcp47)
        do {
            try await ensureInstalled(locale: id, state: {
                let state = await AssetInventory.status(forModules: [transcriber])
                switch state {
                case .unsupported: return .unsupported
                case .supported: return .supported
                case .downloading: return .downloading
                case .installed: return .installed
                @unknown default: return .unsupported
                }
            }, install: {
                if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                    try await request.downloadAndInstall()
                }
            }, pause: {
                try await Task.sleep(for: .seconds(2))
            }, report: report)
        } catch let failure as Failure {
            Logger.localTranscription.error("Apple speech asset preparation failed: \(failure.diagnostic, privacy: .public)")
            throw failure
        }
    }
}
