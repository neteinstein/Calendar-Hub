import AppKit
import CalendarHubCore
import SwiftUI

/// A borderless icon button that shows its tint and a soft background on hover, with a tooltip
/// naming what it does (and its shortcut).
struct IconButton: View {
    let symbol: String
    let help: String
    var shortcut: KeyEquivalent?
    /// In place of the gray, for a button that should stand out.
    var tint: Color?
    let action: () -> Void
    @State private var hovering = false

    init(_ symbol: String, help: String, shortcut: KeyEquivalent? = nil, tint: Color? = nil,
         action: @escaping () -> Void) {
        self.symbol = symbol
        self.help = help
        self.shortcut = shortcut
        self.tint = tint
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 26, height: 24)
                .foregroundStyle(tint.map(AnyShapeStyle.init) ?? (hovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary)))
                .background(hovering ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 7))
                .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(PressableStyle())
        .keyboardShortcut(shortcut.map { KeyboardShortcut($0) })
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

extension View {
    /// Shows the pointing hand while the pointer is over the view, for buttons drawn as chips
    /// and capsules rather than as system buttons.
    func pointingHandCursor() -> some View {
        onHover { inside in
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}

/// Shrinks a little while pressed.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

/// A small accent-tinted capsule, for "Today" and similar quiet actions.
struct PillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(Color.accentColor.opacity(configuration.isPressed ? 0.24 : 0.14), in: Capsule())
            .contentShape(Capsule())
    }
}

/// Opens a meeting's call: a filled accent capsule, larger in the Up next card.
struct JoinButton: View {
    let url: URL
    var large = false

    var body: some View {
        Button {
            NSWorkspace.shared.open(url)
        } label: {
            Label("Join", systemImage: "video.fill")
                .font(.system(size: large ? 13 : 11.5, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, large ? 13 : 9)
                .padding(.vertical, large ? 6 : 3.5)
                .background(Color.accentColor, in: Capsule())
                .shadow(color: Color.accentColor.opacity(0.4), radius: 4, y: 2)
                .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
        .pointingHandCursor()
        .help(MeetingLink.serviceName(of: url).map { "Join on \($0)" } ?? "Join the call")
    }
}

/// Join for a meeting that's further away: a gray capsule shown while the pointer is over its
/// row, darker under the pointer, so it reads as a button before it's clicked.
struct QuietJoinButton: View {
    let url: URL
    @State private var hovering = false

    var body: some View {
        Button {
            NSWorkspace.shared.open(url)
        } label: {
            Label("Join", systemImage: "video.fill")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(hovering ? .primary : .secondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 3.5)
                .background(Color.primary.opacity(hovering ? 0.16 : 0.09), in: Capsule())
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
                .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
        .onHover { hovering = $0 }
        .pointingHandCursor()
        .help(MeetingLink.serviceName(of: url).map { "Join on \($0)" } ?? "Join the call")
    }
}

/// Picks one of a few views, with a highlight that slides to the picked one. Only the highlight
/// animates: the views it switches between have different heights, and the menu window
/// mustn't resize inside an animation (see `WindowTopAnchor`).
struct SlidingSegments<Value: Hashable>: View {
    let options: [(value: Value, title: String)]
    @Binding var selection: Value
    @Namespace private var highlight
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.value) { option in
                let isSelected = option.value == selection
                Button {
                    selection = option.value
                } label: {
                    Text(option.title)
                        .font(.system(size: 12, weight: .medium))
                        // A longer title, such as World Clocks, shrinks a little to fit.
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .foregroundStyle(isSelected ? .primary : .secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 3)
                        .background {
                            if isSelected {
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(colorScheme == .dark ? Color.white.opacity(0.16) : .white)
                                    .shadow(color: .black.opacity(0.12), radius: 1.5, y: 0.5)
                                    .matchedGeometryEffect(id: "highlight", in: highlight)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
            }
        }
        .padding(2)
        .background(Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.06), in: RoundedRectangle(cornerRadius: 8))
        .animation(.snappy(duration: 0.3), value: selection)
    }
}

/// Arrows that spin while something runs.
struct Spinner: View {
    var symbol = "arrow.triangle.2.circlepath"
    @State private var spinning = false

    var body: some View {
        Image(systemName: symbol)
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: spinning)
            .onAppear { spinning = true }
    }
}
