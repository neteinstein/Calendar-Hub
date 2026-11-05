import Charts
import CalendarSyncCore
import SwiftUI

/// The menu's Stats view: hours in meetings around today, the last two weeks as a chart, a few
/// insights, and where a year of this is heading. Shown when Meeting Stats is on. The numbers
/// count up and the bars grow when it opens.
struct MeetingStatsView: View {
    let stats: MeetingStats.Summary
    let calendar: Calendar
    let workingHours: WorkingHours
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Off until the view appears, then on with an animation: the numbers and bars grow from zero.
    @State private var shown = false
    /// The day under the pointer in the chart.
    @State private var hoveredDay: Date?

    /// Hours of the working day, to show days as a share of it.
    private var workingDayHours: Double {
        max(workingHours.hours, 1)
    }

    /// "8-hour", "7.5-hour".
    private var workingDayText: String {
        let hours = workingHours.hours
        return (hours == hours.rounded() ? String(Int(hours)) : String(format: "%.1f", hours)) + "-hour"
    }

    /// Height of everything in the scroll view, to show all of it when the screen has room.
    @State private var contentHeight: CGFloat = 0
    /// The most the scroll view can grow to before the menu runs off the bottom of the screen.
    @State private var roomOnScreen: CGFloat = 0

    /// Every stat at once, without scrolling, for screenshots.
    static var showsEverything = false

