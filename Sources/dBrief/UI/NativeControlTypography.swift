import AppKit
import SwiftUI

/// SwiftUI's native macOS controls do not consistently inherit the SwiftUI font.
/// This bridge changes only the typography of controls in its hosting window.
struct NativeControlTypography: NSViewRepresentable {
    let preferences: AppTypographyPreferences

    func makeNSView(context: Context) -> NativeControlTypographyHost {
        NativeControlTypographyHost(preferences: preferences)
    }

    func updateNSView(_ view: NativeControlTypographyHost, context: Context) {
        view.preferences = preferences
        view.scheduleRefresh(trigger: .swiftUIUpdate)
    }

    static func dismantleNSView(_ view: NativeControlTypographyHost, coordinator: ()) {
        view.stopObserving()
    }
}

@MainActor
final class NativeControlTypographyHost: NSView {
    var preferences: AppTypographyPreferences
    private let applicator = NativeControlTypographyApplicator()
    private var windowObserver: NSObjectProtocol?
    private var menuObserver: NSObjectProtocol?
    private var refreshScheduled = false
    private var trailingRefreshScheduled = false
    /// What the last walk applied, so default typography can skip further walks.
    private var lastApplied: AppTypographyPreferences?
    private var lastRefresh = Date.distantPast

    enum RefreshTrigger {
        /// `NSWindow.didUpdateNotification`: fires after every event, including each
        /// scroll frame, so it must stay cheap.
        case windowUpdate
        /// The hosting view changed or was attached: always reconcile.
        case swiftUIUpdate
    }

    /// Whether a refresh must walk the window. With default typography there is
    /// nothing to restyle, so per-event window updates skip the walk — unless a
    /// custom style was applied earlier and must be restored once.
    static func shouldRefresh(preferences: AppTypographyPreferences,
                              lastApplied: AppTypographyPreferences?,
                              trigger: RefreshTrigger) -> Bool {
        guard trigger == .windowUpdate else { return true }
        let standard = AppTypographyPreferences()
        if preferences == standard { return lastApplied != nil && lastApplied != standard }
        return true
    }

    /// Per-event refreshes closer together than this are coalesced.
    static func isThrottled(sinceLastRefresh interval: TimeInterval) -> Bool {
        interval < 0.1
    }

    /// Clicks and key presses can swap in a whole page of new controls, so they
    /// always restyle in the same frame. Only streams (scroll, drag, mouse-move)
    /// are throttled; a trailing refresh there would show controls resizing.
    static func isThrottled(sinceLastRefresh interval: TimeInterval, eventType: NSEvent.EventType?) -> Bool {
        switch eventType {
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
             .otherMouseDown, .otherMouseUp, .keyDown:
            false
        default:
            isThrottled(sinceLastRefresh: interval)
        }
    }

    init(preferences: AppTypographyPreferences) {
        self.preferences = preferences
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopObserving()
        guard let window else { return }
        windowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didUpdateNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleRefresh(trigger: .windowUpdate) }
        }
        menuObserver = NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main
        ) { [weak self] notification in
            // The observer is delivered on the main queue; extract the native
            // object before entering actor isolation instead of sending Notification.
            nonisolated(unsafe) let trackingMenu = notification.object as? NSMenu
            MainActor.assumeIsolated {
                guard let self, let menu = trackingMenu,
                      Self.ownsTrackingContext(hostWindow: self.window,
                          eventWindow: NSApp.currentEvent?.window,
                          keyWindow: NSApp.keyWindow, mainWindow: NSApp.mainWindow) else { return }
                // SwiftUI can construct a Menu only when it opens. Apply synchronously
                // before tracking draws it, without needing private SwiftUI view types.
                self.applicator.apply(to: menu, preferences: self.preferences)
            }
        }
        scheduleRefresh(trigger: .swiftUIUpdate)
    }

    static func ownsTrackingContext(hostWindow: NSWindow?, eventWindow: NSWindow?,
                                    keyWindow: NSWindow?, mainWindow: NSWindow?) -> Bool {
        guard let hostWindow else { return false }
        // A concrete event or key window takes priority over the main window. This
        // prevents an OS panel's menu from being restyled by the window behind it.
        return (eventWindow ?? keyWindow ?? mainWindow) === hostWindow
    }

    func stopObserving() {
        if let windowObserver {
            NotificationCenter.default.removeObserver(windowObserver)
            self.windowObserver = nil
        }
        if let menuObserver {
            NotificationCenter.default.removeObserver(menuObserver)
            self.menuObserver = nil
        }
    }

    func scheduleRefresh(trigger: RefreshTrigger) {
        guard window != nil,
              Self.shouldRefresh(preferences: preferences, lastApplied: lastApplied, trigger: trigger)
        else { return }
        if trigger == .windowUpdate, Self.isThrottled(sinceLastRefresh: Date().timeIntervalSince(lastRefresh),
                                                      eventType: NSApp.currentEvent?.type) {
            // Keep one trailing refresh so controls created mid-burst still get styled.
            guard !trailingRefreshScheduled else { return }
            trailingRefreshScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self else { return }
                self.trailingRefreshScheduled = false
                self.scheduleRefresh(trigger: .windowUpdate)
            }
            return
        }
        guard !refreshScheduled else { return }
        refreshScheduled = true
        // Walk in this cycle's layout pass: SwiftUI installs its native children while
        // the hosting view (an ancestor) lays out, and this view lays out after it, so
        // controls get their final font before the frame is drawn instead of drawing at
        // the system size first and visibly resizing a run-loop turn later.
        needsLayout = true
        // Backstop for children SwiftUI installs after this cycle's layout pass.
        DispatchQueue.main.async { [weak self] in self?.performRefresh() }
    }

    override func layout() {
        super.layout()
        performRefresh()
    }

    private func performRefresh() {
        guard refreshScheduled else { return }
        refreshScheduled = false
        guard let content = window?.contentView else { return }
        lastRefresh = Date()
        lastApplied = preferences
        applicator.apply(to: content, preferences: preferences)
    }
}

