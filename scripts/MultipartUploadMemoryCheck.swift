// Run via scripts/check-upload-memory.sh. Each size runs in a fresh process so
// unrelated tests and allocator high-water marks cannot hide a size regression.
import Foundation
import Darwin

@main
struct MultipartUploadMemoryCheck {
    static func main() async throws {
        guard CommandLine.arguments.count >= 2, let megabytes = UInt64(CommandLine.arguments[1]) else {
            fatalError("Expected input size in MiB and optional loopback URL")
        }
        let receiver = CommandLine.arguments.count == 3 ? URL(string: CommandLine.arguments[2]) : nil
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("upload-memory-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("synthetic.wav")
        FileManager.default.createFile(atPath: source.path, contents: nil)
        let file = try FileHandle(forWritingTo: source)
        let size = megabytes * 1_024 * 1_024
        // Sparse synthetic input keeps fixture generation out of the memory result.
        try file.truncate(atOffset: size)
        try file.close()
        var form = MultipartFormData(boundary: "memory-check")
        form.addFile(name: "file", fileName: "audio.wav", contentType: "audio/wav", fileURL: source)
        let written = try await form.withBodyFile(in: root) { url in
            let byteCount = UInt64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize!)
            if let receiver {
                guard receiver.host == "127.0.0.1" else { fatalError("Only a loopback receiver is allowed") }
                var request = URLRequest(url: receiver)
                request.httpMethod = "POST"
                request.setValue("multipart/form-data; boundary=memory-check", forHTTPHeaderField: "Content-Type")
                let (data, response) = try await URLSession.shared.upload(for: request, fromFile: url)
                guard (response as? HTTPURLResponse)?.statusCode == 200,
                      UInt64(String(decoding: data, as: UTF8.self)) == byteCount else {
                    fatalError("Receiver did not receive the complete body")
                }
            }
            return byteCount
        }
        guard written > size, written < size + 1_024 else { fatalError("Incomplete upload body") }
        guard try FileManager.default.contentsOfDirectory(atPath: root.path) == ["synthetic.wav"] else {
            fatalError("Upload body leaked")
        }
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { fatalError("Cannot read peak RSS") }
        print("\(megabytes) \(usage.ru_maxrss)")
    }
}
