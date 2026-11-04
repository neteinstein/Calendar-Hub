import Charts
import CalendarSyncCore
import SwiftUI

/// The menu's Stats view: hours in meetings around today, the last two weeks as a chart, a few
/// insights, and where a year of this is heading. Shown when Meeting Stats is on.
struct MeetingStatsView: View {
    let stats: MeetingStats.Summary
    let calendar: Calendar
    let workingHours: WorkingHours

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

    /// Tall enough for all the stats when the screen has room; scrolls otherwise, never shorter
    /// than it used to be.
    private var height: CGFloat {
        let minimum: CGFloat = 380
        guard contentHeight > minimum else { return minimum }
        return min(contentHeight, max(minimum, roomOnScreen))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 6) {
                    dayTile("Yesterday", stats.yesterday)
                    dayTile("Today", stats.today, highlighted: true)
                    dayTile("Tomorrow", stats.tomorrow, note: "scheduled")
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
            .background(GeometryReader { proxy in
                Color.clear.preference(key: ContentHeightKey.self, value: proxy.size.height)
            })
        }
        .onPreferenceChange(ContentHeightKey.self) { contentHeight = $0 }
        .frame(height: height)
        .background(ScreenRoom { roomOnScreen = $0 })
    }

    private struct ContentHeightKey: PreferenceKey {
        static let defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
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
                guard let window, let screen = window.screen else { return }
                let spare = screen.visibleFrame.height - window.frame.height - 12
                let room = (bounds.height + spare).rounded(.down)
                DispatchQueue.main.async { [report] in report?(room) }
            }
        }
    }

    // MARK: - Days

    /// One day's hours, with a bar for how much of the working day they fill.
    private func dayTile(_ title: String, _ hours: MeetingStats.Hours, note: String? = nil,
                         highlighted: Bool = false) -> some View {
        let share = min(hours.hours / workingDayHours, 1)
        return VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            Text(MeetingStats.format(hours.hours))
                .font(.title3.weight(.semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Group {
                if let overlap = MeetingStats.overlapNote(hours) {
                    Text(overlap).foregroundStyle(.orange)
                } else {
                    Text(note ?? " ").foregroundStyle(.tertiary)
                }
            }
                .font(.caption2)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.secondary.opacity(0.15))
                    Capsule().fill(loadColor(share)).frame(width: proxy.size.width * share)
                }
            }
            .frame(height: 4)
            .help("\(Int((share * 100).rounded()))% of a \(workingDayText) working day")
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(highlighted ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            if highlighted {
                RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor.opacity(0.35))
            }
        }
    }

    /// Green while there's room for focused work, orange past half the day, red past three quarters.
    private func loadColor(_ share: Double) -> Color {
        share < 0.5 ? .green : share < 0.75 ? .orange : .red
    }

    // MARK: - Chart

    /// The last two weeks' working days, today and tomorrow. Time in overlapping meetings is
    /// stacked on top in a lighter shade; the dashed line is the average.
    private var chart: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                sectionTitle("Last two weeks")
                Spacer()
                legend(Rectangle().fill(Color.orange.opacity(0.5)).frame(width: 8, height: 8), "overlap")
                legend(Rectangle().fill(.secondary).frame(width: 10, height: 1), "average")
            }
            Chart {
                ForEach(stats.recentDays, id: \.day) { day in
                    let isToday = calendar.isDateInToday(day.day)
                    let isFuture = day.day > Date()
                    BarMark(x: .value("Day", day.day, unit: .day), y: .value("Hours", day.hours.hours))
                        .foregroundStyle(isToday ? Color.accentColor : Color.accentColor.opacity(isFuture ? 0.3 : 0.6))
                        .cornerRadius(2)
                    if day.hours.hasOverlap {
                        BarMark(x: .value("Day", day.day, unit: .day),
                                y: .value("Overlap", day.hours.countingOverlap - day.hours.hours))
                            .foregroundStyle(Color.orange.opacity(0.5))
                            .cornerRadius(2)
                    }
                }
                if stats.averagePerWorkingDay.hours > 0 {
                    RuleMark(y: .value("Average", stats.averagePerWorkingDay.hours))
                        .foregroundStyle(.secondary)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
            }
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
            .frame(height: 110)
        }
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
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Insights")
            insight("calendar", .blue, "Last week", stats.lastWeek, detail: trendText)
            insight("calendar.badge.clock", .indigo, "Last month", stats.lastMonth)
            insight("chart.bar.fill", .teal, "Average per working day", stats.averagePerWorkingDay,
                    detail: "\(Int((stats.averagePerWorkingDay.hours / workingDayHours * 100).rounded()))% of a \(workingDayText) day")
            if let weekday = stats.busiestWeekday {
                insight("flame.fill", .orange, "Busiest day",
                        calendar.weekdaySymbols[weekday - 1] + "s",
                        detail: "\(MeetingStats.format(stats.busiestWeekdayHours)) on average")
            }
            if stats.meetingsLastWeek > 0 {
                insight("arrow.right.to.line", .pink, "Back to back last week",
                        "\(stats.backToBackLastWeek) of \(stats.meetingsLastWeek) meetings",
                        detail: "started within 5 minutes of the one before")
            }
            if let free = stats.longestFreeToday {
                insight("leaf.fill", .green, "Longest free block left today", durationText(free),
                        detail: "between \(WorkingHours.text(workingHours.start)) and \(WorkingHours.text(workingHours.end))")
            }
            if stats.workingHoursThisWeek > 0 {
                insight("airplane", .purple, "Out of office this week", MeetingStats.format(stats.outOfOfficeThisWeek),
                        detail: "\(Int((stats.outOfOfficeThisWeek / stats.workingHoursThisWeek * 100).rounded()))% of \(MeetingStats.format(stats.workingHoursThisWeek)) working hours")
            }
        }
    }

    private func insight(_ symbol: String, _ color: Color, _ title: String, _ hours: MeetingStats.Hours,
                         detail: Text? = nil) -> some View {
        insight(symbol, color, title, MeetingStats.format(hours.hours), note: MeetingStats.overlapNote(hours), detail: detail)
    }

    private func insight(_ symbol: String, _ color: Color, _ title: String, _ hours: MeetingStats.Hours,
                         detail: String) -> some View {
        insight(symbol, color, title, hours, detail: Text(detail))
    }

    private func insight(_ symbol: String, _ color: Color, _ title: String, _ value: String,
                         detail: String) -> some View {
        insight(symbol, color, title, value, detail: Text(detail))
    }

    /// A row: icon, title and value, with an orange overlap note and a detail line under them.
    private func insight(_ symbol: String, _ color: Color, _ title: String, _ value: String,
                         note: String? = nil, detail: Text? = nil) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .font(.caption)
                .foregroundStyle(color)
                .frame(width: 22, height: 22)
                .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).foregroundStyle(.secondary)
                    Spacer(minLength: 6)
                    Text(value).fontWeight(.semibold).monospacedDigit().multilineTextAlignment(.trailing)
                }
                .font(.callout)
                HStack(alignment: .firstTextBaseline) {
                    if let detail {
                        detail.foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 6)
                    if let note {
                        Text(note).foregroundStyle(.orange)
                    }
                }
                .font(.caption)
            }
        }
    }

    /// "↑ 25% on the week before", colored: more meetings is the warning direction.
    private var trendText: Text? {
        guard let trend = MeetingStats.trend(stats) else { return nil }
        let percent = Int((abs(trend) * 100).rounded())
        if percent == 0 { return Text("same as the week before") }
        let up = trend > 0
        return Text("\(up ? "↑" : "↓") \(percent)%").foregroundColor(up ? .orange : .green)
            + Text(" on the week before")
    }

    private func durationText(_ interval: TimeInterval) -> String {
        let minutes = Int(interval / 60)
        let (h, m) = (minutes / 60, minutes % 60)
        return h == 0 ? "\(m) min" : m == 0 ? "\(h) h" : "\(h) h \(m) min"
    }

    // MARK: - Year

    /// The yearly prediction, pictured as something else that takes as long.
    private var yearCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Label("Prediction per year", systemImage: "figure.walk")
                    .font(.callout.weight(.medium))
                Spacer()
                VStack(alignment: .trailing, spacing: 0) {
                    Text(MeetingStats.format(stats.perYear.hours))
                        .font(.title3.weight(.semibold).monospacedDigit())
                    if let overlap = MeetingStats.overlapNote(stats.perYear) {
                        Text(overlap).font(.caption).foregroundStyle(.orange)
                    }
                }
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
        .padding(10)
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
