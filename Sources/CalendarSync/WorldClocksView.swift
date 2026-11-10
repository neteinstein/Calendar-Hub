import CalendarSyncCore
import SwiftUI

/// The menu's World Clocks view: the time here and in each city picked in Settings, colored by
/// whether it's working time there, and a chart of the day showing when everyone's at work.
/// The time compared is now, or one typed in or picked by dragging across the chart.
struct WorldClocksView: View {
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// A time picked to compare, or nil for now.
    @State private var pinned: Date?
    /// Height of everything in the scroll view, so it shows all of it while it's short.
    @State private var contentHeight: CGFloat = 0

    private var workingHours: WorkingHours { settings.menuCalendar.workingHours }

    /// Here first, then the cities in Settings.
    private var rows: [Row] {
        let local = TimeZone.current
        return [Row(id: "here", name: WorldClocks.cityName(of: local.identifier), timeZone: local, isHere: true)]
            + settings.worldClocks.clocks.map { Row(id: $0.id.uuidString, name: $0.name, timeZone: $0.timeZone, isHere: false) }
    }

    var body: some View {
        TimelineView(.everyMinute) { context in
            let date = pinned ?? context.date
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    timeBar(date: date)
                    if settings.worldClocks.clocks.isEmpty {
                        Text("Add the cities to compare in Settings › World Clocks.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 11))
                    }
                    VStack(spacing: 6) {
                        ForEach(rows) { row in
                            ClockCard(row: row, date: date, workingHours: workingHours)
                        }
                    }
                    if !settings.worldClocks.clocks.isEmpty {
                        overlapCard(date: date)
                    }
                }
                .padding(.vertical, 2)
                .background(GeometryReader { proxy in
                    Color.clear
                        .onAppear { contentHeight = proxy.size.height }
                        .onChange(of: proxy.size.height) { _, height in contentHeight = height }
                })
            }
            .frame(height: min(max(contentHeight, 120), 520))
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: pinned)
    }

    // MARK: - The time compared

    /// "Now", live, or the time picked, with a field to type one and a button back to now.
    private func timeBar(date: Date) -> some View {
        HStack(spacing: 8) {
            if pinned == nil {
                HStack(spacing: 5) {
                    Circle().fill(.green).frame(width: 6, height: 6)
                    Text("Now").font(.system(size: 11.5, weight: .semibold))
                }
            } else {
                Text("At").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.secondary)
            }
            // The stepper field: a popover calendar would close the menu.
            DatePicker("Time", selection: Binding(get: { date }, set: { pinned = $0 }),
                       displayedComponents: .hourAndMinute)
                .datePickerStyle(.stepperField)
                .labelsHidden()
                .controlSize(.small)
            Spacer(minLength: 0)
            if pinned != nil {
                Button("Back to now") { pinned = nil }
                    .controlSize(.small)
            } else {
                Text("Type a time or drag across the chart")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
    }

    // MARK: - Overlap

    private func overlapCard(date: Date) -> some View {
        let calendar = Calendar.current
        let overlap = WorldClocks.overlap(on: date, of: rows.map(\.timeZone), workingHours: workingHours, calendar: calendar)
        let total = overlap.reduce(0) { $0 + $1.count }
        let dayStart = calendar.startOfDay(for: date)
        let selected = Int(date.timeIntervalSince(dayStart) / 60)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Working hours overlap").font(.system(size: 12.5, weight: .semibold))
                Spacer()
                Text(total > 0 ? WorldClocks.durationText(minutes: total) : "None")
                    .font(.system(size: 12.5, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(total > 0 ? Color.accentColor : .secondary)
            }
            Text(summary(overlap, dayStart: dayStart, isWeekend: WorldClocks.isWeekend(date, in: .current)))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            OverlapChart(rows: rows, overlap: overlap, date: date, selected: selected, workingHours: workingHours) { minute in
                pinned = calendar.date(byAdding: .minute, value: minute, to: dayStart)
            }
            legend
        }
        .padding(10)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 11))
    }

    /// When everyone's at work, in local time.
    private func summary(_ overlap: [Range<Int>], dayStart: Date, isWeekend: Bool) -> String {
        guard !overlap.isEmpty else {
            return isWeekend ? "It's the weekend here." : "There's no time today when everyone's at work."
        }
        let times = overlap.map { range in
            let from = dayStart.addingTimeInterval(Double(range.lowerBound) * 60)
            let to = dayStart.addingTimeInterval(Double(range.upperBound) * 60)
            return "\(from.formatted(date: .omitted, time: .shortened))–\(to.formatted(date: .omitted, time: .shortened))"
        }
        return "Everyone's at work \(ListFormatter.localizedString(byJoining: times)) your time."
    }

    private var legend: some View {
        HStack(spacing: 10) {
            ForEach(WorldClocks.Period.allCases, id: \.self) { period in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2).fill(period.color.opacity(period.barOpacity)).frame(width: 10, height: 8)
                    Text(period.legend)
                }
            }
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 2).fill(Color.accentColor).frame(width: 10, height: 8)
                Text("Everyone")
            }
        }
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
    }

    struct Row: Identifiable {
        let id: String
        let name: String
        let timeZone: TimeZone
        let isHere: Bool
    }
}