    /// Tall enough for all the stats when the screen has room; scrolls otherwise, never shorter
    /// than it used to be.
    private var height: CGFloat {
        let minimum: CGFloat = 380
        guard contentHeight > minimum else { return minimum }
        if Self.showsEverything { return contentHeight }
        return min(contentHeight, max(minimum, roomOnScreen))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 6) {
                    dayTile("Yesterday", stats.yesterday)
                    dayTile("Today", stats.today, highlighted: true)
                    dayTile("Tomorrow", stats.tomorrow, scheduled: true)
                }
                chart
                insights
                yearCard
                Text("Timed meetings in your main calendar. All-day, declined and out-of-office events don't count, and time in overlapping meetings counts once. Out of office counts the time it covers within working hours, from Monday to Friday.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 2)
            // Read straight from the geometry: a preference from inside the scroll view
            // arrived as 0, which kept the view at its minimum height.
            .background(GeometryReader { proxy in
                Color.clear
                    .onAppear { contentHeight = proxy.size.height }
                    .onChange(of: proxy.size.height) { _, height in contentHeight = height }
            })
        }
        .frame(height: height)
        .background(ScreenRoom { roomOnScreen = $0 })
        .onAppear {
            guard !shown else { return }
            if reduceMotion {
                shown = true
            } else {
                withAnimation(.smooth(duration: 0.8).delay(0.05)) { shown = true }
            }
        }
    }

    /// Reports how tall the view it backs could get: its height plus the screen's height the
    /// window isn't using, less a small margin above the Dock. Growing the view grows the window
    /// by as much, so the answer doesn't change as the view takes up the room.
    private struct ScreenRoom: NSViewRepresentable {
        let report: (CGFloat) -> Void

        func makeNSView(context: Context) -> ReportingView { ReportingView() }
        func updateNSView(_ view: ReportingView, context: Context) { view.report = report }

        final class ReportingView: NSView {
            var report: ((CGFloat) -> Void)?

            override func layout() {
                super.layout()
                // A window off screen (screenshots) gets the main screen's room.
                guard let window, let screen = window.screen ?? NSScreen.main else { return }
                let spare = screen.visibleFrame.height - window.frame.height - 12
                let room = (bounds.height + spare).rounded(.down)
                DispatchQueue.main.async { [report] in report?(room) }
            }
        }
    }

    // MARK: - Days

    /// One day's hours, large, with a ring for how much of the working day they fill.
    private func dayTile(_ title: String, _ hours: MeetingStats.Hours, scheduled: Bool = false,
                         highlighted: Bool = false) -> some View {
        let share = min(hours.hours / workingDayHours, 1)
        let percent = "\(Int((share * 100).rounded()))%"
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary)
                Spacer(minLength: 2)
                LoadRing(share: shown ? share : 0, color: loadColor(share))
            }
            AmountText(hours: shown ? hours.hours : 0, size: 22)
            Group {
                if let overlap = MeetingStats.overlapNote(hours) {
                    Text(overlap).foregroundStyle(.orange)
                } else {
                    Text(scheduled ? "scheduled · \(percent)" : "\(percent) of the day").foregroundStyle(.tertiary)
                }
            }
            .font(.system(size: 10))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(highlighted ? Color.accentColor.opacity(0.11) : Color.secondary.opacity(0.07),
                    in: RoundedRectangle(cornerRadius: 11))
        .overlay {
            if highlighted {
                RoundedRectangle(cornerRadius: 11).strokeBorder(Color.accentColor.opacity(0.3))
            }
        }
        .help("\(percent) of a \(workingDayText) working day")
    }

    /// Green while there's room for focused work, orange past half the day, red past three quarters.
    private func loadColor(_ share: Double) -> Color {
        share < 0.5 ? .green : share < 0.75 ? .orange : .red
    }

    // MARK: - Chart

    /// The last two weeks' working days, today and tomorrow. Time in overlapping meetings is
    /// stacked on top in a lighter shade; the dashed line is the average, with its value.
    /// Hovering a bar shows its day.
    private var chart: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                sectionTitle("Last two weeks")
                Spacer()
                legend(Rectangle().fill(Color.orange.opacity(0.5)).frame(width: 8, height: 8), "overlap")
                legend(Rectangle().fill(Color.accentColor.opacity(0.25)).frame(width: 8, height: 8), "scheduled")
            }
            Chart {
                ForEach(stats.recentDays, id: \.day) { day in
                    let isToday = calendar.isDateInToday(day.day)
                    let isFuture = day.day > Date()
                    let isHovered = hoveredDay.map { calendar.isDate($0, inSameDayAs: day.day) } ?? false
                    BarMark(x: .value("Day", day.day, unit: .day), y: .value("Hours", shown ? day.hours.hours : 0))
                        .foregroundStyle(Color.accentColor.opacity(isToday || isHovered ? 1 : isFuture ? 0.25 : 0.55))
                        .cornerRadius(3)
                    if day.hours.hasOverlap {
                        BarMark(x: .value("Day", day.day, unit: .day),
                                y: .value("Overlap", shown ? day.hours.countingOverlap - day.hours.hours : 0))
                            .foregroundStyle(Color.orange.opacity(0.55))
                            .cornerRadius(3)
                    }
                }
                if stats.averagePerWorkingDay.hours > 0 {
                    RuleMark(y: .value("Average", stats.averagePerWorkingDay.hours))
                        .foregroundStyle(.secondary)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .annotation(position: .top, alignment: .leading, spacing: 1) {
                            Text("avg " + AmountText.parts(stats.averagePerWorkingDay.hours).0
                                 + AmountText.parts(stats.averagePerWorkingDay.hours).1)
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        .opacity(shown ? 1 : 0)
                }
                if let hoveredDay, let day = stats.recentDays.first(where: { calendar.isDate($0.day, inSameDayAs: hoveredDay) }) {
                    RuleMark(x: .value("Day", day.day, unit: .day))
                        .foregroundStyle(.clear)
                        .annotation(position: .top, spacing: 0,
                                    overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                            tooltip(for: day)
                        }
                }
            }
            .chartXSelection(value: $hoveredDay)
            .chartXAxis {
                AxisMarks(values: stats.recentDays.map(\.day)) { value in
                    AxisValueLabel {
                        if let date = value.as(Date.self) {
                            Text(calendar.veryShortWeekdaySymbols[calendar.component(.weekday, from: date) - 1])
                                .fontWeight(calendar.isDateInToday(date) ? .bold : .regular)
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine()
                    AxisValueLabel { if let hours = value.as(Double.self) { Text("\(Int(hours))h") } }
                }
            }
            .frame(height: 120)
        }
    }

    private func tooltip(for day: MeetingStats.Day) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(day.day, format: .dateTime.weekday(.abbreviated).day().month())
                .font(.system(size: 10, weight: .semibold))
            Text(MeetingStats.text(day.hours) + (day.day > Date() ? " scheduled" : ""))
                .font(.system(size: 10))
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
    }

    private func legend(_ swatch: some View, _ title: String) -> some View {
        HStack(spacing: 3) {
            swatch
            Text(title)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    // MARK: - Insights

    private var insights: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Insights")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                tile("calendar", .blue, "Last week", amount: stats.lastWeek, detail: trendText ?? Text("the week before had none"))
                tile("calendar.badge.clock", .indigo, "Last month", amount: stats.lastMonth,
                     detail: Text(previousMonthName))
                tile("chart.bar.fill", .teal, "Per working day", amount: stats.averagePerWorkingDay,
                     detail: Text("\(Int((stats.averagePerWorkingDay.hours / workingDayHours * 100).rounded()))% of a \(workingDayText) day"))
                if let weekday = stats.busiestWeekday {
                    tile("flame.fill", .orange, "Busiest day", value: Text(calendar.weekdaySymbols[weekday - 1] + "s"),
                         detail: Text("\(MeetingStats.format(stats.busiestWeekdayHours)) on average"))
                }
                if stats.meetingsLastWeek > 0 {
                    tile("arrow.right.to.line", .pink, "Back to back",
                         value: Text("\(stats.backToBackLastWeek)") + Text(" of \(stats.meetingsLastWeek)").font(.system(size: 11.5)).foregroundStyle(.secondary),
                         detail: Text("last week, 5 min apart or less"))
                }
                if let free = stats.freeBlockToday {
                    tile("leaf.fill", .green, "Free block left", value: Text(durationText(free.duration)),
                         detail: Text("\(free.start.formatted(date: .omitted, time: .shortened)) – \(free.end.formatted(date: .omitted, time: .shortened))"))
                }
            }
            if stats.workingHoursThisWeek > 0 {
                HStack(spacing: 6) {
                    Image(systemName: "airplane").foregroundStyle(.purple)
                    Text("Out of office this week").foregroundStyle(.secondary)
                    Spacer(minLength: 6)
                    Text("\(MeetingStats.format(stats.outOfOfficeThisWeek)) · \(Int((stats.outOfOfficeThisWeek / stats.workingHoursThisWeek * 100).rounded()))%")
                        .fontWeight(.semibold)
                        .monospacedDigit()
                }
                .font(.system(size: 11))
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .background(Color.purple.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                .help("Of \(MeetingStats.format(stats.workingHoursThisWeek)) working hours this week")
            }
        }
    }

    private var previousMonthName: String {
        let previous = calendar.date(byAdding: .month, value: -1, to: Date()) ?? Date()
        return previous.formatted(.dateTime.month(.wide))
    }

    private func tile(_ symbol: String, _ color: Color, _ title: String, amount: MeetingStats.Hours,
                      detail: Text) -> some View {
        let overlap = MeetingStats.overlapNote(amount)
        return tile(symbol, color, title, value: nil, amount: amount.hours,
                    detail: overlap.map { Text($0).foregroundStyle(.orange) } ?? detail)
    }

    private func tile(_ symbol: String, _ color: Color, _ title: String, value: Text, detail: Text) -> some View {
        tile(symbol, color, title, value: value, amount: nil, detail: detail)
    }

    /// An insight: icon and title, the value large, a detail line under it.
    private func tile(_ symbol: String, _ color: Color, _ title: String, value: Text?, amount: Double?,
                      detail: Text) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(title, systemImage: symbol)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
                .labelStyle(TintedIconLabelStyle(color: color))
                .lineLimit(1)
            if let amount {
                AmountText(hours: shown ? amount : 0, size: 16)
            } else if let value {
                value.font(.system(size: 16, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
            }
            detail
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
    }

    /// "↑ 25% on the week before", colored: more meetings is the warning direction.
    private var trendText: Text? {
        guard let trend = MeetingStats.trend(stats) else { return nil }
        let percent = Int((abs(trend) * 100).rounded())
        if percent == 0 { return Text("same as the week before") }
        let up = trend > 0
        return Text("\(up ? "↑" : "↓") \(percent)%").foregroundColor(up ? .orange : .green).fontWeight(.bold)
            + Text(" on the week before")
    }

    private func durationText(_ interval: TimeInterval) -> String {
        let minutes = Int(interval / 60)
        let (h, m) = (minutes / 60, minutes % 60)
        return h == 0 ? "\(m) min" : m == 0 ? "\(h) h" : "\(h) h \(m) min"
    }

    // MARK: - Year

    /// The yearly prediction, pictured as something else that takes as long, with the journey
    /// drawn when it goes from one place to another.
    private var yearCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("This year, at this pace")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                VStack(alignment: .trailing, spacing: 0) {
                    AmountText(hours: shown ? stats.perYear.hours : 0, size: 20)
                    if let overlap = MeetingStats.overlapNote(stats.perYear) {
                        Text(overlap).font(.caption).foregroundStyle(.orange)
                    }
                }
            }
            if let route = MeetingStats.route(forYearlyHours: stats.perYear.hours) {
                RouteDrawing(route: route, progress: shown ? 1 : 0)
                    .frame(height: 56)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 1.6).delay(0.2), value: shown)
            }
            if let comparison = MeetingStats.comparison(forYearlyHours: stats.perYear.hours) {
                Text(comparison)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Not enough meetings yet to predict a year.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(colors: [Color.purple.opacity(0.16), Color.blue.opacity(0.1)],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 12))
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .tracking(0.5)
    }
}

