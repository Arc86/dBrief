import OSLog

extension Logger {
    public static let app = Logger(subsystem: "com.dbrief.app", category: "app")
    public static let audio = Logger(subsystem: "com.dbrief.app", category: "audio")
    public static let recording = Logger(subsystem: "com.dbrief.app", category: "recording")
    public static let transcription = Logger(subsystem: "com.dbrief.app", category: "transcription")
    public static let ai = Logger(subsystem: "com.dbrief.app", category: "ai")
    public static let localAI = Logger(subsystem: "com.dbrief.app", category: "localai")
    public static let callDetection = Logger(subsystem: "com.dbrief.app", category: "callDetection")
    public static let integrations = Logger(subsystem: "com.dbrief.app", category: "integrations")
    public static let hotkey = Logger(subsystem: "com.dbrief.app", category: "hotkey")
    public static let player = Logger(subsystem: "com.dbrief.app", category: "player")
    public static let localTranscription = Logger(subsystem: "com.dbrief.app", category: "localtranscription")
    public static let calendar = Logger(subsystem: "com.dbrief.app", category: "calendar")
}
