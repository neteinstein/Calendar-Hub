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

/// Opens a meeting's call: a filled capsule in the colors of the meeting's service with its
/// app's icon, like the alert's Join (the accent color and a camera for any other link), larger
/// in the Up next card.
struct JoinButton: View {
    let url: URL
    var large = false

    private var service: MeetingService? { MeetingService.of(url) }

    var body: some View {
        let fill = service?.fill ?? .accentColor
        Button {
            NSWorkspace.shared.open(url)
        } label: {
            Label {
                Text("Join")
            } icon: {
                MeetingServiceIcon(service: service, size: large ? 16 : 14)
            }
                .font(.system(size: large ? 13 : 11.5, weight: .semibold))
                .foregroundStyle(service?.textColor ?? .white)
                .padding(.horizontal, large ? 13 : 9)
                .padding(.vertical, large ? 6 : 3.5)
                .background(fill, in: Capsule())
                .shadow(color: fill.opacity(0.4), radius: 4, y: 2)
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
            Label {
                Text("Join")
            } icon: {
                MeetingServiceIcon(service: MeetingService.of(url), size: 14)
            }
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

/// Picks one of a few views, with a highlight that slides to the picked one.
///
/// Only the highlight's offset and width along the strip animate. The views it switches between
/// have different heights, so picking one resizes the menu window in the same update (see
/// `WindowTopAnchor`); anything animated by its place in the window, as a matched geometry
/// effect or an animation over the whole strip is, flies in from where the resize left it
/// for a moment, over the Up next card. An offset within the strip can't be moved by that.
///
/// Each segment is as wide as its title, and the room left is shared out evenly, so a long
/// title such as Time Tracking fits next to short ones like List.
struct SlidingSegments<Value: Hashable>: View {
    let options: [(value: Value, title: String)]
    @Binding var selection: Value
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Where each segment sits in the strip, for the highlight.
    @State private var frames: [Int: CGRect] = [:]

    var body: some View {
        let index = options.firstIndex { $0.value == selection } ?? 0
        SegmentsLayout {
            ForEach(Array(options.enumerated()), id: \.element.value) { offset, option in
                let isSelected = option.value == selection
                Button {
                    selection = option.value
                } label: {
                    Text(option.title)
                        .font(.system(size: 12, weight: .medium))
                        // Shrinks a little when even the shared-out room is too narrow.
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        // Only the color: an animation over the whole label would move it too
                        // when the menu window resizes in the same update.
                        .animation(.easeOut(duration: 0.2)) {
                            $0.foregroundStyle(isSelected ? .primary : .secondary)
                        }
                        .padding(.horizontal, 3)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 3)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: SegmentFrames.self, value: [offset: proxy.frame(in: .named(Self.space))])
                })
            }
        }
        .coordinateSpace(name: Self.space)
        .onPreferenceChange(SegmentFrames.self) { frames = $0 }
        .background(alignment: .topLeading) {
            if let frame = frames[index] {
                RoundedRectangle(cornerRadius: 6)
                    .fill(colorScheme == .dark ? Color.white.opacity(0.16) : .white)
                    .shadow(color: .black.opacity(0.12), radius: 1.5, y: 0.5)
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: frame.minX, y: frame.minY)
                    .animation(reduceMotion ? nil : .snappy(duration: 0.3), value: frame)
            }
        }
        .padding(2)
        .background(Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    private static var space: String { "segments" }

    private struct SegmentFrames: PreferenceKey {
        static var defaultValue: [Int: CGRect] { [:] }
        static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
            value.merge(nextValue()) { $1 }
        }
    }
}

/// Lays segments out in a row, each as wide as its title plus an even share of the room
/// left; when there's too little room, each gives up its share of the shortfall.
private struct SegmentsLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let ideal = subviews.map { $0.sizeThatFits(.unspecified) }
        return CGSize(width: proposal.width ?? ideal.map(\.width).reduce(0, +),
                      height: ideal.map(\.height).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let ideal = subviews.map { $0.sizeThatFits(.unspecified).width }
        let total = ideal.reduce(0, +)
        guard total > 0 else { return }
        let extra = (bounds.width - total) / CGFloat(subviews.count)
        var x = bounds.minX
        for (subview, width) in zip(subviews, ideal) {
            let shown = extra >= 0 ? width + extra : width * bounds.width / total
            subview.place(at: CGPoint(x: x, y: bounds.minY), proposal: ProposedViewSize(width: shown, height: bounds.height))
            x += shown
        }
    }
}

/// Picks one of a few options, each as wide as its title needs: Meeting Stats' calendars,
/// whose names vary in length. Looks like `SlidingSegments`, a little smaller, and its titles
/// never shrink, so it doesn't change how the views above it are drawn.
struct CompactSegments<Value: Hashable>: View {
    let options: [(value: Value, title: String)]
    @Binding var selection: Value
    @Environment(\.colorScheme) private var colorScheme

    private static var font: NSFont { .systemFont(ofSize: 10.5, weight: .medium) }
    private static var titlePadding: CGFloat { 8 }

    /// Whether `titles` fit side by side in `width`.
    static func fit(_ titles: [String], in width: CGFloat) -> Bool {
        let needed = titles.map { ($0 as NSString).size(withAttributes: [.font: font]).width.rounded(.up) + 2 * titlePadding }
        return needed.reduce(4, +) <= width
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.value) { option in
                let isSelected = option.value == selection
                Button {
                    selection = option.value
                } label: {
                    Text(option.title)
                        .font(Font(Self.font))
                        .lineLimit(1)
                        .fixedSize()
                        .foregroundStyle(isSelected ? .primary : .secondary)
                        .padding(.horizontal, Self.titlePadding)
                        .padding(.vertical, 3)
                        .frame(maxWidth: .infinity)
                        .background {
                            if isSelected {
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(colorScheme == .dark ? Color.white.opacity(0.16) : .white)
                                    .shadow(color: .black.opacity(0.12), radius: 1.5, y: 0.5)
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