/// Hours as a large number and a small unit, "4 h" or "45 min", rolling as the number changes.
private struct AmountText: View {
    let hours: Double
    let size: CGFloat

    var body: some View {
        let (number, unit) = Self.parts(hours)
        (Text(number).font(.system(size: size, weight: .semibold))
            + Text(" " + unit).font(.system(size: size * 0.55, weight: .medium)).foregroundStyle(.secondary))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .contentTransition(.numericText(value: hours))
    }

    /// "2.3 hours" as ("2.3", "h"), "45 min" as ("45", "min").
    static func parts(_ hours: Double) -> (String, String) {
        let text = MeetingStats.format(hours)
        guard let space = text.lastIndex(of: " ") else { return (text, "") }
        let unit = text[text.index(after: space)...]
        return (String(text[..<space]), unit.hasPrefix("hour") ? "h" : String(unit))
    }
}

/// A ring filled to a day's share of the working day.
private struct LoadRing: View {
    let share: Double
    let color: Color

    var body: some View {
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.18), lineWidth: 3)
            Circle()
                .trim(from: 0, to: share)
                .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 20, height: 20)
    }
}

/// An insight's icon in its own color, its title in the label's.
private struct TintedIconLabelStyle: LabelStyle {
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.foregroundStyle(color)
            configuration.title
        }
    }
}

