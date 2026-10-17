import AppKit
import SwiftUI

// Standalone visual prototype. No dependency on dBrief services or persistence.
enum PanelState: String, CaseIterable, Identifiable {
    case idle = "Idle", recording = "Recording", complete = "Complete", output = "Output"
    var id: String { rawValue }
    var height: CGFloat {
        switch self {
        case .idle, .output: 799
        case .recording: 710
        case .complete: 900
        }
    }
}

struct PreviewPalette {
    var dark = false
    func color(_ light: String, _ darkHex: String) -> Color {
        let value = UInt32(dark ? darkHex : light, radix: 16)!
        return Color(red: Double((value >> 16) & 255) / 255,
                     green: Double((value >> 8) & 255) / 255,
                     blue: Double(value & 255) / 255)
    }
    var panel: Color { color("F9FBFE", "0D1423") }
    var card: Color { color("FFFFFF", "121A2B") }
    var control: Color { color("E9EDF3", "1A2538") }
    var field: Color { color("F0F3F7", "182337") }
    var selected: Color { color("EDF4FF", "142A4B") }
    var text: Color { color("0B1430", "F4F7FC") }
    var secondary: Color { color("31405F", "C5CEDD") }
    var muted: Color { color("6D7892", "8D99AE") }
    var border: Color { color("E1E7F0", "273349") }
    var accent: Color { color("1268F5", "4C8DFF") }
    var green: Color { color("16B364", "4CCB8A") }
    var red: Color { color("FF4567", "FF6B86") }
    var stop: Color { color("FFF0F3", "42202A") }
    var gradient: LinearGradient {
        LinearGradient(colors: [color("2E8DFF", "2E8DFF"), color("155EEF", "155EEF")],
                       startPoint: .leading, endPoint: .trailing)
    }
}

private struct PaletteKey: EnvironmentKey {
    static let defaultValue = PreviewPalette()
}
extension EnvironmentValues {
    var previewPalette: PreviewPalette {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
}

@MainActor enum PreviewArtwork {
    static var icon: NSImage?
}

struct PreviewPanel: View {
    let state: PanelState
    let dark: Bool
    var body: some View {
        let palette = PreviewPalette(dark: dark)
        VStack(spacing: 12) {
            PanelHeader(recording: state == .recording)
            switch state {
            case .idle:
                CaptureCard()
                ViewerButton()
                RecentRecordings()
            case .recording:
                ActiveRecording()
            case .complete:
                CompletionReview()
            case .output:
                CaptureCard()
                OutputNotes()
            }
            if state != .complete {
                if state != .idle { ViewerButton() }
                QueueCard()
                ImportButtons(inactive: state == .recording)
            }
            Spacer(minLength: 0)
            PanelFooter()
        }
        .padding(20)
        .frame(width: 450, height: state.height, alignment: .top)
        .foregroundStyle(palette.text)
        .background(palette.panel, in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(palette.border, lineWidth: 1))
        .environment(\.previewPalette, palette)
        .environment(\.colorScheme, dark ? .dark : .light)
        .compositingGroup()
        .shadow(color: .black.opacity(dark ? 0.22 : 0.10), radius: 14, y: 8)
    }
}

struct PanelHeader: View {
    let recording: Bool
    @Environment(\.previewPalette) private var p
    var body: some View {
        HStack(spacing: 10) {
            if let icon = PreviewArtwork.icon {
                Image(nsImage: icon).resizable().scaledToFit().frame(width: 34, height: 34)
            }
            Text("dBrief").font(.system(size: 17, weight: .bold))
            Spacer()
            if recording {
                HStack(spacing: 6) {
                    Circle().fill(p.red).frame(width: 8, height: 8)
                    Text("Recording").font(.system(size: 13))
                }.foregroundStyle(p.red)
            }
        }.frame(height: 42)
    }
}

// These are visual controls, deliberately without Button actions.
struct MockButton: View {
    let title: String
    var icon: String? = nil
    var kind: Kind = .secondary
    var height: CGFloat = 42
    var fontSize: CGFloat = 12
    var radius: CGFloat = 10
    var inactive = false
    enum Kind { case primary, secondary, white, stop, destructive }
    @Environment(\.previewPalette) private var p
    var body: some View {
        HStack(spacing: 7) {
            if let icon { Image(systemName: icon).font(.system(size: fontSize + 2)) }
            if !title.isEmpty { Text(title).font(.system(size: fontSize, weight: .semibold)).lineLimit(1) }
        }
        .foregroundStyle(kind == .primary || kind == .destructive ? .white : kind == .stop ? p.red : p.text)
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .background {
            RoundedRectangle(cornerRadius: radius)
                .fill(fill)
        }
        .overlay(RoundedRectangle(cornerRadius: radius)
            .stroke(kind == .stop ? p.red.opacity(0.65) : .clear, lineWidth: 1))
        .opacity(inactive ? 0.38 : 1)
    }
    var fill: AnyShapeStyle {
        switch kind {
        case .primary: AnyShapeStyle(p.gradient)
        case .secondary: AnyShapeStyle(p.control)
        case .white: AnyShapeStyle(p.card)
        case .stop: AnyShapeStyle(p.stop)
        case .destructive: AnyShapeStyle(p.color("E5484D", "E5484D"))
        }
    }
}

struct ProfileBadge: View {
    var compact = false
    @Environment(\.previewPalette) private var p
    var body: some View {
        HStack(spacing: 8) {
            if compact { Text("Profile:").foregroundStyle(p.muted).font(.system(size: 11)).fixedSize() }
            Text("Default").font(.system(size: compact ? 12 : 13, weight: .medium)).fixedSize()
            Spacer(minLength: 6)
            Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .semibold))
        }
        .padding(.horizontal, 10)
        .frame(width: compact ? 137 : 156, height: compact ? 30 : 34)
        .background(compact ? p.selected : p.field, in: RoundedRectangle(cornerRadius: 9))
    }
}