extension WorldClocks.Period {
    var color: Color {
        switch self {
        case .working: .green
        case .free: .orange
        case .night: .indigo
        }
    }

    /// How strong its bars are in the chart: working time stands out.
    var barOpacity: Double {
        switch self {
        case .working: 0.85
        case .free: 0.35
        case .night: 0.3
        }
    }

    var legend: String {
        switch self {
        case .working: "Working"
        case .free: "Off work"
        case .night: "Night"
        }
    }
}

/// A city's time: a small clock face, its name, how far ahead or behind it is, the time, and
/// whether it's working time, all in that period's color.
private struct ClockCard: View {
    let row: WorldClocksView.Row
    let date: Date
    let workingHours: WorkingHours

    private var period: WorldClocks.Period {
        WorldClocks.period(at: date, in: row.timeZone, workingHours: workingHours)
    }

    private var status: String {
        if period == .free && WorldClocks.isWeekend(date, in: row.timeZone) { return "Weekend" }
        return period.legend
    }

    private var detail: String {
        if row.isHere { return "Here" }
        let offset = WorldClocks.offsetText(row.timeZone, from: .current, at: date)
        return [offset, WorldClocks.dayText(row.timeZone, from: .current, at: date)].compactMap { $0 }.joined(separator: " · ")
    }

    var body: some View {
        let tint = period.color
        HStack(spacing: 10) {
            ClockFace(minute: WorldClocks.minuteOfDay(date, in: row.timeZone), tint: tint)
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(row.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    if row.isHere {
                        Image(systemName: "location.fill").font(.system(size: 8.5)).foregroundStyle(.secondary)
                    }
                }
                Text(detail).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 1) {
                Text(date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: row.timeZone)))
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text(status)
                    .font(.system(size: 9.5, weight: .bold))
                    .textCase(.uppercase)
                    .tracking(0.4)
                    .foregroundStyle(tint)
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 10)
        .padding(.vertical, 6)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 11))
        .overlay(alignment: .leading) {
            Rectangle().fill(tint).frame(width: 3)
        }
        .clipShape(RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(tint.opacity(0.3), lineWidth: 0.5))
        .accessibilityElement(children: .combine)
    }
}

/// An analog clock showing `minute` of the day.
private struct ClockFace: View {
    let minute: Int
    let tint: Color

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = min(size.width, size.height) / 2
            for tick in 0..<12 {
                let angle = Double(tick) / 12 * 2 * .pi
                let inner = radius * (tick % 3 == 0 ? 0.72 : 0.8)
                var path = Path()
                path.move(to: point(center, inner, angle))
                path.addLine(to: point(center, radius * 0.9, angle))
                context.stroke(path, with: .color(tint.opacity(0.55)), lineWidth: tick % 3 == 0 ? 1.4 : 0.8)
            }
            let hourAngle = Double(minute % 720) / 720 * 2 * .pi
            let minuteAngle = Double(minute % 60) / 60 * 2 * .pi
            for (angle, length, width) in [(hourAngle, 0.5, 2.0), (minuteAngle, 0.75, 1.4)] {
                var hand = Path()
                hand.move(to: center)
                hand.addLine(to: point(center, radius * length, angle))
                context.stroke(hand, with: .color(.primary), style: StrokeStyle(lineWidth: width, lineCap: .round))
            }
            context.fill(Path(ellipseIn: CGRect(x: center.x - 1.6, y: center.y - 1.6, width: 3.2, height: 3.2)), with: .color(tint))
        }
        .background(Circle().fill(tint.opacity(0.14)))
        .overlay(Circle().strokeBorder(tint.opacity(0.6), lineWidth: 1))
    }

    /// The point `length` from `center` at `angle` clockwise from twelve.
    private func point(_ center: CGPoint, _ length: Double, _ angle: Double) -> CGPoint {
        CGPoint(x: center.x + length * sin(angle), y: center.y - length * cos(angle))
    }
}

