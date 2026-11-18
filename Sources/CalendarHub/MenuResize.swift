import AppKit
import SwiftUI

/// How much taller than usual the menu was dragged for each of its sections, kept between
/// launches as "list:120,tasks:80". A section missing from it has its usual height.
struct MenuSectionHeights: RawRepresentable, Equatable {
    private var extras: [String: CGFloat] = [:]

    init() {}

    init?(rawValue: String) {
        for pair in rawValue.split(separator: ",") {
            let parts = pair.split(separator: ":")
            guard parts.count == 2, let value = Double(parts[1]), value > 0 else { continue }
            extras[String(parts[0])] = CGFloat(value)
        }
    }

    var rawValue: String {
        extras.sorted { $0.key < $1.key }
            .map { "\($0.key):\(Int($0.value.rounded()))" }
            .joined(separator: ",")
    }

    subscript(section: String) -> CGFloat {
        get { extras[section] ?? 0 }
        set { extras[section] = newValue > 0 ? newValue : nil }
    }
}

private struct MenuExtraHeightKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    /// How much taller than usual the menu's section is, dragged by its bottom edge. The
    /// section's scrolling part grows by as much.
    var menuExtraHeight: CGFloat {
        get { self[MenuExtraHeightKey.self] }
        set { self[MenuExtraHeightKey.self] = newValue }
    }
}

/// The menu's bottom edge, dragged down to make the menu taller and up to make it shorter again,
/// never shorter than usual. The menu grows downwards only: its top stays under the menu bar.
/// A double click puts back the usual height. Shows a grip while the pointer is on it.
struct MenuResizeHandle: View {
    /// The extra height shown now.
    let extra: CGFloat
    /// The new extra height while dragging, and `ended` true when the drag is over.
    let change: (_ extra: CGFloat, _ ended: Bool) -> Void
    @State private var active = false

    var body: some View {
        DragEdge(extra: extra, change: change) { active = $0 }
            .overlay(alignment: .bottom) {
                Capsule()
                    .fill(Color.secondary.opacity(0.45))
                    .frame(width: 36, height: 4)
                    .padding(.bottom, 3)
                    .opacity(active ? 1 : 0)
                    .animation(.easeInOut(duration: 0.15), value: active)
                    .allowsHitTesting(false)
            }
            .accessibilityHidden(true)
    }

    /// In AppKit: the pointer is followed in screen coordinates, which don't move as the window
    /// grows under it, and the resize cursor stays put while dragging.
    private struct DragEdge: NSViewRepresentable {
        let extra: CGFloat
        let change: (CGFloat, Bool) -> Void
        let activate: (Bool) -> Void

        func makeNSView(context: Context) -> EdgeView { EdgeView() }

        func updateNSView(_ view: EdgeView, context: Context) {
            view.extra = extra
            view.change = change
            view.activate = activate
        }
    }

    final class EdgeView: NSView {
        var extra: CGFloat = 0
        var change: ((CGFloat, Bool) -> Void)?
        var activate: ((Bool) -> Void)?
        /// Where the pointer and the extra height were when the drag started.
        private var start: (mouseY: CGFloat, extra: CGFloat)?
        private var hovering = false

        private static var cursor: NSCursor {
            #if compiler(>=6.0)
            if #available(macOS 15, *) { return .frameResize(position: .bottom, directions: .all) }
            #endif
            return .resizeUpDown
        }

        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: bounds,
                                           options: [.mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect],
                                           owner: self))
        }

        override func cursorUpdate(with event: NSEvent) { Self.cursor.set() }

        override func mouseEntered(with event: NSEvent) {
            hovering = true
            Self.cursor.set()
            activate?(true)
        }

        override func mouseExited(with event: NSEvent) {
            hovering = false
            guard start == nil else { return }
            NSCursor.arrow.set()
            activate?(false)
        }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                start = nil
                change?(0, true)
                return
            }
            start = (NSEvent.mouseLocation.y, extra)
            activate?(true)
        }

        override func mouseDragged(with event: NSEvent) {
            guard let start else { return }
            Self.cursor.set()
            // Screen y grows upwards: dragging down makes the menu taller.
            change?(max(start.extra + start.mouseY - NSEvent.mouseLocation.y, 0).rounded(), false)
        }

        override func mouseUp(with event: NSEvent) {
            guard let start else { return }
            self.start = nil
            change?(max(start.extra + start.mouseY - NSEvent.mouseLocation.y, 0).rounded(), true)
            if !hovering {
                NSCursor.arrow.set()
                activate?(false)
            }
        }
    }
}