struct CaptureCard: View {
    @Environment(\.previewPalette) private var p
    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Profile").font(.system(size: 12)).foregroundStyle(p.muted)
                Spacer()
                ProfileBadge()
            }.frame(height: 34)
            HStack(spacing: 9) {
                Image(systemName: "record.circle").font(.system(size: 21))
                Text("Record meeting").font(.system(size: 16, weight: .semibold))
                Text("⌃⌥⌘ R").font(.system(size: 10))
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .background(.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 7))
            }
            .foregroundStyle(.white).frame(maxWidth: .infinity).frame(height: 54)
            .background(p.gradient, in: RoundedRectangle(cornerRadius: 12))
            .shadow(color: p.accent.opacity(0.12), radius: 7, y: 4)
        }
        .padding(12).frame(height: 132)
        .background(p.card, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(p.border, lineWidth: 1))
    }
}

struct ViewerButton: View {
    var body: some View {
        MockButton(title: "Open meeting viewer", icon: "rectangle.split.2x1", height: 46, fontSize: 14, radius: 12)
    }
}

struct RecentRecordings: View {
    @Environment(\.previewPalette) private var p
    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 9) {
                Image(systemName: "chevron.down").font(.system(size: 12)).foregroundStyle(p.muted)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Recent recordings").font(.system(size: 16, weight: .semibold))
                    Text("20 recent").font(.system(size: 11)).foregroundStyle(p.muted)
                }
                Spacer()
                Image(systemName: "arrow.clockwise").font(.system(size: 13)).foregroundStyle(p.muted)
                    .frame(width: 30, height: 30).background(p.field, in: RoundedRectangle(cornerRadius: 8))
            }.frame(height: 40)
            VStack(spacing: 7) {
                RecordingRow(title: "UWV presentation", detail: "Today, 18:44 · 1:48:00", expanded: true)
                HStack(spacing: 6) {
                    MockButton(title: "Copy summary", icon: "doc.on.doc", kind: .white, height: 34, fontSize: 10, radius: 8)
                    MockButton(title: "Show in Finder", icon: "folder", kind: .white, height: 34, fontSize: 10, radius: 8)
                    MockButton(title: "Transcript", icon: "doc.text", kind: .white, height: 34, fontSize: 10, radius: 8)
                }
                HStack(spacing: 6) {
                    MockButton(title: "Reprocess⌄", icon: "arrow.triangle.2.circlepath", height: 34, fontSize: 10, radius: 8, inactive: true)
                    MockButton(title: "Integrations", icon: "paperplane", kind: .white, height: 34, fontSize: 10, radius: 8)
                    MockButton(title: "Delete recording", icon: "trash", kind: .destructive, height: 34, fontSize: 10, radius: 8)
                }
            }
            .padding(10).frame(height: 156)
            .background(p.selected, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(p.accent.opacity(0.12), lineWidth: 1))
            VStack(spacing: 2) {
                RecordingRow(title: "Project kickoff", detail: "Today, 14:12 · 0:42:18", expanded: false)
                RecordingRow(title: "Weekly team sync", detail: "Fri, 09:56 · 0:30:24", expanded: false)
            }.padding(.horizontal, 8)
        }
    }
}

