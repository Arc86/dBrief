import OSLog

extension Logger {
    static let app = Logger(subsystem: "com.dbrief.app", category: "app")
    static let audio = Logger(subsystem: "com.dbrief.app", category: "audio")
    static let recording = Logger(subsystem: "com.dbrief.app", category: "recording")
    static let transcription = Logger(subsystem: "com.dbrief.app", category: "transcription")
    static let ai = Logger(subsystem: "com.dbrief.app", category: "ai")
    static let localAI = Logger(subsystem: "com.dbrief.app", category: "localai")
    static let callDetection = Logger(subsystem: "com.dbrief.app", category: "callDetection")
    static let integrations = Logger(subsystem: "com.dbrief.app", category: "integrations")
    static let hotkey = Logger(subsystem: "com.dbrief.app", category: "hotkey")
    static let player = Logger(subsystem: "com.dbrief.app", category: "player")
    static let localTranscription = Logger(subsystem: "com.dbrief.app", category: "localtranscription")
}
