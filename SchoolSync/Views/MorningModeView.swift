import SwiftUI
import SwiftData

/// The screen this whole app exists for: look at the phone in the morning and
/// see what each kid needs today.
///
/// The design rule everywhere below is that **a normal day should be quiet**.
/// Defaults render in muted text; only things that differ from the baseline get
/// weight and a coloured marker. If every line shouted, the jeans day would look
/// exactly like the uniform day and the screen would be worth nothing at 7am.
struct MorningModeView: View {
    @Environment(\.isViewer) private var isViewer
    @Query(sort: \KidRecord.name) private var kids: [KidRecord]
    @Query private var dayDefaults: [KidDayDefaults]
    @Query private var exceptions: [DayException]
    @Query(filter: #Predicate<SchoolEventRecord> { !$0.isDeletedByUser })
    private var events: [SchoolEventRecord]

    @State private var isPresentingAddKid = false

    /// Watched, not sampled — so the line below moves when a refresh lands
    /// rather than showing whatever it read when the tab first appeared.
    @AppStorage(ViewerSettings.snapshotPublishedAtKey) private var publishedAtRaw = 0.0

    private var publishedAt: Date? { ViewerSettings.date(fromStoredInterval: publishedAtRaw) }

    /// Days either side of today that can be swiped to.
    ///
    /// Bounded because a paging TabView needs a finite set of pages, and these
    /// are the bounds that match the data: a fortnight back covers "what did we
    /// miss", and a school year forward covers everything the semester calendar
    /// and the district PDF put in the store. Past that there is nothing to
    /// show and swiping would only find empty days.
    private static let daysBack = 14
    private static let daysForward = 300

    /// Which day is on screen, as an offset from today. Zero is today, and the
    /// Today button exists because after a few swipes it stops being obvious
    /// which way back is.
    @State private var dayOffset = 0

    private var today: Date { Calendar.current.startOfDay(for: .now) }

    private func date(forOffset offset: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: offset, to: today) ?? today
    }

    private var selectedDay: Date { date(forOffset: dayOffset) }

    /// "Today", "Tomorrow", or the weekday and date.
    ///
    /// The relative words matter more than they look: once the screen can show
    /// any day, the title is the only thing stopping you from reading
    /// tomorrow's gym shoes as this morning's.
    private var title: String {
        switch dayOffset {
        case 0: "Today"
        case 1: "Tomorrow"
        case -1: "Yesterday"
        default: selectedDay.formatted(.dateTime.weekday(.abbreviated).month().day())
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if kids.isEmpty {
                    ContentUnavailableView(
                        isViewer ? "Nothing sent yet" : "Add a kid to get started",
                        systemImage: isViewer ? "clock.arrow.circlepath" : "sun.horizon",
                        description: Text(
                            isViewer
                                ? "The schedule arrives the next time whoever shared it opens their app. Settings has a button to check again now."
                                : "Morning Mode shows what each kid needs today. Add a kid, then set up their normal day."
                        )
                    )
                } else {
                    VStack(spacing: 0) {
                        // A paging TabView rather than a swipe gesture: it
                        // tracks the finger, rubber-bands at the ends, and
                        // behaves the way every other iOS page does, none of
                        // which a DragGesture gives for free. Index dots are
                        // off — three hundred of them would be nonsense.
                        TabView(selection: $dayOffset) {
                            ForEach(-Self.daysBack...Self.daysForward, id: \.self) { offset in
                                dayView(for: date(forOffset: offset))
                                    .tag(offset)
                            }
                        }
                        .tabViewStyle(.page(indexDisplayMode: .never))
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    if dayOffset != 0 {
                        Button("Today") {
                            withAnimation { dayOffset = 0 }
                        }
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    if !isViewer {
                        Button { isPresentingAddKid = true } label: { Image(systemName: "plus") }
                    }
                }
            }
            .sheet(isPresented: $isPresentingAddKid) { AddKidView() }
            // Always on, not only when it's old.
            //
            // This screen is designed so that a normal day is quiet, which
            // means a phone that stopped receiving updates looks exactly like a
            // week with nothing unusual in it. On a viewing phone that
            // resemblance is the whole risk, so the age of what's on screen is
            // part of what's on screen.
            .safeAreaInset(edge: .bottom) {
                if isViewer {
                    Text(SnapshotFreshness.describe(publishedAt))
                        .font(.caption2)
                        .foregroundStyle(SnapshotFreshness.isStale(publishedAt) ? Color.orange : Color.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(.bar)
                }
            }
        }
    }

    /// One day's panels.
    @ViewBuilder
    private func dayView(for day: Date) -> some View {
        // The weather belongs to the day, so it rides inside the page rather
        // than sitting fixed above it. Above the pager it would have shown
        // today's rain over tomorrow's plan.
        VStack(spacing: 0) {
            WeatherStripView(day: day)
            Divider()
            kidPanels(for: day)
        }
    }

    @ViewBuilder
    private func kidPanels(for day: Date) -> some View {
        // Equal division rather than a scroll: the point is a glance, and a
        // screen you have to scroll to finish reading is a screen you'll skip
        // on a school morning. Past two kids that stops being possible, so it
        // falls back to scrolling rather than shrinking to unreadable.
        if kids.count <= 2 {
            VStack(spacing: 0) {
                ForEach(Array(kids.enumerated()), id: \.element.id) { index, kid in
                    if index > 0 { Divider() }
                    KidPanel(kid: kid, plan: plan(for: kid, on: day), events: calendarEvents(for: kid, on: day))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        } else {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(kids.enumerated()), id: \.element.id) { index, kid in
                        if index > 0 { Divider() }
                        KidPanel(kid: kid, plan: plan(for: kid, on: day), events: calendarEvents(for: kid, on: day))
                    }
                }
            }
        }
    }

    private func plan(for kid: KidRecord, on day: Date) -> DayPlan {
        DayPlanResolver.resolve(
            kidID: kid.id,
            day: day,
            defaults: dayDefaults.first { $0.kidID == kid.id },
            exceptions: exceptions
        )
    }

    /// One kid's calendar events on a given day.
    ///
    /// Named to avoid shadowing the `events` query it reads from — legal in
    /// Swift, confusing to read.
    ///
    /// Surfaced alongside the resolved reminders because an event on a day IS
    /// a morning reminder — picture day is the thing you'd want to know at
    /// breakfast.
    private func calendarEvents(for kid: KidRecord, on day: Date) -> [SchoolEventRecord] {
        let calendar = Calendar.current
        return events
            .filter { $0.kidID == kid.id && calendar.isDate($0.startDate, inSameDayAs: day) }
            .sorted { $0.startDate < $1.startDate }
    }
}

private struct KidPanel: View {
    let kid: KidRecord
    let plan: DayPlan
    let events: [SchoolEventRecord]