struct RecordingRow: View {
    let title: String
    let detail: String
    let expanded: Bool
    @Environment(\.previewPalette) private var p
    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: "play").font(.system(size: expanded ? 17 : 15))
                .foregroundStyle(p.accent)
                .frame(width: expanded ? 40 : 36, height: expanded ? 40 : 36)
                .background(p.accent.opacity(0.08), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: expanded ? 14 : 13, weight: .semibold))
                HStack(spacing: 4) {
                    Text(detail)
                    Image(systemName: "waveform")
                    Text("Transcribed").foregroundStyle(p.secondary)
                }.font(.system(size: expanded ? 11 : 10)).foregroundStyle(p.muted)
            }
            Spacer(minLength: 0)
            Image(systemName: expanded ? "chevron.up" : "chevron.down")
                .font(.system(size: 10)).foregroundStyle(p.muted)
        }.frame(height: expanded ? 54 : 57)
    }
}

struct QueueCard: View {
    @Environment(\.previewPalette) private var p
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(p.muted)
            VStack(alignment: .leading, spacing: 2) {
                Text("Queue & Recovery").font(.system(size: 14, weight: .semibold))
                Text("Paused · 1 needs attention").font(.system(size: 11)).foregroundStyle(p.muted)
            }
            Spacer()
            Image(systemName: "exclamationmark.triangle").foregroundStyle(Color.orange)
            Image(systemName: "arrow.clockwise").foregroundStyle(p.muted)
        }
        .font(.system(size: 14)).padding(.horizontal, 10).frame(height: 58)
        .background(p.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(p.border, lineWidth: 1))
    }
}

struct ImportButtons: View {
    let inactive: Bool
    var body: some View {
        HStack(spacing: 10) {
            MockButton(title: "Transcribe file…", icon: "doc.badge.plus", inactive: inactive)
            MockButton(title: "YouTube URL…", icon: "play.rectangle", inactive: inactive)
        }
    }
}

struct PanelFooter: View {
    @Environment(\.previewPalette) private var p
    var body: some View {
        HStack {
            Text("Settings…")
            Spacer()
            Text("Quit dBrief")
        }
        .font(.system(size: 12)).foregroundStyle(p.muted)
        .padding(.top, 13).frame(height: 30)
        .overlay(alignment: .top) { Rectangle().fill(p.border).frame(height: 1) }
    }
}

struct ActiveRecording: View {
    @Environment(\.previewPalette) private var p
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("0:05").font(.system(size: 42, weight: .bold)).monospacedDigit()
                Spacer()
                HStack(spacing: 6) {
                    Circle().fill(p.red).frame(width: 10, height: 10)
                    Text("REC").font(.system(size: 14, weight: .bold)).foregroundStyle(p.red)
                }
            }.frame(height: 60)
            StaticWaveform()
            HStack(spacing: 12) {
                MockButton(title: "Pause", icon: "pause", height: 58, fontSize: 16, radius: 14)
                MockButton(title: "Stop", icon: "stop", kind: .stop, height: 58, fontSize: 16, radius: 14)
            }
            HStack(spacing: 14) {
                Label("Mic ⌄", systemImage: "mic")
                Label("System Audio", systemImage: "speaker.wave.2")
                Spacer()
            }.font(.system(size: 12)).foregroundStyle(p.green).frame(height: 28)
            OutputFolder(large: true)
            Spacer(minLength: 0)
        }.frame(height: 366)
    }
}

struct StaticWaveform: View {
    let heights: [CGFloat] = [26,34,40,46,50,44,38,34,30,28,32,36,40,42,38,34,30,26,22,18,16,20,24,28,24,20]
    var body: some View {
        HStack(spacing: 5) {
            ForEach(heights.indices, id: \.self) { i in
                Capsule().fill(LinearGradient(colors: [Color(red: 0.55, green: 0.36, blue: 0.96), Color(red: 0.18, green: 0.55, blue: 1)], startPoint: .top, endPoint: .bottom))
                    .frame(width: 8, height: heights[i])
            }
        }.frame(maxWidth: .infinity).frame(height: 58)
    }
}

