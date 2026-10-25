import SwiftUI
import PeerDropCore

/// Project F2 on a category's page: what friends in this category see (online / offline / offline on a
/// schedule, edited in place — no menus or popups) and the category's status message. Two list sections.
struct CategoryStatusSection: View, PaperThemed {
    @Environment(\.paperMode) var paperMode
    @ObservedObject var store: FriendCategoryStore
    let category: FriendCategory
    /// Whether the category hides us right now (`.offline`, or inside its schedule window).
    let hiddenNow: Bool

    /// Times picked in the editor that the store has not accepted (start == end).
    @State private var draftStart: Int?
    @State private var draftEnd: Int?
    /// Width of a weekday capsule; grows with Dynamic Type so the row wraps instead of clipping.
    @ScaledMetric(relativeTo: .subheadline) private var dayWidth: CGFloat = 40

    private enum Mode: Hashable { case online, offline, scheduled }

    private var mode: Mode {
        switch category.presence {
        case .online: return .online
        case .offline: return .offline
        case .scheduled: return .scheduled
        }
    }

    private var modeBinding: Binding<Mode> {
        Binding(get: { mode }, set: { newMode in
            guard newMode != mode else { return }
            draftStart = nil
            draftEnd = nil
            switch newMode {
            case .online: store.setPresence(.online, for: category.id)
            case .offline: store.setPresence(.offline, for: category.id)
            case .scheduled: store.setPresence(.scheduled(ScheduleEditorLogic.defaultWindow), for: category.id)
            }
        })
    }

    var body: some View {
        Section {
            Picker(selection: modeBinding) {
                Text("Show as online").tag(Mode.online)
                Text("Show as offline").tag(Mode.offline)
                Text("Offline on a schedule").tag(Mode.scheduled)
            } label: {
                Text("Status for this category")
            }
            .pickerStyle(.inline)
            .labelsHidden()
            .tint(paper(.brand))
            .foregroundStyle(paper(.incomingText))
            .accessibilityIdentifier("category-presence-picker")

            if case .scheduled(let window) = category.presence {
                scheduleEditor(window)
            }
        } header: {
            Text("Status for this category")
        } footer: {
            // Only explain what "offline" does when it can apply; "Show as online" needs no caveat.
            if mode != .online {
                Text("While offline (or inside the schedule), friends in this category see you as offline and can't connect to you, and you won't be connected to them either. They can still reach you with a room code or a relay invite you accept. On the same Wi-Fi they may still see this device under Nearby.")
            }
        }
        .listRowBackground(paper(.incomingBubble))

        Section {
            CategoryStatusMessageField(store: store, category: category)
            Toggle(isOn: Binding(get: { category.showStatusMessage },
                                 set: { store.setShowStatusMessage($0, for: category.id) })) {
                Text("Show status message")
                    .foregroundStyle(paper(.incomingText))
            }
            .tint(paper(.brand))
            .accessibilityIdentifier("category-status-toggle")
        } header: {
            Text("Status message")
        } footer: {
            Text("End-to-end encrypted, sent directly to friends in this category while you're connected; never stored on a server.")
        }
        .listRowBackground(paper(.incomingBubble))
    }

    // MARK: - Schedule

    @ViewBuilder
    private func scheduleEditor(_ window: ScheduleWindow) -> some View {
        if hiddenNow {
            Label("Offline now (scheduled)", systemImage: "moon.zzz")
                .font(.subheadline)
                .foregroundStyle(paper(.datePillText))
        }
        VStack(alignment: .leading, spacing: 6) {
            weekdayButtons(window)
            Text("No days selected means every day.")
                .font(.caption)
                .foregroundStyle(paper(.datePillText))
        }
        .padding(.vertical, 2)

        DatePicker(selection: timeBinding(window, isStart: true), displayedComponents: .hourAndMinute) {
            Text("Offline from").foregroundStyle(paper(.incomingText))
        }
        .accessibilityIdentifier("category-schedule-start")
        DatePicker(selection: timeBinding(window, isStart: false), displayedComponents: .hourAndMinute) {
            Text("Until").foregroundStyle(paper(.incomingText))
        }
        .accessibilityIdentifier("category-schedule-end")

        if (draftStart ?? window.startMinute) == (draftEnd ?? window.endMinute) {
            Label("Start and end can't be the same time.", systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(paper(.warning))
        }
    }

    private func weekdayButtons(_ window: ScheduleWindow) -> some View {
        let calendar = Calendar.current
        let short = calendar.veryShortStandaloneWeekdaySymbols
        let full = calendar.standaloneWeekdaySymbols
        // Adaptive columns: one row of seven at normal sizes, wrapping at the largest text sizes.
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: dayWidth), spacing: 6)], alignment: .leading, spacing: 6) {
            ForEach(ScheduleEditorLogic.orderedWeekdays(firstWeekday: calendar.firstWeekday), id: \.self) { day in
                let selected = window.weekdays.contains(day)
                Button { toggle(day, in: window) } label: {
                    Text(verbatim: short[day - 1])
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(selected ? Color.white : paper(.brand))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity, minHeight: 32)
                        .background(Capsule().fill(selected ? paper(.brand) : Color.clear))
                        .overlay(Capsule().stroke(paper(.brand), lineWidth: 1))
                        .contentShape(Capsule())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(Text(verbatim: full[day - 1]))
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier("category-schedule-day")
            }
        }
    }

    private func toggle(_ day: Int, in window: ScheduleWindow) {
        var w = window
        if w.weekdays.contains(day) { w.weekdays.remove(day) } else { w.weekdays.insert(day) }
        store.setPresence(.scheduled(w), for: category.id)
    }

    private func timeBinding(_ window: ScheduleWindow, isStart: Bool) -> Binding<Date> {
        let calendar = Calendar.autoupdatingCurrent
        return Binding(get: {
            let minutes = isStart ? (draftStart ?? window.startMinute) : (draftEnd ?? window.endMinute)
            return ScheduleEditorLogic.date(fromMinutes: minutes, on: Date(), calendar: calendar)
        }, set: { date in
            let minutes = ScheduleEditorLogic.minutes(from: date, calendar: calendar)
            if isStart { draftStart = minutes } else { draftEnd = minutes }
            var w = window
            w.startMinute = draftStart ?? window.startMinute
            w.endMinute = draftEnd ?? window.endMinute
            // start == end is rejected by the store; keep the drafts so the warning shows.
            guard w.startMinute != w.endMinute else { return }
            if store.setPresence(.scheduled(w), for: category.id) {
                draftStart = nil
                draftEnd = nil
            }
        })
    }
}

