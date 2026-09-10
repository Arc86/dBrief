import SwiftUI

/// Readable failure feedback. Only the diagnostic projection reaches the view:
/// arbitrary server bodies, URLs, and command output may contain credentials.
struct SettingsErrorDetails: View {
    let summary: String
    let error: String
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(summary)
                    .foregroundStyle(.primary)
            } icon: {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
            }
            .font(.callout)

            DisclosureGroup("Error details", isExpanded: $isExpanded) {
                ScrollView {
                    Text(SettingsErrorSanitizer.details(for: error))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                }
                .frame(maxHeight: 180)
            }
            .accessibilityLabel("\(summary) Details")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// An allowlist projection, not a best-effort regex redactor. No arbitrary input
/// text is returned. This also protects unknown key formats, URL credentials,
/// JSON bodies, shell arguments, and secrets echoed without a recognizable label.
enum SettingsErrorSanitizer {
    static func details(for error: String) -> String {
        let message = error.lowercased()
        let hint: String
        if let code = captureCode(in: message, pattern: #"^server error \(([1-5][0-9]{2})\):"#) {
            switch code {
            case 401, 403:
                hint = "The provider rejected access (HTTP \(code)). Check the API key and account permissions, then test the connection again."
            case 404:
                hint = "The provider could not find the requested resource (HTTP 404). Check the base URL and model name, then test the connection again."
            case 429:
                hint = "The provider limited the request (HTTP 429). Check account quota or wait before testing again."
            default:
                hint = "The provider returned HTTP \(code). Check the provider configuration and service status, then test the connection again."
            }
        } else if let code = captureCode(in: message, pattern: #"^local cli command exited with code ([0-9]{1,3}):"#) {
            hint = "The command exited with code \(code). Check the command, its installation, and authentication, then test it again."
        } else if message.hasPrefix("failed to launch local cli command:") {
            hint = "The command could not be launched. Check the executable path and permissions, then test it again."
        } else if message.hasPrefix("local cli output was not valid json.") {
            hint = "The command returned invalid JSON. Check that its output matches the required format, then test it again."
        } else if message == "local cli command produced no output." {
            hint = "The command produced no output. Check that it prints the result to standard output, then test it again."
        } else if message.hasPrefix("no local cli command configured.") {
            hint = "Configure a command before testing it."
        } else if message.contains("timed out") || message.contains("timeout") {
            hint = "The error indicates a timeout. Check the connection or allow more time, then try again."
        } else if message.contains("offline") || message.contains("not connected to the internet") {
            hint = "The error indicates an unavailable network connection. Check the connection, then try again."
        } else if message.contains("could not connect") || message.contains("could not be found") || message.contains("cannot find host") {
            hint = "The error indicates an unavailable resource. Check the service address or required local model, then try again."
        } else {
            hint = "No additional diagnostic information can be displayed safely. Check the selected service or model and its configuration, then try again."
        }
        return hint + "\n\nRaw error text is omitted because provider responses and command output may contain credentials or private data."
    }

    private static func captureCode(in message: String, pattern: String) -> Int? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)),
              let range = Range(match.range(at: 1), in: message)
        else { return nil }
        return Int(message[range])
    }
}
