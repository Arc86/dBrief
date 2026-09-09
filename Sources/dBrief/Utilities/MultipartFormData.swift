import Foundation

struct MultipartFormData: Sendable {
    private let boundary: String
    enum Content: Sendable {
        case data(Data)
        case file(URL)
    }

    private var parts: [(Content, String, String?, String?)] = []

    init(boundary: String = UUID().uuidString) {
        self.boundary = boundary
    }

    var contentType: String {
        "multipart/form-data; boundary=\(boundary)"
    }

    mutating func addField(name: String, value: String) {
        guard let data = value.data(using: .utf8) else { return }
        parts.append((.data(data), name, nil, nil))
    }

    mutating func addFile(name: String, fileName: String, contentType: String, data: Data) {
        parts.append((.data(data), name, fileName, contentType))
    }

    mutating func addFile(name: String, fileName: String, contentType: String, fileURL: URL) {
        parts.append((.file(fileURL), name, fileName, contentType))
    }

    /// In-memory encoding for small payloads. Audio uploads use `withBodyFile`.
    func encode() throws -> Data {
        var body = Data()
        try writeParts { body.append($0) }
        return body
    }

    /// Owns a private temporary body for exactly one request attempt. Preparation
    /// and transport failures (including cancellation) both remove private content.
    /// The source audio is borrowed and is never modified or removed.
    func withBodyFile<T: Sendable>(
        in parent: URL = FileManager.default.temporaryDirectory,
        operation: @Sendable (URL) async throws -> T
    ) async throws -> T {
        try Task.checkCancellation()
        let directory = parent.appendingPathComponent("dbrief-upload-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("body.multipart")
        guard FileManager.default.createFile(
            atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let output = try FileHandle(forWritingTo: url)
        do {
            try writeParts { try output.write(contentsOf: $0) }
            try output.close()
        } catch {
            try? output.close()
            throw error
        }
        try Task.checkCancellation()
        return try await operation(url)
    }

    private func writeParts(_ write: (Data) throws -> Void) throws {
        for (content, name, fileName, contentType) in parts {
            try Task.checkCancellation()
            var header = "--\(boundary)\r\n"
            if let fileName, let contentType {
                header += "Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(fileName)\"\r\n"
                header += "Content-Type: \(contentType)\r\n\r\n"
            } else {
                header += "Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n"
            }
            try write(Data(header.utf8))
            switch content {
            case .data(let data):
                try write(data)
            case .file(let url):
                let input = try FileHandle(forReadingFrom: url)
                defer { try? input.close() }
                // Bound audio memory independently of recording/chunk size.
                while true {
                    try Task.checkCancellation()
                    // FileHandle bridges through autoreleased Foundation buffers.
                    // Drain each iteration; ARC scope alone retains an entire upload.
                    let copied = try autoreleasepool {
                        guard let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty else { return false }
                        try write(chunk)
                        return true
                    }
                    if !copied { break }
                }
            }
            try write(Data("\r\n".utf8))
        }
        try write(Data("--\(boundary)--\r\n".utf8))
    }
}