    private var accent: Color { Color(hex: kid.colorHex) }

    var body: some View {
        // Scrolls only when it has to. Larger type, a rotation reminder and a
        // couple of events can together outgrow half a screen, and a clipped
        // panel would hide exactly the line this app exists to show. Bounce is
        // size-based so a panel that fits still feels fixed rather than loose.
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                BlockWord(word: kid.name, colorSeed: kid.name.count, sizes: [24, 21, 18, 15])

                // Breakfast, lunch and uniform are all answers to "what does
                // the school day need". On a day with no school they are
                // answers to a question nobody is asking, and printing them
                // costs the closure the prominence it should have.
                //
                // Events survive: a cross country meet at 3:30 still happens on
                // a day off, and still needs someone to drive.
                if !isClosed {
                    VStack(alignment: .leading, spacing: 7) {
                        FieldRow(field: plan.breakfast, accent: accent)
                        FieldRow(field: plan.lunch, accent: accent)
                        FieldRow(field: plan.clothing, accent: accent)
                    }
                }

                if plan.reminders.isEmpty && events.isEmpty {
                    // Say it rather than leaving a gap. An empty panel is
                    // ambiguous — it could mean "nothing unusual" or "this failed
                    // to load", and at 7am you shouldn't have to work out which.
                    // Silence only functions as a signal when it's distinguishable
                    // from a bug.
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        Text("Nothing unusual")
                            .font(.subheadline)
                            .foregroundStyle(.tertiary)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(lines) { line in
                            ReminderRow(
                                text: line.text,
                                detail: line.detail,
                                isException: line.isNotable,
                                accent: accent
                            )
                        }
                    }
                }

            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            // A faint tint of the kid's own colour. Without a boundary the
            // panel's unused half-screen reads as emptiness; with one it reads
            // as this kid's area, which is what it is.
            accent.opacity(0.06)
        )
    }

    /// Day changes and calendar events, merged into one list.
    ///
    /// They were two `ForEach`es rendering identically, which meant a closure
    /// known to both stores read twice — and on Sep 25 it read three times
    /// across two kids, each source phrasing it its own way.
    private var lines: [MorningItem] {
        let reminders = plan.reminders.map {
            MorningItem(text: $0.value, isNotable: $0.isException)
        }

        // Events always read as notable — an event on the calendar is by
        // definition not part of an ordinary day. Matched on the bare title, so
        // a timed event's "3:30 PM · " prefix can't confuse the detection.
        let eventItems = events.map {
            MorningItem(text: eventLabel($0), isNotable: true, matchText: $0.title)
        }

        return ClosureCollapse.collapse(reminders + eventItems)
    }

    /// Only ever true for this one kid on this one day. The other panel is
    /// resolved separately, because one school being shut says nothing about
    /// the other.
    private var isClosed: Bool { ClosureCollapse.containsClosure(lines) }

    private func eventLabel(_ event: SchoolEventRecord) -> String {
        guard !event.isAllDay else { return event.title }
        return "\(event.startDate.formatted(date: .omitted, time: .shortened)) · \(event.title)"
    }
}

/// One of the three baseline fields.
private struct FieldRow: View {
    let field: ResolvedField
    let accent: Color

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(field.field.label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 84, alignment: .leading)

            VStack(alignment: .leading, spacing: 1) {
                Text(field.value.isEmpty ? "—" : field.value)
                    .font(.body)
                    // Weight is the whole signal. A day where nothing differs
                    // should read as flat grey text you can skim past.
                    .fontWeight(field.isException ? .semibold : .regular)
                    .foregroundStyle(field.value.isEmpty ? .tertiary : (field.isException ? .primary : .secondary))
                    .fixedSize(horizontal: false, vertical: true)

                if field.isException, let provenance = field.provenance {
                    Text(provenance)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 0)

            if field.isException {
                Circle().fill(accent).frame(width: 7, height: 7)
            }
        }
    }
}

private struct ReminderRow: View {
    let text: String
    var detail: String?
    let isException: Bool
    let accent: Color

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: isException ? "exclamationmark.circle.fill" : "circle")
                .font(.caption)
                .foregroundStyle(isException ? accent : Color.secondary)

            VStack(alignment: .leading, spacing: 1) {
                Text(text)
                    .font(.subheadline)
                    .fontWeight(isException ? .medium : .regular)
                    .foregroundStyle(isException ? .primary : .secondary)
                    .fixedSize(horizontal: false, vertical: true)

                // The reasons behind a collapsed closure. Quiet on purpose:
                // that school is out is the news, and why is the footnote —
                // but it stays on screen, because deleting the reasons to
                // tidy the line would be losing information to look neater.
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 0)
        }
    }
}
