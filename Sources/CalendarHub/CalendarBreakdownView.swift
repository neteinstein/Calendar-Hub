import Charts
import CalendarHubCore
import SwiftUI

/// The Stats view's "By calendar": hours in meetings last week and last month for each calendar
/// they came from, the main calendar's own (internal) included, and the last two weeks as a
/// chart stacked by calendar. Each calendar counts its own time, so with meetings from two
/// calendars at once the calendars add up to more than the total.
struct CalendarBreakdownView: View {
    /// A calendar's hours, with its name and color.
    struct Row: Identifiable {
        let group: MeetingStats.Breakdown.Group
        let name: String
        let color: Color
        var isInternal: Bool { group.calendar == nil }
        var id: String { group.calendar?.uuidString ?? "internal" }
    }

    let breakdown: MeetingStats.Breakdown
    /// One for each of `breakdown.groups`, in their order.
    let rows: [Row]
    let calendar: Calendar
    /// Shows one calendar's stats on their own: a secondary calendar's id, or nil for internal.
    var open: (UUID?) -> Void = { _ in }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Off until the view appears, then on with an animation: the numbers and bars grow from zero.
    @State private var shown = false
    /// The day under the pointer in the chart.
    @State private var hoveredDay: Date?

    private var mainName: String { rows.first(where: \.isInternal)?.name ?? "Main calendar" }

    var body: some View {
        StatsScroll {
            VStack(alignment: .leading, spacing: 12) {
                card("Last week", total: breakdown.lastWeek, \.lastWeek)
                card("Last month", total: breakdown.lastMonth, \.lastMonth)
                chart
                Text("Each calendar's own meetings: rows can add up to more than the total when meetings from two calendars overlap. \"\(mainName) (internal)\" is your main calendar without the copies. All-day, declined and out-of-office events don't count.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear {
            guard !shown else { return }
            if reduceMotion {
                shown = true
            } else {
                withAnimation(.smooth(duration: 0.8).delay(0.05)) { shown = true }
            }
        }
    }

    // MARK: - Periods

    /// A period's total, then a row per calendar, the most hours first, with a bar against the
    /// busiest one.
    private func card(_ title: String, total: MeetingStats.Hours,
                      _ hours: KeyPath<MeetingStats.Breakdown.Group, MeetingStats.Hours>) -> some View {
        // Stable: calendars with as many hours keep their order.
        let sorted = rows.enumerated()
            .sorted { ($0.element.group[keyPath: hours].hours, -$0.offset) > ($1.element.group[keyPath: hours].hours, -$1.offset) }
            .map(\.element)
        let busiest = max(sorted.first?.group[keyPath: hours].hours ?? 0, 0.01)
        let (number, unit) = AmountText.parts(shown ? total.hours : 0)
        return VStack(alignment: .leading, spacing: 7) {
            (Text(title) + Text(" · \(number) \(unit)").monospacedDigit())
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
                .contentTransition(.numericText(value: shown ? total.hours : 0))
            ForEach(sorted) { row in
                rowView(row, row.group[keyPath: hours], busiest: busiest)
            }
            if let overlap = MeetingStats.overlapNote(total) {
                Text(overlap).font(.system(size: 10.5)).foregroundStyle(.orange)
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 11))
    }

/// A calendar's name, hours and a bar as long as its share of `busiest`. Clicking it shows
    /// that calendar's stats on their own.
    private func rowView(_ row: Row, _ amount: MeetingStats.Hours, busiest: Double) -> some View {
        Button { open(row.group.calendar) } label: {
            HStack(spacing: 6) {
                Circle().fill(row.color).frame(width: 8, height: 8)
                (Text(row.name) + (row.isInternal ? Text(" (internal)").foregroundStyle(.tertiary) : Text("")))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 6)
                AmountText(hours: shown ? amount.hours : 0, size: 12.5)
                    .frame(width: 52, alignment: .trailing)
                Capsule()
                    .fill(row.color)
                    .frame(width: max(110 * (shown ? amount.hours / busiest : 0), amount.hours > 0 ? 4 : 0), height: 7)
                    .frame(width: 110, alignment: .leading)
            }
            .font(.system(size: 12))
            .opacity(amount.hours > 0 ? 1 : 0.5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(row.name): \(MeetingStats.text(amount)). Click for its stats on their own.")
    }

        // MARK: - Chart

    /// The bottom of each day's stack is the calendar with the most hours last month.
    private var chartRows: [Row] {
        rows.enumerated()
            .sorted { ($0.element.group.lastMonth.hours, -$0.offset) > ($1.element.group.lastMonth.hours, -$1.offset) }
            .map(\.element)
    }

    /// Each day's meetings stacked by calendar, in the cards' colors; today and tomorrow are
    /// lighter, as scheduled. Each calendar counts its own overlap once, so with meetings from
    /// two calendars at once a stack is taller than the time they took.
    private var chart: some View {
        VStack(alignment: .leading, spacing: 6) {
            StatsSectionTitle(title: "Last two weeks")
            Chart {
                ForEach(Array(breakdown.days.enumerated()), id: \.offset) { index, day in
                    let isFuture = day > Date()
                    let isHovered = hoveredDay.map { calendar.isDate($0, inSameDayAs: day) } ?? false
                    ForEach(chartRows) { row in
                        BarMark(x: .value("Day", day, unit: .day),
                                y: .value("Hours", shown ? row.group.recentDays[index].hours : 0))
                            .foregroundStyle(row.color.opacity(isHovered ? 1 : isFuture ? 0.3 : hoveredDay == nil ? 0.85 : 0.5))
                    }
                }
                if let hoveredDay, let index = breakdown.days.firstIndex(where: { calendar.isDate($0, inSameDayAs: hoveredDay) }) {
                    RuleMark(x: .value("Day", breakdown.days[index], unit: .day))
                        .foregroundStyle(.clear)
                        .annotation(position: .top, spacing: 0,
                                    overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                            tooltip(day: index)
                        }
                }
            }
            .chartXSelection(value: $hoveredDay)
            .chartXAxis {
                AxisMarks(values: breakdown.days) { value in
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

    /// The hovered day: each calendar with meetings that day, and its hours.
    private func tooltip(day index: Int) -> some View {
        let day = breakdown.days[index]
        let busy = chartRows.filter { $0.group.recentDays[index].hours > 0 }
        return VStack(alignment: .leading, spacing: 2) {
            Text(day, format: .dateTime.weekday(.abbreviated).day().month())
                .font(.system(size: 10, weight: .semibold))
            if busy.isEmpty {
                Text("No meetings").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            ForEach(busy) { row in
                HStack(spacing: 4) {
                    Circle().fill(row.color).frame(width: 6, height: 6)
                    Text("\(row.name) · \(MeetingStats.format(row.group.recentDays[index].hours))")
                }
                .font(.system(size: 10))
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
    }
}
