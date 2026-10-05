import AppKit
import SwiftUI
import WebKit
import os
import dBriefWire

/// Owns the WKWebView hosting the bundled Milkdown page and its JS bridge.
/// Theme, read-only state and the latest markdown live here and are replayed
/// on every `ready`, so a reload (or web-content crash) restores the editor.
@MainActor
final class MarkdownEditorController: NSObject {
    let webView: WKWebView
    var onMessage: (MarkdownEditorMessage) -> Void = { _ in }

    private let indexURL: URL
    private var latestMarkdown: String
    private var theme: MarkdownEditorTheme?
    private var isReadOnly = false
    private var isReady = false

    init(indexURL: URL, markdown: String) {
        self.indexURL = indexURL
        self.latestMarkdown = markdown
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.configuration.userContentController.add(WeakScriptMessageHandler(self), name: "dbrief")
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsMagnification = false
        webView.allowsBackForwardNavigationGestures = false
        load()
    }

    func setTheme(_ theme: MarkdownEditorTheme) {
        guard theme != self.theme else { return }
        self.theme = theme
        run(MarkdownEditorScript.call("setTheme", theme.cssVariables))
    }

    func setReadOnly(_ readOnly: Bool) {
        guard readOnly != isReadOnly else { return }
        isReadOnly = readOnly
        run(MarkdownEditorScript.call("setReadOnly", readOnly))
    }

    func focus() {
        run("window.dbrief.focus();")
    }

    func tearDown() {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "dbrief")
        webView.navigationDelegate = nil
        onMessage = { _ in }
    }

    /// Test hook: behaves exactly like WebKit's crash callback.
    func simulateWebContentCrashForTesting() {
        webViewWebContentProcessDidTerminate(webView)
    }

    fileprivate func receive(_ body: Any) {
        guard let message = MarkdownEditorMessage(body: body) else { return }
        switch message {
        case .ready:
            isReady = true
            if let theme { run(MarkdownEditorScript.call("setTheme", theme.cssVariables)) }
            run(MarkdownEditorScript.call("setReadOnly", isReadOnly))
            run(MarkdownEditorScript.call("setMarkdown", latestMarkdown))
            if !isReadOnly { focus() }
        case .loaded(let markdown), .changed(let markdown):
            latestMarkdown = markdown
        case .height, .shortcut:
            break
        }
        onMessage(message)
    }

    private func load() {
        isReady = false
        // Read access to the whole Resources dir so the page can use ../Fonts.
        let resources = indexURL.deletingLastPathComponent().deletingLastPathComponent()
        webView.loadFileURL(indexURL, allowingReadAccessTo: resources)
    }

    /// Calls before `ready` are dropped on purpose: `ready` replays all state.
    private func run(_ script: String) {
        guard isReady else { return }
        webView.evaluateJavaScript(script) { _, error in
            if let error {
                Logger.app.error("Summary editor script failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

extension MarkdownEditorController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        switch MarkdownEditorNavigation.decide(navigationAction.request.url, indexURL: indexURL) {
        case .allow:
            return .allow
        case .openExternally(let url):
            if navigationAction.navigationType == .linkActivated { NSWorkspace.shared.open(url) }
            return .cancel
        case .cancel:
            return .cancel
        }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Logger.app.error("Summary editor web content process terminated; reloading")
        load()
    }
}

/// Breaks the WKUserContentController → handler retain cycle.
@MainActor
private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: MarkdownEditorController?

    init(_ target: MarkdownEditorController) {
        self.target = target
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.receive(message.body)
    }
}

/// Inline Notion-style Markdown editor for the Summary card.
struct MarkdownBlockEditor: NSViewRepresentable {
    let indexURL: URL
    let initialMarkdown: String
    let isReadOnly: Bool
    /// False while another viewer tab is showing: the hidden editor gives up focus.
    let isActive: Bool
    let theme: MarkdownEditorTheme
    let onMessage: (MarkdownEditorMessage) -> Void

    func makeCoordinator() -> MarkdownEditorController {
        MarkdownEditorController(indexURL: indexURL, markdown: initialMarkdown)
    }

    func makeNSView(context: Context) -> WKWebView {
        configure(context.coordinator)
        return context.coordinator.webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        configure(context.coordinator)
        if !isActive, let window = webView.window,
           let responder = window.firstResponder as? NSView, responder.isDescendant(of: webView) {
            window.makeFirstResponder(nil)
        }
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: MarkdownEditorController) {
        coordinator.tearDown()
    }

    private func configure(_ controller: MarkdownEditorController) {
        controller.onMessage = onMessage
        controller.setTheme(theme)
        controller.setReadOnly(isReadOnly)
    }
}