@MainActor
final class NativeControlTypographyApplicator {
    private final class FontRecords: NSObject {
        struct Entry {
            var original: NSFont
            var applied: NSFont
        }
        var slots: [String: Entry] = [:]
    }

    // Native controls can be replaced during SwiftUI updates. Never keep them alive.
    private let records = NSMapTable<NSObject, FontRecords>.weakToStrongObjects()

    func apply(to root: NSView, preferences: AppTypographyPreferences) {
        visit(root, preferences: preferences)
    }

    private func visit(_ view: NSView, preferences: AppTypographyPreferences) {
        if let popup = view as? NSPopUpButton {
            // A popup's attributedTitle belongs to its selected menu item. Treat
            // it like a menu title, not like an ordinary push-button title.
            let original = originalFont(popup.font ?? defaultFont(popup), owner: popup, slot: "font")
            if let menu = popup.menu { apply(to: menu, preferences: preferences) }
            setControlFont(popup, original: original, resolved: resolved(original, preferences: preferences))
        } else if let button = view as? NSButton {
            let existingTitle = button.attributedTitle
            let existingAlternate = button.attributedAlternateTitle
            let original = originalFont(button.font ?? defaultFont(button), owner: button, slot: "font")
            let font = resolved(original, preferences: preferences)
            setControlFont(button, original: original, resolved: font)
            let title = restyled(existingTitle, owner: button, slot: "title",
                                 fallback: original, preferences: preferences)
            if !button.attributedTitle.isEqual(to: title) { button.attributedTitle = title }
            let alternate = restyled(existingAlternate, owner: button, slot: "alternate",
                                     fallback: original, preferences: preferences)
            if !button.attributedAlternateTitle.isEqual(to: alternate) { button.attributedAlternateTitle = alternate }
        } else if let field = view as? NSTextField {
            // SwiftUI text fields already inherit the scaled environment font.
            // Change their family without multiplying their size a second time.
            let fieldPreferences = AppTypographyPreferences(readingFont: preferences.readingFont)
            let existingValue = field.attributedStringValue
            let existingPlaceholder = field.placeholderAttributedString
            let original = originalFont(field.font ?? defaultFont(field), owner: field, slot: "font")
            let font = resolved(original, preferences: fieldPreferences)
            setControlFont(field, original: original, resolved: font)
            let value = restyled(existingValue, owner: field, slot: "value",
                                 fallback: original, preferences: fieldPreferences)
            if !field.attributedStringValue.isEqual(to: value) { field.attributedStringValue = value }
            if let placeholder = existingPlaceholder {
                let styled = restyled(placeholder, owner: field, slot: "placeholder",
                                      fallback: original, preferences: fieldPreferences)
                if !placeholder.isEqual(to: styled) { field.placeholderAttributedString = styled }
            } else if let placeholder = field.placeholderString, !placeholder.isEmpty {
                // Keep the system placeholder colour: an attributed string without a
                // colour would draw in default black, unreadable on dark themes.
                field.placeholderAttributedString = restyled(
                    NSAttributedString(string: placeholder, attributes: [.foregroundColor: NSColor.placeholderTextColor]),
                    owner: field, slot: "placeholder", fallback: original, preferences: fieldPreferences)
            }
            // AppKit's shared field editor is not part of the text field's view subtree.
            if let editor = field.currentEditor(), editor.font != font { editor.font = font }
        } else if let segmented = view as? NSSegmentedControl {
            let original = originalFont(segmented.font ?? defaultFont(segmented), owner: segmented, slot: "font")
            setControlFont(segmented, original: original, resolved: resolved(original, preferences: preferences))
        }
        if let menu = view.menu { apply(to: menu, preferences: preferences) }
        // Document and custom prompt NSTextViews own their typography, including rich runs.
        // Their children are still visited, so their embedded native controls remain eligible.
        for child in view.subviews { visit(child, preferences: preferences) }
    }

