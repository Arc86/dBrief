import Foundation

struct MultipartFormData: Sendable {
    private let boundary: String
    private var parts: [(Data, String, String?, String?)] = []  // data, name, filename, contentType

    init(boundary: String = UUID().uuidString) {
        self.boundary = boundary
    }

    var contentType: String {
        "multipart/form-data; boundary=\(boundary)"
    }

    mutating func addField(name: String, value: String) {
        guard let data = value.data(using: .utf8) else { return }
        parts.append((data, name, nil, nil))
    }

    mutating func addFile(name: String, fileName: String, contentType: String, data: Data) {
        parts.append((data, name, fileName, contentType))
    }

    func encode() -> Data {
        var body = Data()

        for (data, name, fileName, contentType) in parts {
            body.append("--\(boundary)\r\n")
            if let fileName, let contentType {
                body.append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(fileName)\"\r\n")
                body.append("Content-Type: \(contentType)\r\n\r\n")
            } else {
                body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            }
            body.append(data)
            body.append("\r\n")
        }

        body.append("--\(boundary)--\r\n")
        return body
    }
}

private extension Data {
    mutating func append(_ string: String) {
        if let data = string.data(using: .utf8) {
            append(data)
        }
    }
}
