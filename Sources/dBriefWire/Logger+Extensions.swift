import Foundation
import OSLog

private let dBriefLogSubsystem = Bundle.main.bundleIdentifier ?? "com.dbrief.app"

extension Logger {
    public static let app = Logger(subsystem: dBriefLogSubsystem, category: "app")
    public static let audio = Logger(subsystem: dBriefLogSubsystem, category: "audio")
    public static let recording = Logger(subsystem: dBriefLogSubsystem, category: "recording")
    public static let transcription = Logger(subsystem: dBriefLogSubsystem, category: "transcription")
    public static let ai = Logger(subsystem: dBriefLogSubsystem, category: "ai")
    public static let localAI = Logger(subsystem: dBriefLogSubsystem, category: "localai")
    public static let callDetection = Logger(subsystem: dBriefLogSubsystem, category: "callDetection")
    public static let integrations = Logger(subsystem: dBriefLogSubsystem, category: "integrations")
    public static let hotkey = Logger(subsystem: dBriefLogSubsystem, category: "hotkey")
    public static let player = Logger(subsystem: dBriefLogSubsystem, category: "player")
    public static let localTranscription = Logger(subsystem: dBriefLogSubsystem, category: "localtranscription")
    public static let calendar = Logger(subsystem: dBriefLogSubsystem, category: "calendar")
}