struct OutputFolder: View {
    var large = false
    @Environment(\.previewPalette) private var p
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Obsidian output folder").font(.system(size: 11)).foregroundStyle(p.muted)
            HStack {
                Text("Meta/Transcripts").font(.system(size: large ? 16 : 13, weight: .medium)).foregroundStyle(p.secondary)
                Spacer()
                MockButton(title: "Choose…", height: large ? 40 : 34, fontSize: large ? 13 : 12, radius: 9)
                    .frame(width: large ? 85 : 80)
            }
        }.frame(height: large ? 82 : 62, alignment: .top)
    }
}

struct CompletionReview: View {
    @Environment(\.previewPalette) private var p
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 4) {
                Text("Profile for this recording:").foregroundStyle(p.secondary)
                Text("Default").fontWeight(.semibold)
            }.font(.system(size: 11)).frame(height: 24)
            HStack(spacing: 12) {
                Image(systemName: "checkmark").font(.system(size: 22)).foregroundStyle(p.accent)
                    .frame(width: 44, height: 44).background(p.selected, in: Circle())
                VStack(alignment: .leading, spacing: 7) {
                    Text("Recording complete").font(.system(size: 18, weight: .semibold)).fixedSize()
                    ProfileBadge(compact: true)
                }.layoutPriority(1)
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 8) {
                    Label("0:07", systemImage: "clock")
                    Label("4.6 MB", systemImage: "doc")
                }.font(.system(size: 11)).foregroundStyle(p.muted)
            }.frame(height: 86)
            MockField(title: "Meeting title", text: "meeting", help: "Used for file naming · YYYY-MM-DD_HHMM_[meeting-title].md", height: 40)
            MockField(title: "Participants", text: "Add a name and press Return…", help: "Matched to speakers in order of first appearance", height: 52, placeholder: true)
            Rectangle().fill(p.border).frame(height: 1)
            VStack(alignment: .leading, spacing: 8) {
                Text("POST-PROCESSING").font(.system(size: 10, weight: .medium)).tracking(1.1).foregroundStyle(p.muted)
                MockCheckbox(title: "Transcribe audio")
                MockCheckbox(title: "Generate summary")
                MockCheckbox(title: "Extract action items")
                MockCheckbox(title: "Analyze tags & sentiment")
            }
            Rectangle().fill(p.border).frame(height: 1)
            OutputFolder()
            HStack(spacing: 8) {
                MockButton(title: "", icon: "trash", kind: .stop, height: 52).frame(width: 48)
                MockButton(title: "Skip", height: 52)
                MockButton(title: "Queue", height: 52)
                MockButton(title: "Process", icon: "play", kind: .primary, height: 52)
            }
            Text("Skip keeps the audio and stops here · Delete removes the file")
                .font(.system(size: 10)).foregroundStyle(p.muted)
            Spacer(minLength: 0)
        }.frame(height: 760, alignment: .top)
    }
}

struct MockField: View {
    let title: String
    let text: String
    let help: String
    let height: CGFloat
    var placeholder = false
    @Environment(\.previewPalette) private var p
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(text).font(.system(size: 13)).foregroundStyle(placeholder ? p.muted : p.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12)
                .frame(height: height)
                .background(placeholder ? p.card : p.field, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(placeholder ? p.accent.opacity(0.22) : .clear, lineWidth: 1))
            Text(help).font(.system(size: 10)).foregroundStyle(p.muted)
        }
    }
}

struct MockCheckbox: View {
    let title: String
    @Environment(\.previewPalette) private var p
    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                .frame(width: 24, height: 24).background(p.accent, in: RoundedRectangle(cornerRadius: 7))
            Text(title).font(.system(size: 13, weight: .medium))
        }.frame(height: 26)
    }
}

