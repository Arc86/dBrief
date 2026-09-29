import AppKit
import SwiftUI

/// Width-controlled, resizable columns. The sidebar retains its content and
/// final width while its visible slot opens, avoiding a post-mount divider jump.
struct ViewerLibraryLayout<Sidebar: View, Detail: View>: View {
    var sidebarOpen: Bool
    var onToggleSidebar: (() -> Void)? = nil
    var width: Binding<CGFloat>? = nil
    @ViewBuilder var sidebar: () -> Sidebar
    @ViewBuilder var detail: () -> Detail
    @State private var rememberedWidth: CGFloat = 300
    @State private var dragStartWidth: CGFloat?
    @Environment(\.viewerPalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var sidebarWidth: CGFloat { min(max(width?.wrappedValue ?? rememberedWidth, 220), 360) }

    var body: some View {
        GeometryReader { viewport in
            HStack(spacing: 0) {
                GeometryReader { column in
                    VStack(spacing: 0) {
                        if onToggleSidebar != nil { Color.clear.frame(height: 32) }
                        sidebar()
                    }
                    .frame(width: column.size.width, height: column.size.height)
                    .background(palette.sidebarTop.color)
                    .clipped()
                    .overlay(alignment: .topTrailing) {
                        if onToggleSidebar != nil {
                            sidebarToggle.padding(.trailing, 18).padding(.top, 42)
                        }
                    }
                }
                .frame(width: sidebarWidth)
                .ignoresSafeArea(.container, edges: .top)
                .frame(width: sidebarOpen ? sidebarWidth : 0)
                .opacity(sidebarOpen ? 1 : 0)
                .clipped()
                .disabled(!sidebarOpen)
                .allowsHitTesting(sidebarOpen)
                .accessibilityHidden(!sidebarOpen)

                resizeHandle
                    .frame(width: sidebarOpen ? 1 : 0)
                    .opacity(sidebarOpen ? 1 : 0)
                    .allowsHitTesting(sidebarOpen)
                    .accessibilityHidden(!sidebarOpen)

                GeometryReader { column in
                    detail()
                        .padding(.top, !sidebarOpen && onToggleSidebar != nil ? 52 : 0)
                        .frame(width: column.size.width, height: column.size.height)
                        .clipped()
                        .overlay(alignment: .topLeading) {
                            if !sidebarOpen, onToggleSidebar != nil {
                                sidebarToggle.padding(.leading, 24).padding(.top, 40)
                            }
                        }
                }
                .frame(minWidth: 0, maxWidth: .infinity)
                .layoutPriority(1)
                .ignoresSafeArea(.container, edges: .top)
            }
            .frame(width: viewport.size.width, height: viewport.size.height)
            .animation(reduceMotion ? nil : ViewerMotion.panel, value: sidebarOpen)
        }
    }

    private func setWidth(_ proposed: CGFloat) {
        let clamped = min(max(proposed, 220), 360)
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            if let width { width.wrappedValue = clamped }
            else { rememberedWidth = clamped }
        }
    }

    private var resizeHandle: some View {
        palette.divider.color
            .overlay(Color.clear.frame(width: 10).contentShape(Rectangle()).preventsWindowDrag())
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    let start = dragStartWidth ?? sidebarWidth
                    if dragStartWidth == nil { dragStartWidth = start }
                    setWidth(start + value.location.x - value.startLocation.x)
                }
                .onEnded { _ in dragStartWidth = nil })
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Recording sidebar width")
            .accessibilityValue("\(Int(sidebarWidth)) points")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: setWidth(sidebarWidth + 20)
                case .decrement: setWidth(sidebarWidth - 20)
                @unknown default: break
                }
            }
    }

    private var sidebarToggle: some View {
        Button { onToggleSidebar?() } label: {
            Image(systemName: "sidebar.left")
                .font(.system(size: 14))
                .foregroundStyle(palette.secondary.color)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(sidebarOpen ? "Hide recording sidebar" : "Show recording sidebar")
        .accessibilityLabel(sidebarOpen ? "Hide recording sidebar" : "Show recording sidebar")
        .accessibilityIdentifier("viewer-sidebar-toggle")
        .keyboardShortcut("s", modifiers: [.command, .control])
    }
}
