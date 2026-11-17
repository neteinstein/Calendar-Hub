import AppKit
import CalendarHubCore
import SwiftUI

/// Share availability, opened from the menu's footer in place of the calendar views: the free
/// time in every calendar over the next days, in the other person's time, as text to paste
/// into an email or chat.
struct AvailabilityView: View {
    /// Back to the calendar views.
    let close: () -> Void
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var controller: SyncController
    @AppStorage("availabilitySpan") private var span = Availability.Span.nextDays
    /// The other person's time zone, or empty for ours.
    @AppStorage("availabilityTimeZone") private var timeZoneID = ""
    /// The name for a time zone picked by searching, not one of the World Clocks.
    @AppStorage("availabilityPlaceName") private var otherName = ""
    @AppStorage("availabilityMinimum") private var minimumMinutes = 30
    @AppStorage("availabilityBothWorking") private var bothWorking = true
    @State private var events: [SourceEvent] = []
    @State private var searching = false
    @State private var query = ""
    @State private var copied = false
    @FocusState private var searchFocused: Bool

    private var share: AvailabilityShare {
        AvailabilityShare(settings: settings, controller: controller, span: span, timeZoneID: timeZoneID,
                          otherName: otherName, minimumMinutes: minimumMinutes, bothWorking: bothWorking)
    }

    private var places: [AvailabilityShare.Place] { share.places }
    private var place: AvailabilityShare.Place { share.place }
    private var limitsToTheirHours: Bool { share.limitsToTheirHours }
    private var plan: Availability.Plan { share.plan(events) }
    private var text: String { share.text(events) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Share availability")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                IconButton("xmark", help: "Close", action: close)
            }

            SlidingSegments(options: Availability.Span.allCases.map { ($0, $0.title) }, selection: $span)

            VStack(spacing: 0) {
                row("In their time") { placeMenu }
                if searching {
                    Divider().padding(.leading, 12)
                    search
                }
                Divider().padding(.leading, 12)
                row("Shortest slot") {
                    Picker("Shortest slot", selection: $minimumMinutes) {
                        Text("15 min").tag(15)
                        Text("30 min").tag(30)
                        Text("1 hour").tag(60)
                        Text("2 hours").tag(120)
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                Divider().padding(.leading, 12)
                row("Only when we're both working") {
                    Toggle("Only when we're both working", isOn: $bothWorking)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .disabled(place.isHere)
                }
                .help(place.isHere ? "Pick someone else's time to use their working hours too"
                    : "Only times within \(place.name)'s working hours as well as yours")
            }
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))

