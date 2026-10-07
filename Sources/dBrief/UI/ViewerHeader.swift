import SwiftUI

/// The document header: title, tabs, utility icons, commands and the assistant
/// toggle. States without a finished transcript (live, not yet transcribed) pass
/// no `tabs`, and live capture passes no `onDelete`.
struct ViewerHeader<Commands: View>: View {
    let title: String
    let tabs: [ViewerDocumentMode]
    let showsAssistantToggle: Bool
    @Binding private var mode: ViewerDocumentMode
    @Binding private var readingOptionsPresented: Bool
    @Binding private var readingPreferences: ViewerAppearancePreferences
    let unfinishedActions: Int
    let assistantOpen: Bool
    let onToggleAssistant: () -> Void
    let onPrivacyReceipt: () -> Void
    let onDelete: (() -> Void)?

    @Environment(\.viewerPalette) private var palette
    @FocusState private var focusedMode: ViewerDocumentMode?
    @FocusState private var assistantFocused: Bool
    private let commands: () -> Commands

    init(
        title: String,
        tabs: [ViewerDocumentMode] = ViewerDocumentMode.allCases,
        showsAssistantToggle: Bool = true,
        mode: Binding<ViewerDocumentMode>,
        readingOptionsPresented: Binding<Bool>,
        readingPreferences: Binding<ViewerAppearancePreferences>,
        unfinishedActions: Int,
        assistantOpen: Bool,
        onToggleAssistant: @escaping () -> Void,
        onPrivacyReceipt: @escaping () -> Void,
        onDelete: (() -> Void)?,
        @ViewBuilder commands: @escaping () -> Commands
    ) {
        self.title = title
        self.tabs = tabs
        self.showsAssistantToggle = showsAssistantToggle
        self._mode = mode
        self._readingOptionsPresented = readingOptionsPresented
        self._readingPreferences = readingPreferences
        self.unfinishedActions = unfinishedActions
        self.assistantOpen = assistantOpen
        self.onToggleAssistant = onToggleAssistant
        self.onPrivacyReceipt = onPrivacyReceipt
        self.onDelete = onDelete
        self.commands = commands
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            breadcrumb
            titleText
            navigationRow
            commandRow
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var breadcrumb: some View {
        HStack(spacing: 5) {
            Image(systemName: "house")
                .accessibilityHidden(true)
            Text("Recording library")
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .accessibilityHidden(true)
        }
        .uiFont(.system(size: 11, weight: .medium))
        .foregroundStyle(palette.secondary.color)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Recording library")
    }

    private var titleText: some View {
        Text(title)
            .uiFont(.system(size: 25, weight: .semibold))
            .foregroundStyle(palette.heading.color)
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
    }

    private var navigationRow: some View {
        // Tabs on the left and the utility icons pinned right; narrow windows wrap
        // the tabs and drop the icons to their own row.
        ViewerWrapLayout(spacing: 5, lineSpacing: 6, pinsLastToTrailing: true) {
            ForEach(tabs, id: \.self) { tabButton($0) }
            navigationActions
        }
        .frame(minHeight: 36)
        .padding(.bottom, 9)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(palette.divider.color)
                .frame(height: 1)
                .allowsHitTesting(false)
        }
    }

