import SwiftUI

struct PromptEditorView: View {
    @Bindable var session: PromptEditorSession
    let close: () -> Void
    @AppStorage("promptEditorFontSize") private var storedFontSize = 16.0
    @State private var narrowSection = PromptEditorSession.Panel.none
    private var fontSize: Double { storedFontSize.isFinite ? min(22, max(14, storedFontSize)) : 16 }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
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
            Divider()
            footer
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 680, minHeight: 500)
        .onChange(of: session.configuration) { _, _ in session.configurationChanged() }
        .onChange(of: session.panel) { _, value in narrowSection = value }
    }
    private var header: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 5) {
                Text(session.identity.kind.title + " Prompt").font(.title2.weight(.semibold))
                Text(session.identity.kind.description).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text("Editing").font(.caption).foregroundStyle(.secondary)
                Text(session.draft.baseline.scopeName + (session.identity.scope == .appDefaults ? "" : " only"))
                if session.identity.scope == .appDefaults {
                    Text("Also used by inheriting profiles").font(.caption).foregroundStyle(.secondary)
                }
            }
        }.padding(22)
    }
    private var editor: some View {
        VStack(spacing: 0) {
            HStack { editingControls }.padding(12)
            PromptTextEditor(session: session, fontSize: fontSize)
            Text(session.identity.kind.outputContract).font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(16)
        }.background(Color(nsColor: .textBackgroundColor))
    }
    @ViewBuilder private var editingControls: some View {
        Text("Instructions").fontWeight(.medium)
        Spacer(minLength: 2)
        Menu {
            ForEach(session.identity.kind.templates) { template in
                Button(template.name) { session.applyText(template.text) }
            }
        } label: { Text("Start from…") }
        .fixedSize().disabled(session.identity.kind.templates.isEmpty)
        Button("A−") { storedFontSize = max(14, fontSize - 1) }.disabled(fontSize <= 14).accessibilityLabel("Decrease prompt text size")
        Button("A+") { storedFontSize = min(22, fontSize + 1) }.disabled(fontSize >= 22).accessibilityLabel("Increase prompt text size")
    }
    @ViewBuilder private var sidePanel: some View {
        if session.panel == .improve { PromptImprovementPanel(session: session) }
        else { PromptPreviewPanel(session: session) }
    }
    private var footer: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Button(session.identity.scope == .appDefaults ? "Restore default" : "Use app default") { session.restoreDefault() }
                Button(session.panel == .improve ? "Hide AI" : "Improve with AI…") {
                    session.panel = session.panel == .improve ? .none : .improve
                }
                Button(session.panel == .preview ? "Hide preview" : "Try prompt") {
                    session.panel = session.panel == .preview ? .none : .preview
                }
                if session.canUndoAI { Button("Undo AI edit") { session.undoAIEdit() } }
                Spacer(minLength: 0)
            }
            HStack(spacing: 10) {
                Text(session.draft.hasChanges ? "Unsaved changes" : "Saved").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", action: close)
                Button("Save changes") { try? session.save() }
                    .keyboardShortcut("s", modifiers: .command)
                    .buttonStyle(.borderedProminent).disabled(!session.draft.canSave)
            }
        }.padding(14)
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
