import SwiftUI

struct PromptEditorView: View {
    @Bindable var session: PromptEditorSession
    let close: () -> Void
    @AppStorage("promptEditorFontSize") private var storedFontSize = 16.0
    @State private var narrowSection = PromptEditorSession.Panel.improve
    private var fontSize: Double { storedFontSize.isFinite ? min(22, max(14, storedFontSize)) : 16 }

    var body: some View {
        VStack(spacing: 0) {
            header
            GeometryReader { geometry in
                if geometry.size.width < 840, session.panel != .none {
                    VStack(spacing: 0) {
                        Picker("Editor section", selection: $narrowSection) {
                            Text("Editor").tag(PromptEditorSession.Panel.none)
                            Text(session.panel.rawValue).tag(session.panel)
                        }.pickerStyle(.segmented).padding(12)
                        if narrowSection == .none { editor } else { sidePanel }
                    }
                } else if session.panel != .none {
                    HSplitView {
                        editor.frame(minWidth: 380, idealWidth: 550)
                            .background(PromptSplitAutosave())
                        sidePanel.frame(minWidth: 310, idealWidth: 380)
                    }
                } else { editor }
            }
            if let error = session.errorMessage {
                VStack(alignment: .leading, spacing: 6) {
                    Text(error).font(.callout).textSelection(.enabled)
                    Button("Reload saved") { try? session.reloadSaved() }
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            }
            footer
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 680, minHeight: 500)
        .onChange(of: session.configuration) { _, _ in session.configurationChanged() }
        .onChange(of: session.panel) { _, value in narrowSection = value }
    }
    private var header: some View {
        HStack(spacing: 12) {
            Label(session.draft.baseline.scopeName, systemImage: session.identity.scope == .appDefaults ? "slider.horizontal.3" : "person.crop.circle")
                .font(.callout.weight(.medium))
                .padding(.horizontal, 11).padding(.vertical, 6)
                .background(.quaternary, in: Capsule())
            Text(session.identity.scope == .appDefaults ? "Shared with inheriting profiles" : "Changes apply to this profile")
                .font(.callout).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
        }.padding(.horizontal, 22).padding(.vertical, 10)
    }
    private var editor: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Text("Instructions").font(.headline)
                Spacer()
                Menu {
                    ForEach(session.identity.kind.templates) { template in
                        Button(template.name) { session.applyText(template.text) }
                    }
                } label: { Image(systemName: "doc.badge.plus") }
                .menuStyle(.borderlessButton).fixedSize()
                .help("Start from a template").accessibilityLabel("Start from a template")
                .disabled(session.identity.kind.templates.isEmpty)
                ControlGroup {
                    Button { storedFontSize = max(14, fontSize - 1) } label: { Image(systemName: "textformat.size.smaller") }
                        .disabled(fontSize <= 14).accessibilityLabel("Decrease prompt text size")
                    Button { storedFontSize = min(22, fontSize + 1) } label: { Image(systemName: "textformat.size.larger") }
                        .disabled(fontSize >= 22).accessibilityLabel("Increase prompt text size")
                }.fixedSize()
            }.padding(.horizontal, 22).padding(.top, 18).padding(.bottom, 6)
            Text(session.identity.kind.description).font(.callout).foregroundStyle(.secondary)
                .padding(.horizontal, 22).padding(.bottom, 8)
            PromptTextEditor(session: session, fontSize: fontSize)
            DisclosureGroup("Output format") {
                Text(session.identity.kind.outputContract).font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
            }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 22).padding(.vertical, 12)
        }
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 18))
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .padding(.leading, 14).padding(.trailing, session.panel == .none ? 14 : 6).padding(.vertical, 6)
    }
    private var sidePanel: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Assistant", selection: $session.panel) {
                    Label("Improve", systemImage: "sparkles").tag(PromptEditorSession.Panel.improve)
                    Label("Preview", systemImage: "play").tag(PromptEditorSession.Panel.preview)
                }.pickerStyle(.segmented)
                Button { session.panel = .none } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("Close inspector").accessibilityLabel("Close inspector")
            }.padding(16)
            PromptEnginePicker(session: session).padding(.horizontal, 20).padding(.bottom, 16)
            if session.panel == .improve { PromptImprovementPanel(session: session) }
            else { PromptPreviewPanel(session: session) }
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 20))
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .padding(.leading, 6).padding(.trailing, 14).padding(.vertical, 6)
    }
    private var footer: some View {
        HStack(spacing: 12) {
            Label(session.draft.hasChanges ? "Unsaved changes" : "All changes saved",
                  systemImage: session.draft.hasChanges ? "circle.fill" : "checkmark.circle")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Close", action: close).buttonStyle(.borderless)
            Button("Save changes") { try? session.save() }
                .keyboardShortcut("s", modifiers: .command)
                .modifier(PromptPrimaryAction()).disabled(!session.draft.canSave)
        }.padding(.horizontal, 22).padding(.vertical, 12)
    }

}

/// Persists the native divider position along with the editor window frame.
private struct PromptSplitAutosave: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ nsView: NSView, context: Context) { (nsView as? Probe)?.restore() }
    private final class Probe: NSView {
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); restore() }
        func restore() {
            var ancestor = superview
            while let view = ancestor {
                if let split = view as? NSSplitView {
                    if split.autosaveName == nil { split.autosaveName = "dBrief.PromptEditor.Divider" }
                    return
                }
                ancestor = view.superview
            }
        }
    }
}