/// Today in local time, a row per city in its periods' colors and a row for when everyone's
/// working, with a line at the time compared. Click or drag across it to pick a time.
private struct OverlapChart: View {
    let rows: [WorldClocksView.Row]
    let overlap: [Range<Int>]
    let date: Date
    let selected: Int
    let workingHours: WorkingHours
    let pick: (Int) -> Void

    private static let labelWidth: CGFloat = 74
    private static let barHeight: CGFloat = 12
    private static let day = 24 * 60

    var body: some View {
        let calendar = Calendar.current
        VStack(alignment: .leading, spacing: 4) {
            ForEach(rows) { row in
                line(row.name, bold: row.isHere) { width in
                    ForEach(WorldClocks.segments(on: date, for: row.timeZone, workingHours: workingHours, calendar: calendar),
                            id: \.start) { segment in
                        bar(segment.start, segment.end, width: width,
                            color: segment.period.color.opacity(segment.period.barOpacity))
                    }
                }
            }
            line("Everyone", bold: true, tint: .accentColor) { width in
                Capsule().fill(Color.primary.opacity(0.06)).frame(width: width, height: Self.barHeight)
                ForEach(overlap, id: \.lowerBound) { range in
                    bar(range.lowerBound, range.upperBound, width: width, color: .accentColor)
                        .shadow(color: .accentColor.opacity(0.5), radius: 3)
                }
            }
            axis
        }
        .overlay(alignment: .topLeading) { cursor }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Working hours of each city today, in your time")
    }

    /// A row: its name, then the day as a bar.
    private func line<Bars: View>(_ name: String, bold: Bool = false, tint: Color = .secondary,
                                  @ViewBuilder bars: @escaping (CGFloat) -> Bars) -> some View {
        HStack(spacing: 6) {
            Text(name)
                .font(.system(size: 10, weight: bold ? .semibold : .regular))
                .foregroundStyle(tint)
                .lineLimit(1)
                .frame(width: Self.labelWidth, alignment: .leading)
            GeometryReader { proxy in
                ZStack(alignment: .leading) { bars(proxy.size.width) }
                    .frame(maxHeight: .infinity)
            }
            .frame(height: Self.barHeight)
        }
    }

    private func bar(_ start: Int, _ end: Int, width: CGFloat, color: Color) -> some View {
        let scale = width / CGFloat(Self.day)
        return RoundedRectangle(cornerRadius: 3)
            .fill(color)
            .frame(width: max(CGFloat(end - start) * scale - 1, 1), height: Self.barHeight)
            .offset(x: CGFloat(start) * scale)
    }

    /// Hours along the bottom.
    private var axis: some View {
        HStack(spacing: 6) {
            Color.clear.frame(width: Self.labelWidth, height: 1)
            GeometryReader { proxy in
                ForEach([0, 6, 12, 18], id: \.self) { hour in
                    Text(WorkingHours.text(hour * 60))
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                        .offset(x: proxy.size.width * CGFloat(hour) / 24)
                }
            }
            .frame(height: 12)
        }
    }

    /// The line at the time compared, with that time on top, over the bars; clicks and drags
    /// across the bars move it.
    private var cursor: some View {
        HStack(spacing: 6) {
            Color.clear.frame(width: Self.labelWidth, height: 1)
            GeometryReader { proxy in
                let x = proxy.size.width * CGFloat(selected) / CGFloat(Self.day)
                ZStack(alignment: .topLeading) {
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                            let minute = Double(drag.location.x / proxy.size.width) * Double(Self.day)
                            pick(min(max(Int((minute / 15).rounded()) * 15, 0), Self.day - 15))
                        })
                        .pointingHandCursor()
                    Rectangle()
                        .fill(Color.primary)
                        .frame(width: 1.5, height: proxy.size.height - 12)
                        .offset(x: x - 0.75)
                        .allowsHitTesting(false)
                }
            }
        }
    }
}