    private func tabButton(_ destination: ViewerDocumentMode) -> some View {
        let isSelected = mode == destination
        let unfinishedCount = max(0, unfinishedActions)

        return Button {
            mode = destination
        } label: {
            HStack(spacing: 6) {
                Text(destination.displayName)
                    .lineLimit(1)
                if destination == .actions {
                    Text("\(unfinishedCount)")
                        .uiFont(.system(size: 11, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(palette.accentText.color)
                        .padding(.horizontal, 5)
                        .frame(minHeight: 19)
                        .background(palette.selected.color, in: RoundedRectangle(cornerRadius: 5))
                }
            }
            .uiFont(.system(size: 13, weight: isSelected ? .semibold : .medium))
            .foregroundStyle(isSelected ? palette.accentText.color : palette.secondary.color)
            .padding(.horizontal, 9)
            .frame(minHeight: 36)
            .overlay(alignment: .bottom) {
                if isSelected {
                    Rectangle()
                        .fill(palette.accentText.color)
                        .frame(height: 2)
                        .allowsHitTesting(false)
                }
            }
            .overlay {
                if focusedMode == destination {
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(palette.accentText.color, lineWidth: 2)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focused($focusedMode, equals: destination)
        .accessibilityLabel(destination == .actions
            ? "Actions, \(unfinishedCount) unfinished"
            : destination.displayName)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("viewer-tab-\(destination.rawValue)")
    }

    private var navigationActions: some View {
        HStack(spacing: 4) { utilityIcons }
            .fixedSize(horizontal: true, vertical: false)
    }

    private var commandRow: some View {
        // `commands` may be several groups; each stays whole and the groups wrap.
        ViewerWrapLayout(alignment: .trailing, spacing: 8, lineSpacing: 8) {
            commands()
            if showsAssistantToggle { assistantToggle }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    @ViewBuilder private var utilityIcons: some View {
        HeaderIconButton(symbol: "textformat.size", label: "Display options") {
            readingOptionsPresented.toggle()
        }
        .popover(isPresented: $readingOptionsPresented) {
            ViewerPopoverContent {
                ViewerReadingOptions(preferences: $readingPreferences)
            }
        }
        HeaderIconButton(symbol: "lock.shield", label: "Privacy receipt", action: onPrivacyReceipt)
        if let onDelete { HeaderDeleteButton(action: onDelete) }
    }

    private var assistantToggle: some View {
        Button(action: onToggleAssistant) {
            HStack(spacing: 7) {
                ViewerSparkle(size: 14)
                Text("Ask dBrief AI")
            }
        }
        .buttonStyle(ViewerBrandButtonStyle(height: 32))
        .focused($assistantFocused)
        .overlay {
            if assistantFocused {
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(palette.accentText.color, lineWidth: 2)
                    .padding(-2)
                    .allowsHitTesting(false)
            }
        }
        .help(assistantOpen ? "Hide dBrief AI assistant" : "Ask dBrief AI")
        .accessibilityLabel("Ask dBrief AI")
        .accessibilityValue(assistantOpen ? "Shown" : "Hidden")
        .accessibilityAddTraits(assistantOpen ? .isSelected : [])
    }
}

private struct HeaderIconButton: View {
    let symbol: String
    let label: String
    let action: () -> Void

    @Environment(\.viewerPalette) private var palette
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 34, height: 32)
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .overlay {
            if isFocused {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(palette.accentText.color, lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
        .help(label)
        .accessibilityLabel(label)
    }
}

private struct HeaderDeleteButton: View {
    let action: () -> Void

    @Environment(\.viewerPalette) private var palette
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(role: .destructive, action: action) {
            Image(systemName: "trash")
                .font(.system(size: 14, weight: .medium))
                .frame(width: 34, height: 32)
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.red)
        .focused($isFocused)
        .overlay {
            if isFocused {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(palette.accentText.color, lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
        .help("Delete recording")
        .accessibilityLabel("Delete recording")
    }
}

/// A quiet viewer command treatment with an opaque theme surface and no accent fill.
struct ViewerCommandButtonStyle: ButtonStyle {
    @Environment(\.viewerPalette) private var palette
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .uiFont(.system(size: 12, weight: .medium))
            .foregroundStyle(palette.heading.color)
            .padding(.horizontal, 10)
            .frame(minHeight: 32)
            .background(
                configuration.isPressed ? palette.selected.color : palette.surface.color,
                in: RoundedRectangle(cornerRadius: 7)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(palette.divider.color, lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .opacity(isEnabled ? 1 : 0.5)
            .contentShape(RoundedRectangle(cornerRadius: 7))
    }
}