/// The in-page status-message field: Return or losing focus saves through the store (cleaned, ≤ 60
/// characters, blank clears). Text over the limit is kept, not saved, and the hint turns into a warning.
private struct CategoryStatusMessageField: View, PaperThemed {
    @Environment(\.paperMode) var paperMode
    @ObservedObject var store: FriendCategoryStore
    let category: FriendCategory
    @State private var text = ""
    @State private var showTooLong = false
    @FocusState private var focused: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var length: Int { PresencePolicy.cleanStatusMessage(text)?.count ?? 0 }
    private var overLimit: Bool { length > PresencePolicy.maxStatusMessageLength }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // At accessibility text sizes the counter moves under the field so the text keeps the full width.
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
                : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8))
            layout {
                TextField(text: $text) { Text("Status message") }
                    .focused($focused)
                    .submitLabel(.done)
                    .onSubmit { commit(fromReturn: true) }
                    .foregroundStyle(paper(.incomingText))
                    .accessibilityIdentifier("category-status-field")
                    .accessibilityHint(Text("Up to 60 characters."))
                Text(verbatim: "\(length)/\(PresencePolicy.maxStatusMessageLength)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(overLimit ? paper(.warning) : paper(.datePillText))
                    .accessibilityHidden(true)
            }
            if showTooLong || overLimit {
                Text("Up to 60 characters.")
                    .font(.caption2)
                    .foregroundStyle(paper(.warning))
            }
        }
        // The first Text in the row is the counter; keep the separator at the row's leading edge.
        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
        .onAppear { text = category.statusMessage ?? "" }
        .onChange(of: category.statusMessage) { stored in
            if !focused { text = stored ?? "" }
        }
        .onChange(of: text) { _ in showTooLong = false }
        .onChange(of: focused) { isFocused in
            if !isFocused { commit(fromReturn: false) }
        }
    }

    private func commit(fromReturn: Bool) {
        guard PresencePolicy.cleanStatusMessage(text) != category.statusMessage else { return }
        if store.setStatusMessage(text, for: category.id) {
            showTooLong = false
        } else {
            showTooLong = true
            if fromReturn { DispatchQueue.main.async { focused = true } }
        }
    }
}

/// Pure helpers behind the schedule editor (tested in `HomeCategoriesLogicTests`).
enum ScheduleEditorLogic {
    /// What "Offline on a schedule" starts with: every day, 22:00–07:00.
    static let defaultWindow = ScheduleWindow(weekdays: [], startMinute: 1320, endMinute: 420)

    /// Calendar weekdays (1 = Sunday … 7 = Saturday) in display order, starting at `firstWeekday`.
    static func orderedWeekdays(firstWeekday: Int) -> [Int] {
        (0..<7).map { (firstWeekday - 1 + $0) % 7 + 1 }
    }

    static func minutes(from date: Date, calendar: Calendar) -> Int {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    static func date(fromMinutes minutes: Int, on day: Date, calendar: Calendar) -> Date {
        calendar.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: day) ?? day
    }
}

extension FriendCategory {
    /// Whether this category hides us from its friends at `date`: always for `.offline`, inside the
    /// window for `.scheduled` (same rule `PresencePolicy` enforces; production clock and time zone).
    func isHiddenNow(at date: Date = Date(), calendar: Calendar = .autoupdatingCurrent) -> Bool {
        switch presence {
        case .online: return false
        case .offline: return true
        case .scheduled(let window): return PresencePolicy.isInWindow(window, at: date, calendar: calendar)
        }
    }
}