/// A journey from one place to another, drawn as far as `progress`, with a walker at its tip.
private struct RouteDrawing: View {
    let route: MeetingStats.Route
    var progress: Double

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack(alignment: .topLeading) {
                RouteCurve().stroke(Color.secondary.opacity(0.45),
                                    style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [2, 4]))
                RouteCurve().trim(from: 0, to: progress)
                    .stroke(Color.purple, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                RouteCurve.Walker(progress: progress)
                    .fill(Color.purple)
                Text(route.from)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .position(x: 30, y: size.height - 5)
                Text(route.to)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .position(x: size.width - 30, y: 5)
            }
        }
        .accessibilityHidden(true)
    }
}

/// A gentle S from the bottom left to the top right.
private struct RouteCurve: Shape {
    static func points(in rect: CGRect) -> (CGPoint, CGPoint, CGPoint, CGPoint) {
        let inset = rect.insetBy(dx: 8, dy: 14)
        return (CGPoint(x: inset.minX, y: inset.maxY),
                CGPoint(x: inset.minX + inset.width * 0.3, y: inset.minY - 10),
                CGPoint(x: inset.minX + inset.width * 0.65, y: inset.maxY + 10),
                CGPoint(x: inset.maxX, y: inset.minY))
    }

    func path(in rect: CGRect) -> Path {
        let (start, c1, c2, end) = Self.points(in: rect)
        var path = Path()
        path.move(to: start)
        path.addCurve(to: end, control1: c1, control2: c2)
        return path
    }

    /// A dot where the drawn part of the curve ends.
    struct Walker: Shape {
        var progress: Double

        var animatableData: Double {
            get { progress }
            set { progress = newValue }
        }

        func path(in rect: CGRect) -> Path {
            let (p0, p1, p2, p3) = RouteCurve.points(in: rect)
            let t = min(max(progress, 0), 1), u = 1 - t
            let x = u * u * u * p0.x + 3 * u * u * t * p1.x + 3 * u * t * t * p2.x + t * t * t * p3.x
            let y = u * u * u * p0.y + 3 * u * u * t * p1.y + 3 * u * t * t * p2.y + t * t * t * p3.y
            return Path(ellipseIn: CGRect(x: x - 4.5, y: y - 4.5, width: 9, height: 9))
        }
    }
}
