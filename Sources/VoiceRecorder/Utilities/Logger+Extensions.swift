import OSLog

extension Logger {
    static let audio = Logger(subsystem: "com.voicerecorder.app", category: "audio")
    static let recording = Logger(subsystem: "com.voicerecorder.app", category: "recording")
    static let transcription = Logger(subsystem: "com.voicerecorder.app", category: "transcription")
    static let ai = Logger(subsystem: "com.voicerecorder.app", category: "ai")
    static let callDetection = Logger(subsystem: "com.voicerecorder.app", category: "callDetection")
}
