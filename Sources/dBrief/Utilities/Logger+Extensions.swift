import OSLog

extension Logger {
    static let audio = Logger(subsystem: "com.dbrief.app", category: "audio")
    static let recording = Logger(subsystem: "com.dbrief.app", category: "recording")
    static let transcription = Logger(subsystem: "com.dbrief.app", category: "transcription")
    static let ai = Logger(subsystem: "com.dbrief.app", category: "ai")
    static let callDetection = Logger(subsystem: "com.dbrief.app", category: "callDetection")
}