            Text(text)
                .font(.system(size: 11.5, design: .monospaced))
                .lineSpacing(3)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))

            Text(note)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button(action: copy) {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .frame(minWidth: 70)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .onExitCommand(perform: close)
        .onAppear(perform: reload)
        .onChange(of: controller.lastSync) { _, _ in reload() }
        .onChange(of: settings.targetCalendarID) { _, _ in reload() }
    }

    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(title).font(.system(size: 12.5))
            Spacer(minLength: 8)
            content()
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 36)
    }

    private func label(_ place: AvailabilityShare.Place) -> String {
        [place.flag, place.isHere ? "\(place.name) (mine)" : place.name].compactMap { $0 }.joined(separator: " ")
    }

    private var placeMenu: some View {
        Menu {
            ForEach(places) { option in
                Button {
                    timeZoneID = option.id
                    searching = false
                } label: {
                    if option.id == place.id {
                        Label(label(option), systemImage: "checkmark")
                    } else {
                        Text(label(option))
                    }
                }
            }
            Divider()
            Button("Another time zone…") {
                searching = true
                searchFocused = true
            }
        } label: {
            Text(label(place))
        }
        .menuStyle(.button)
        .fixedSize()
    }

    /// Any city or time zone, found as when adding a World Clocks city.
    private var search: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("City, country or time zone", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .onExitCommand { searching = false }
            ForEach(WorldClocks.search(query, limit: 5), id: \.timeZoneID) { found in
                Button {
                    timeZoneID = found.timeZoneID
                    otherName = found.city
                    query = ""
                    searching = false
                } label: {
                    HStack(spacing: 6) {
                        Text([WorldClocks.flag(of: found.timeZoneID), found.city].compactMap { $0 }.joined(separator: " "))
                        Text(found.countryName()).foregroundStyle(.secondary)
                        Spacer()
                    }
                    .font(.system(size: 12))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// What the text is based on, and what it leaves out.
    private var note: String {
        var note = "Free in all your calendars, within your working hours"
        note += limitsToTheirHours ? " and \(place.name)'s." : "."
        if let readsUntil = plan.readsUntil {
            let day = readsUntil.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
            note += " Only until \(day): Calendar Hub reads your calendars \(settings.options.daysAhead) days ahead"
                + " (Settings › General)."
        }
        return note
    }

    private func copy() {
        AvailabilityShare.copy(text)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }

    private func reload() {
        if let fetched = AvailabilityShare.events(settings: settings, controller: controller) { events = fetched }
    }
}

/// What Share availability is set to and the text it makes, for the panel and for the menu bar
/// item's right-click menu, which copies with the panel's last choices.
@MainActor
struct AvailabilityShare {
    let settings: SettingsStore
    let controller: SyncController
    var span: Availability.Span
    /// The other person's time zone, or empty for ours.
    var timeZoneID: String
    /// The name for a time zone picked by searching, not one of the World Clocks.
    var otherName: String
    var minimumMinutes: Int
    var bothWorking: Bool

    /// The panel's choices, as saved in `defaults`.
    init(settings: SettingsStore, controller: SyncController, defaults: UserDefaults = .standard) {
        self.init(settings: settings, controller: controller,
                  span: defaults.string(forKey: "availabilitySpan").flatMap(Availability.Span.init(rawValue:)) ?? .nextDays,
                  timeZoneID: defaults.string(forKey: "availabilityTimeZone") ?? "",
                  otherName: defaults.string(forKey: "availabilityPlaceName") ?? "",
                  minimumMinutes: defaults.object(forKey: "availabilityMinimum") as? Int ?? 30,
                  bothWorking: defaults.object(forKey: "availabilityBothWorking") as? Bool ?? true)
    }

    init(settings: SettingsStore, controller: SyncController, span: Availability.Span, timeZoneID: String,
         otherName: String, minimumMinutes: Int, bothWorking: Bool) {
        self.settings = settings
        self.controller = controller
        self.span = span
        self.timeZoneID = timeZoneID
        self.otherName = otherName
        self.minimumMinutes = minimumMinutes
        self.bothWorking = bothWorking
    }

    var calendar: Calendar { settings.menuCalendar.applied(to: .current) }
    var workingHours: WorkingHours { settings.menuCalendar.workingHours }

    /// Someone the text can be for: here, a World Clocks city, or a time zone searched for.
    struct Place: Hashable, Identifiable {
        var id: String
        var name: String
        var timeZone: TimeZone
        var workingHours: WorkingHours
        var isHere: Bool

        var flag: String? { WorldClocks.flag(of: timeZone.identifier) }
    }

    var here: Place {
        Place(id: "", name: settings.worldClocks.localName(in: .current), timeZone: .current,
              workingHours: workingHours, isHere: true)
    }

    var places: [Place] {
        var places = [here] + settings.worldClocks.clocks.map {
            Place(id: $0.timeZoneID, name: $0.name, timeZone: $0.timeZone,
                  workingHours: $0.workingHours ?? workingHours, isHere: false)
        }
        // A time zone found by searching stays in the list while it's picked.
        if !timeZoneID.isEmpty, !places.contains(where: { $0.id == timeZoneID }), let zone = TimeZone(identifier: timeZoneID) {
            places.append(Place(id: timeZoneID, name: otherName.isEmpty ? WorldClocks.cityName(of: timeZoneID) : otherName,
                                timeZone: zone, workingHours: workingHours, isHere: false))
        }
        var seen = Set<String>()
        return places.filter { seen.insert($0.id).inserted }
    }

    var place: Place { places.first { $0.id == timeZoneID } ?? here }

    /// Narrows to their working hours only for somewhere else; ours are the limit anyway.
    var limitsToTheirHours: Bool { bothWorking && !place.isHere }

    func plan(_ events: [SourceEvent]) -> Availability.Plan {
        Availability.plan(span, events: events, now: Date(), calendar: calendar, workingHours: workingHours,
                          recipient: limitsToTheirHours ? .init(timeZone: place.timeZone, workingHours: place.workingHours) : nil,
                          minimum: TimeInterval(minimumMinutes * 60), readsUntil: controller.window.end)
    }

    /// English, as the rest of the app, with the dates and times of the user's region.
    static var locale: Locale {
        Locale(languageCode: .english, languageRegion: Locale.current.region)
    }

    func text(_ events: [SourceEvent]) -> String {
        Availability.text(of: plan(events), timeZone: place.timeZone, placeName: place.name, locale: Self.locale,
                          calendar: calendar)
    }

    /// The main calendar from today to the end of next week, the furthest a span reaches, or
    /// nil when it can't be read.
    static func events(settings: SettingsStore, controller: SyncController) -> [SourceEvent]? {
        let calendar = settings.menuCalendar.applied(to: .current)
        let today = calendar.startOfDay(for: Date())
        guard let targetID = settings.targetCalendarID,
              let end = calendar.date(byAdding: .day, value: 15, to: today),
              case .success(let fetched) = controller.eventKit.sourceEvents(calendarID: targetID, from: today, to: end)
        else { return nil }
        return fetched.filter { !$0.isCancelled }
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Whether the menu shows Share availability in place of the calendar views. Shared so the
/// menu bar item's right-click menu can open the menu at it.
@MainActor
final class MenuPanel: ObservableObject {
    static let shared = MenuPanel()
    @Published var sharingAvailability = false
}