    func apply(to menu: NSMenu, preferences: AppTypographyPreferences) {
        // A submenu can inherit its parent's font; capture all baselines before changing it.
        var baselines: [ObjectIdentifier: NSFont] = [:]
        captureMenuFonts(menu, baselines: &baselines)
        apply(menu, baselines: baselines, preferences: preferences)
    }

    private func captureMenuFonts(_ menu: NSMenu, baselines: inout [ObjectIdentifier: NSFont]) {
        guard baselines[ObjectIdentifier(menu)] == nil else { return }
        baselines[ObjectIdentifier(menu)] = originalFont(menu.font, owner: menu, slot: "font")
        for item in menu.items {
            if let submenu = item.submenu { captureMenuFonts(submenu, baselines: &baselines) }
        }
    }

    private func apply(_ menu: NSMenu, baselines: [ObjectIdentifier: NSFont], preferences: AppTypographyPreferences) {
        guard let original = baselines[ObjectIdentifier(menu)] else { return }
        let font = resolved(original, preferences: preferences)
        remember(original, applied: font, owner: menu, slot: "font")
        if menu.font != font { menu.font = font }
        for item in menu.items {
            // SwiftUI owns the title's drawing metadata. Replacing attributedTitle
            // makes those rows blank, even while accessibility still reads them.
            // NSMenu.font styles native titles without replacing their renderer.
            if let submenu = item.submenu { apply(submenu, baselines: baselines, preferences: preferences) }
        }
    }

    private func defaultFont(_ control: NSControl) -> NSFont {
        NSFont.systemFont(ofSize: NSFont.systemFontSize(for: control.controlSize))
    }

    private func fontRecords(_ owner: NSObject) -> FontRecords {
        if let existing = records.object(forKey: owner) { return existing }
        let created = FontRecords()
        records.setObject(created, forKey: owner)
        return created
    }

    private func originalFont(_ current: NSFont, owner: NSObject, slot: String) -> NSFont {
        guard let entry = fontRecords(owner).slots[slot], current == entry.applied else { return current }
        return entry.original
    }

    private func remember(_ original: NSFont, applied: NSFont, owner: NSObject, slot: String) {
        fontRecords(owner).slots[slot] = .init(original: original, applied: applied)
    }

    private func setControlFont(_ control: NSControl, original: NSFont, resolved font: NSFont) {
        remember(original, applied: font, owner: control, slot: "font")
        if control.font != font { control.font = font }
    }

    private func restyled(_ source: NSAttributedString, owner: NSObject, slot: String,
                          fallback: NSFont, preferences: AppTypographyPreferences) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: source)
        source.enumerateAttribute(.font, in: NSRange(location: 0, length: source.length)) { value, range, _ in
            let key = "\(slot).\(range.location)"
            let original = originalFont(value as? NSFont ?? fallback, owner: owner, slot: key)
            let font = resolved(original, preferences: preferences)
            remember(original, applied: font, owner: owner, slot: key)
            result.addAttribute(.font, value: font, range: range)
        }
        return result
    }

    private func resolved(_ original: NSFont, preferences: AppTypographyPreferences) -> NSFont {
        let traits = NSFontManager.shared.traits(of: original)
        let descriptorWeight = (original.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any])?[.weight] as? CGFloat ?? 0
        let weight: Font.Weight
        if traits.contains(.boldFontMask) || descriptorWeight >= NSFont.Weight.bold.rawValue { weight = .bold }
        else if descriptorWeight >= NSFont.Weight.semibold.rawValue { weight = .semibold }
        else if descriptorWeight >= NSFont.Weight.medium.rawValue { weight = .medium }
        else if descriptorWeight <= NSFont.Weight.thin.rawValue { weight = .thin }
        else if descriptorWeight <= NSFont.Weight.light.rawValue { weight = .light }
        else { weight = .regular }
        var style = AppFontStyle.system(size: original.pointSize, weight: weight,
                                       design: traits.contains(.fixedPitchFontMask) ? .monospaced : .default)
        if traits.contains(.italicFontMask) { style = style.italic() }
        return style.nsFont(using: preferences)
    }
}