struct OutputNotes: View {
    @Environment(\.previewPalette) private var p
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Meeting notes").font(.system(size: 16, weight: .semibold))
                Spacer()
                Text("0:25").font(.system(size: 12)).foregroundStyle(p.muted)
            }.frame(height: 28)
            Label("Notes ready", systemImage: "checkmark").font(.system(size: 12)).foregroundStyle(p.green).frame(height: 24)
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("TRANSCRIPT").font(.system(size: 11, weight: .medium)).tracking(1)
                    Spacer()
                    Image(systemName: "chevron.down").font(.system(size: 11))
                }.foregroundStyle(p.muted)
                Text("We reviewed the presentation and agreed on the next steps for the project. The team will update the proposal before Friday and share it for review.\n\nThe kickoff is planned for next week. We’ll confirm the participants and make sure everyone has the latest materials before the meeting.")
                    .font(.system(size: 13)).lineSpacing(4).foregroundStyle(p.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
            }
            .padding(14).frame(height: 210)
            .background(p.field, in: RoundedRectangle(cornerRadius: 12))
            HStack(spacing: 8) {
                MockButton(title: "Copy notes", icon: "doc.on.doc", height: 40, fontSize: 11, radius: 9)
                MockButton(title: "Open file", icon: "folder", height: 40, fontSize: 11, radius: 9, inactive: true)
                MockButton(title: "Transcript", icon: "doc.text", height: 40, fontSize: 11, radius: 9)
                MockButton(title: "Done", kind: .primary, height: 40, fontSize: 11, radius: 9)
            }
        }
    }
}

struct PreviewPair: View {
    let state: PanelState
    var body: some View {
        HStack(alignment: .top, spacing: 32) {
            ForEach([false, true], id: \.self) { dark in
                VStack(alignment: .leading, spacing: 14) {
                    Text(dark ? "DARK" : "LIGHT").font(.system(size: 11, weight: .semibold)).tracking(2)
                        .foregroundStyle(Color(red: 0.43, green: 0.48, blue: 0.57))
                    PreviewPanel(state: state, dark: dark)
                }
            }
        }.padding(28)
    }
}

struct ReviewWindow: View {
    @State private var state = PanelState.idle
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Menu bar panel").font(.system(size: 20, weight: .semibold))
                    Text("Visual prototype · mock data · panel controls are inactive")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Picker("Panel state", selection: $state) {
                    ForEach(PanelState.allCases) { state in Text(state.rawValue).tag(state) }
                }.pickerStyle(.segmented).frame(width: 370)
            }.padding(.horizontal, 28).padding(.vertical, 20)
            Divider()
            ScrollView([.horizontal, .vertical]) {
                PreviewPair(state: state).frame(maxWidth: .infinity, alignment: .top)
            }.background(Color(red: 0.90, green: 0.92, blue: 0.95))
        }.frame(minWidth: 1020, minHeight: 700).environment(\.colorScheme, .light)
    }
}

final class PreviewAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main enum MenuBarPreviewMain {
    @MainActor static func main() throws {
        let app = NSApplication.shared
        let assets = Bundle.main.resourceURL
        PreviewArtwork.icon = assets.flatMap { NSImage(contentsOf: $0.appendingPathComponent("dBrief-Icon.png")) }
        if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--render" {
            let destination = URL(fileURLWithPath: CommandLine.arguments[2])
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            for state in PanelState.allCases {
                for dark in [false, true] {
                    let renderer = ImageRenderer(content: PreviewPanel(state: state, dark: dark).padding(24))
                    renderer.scale = 2
                    guard let image = renderer.cgImage,
                          let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                        throw NSError(domain: "PreviewRender", code: 1)
                    }
                    try data.write(to: destination.appendingPathComponent("\(state.rawValue.lowercased())-\(dark ? "dark" : "light").png"))
                }
                let renderer = ImageRenderer(content: PreviewPair(state: state).background(Color(red: 0.90, green: 0.92, blue: 0.95)))
                renderer.scale = 1.5
                guard let image = renderer.cgImage,
                      let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                    throw NSError(domain: "PreviewRender", code: 2)
                }
                try data.write(to: destination.appendingPathComponent("\(state.rawValue.lowercased())-comparison.png"))
            }
            print("Rendered all four panel states in light and dark.")
            return
        }
        let delegate = PreviewAppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        let screenHeight = NSScreen.main?.visibleFrame.height ?? 950
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1050, height: min(980, screenHeight - 40)),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "dBrief — Menu Bar UI Preview"
        window.contentView = NSHostingView(rootView: ReviewWindow())
        window.minSize = NSSize(width: 1020, height: 700)
        window.center()
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        withExtendedLifetime(delegate) { app.run() }
    }
}
