import AppKit
import CalendarSyncCore
import SwiftUI

/// The month grid and event list shown at the top of the menu when "Show a calendar in the
/// menu" is on. Events come from the main calendar, where secondary-calendar meetings are already copied.
struct MenuCalendarView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var controller: SyncController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("menuCalendarMode") private var mode: Mode = .month
    @State private var shownMonth = Date()
    /// The edge the next month grid slides in from: trailing going forward, leading going back.
    @State private var direction = Edge.trailing
    /// A day picked in the month grid, shown as that day's event list until dismissed.
    @State private var selectedDay: Date?
    /// Where the picked day's cell sits in the month view, so its list grows out of it.
    @State private var dayAnchor = UnitPoint.center
    @State private var events: [SourceEvent] = []
    /// Height of the month view, which the picked day's list takes too: the menu window
    /// mustn't resize while the day grows out of its cell (see `WindowTopAnchor`).
    @State private var monthHeight: CGFloat = 0
    /// Today's finished meetings in the List view, folded into one row until opened.
    @State private var showsEarlier = false
    /// Which calendar Meeting Stats counts: empty for the main calendar, which holds every
    /// meeting, or a secondary calendar's id for the meetings copied from it.
    @AppStorage("meetingStatsCalendar") private var statsCalendar = ""

    enum Mode: String {
        case month, list, stats
    }

    /// The saved mode, or the list when Stats was picked and Meeting Stats is now off.
    private var shownMode: Mode {
        mode == .stats && !settings.menuCalendar.showsMeetingStats ? .list : mode
    }

    private var calendar: Calendar { settings.menuCalendar.applied(to: .current) }
    private var showsWeekends: Bool { settings.menuCalendar.showsWeekends }

    /// Slides and growth, or plain fades with Reduce Motion on.
    private var motion: Animation { reduceMotion ? .easeInOut(duration: 0.2) : .snappy(duration: 0.32) }

    var body: some View {
        VStack(spacing: 10) {
            SlidingSegments(options: modes, selection: Binding(get: { shownMode }, set: { mode = $0 }))

            ZStack(alignment: .top) {
                switch shownMode {
                case .month:
                    monthOrDay
                case .list:
                    listView.transition(.opacity)
                case .stats:
                    VStack(spacing: 8) {
                        if settings.sources.isEmpty == false {
                            statsCalendarPicker
                        }
                        let workingHours = settings.menuCalendar.workingHours
                        MeetingStatsView(stats: MeetingStats.summary(of: statsEvents, now: Date(), calendar: calendar,
                                                                     workingHours: workingHours),
                                         calendar: calendar, workingHours: workingHours)
                    }
                    .transition(.opacity)
                }
            }
        }
        .onAppear { reload() }
        .onChange(of: mode) { _, _ in reload() }
        .onChange(of: shownMonth) { _, _ in reload() }
        .onChange(of: settings.menuCalendar) { _, _ in reload() }
        .onChange(of: controller.lastSync) { _, _ in reload() }
    }

    private var modes: [(value: Mode, title: String)] {
        [(.month, "Month"), (.list, "List")] + (settings.menuCalendar.showsMeetingStats ? [(.stats, "Stats")] : [])
    }

    // MARK: - Data

    /// Reads the shown month (or the list's window) from the main calendar.
    private func reload() {
        guard let targetID = settings.targetCalendarID else {
            events = []
            return
        }
        let (from, to): (Date, Date)
        switch shownMode {
        case .month:
            let days = gridDays(for: shownMonth)
            guard let first = days.first, let last = days.last,
                  let end = calendar.date(byAdding: .day, value: 1, to: last) else { return }
            (from, to) = (first, end)
        case .list:
            let today = calendar.startOfDay(for: Date())
            (from, to) = (calendar.date(byAdding: .day, value: -30, to: today)!,
                          calendar.date(byAdding: .day, value: 60, to: today)!)
        case .stats:
            let window = MeetingStats.window(now: Date(), calendar: calendar)
            (from, to) = (window.start, window.end)
        }
        if case .success(let fetched) = controller.eventKit.sourceEvents(calendarID: targetID, from: from, to: to) {
            events = fetched.filter { !$0.isCancelled }
        }
    }

    // MARK: - Stats

    /// The picked calendar, or all of them when the picked one was removed.
    private var shownStatsCalendar: String {
        settings.sources.contains(where: { $0.id.uuidString == statsCalendar }) ? statsCalendar : ""
    }

    /// The events Meeting Stats counts: all of them, or those of the picked calendar.
    private var statsEvents: [SourceEvent] {
        switch shownStatsCalendar {
        case "": events
        case let id: events.filter { MenuCalendar.originID(of: $0)?.uuidString == id }
        }
    }

    /// All (the main calendar, which holds every meeting) | each secondary calendar.
    /// Segmented while the names fit, else a menu.
    private var statsCalendarPicker: some View {
        let mainName = controller.eventKit.calendar(id: settings.targetCalendarID)?.title
        let options = [("", mainName.map { "All (\($0))" } ?? "All")]
            + settings.sources.map { ($0.id.uuidString, $0.calendarName) }
        let picker = Picker("Calendar", selection: Binding(get: { shownStatsCalendar }, set: { statsCalendar = $0 })) {
            ForEach(options, id: \.0) { tag, name in
                Text(name).tag(tag)
            }
        }
        .labelsHidden()
        return Group {
            if options.count <= 4 && options.map(\.1.count).reduce(0, +) <= 36 {
                picker.pickerStyle(.segmented)
            } else {
                picker.pickerStyle(.menu).fixedSize()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func events(on day: Date) -> [SourceEvent] {
        events
            .filter { calendar.isDate($0.start, inSameDayAs: day) }
            .sorted { ($0.start, $0.title) < ($1.start, $1.title) }
    }

    // MARK: - Month

    /// The month grid, or the picked day's list grown out of its cell, in the same height.
    private var monthOrDay: some View {
        ZStack(alignment: .top) {
            if let day = selectedDay {
                dayView(day)
                    .frame(height: monthHeight > 0 ? monthHeight : nil, alignment: .top)
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.25, anchor: dayAnchor).combined(with: .opacity))
                    .zIndex(1)
            } else {
                monthView
                    .background(GeometryReader { proxy in
                        Color.clear.preference(key: MonthHeightKey.self, value: proxy.size.height)
                    })
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.97).combined(with: .opacity))
            }
        }
        .onPreferenceChange(MonthHeightKey.self) { if $0 > 0 { monthHeight = $0 } }
    }

    private struct MonthHeightKey: PreferenceKey {
        static let defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
    }

    /// The days of `month`'s grid, always six weeks: the weeks after the month fill the rest,
    /// so the grid keeps its height from month to month and the menu window doesn't resize
    /// while the next month slides in.
    private func gridDays(for month: Date) -> [Date] {
        var days = MenuCalendar.gridDays(for: month, calendar: calendar, showsWeekends: showsWeekends)
        let columns = MenuCalendar.weekdays(calendar: calendar, showsWeekends: showsWeekends).count
        guard columns > 0, var day = days.last else { return days }
        while days.count < columns * 6 {
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
            if showsWeekends || !calendar.isDateInWeekend(day) { days.append(day) }
        }
        return days
    }

    private var isShowingThisMonth: Bool {
        calendar.isDate(shownMonth, equalTo: Date(), toGranularity: .month)
    }

    private var monthView: some View {
        let days = gridDays(for: shownMonth)
        let weekdays = MenuCalendar.weekdays(calendar: calendar, showsWeekends: showsWeekends)
        return VStack(spacing: 2) {
            HStack(spacing: 2) {
                (Text(shownMonth, format: .dateTime.month(.wide)) + Text(" ")
                    + Text(shownMonth, format: .dateTime.year()).foregroundStyle(.secondary))
                    .font(.system(size: 15, weight: .semibold))
                    .id(monthKey(shownMonth))
                    .transition(.opacity)
                Spacer()
                if !isShowingThisMonth {
                    Button("Today") { show(month: Date()) }
                        .buttonStyle(PillButtonStyle())
                        .padding(.trailing, 4)
                        .transition(.scale(scale: 0.8).combined(with: .opacity))
                }
                IconButton("chevron.left", help: "Previous month") { step(by: -1) }
                IconButton("chevron.right", help: "Next month") { step(by: 1) }
            }
            .padding(.leading, 2)

            // By weekday: the very short symbols repeat (two "T"s, two "S"s).
            HStack(spacing: 2) {
                ForEach(weekdays, id: \.self) { weekday in
                    Text(calendar.veryShortStandaloneWeekdaySymbols[weekday - 1])
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 18)

            ZStack {
                monthGrid(days: days, columns: weekdays.count)
                    .id(monthKey(shownMonth))
                    .transition(reduceMotion ? .opacity : .push(from: direction))
            }
            .clipped()
        }
    }

    private func monthKey(_ month: Date) -> String {
        let parts = calendar.dateComponents([.year, .month], from: month)
        return "\(parts.year ?? 0)-\(parts.month ?? 0)"
    }

    private func step(by months: Int) {
        if let month = calendar.date(byAdding: .month, value: months, to: shownMonth) { show(month: month) }
    }

    /// Slides to `month`: from the trailing edge going forward, from the leading edge going back.
    private func show(month: Date) {
        guard !calendar.isDate(month, equalTo: shownMonth, toGranularity: .month) else { return }
        let edge: Edge = month > shownMonth ? .trailing : .leading
        // The grid leaving takes its transition from the last update, so the edge changes
        // first, in an update of its own, and the month in the next one.
        if edge != direction {
            direction = edge
            DispatchQueue.main.async { withAnimation(motion) { shownMonth = month } }
        } else {
            withAnimation(motion) { shownMonth = month }
        }
    }

    private func monthGrid(days: [Date], columns: Int) -> some View {
        let dots = dotsByDay()
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: columns), spacing: 1) {
            ForEach(Array(days.enumerated()), id: \.element) { index, day in
                let isToday = calendar.isDateInToday(day)
                let inMonth = calendar.isDate(day, equalTo: shownMonth, toGranularity: .month)
                DayCell(
                    number: calendar.component(.day, from: day),
                    isToday: isToday,
                    inMonth: inMonth,
                    isPast: !isToday && day < Date(),
                    dots: dots[calendar.startOfDay(for: day)] ?? []
                ) {
                    open(day, index: index, of: days.count, columns: columns)
                }
                .accessibilityLabel(Text(day, format: .dateTime.weekday(.wide).day().month(.wide)))
            }
        }
        .background(alignment: .topLeading) { weekendBands(days: days, columns: columns) }
    }

    /// One soft band behind each run of weekend columns, so weekends read as a block.
    private func weekendBands(days: [Date], columns: Int) -> some View {
        let weekend = days.prefix(columns).enumerated()
            .filter { calendar.isDateInWeekend($0.element) }.map(\.offset)
        // Runs of neighbouring columns: Saturday and Sunday side by side make one band.
        var runs: [ClosedRange<Int>] = []
        for column in weekend {
            if let last = runs.last, last.upperBound == column - 1 {
                runs[runs.count - 1] = last.lowerBound...column
            } else {
                runs.append(column...column)
            }
        }
        return GeometryReader { proxy in
            let spacing: CGFloat = 2
            let width = (proxy.size.width - spacing * CGFloat(columns - 1)) / CGFloat(max(columns, 1))
            ForEach(runs, id: \.lowerBound) { run in
                RoundedRectangle(cornerRadius: 9)
                    .fill(Color.secondary.opacity(0.09))
                    .frame(width: width * CGFloat(run.count) + spacing * CGFloat(run.count - 1),
                           height: proxy.size.height)
                    .offset(x: CGFloat(run.lowerBound) * (width + spacing))
            }
        }
    }

    /// Up to three dots per day, in the colors of the calendars its meetings came from, or one
    /// accent dot when events aren't colored by calendar.
    private func dotsByDay() -> [Date: [Color]] {
        var byDay: [Date: [Color]] = [:]
        var seen: [Date: Set<String>] = [:]
        var origins: [String: Color] = [:]
        let colors = settings.menuCalendar.colorsByCalendar
        for event in events.sorted(by: { $0.start < $1.start }) {
            let day = calendar.startOfDay(for: event.start)
            guard (byDay[day]?.count ?? 0) < (colors ? 3 : 1) else { continue }
            let key = colors ? (MenuCalendar.originID(of: event)?.uuidString ?? "main") : "any"
            guard seen[day, default: []].insert(key).inserted else { continue }
            if origins[key] == nil {
                origins[key] = colors
                    ? (EventOrigin.of(event, settings: settings, eventKit: controller.eventKit)?.color ?? .accentColor)
                    : .accentColor
            }
            byDay[day, default: []].append(origins[key]!)
        }
        return byDay
    }

    /// Opens `day`'s list, growing out of its cell.
    private func open(_ day: Date, index: Int, of count: Int, columns: Int) {
        let rows = max(count / max(columns, 1), 1)
        let column = index % max(columns, 1), row = index / max(columns, 1)
        // The grid starts below the header and the weekday letters, about a fifth of the way down.
        dayAnchor = UnitPoint(x: (CGFloat(column) + 0.5) / CGFloat(columns),
                              y: 0.2 + 0.8 * (CGFloat(row) + 0.5) / CGFloat(rows))
        withAnimation(motion) { selectedDay = day }
    }

    // MARK: - One day

    private func dayView(_ day: Date) -> some View {
        let dayEvents = events(on: day)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                IconButton("chevron.left", help: "Back to the month") {
                    withAnimation(motion) { selectedDay = nil }
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text(day, format: .dateTime.weekday(.wide).day().month(.wide))
                        .font(.system(size: 14, weight: .semibold))
                    Text(daySummary(dayEvents, on: day) + (calendar.isDateInToday(day) ? " · today" : ""))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            if dayEvents.isEmpty {
                EmptyDay(day: day)
                    .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        eventRows(dayEvents, nowLine: calendar.isDateInToday(day))
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// "6 meetings · 4 hours", or "No meetings".
    private func daySummary(_ dayEvents: [SourceEvent], on day: Date) -> String {
        let meetings = dayEvents.filter { !$0.isAllDay && !$0.isDeclined }
        guard !meetings.isEmpty, let interval = calendar.dateInterval(of: .day, for: day) else { return "No meetings" }
        let hours = MeetingStats.hours(of: meetings, in: interval).hours
        let count = "\(meetings.count) \(meetings.count == 1 ? "meeting" : "meetings")"
        return hours > 0 ? "\(count) · \(MeetingStats.format(hours))" : count
    }

    // MARK: - List

    /// Height of the List view's scrolling events.
    private static let listHeight: CGFloat = 300

    /// Every event of the window, one section per day under a header that stays put while its
    /// day scrolls. Opens at today; today's finished meetings are folded into one row, and
    /// scrolling back shows past days dimmed.
    private var listView: some View {
        let sections = MenuCalendar.sections(for: events, calendar: calendar)
        let today = calendar.startOfDay(for: Date())
        let anchor = sections.first { $0.day >= today }?.day
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2, pinnedViews: .sectionHeaders) {
                    if sections.isEmpty {
                        Text("No events")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 60)
                    }
                    ForEach(sections, id: \.day) { section in
                        let isToday = calendar.isDateInToday(section.day)
                        Section {
                            eventRows(section.events, nowLine: isToday, foldsEarlier: isToday)
                                .padding(.bottom, 6)
                        } header: {
                            dayHeader(section)
                                .id(section.day)
                        }
                    }
                }
            }
            .frame(height: Self.listHeight)
            .onAppear {
                // After the first layout, so the lazy stack knows where today is.
                if let anchor { DispatchQueue.main.async { proxy.scrollTo(anchor, anchor: .top) } }
            }
        }
    }

    private func dayHeader(_ section: MenuCalendar.DaySection) -> some View {
        let isToday = calendar.isDateInToday(section.day)
        let isPast = section.day < calendar.startOfDay(for: Date())
        let relative = relativeName(section.day)
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(relative ?? section.day.formatted(.dateTime.weekday(.wide)))
                .font(.system(size: 11, weight: .bold))
                .textCase(.uppercase)
                .tracking(0.5)
                .foregroundStyle(isToday ? AnyShapeStyle(Color.accentColor) : isPast ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            Text(relative == nil ? section.day.formatted(.dateTime.day().month())
                                 : section.day.formatted(.dateTime.weekday().day().month()))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(daySummary(section.events, on: section.day))
                .font(.system(size: 10.5))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(.bar)
    }

    private func relativeName(_ day: Date) -> String? {
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInTomorrow(day) { return "Tomorrow" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return nil
    }

    // MARK: - Event rows

    /// One day's events: all-day ones first, then the morning and afternoon ones, each in a
    /// colored block when that's on. Today gets a line at the current time, and in the List
    /// view its finished meetings fold into one row. Rows carry their key as id.
    @ViewBuilder
    private func eventRows(_ dayEvents: [SourceEvent], nowLine: Bool = false, foldsEarlier: Bool = false) -> some View {
        let now = Date()
        let options = settings.menuCalendar
        let parts = MenuCalendar.parts(of: dayEvents, calendar: calendar)
        let timed = parts.morning + parts.afternoon
        let earlier = foldsEarlier ? timed.filter { $0.end < now } : []
        let folded = Set(showsEarlier ? [] : earlier.map(\.key))
        // The now line goes before the first meeting still to start, or after the last one.
        let nextKey = nowLine ? timed.first { $0.start > now }?.key : nil

        ForEach(parts.allDay, id: \.key) { allDayRow($0, shaded: options.shadesAllDay) }
        if !earlier.isEmpty {
            EarlierRow(events: earlier, isOpen: showsEarlier) {
                withAnimation(motion) { showsEarlier.toggle() }
            }
        }
        if options.shadesTimeOfDay {
            timeOfDayBlock("Morning", symbol: "sun.max.fill", parts.morning.filter { !folded.contains($0.key) },
                           color: .orange, nextKey: nextKey)
            timeOfDayBlock("Afternoon", symbol: "moon.fill", parts.afternoon.filter { !folded.contains($0.key) },
                           color: .indigo, nextKey: nextKey)
        } else {
            timedRows(timed.filter { !folded.contains($0.key) }, nextKey: nextKey)
        }
        if nowLine && nextKey == nil && !timed.isEmpty {
            NowLine(now: now)
        }
    }

    @ViewBuilder
    private func timeOfDayBlock(_ title: String, symbol: String, _ blockEvents: [SourceEvent], color: Color,
                                nextKey: String?) -> some View {
        if !blockEvents.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Label(title, systemImage: symbol)
                    .font(.system(size: 9.5, weight: .bold))
                    .textCase(.uppercase)
                    .tracking(0.5)
                    .foregroundStyle(color.opacity(0.85))
                    .padding(.horizontal, 8)
                    .padding(.top, 5)
                timedRows(blockEvents, nextKey: nextKey)
            }
            .padding(.bottom, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func timedRows(_ list: [SourceEvent], nextKey: String?) -> some View {
        ForEach(list, id: \.key) { event in
            if event.key == nextKey { NowLine(now: Date()) }
            EventRow(event: event, origin: origin(of: event), tint: tint(of: event))
                .id(event.key)
        }
    }

    private func allDayRow(_ event: SourceEvent, shaded: Bool) -> some View {
        let tint = tint(of: event) ?? .secondary
        return HStack(spacing: 8) {
            Text("All day")
                .font(.system(size: 9.5, weight: .bold))
                .textCase(.uppercase)
                .foregroundStyle(tint)
            Text(MenuCalendar.displayTitle(of: event))
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: 4)
            if let origin = origin(of: event) {
                Text(origin.name).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(tint.opacity(shaded ? 0.18 : 0.07), in: RoundedRectangle(cornerRadius: 8))
        .opacity(event.end < Date() ? 0.45 : 1)
        .id(event.key)
    }

    private func origin(of event: SourceEvent) -> EventOrigin? {
        EventOrigin.of(event, settings: settings, eventKit: controller.eventKit)
    }

    /// The color of the calendar an event was copied from, when events are colored that way.
    private func tint(of event: SourceEvent) -> Color? {
        settings.menuCalendar.colorsByCalendar ? origin(of: event)?.color : nil
    }
}

/// One day in the month grid: today in a filled circle, a dot per calendar with meetings, and
/// a soft highlight under the pointer.
private struct DayCell: View {
    let number: Int
    let isToday: Bool
    let inMonth: Bool
    let isPast: Bool
    let dots: [Color]
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Text("\(number)")
                    .font(.system(size: 12.5, weight: isToday ? .semibold : .regular))
                    .monospacedDigit()
                    .foregroundStyle(isToday ? AnyShapeStyle(.white)
                                     : !inMonth ? AnyShapeStyle(.tertiary)
                                     : isPast ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    .frame(width: 22, height: 22)
                    .background {
                        if isToday {
                            Circle()
                                .fill(Color.accentColor)
                                .shadow(color: Color.accentColor.opacity(0.45), radius: 3, y: 1)
                        }
                    }
                HStack(spacing: 2) {
                    ForEach(dots.indices, id: \.self) { index in
                        Circle().fill(dots[index]).frame(width: 4, height: 4)
                    }
                }
                .frame(height: 4)
                .opacity(inMonth ? 1 : 0.45)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 34)
            .background(hovering ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// "Nothing on Saturday", for a day without events.
private struct EmptyDay: View {
    let day: Date

    var body: some View {
        VStack(spacing: 3) {
            Image(systemName: "leaf.fill")
                .font(.title3)
                .foregroundStyle(.green)
                .padding(.bottom, 2)
            Text("Nothing on \(day.formatted(.dateTime.weekday(.wide)))")
                .font(.callout.weight(.semibold))
            Text("No events in your main calendar.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 90)
    }
}

/// A red line at the current time, between the last meeting and the next one.
private struct NowLine: View {
    let now: Date

    var body: some View {
        HStack(spacing: 9) {
            Text(now, format: .dateTime.hour().minute())
                .font(.system(size: 9.5, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(.red)
                .frame(width: 40, alignment: .trailing)
            Rectangle()
                .fill(.red)
                .frame(height: 1.5)
                .overlay(alignment: .leading) {
                    Circle().fill(.red).frame(width: 7, height: 7).offset(x: -3.5)
                }
        }
        .padding(.horizontal, 6)
        .frame(height: 12)
        .accessibilityLabel(Text("Now, \(now.formatted(.dateTime.hour().minute()))"))
        .id("now")
    }
}

/// Today's finished meetings, folded: "2 earlier · Standup, Sprint planning".
private struct EarlierRow: View {
    let events: [SourceEvent]
    let isOpen: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
                Text("\(events.count) earlier")
                    .font(.system(size: 11, weight: .semibold))
                if !isOpen {
                    Text(events.map { MenuCalendar.displayTitle(of: $0) }.joined(separator: ", "))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isOpen ? "Fold today's finished meetings" : "Show today's finished meetings")
    }
}

/// One event: start and end, a bar in its calendar's color, the title without the copy's
/// "[Calendar]" prefix, then its calendar, room and call service. A Join button from 15
/// minutes before until it ends; other calls show a faint camera that turns into a gray Join
/// button while the pointer is over the row. Finished events are dimmed.
private struct EventRow: View {
    let event: SourceEvent
    var origin: EventOrigin?
    /// The calendar's color, or nil when events aren't colored by calendar.
    var tint: Color?
    @State private var hovering = false

    private var meta: String {
        var parts: [String] = []
        if let origin { parts.append(origin.name) }
        if let location = event.location?.components(separatedBy: .newlines).first?
            .trimmingCharacters(in: .whitespaces), !location.isEmpty {
            parts.append(location)
        }
        if let url = event.meetingURL, let service = MeetingLink.serviceName(of: url) { parts.append(service) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        let now = Date()
        let isPast = event.end < now
        HStack(spacing: 9) {
            VStack(alignment: .trailing, spacing: 0) {
                Text(event.start, format: .dateTime.hour().minute())
                    .font(.system(size: 11.5, weight: .semibold))
                Text(event.end, format: .dateTime.hour().minute())
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .monospacedDigit()
            .frame(width: 40, alignment: .trailing)

            VStack(alignment: .leading, spacing: 1) {
                Text(MenuCalendar.displayTitle(of: event))
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                if !meta.isEmpty {
                    HStack(spacing: 4) {
                        if let tint { Circle().fill(tint).frame(width: 6, height: 6) }
                        Text(meta).lineLimit(1)
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.leading, 12)
            .overlay(alignment: .leading) {
                Capsule().fill(tint ?? Color.secondary.opacity(0.35)).frame(width: 3)
            }

            Spacer(minLength: 0)

            if let url = event.meetingURL, !isPast {
                if event.start.timeIntervalSince(now) <= 15 * 60 {
                    JoinButton(url: url)
                } else if hovering {
                    QuietJoinButton(url: url)
                } else {
                    Image(systemName: "video")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .padding(.trailing, 4)
                        .accessibilityLabel("Has a call link")
                }
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 6)
        .background(hovering ? Color.primary.opacity(0.05) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .onHover { hovering = $0 }
        .opacity(isPast ? 0.45 : 1)
    }
}
