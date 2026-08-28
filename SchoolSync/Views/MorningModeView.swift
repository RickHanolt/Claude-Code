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
    @Query(sort: \KidRecord.name) private var kids: [KidRecord]
    @Query private var dayDefaults: [KidDayDefaults]
    @Query private var exceptions: [DayException]
    @Query(filter: #Predicate<SchoolEventRecord> { !$0.isDeletedByUser })
    private var events: [SchoolEventRecord]

    @State private var isPresentingAddKid = false

    private var today: Date { Calendar.current.startOfDay(for: .now) }

    var body: some View {
        NavigationStack {
            Group {
                if kids.isEmpty {
                    ContentUnavailableView(
                        "Add a kid to get started",
                        systemImage: "sun.horizon",
                        description: Text("Morning Mode shows what each kid needs today. Add a kid, then set up their normal day.")
                    )
                } else {
                    VStack(spacing: 0) {
                        WeatherStrip()

                        // Equal division rather than a scroll: the point is a
                        // glance, and a screen you have to scroll to finish
                        // reading is a screen you'll skip on a school morning.
                        // Past two kids that stops being possible, so it falls
                        // back to scrolling rather than shrinking to unreadable.
                        if kids.count <= 2 {
                            VStack(spacing: 0) {
                                ForEach(Array(kids.enumerated()), id: \.element.id) { index, kid in
                                    if index > 0 { Divider() }
                                    KidPanel(kid: kid, plan: plan(for: kid), events: todaysEvents(for: kid))
                                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                                }
                            }
                        } else {
                            ScrollView {
                                VStack(spacing: 0) {
                                    ForEach(Array(kids.enumerated()), id: \.element.id) { index, kid in
                                        if index > 0 { Divider() }
                                        KidPanel(kid: kid, plan: plan(for: kid), events: todaysEvents(for: kid))
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(today.formatted(.dateTime.weekday(.wide).month().day()))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { isPresentingAddKid = true } label: { Image(systemName: "plus") }
                }
            }
            .sheet(isPresented: $isPresentingAddKid) { AddKidView() }
        }
    }

    private func plan(for kid: KidRecord) -> DayPlan {
        DayPlanResolver.resolve(
            kidID: kid.id,
            day: today,
            defaults: dayDefaults.first { $0.kidID == kid.id },
            exceptions: exceptions
        )
    }

    /// Today's calendar events for one kid.
    ///
    /// Surfaced alongside the resolved reminders because an event happening
    /// today IS a morning reminder — picture day is the thing you'd want to
    /// know at breakfast. This is also what makes the screen useful before
    /// Phase 4 wires up menus and the rotation: the calendar already has real
    /// events in it.
    private func todaysEvents(for kid: KidRecord) -> [SchoolEventRecord] {
        let calendar = Calendar.current
        return events
            .filter { $0.kidID == kid.id && calendar.isDate($0.startDate, inSameDayAs: today) }
            .sorted { $0.startDate < $1.startDate }
    }
}

/// Placeholder until WeatherKit is enabled in the developer portal.
///
/// Kept in the layout rather than left out, so adding the real forecast is a
/// change to this view's body instead of a re-think of the split below it —
/// and so the space it needs is accounted for now rather than discovered later.
private struct WeatherStrip: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "cloud.sun")
                .foregroundStyle(.secondary)
            Text("Weather not set up yet")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.3))
    }
}

/// One kid's half of the screen.
private struct KidPanel: View {
    let kid: KidRecord
    let plan: DayPlan
    let events: [SchoolEventRecord]

    private var accent: Color { Color(hex: kid.colorHex) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            BlockWord(word: kid.name, colorSeed: kid.name.count, sizes: [20, 17, 14, 12])

            VStack(alignment: .leading, spacing: 7) {
                FieldRow(field: plan.breakfast, accent: accent)
                FieldRow(field: plan.lunch, accent: accent)
                FieldRow(field: plan.clothing, accent: accent)
            }

            if !plan.reminders.isEmpty || !events.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(plan.reminders, id: \.value) { reminder in
                        ReminderRow(text: reminder.value, isException: reminder.isException, accent: accent)
                    }

                    // Events always read as notable — an event on the calendar
                    // today is by definition not part of an ordinary day.
                    ForEach(events) { event in
                        ReminderRow(text: eventLabel(event), isException: true, accent: accent)
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

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
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 68, alignment: .leading)

            VStack(alignment: .leading, spacing: 1) {
                Text(field.value.isEmpty ? "—" : field.value)
                    .font(.subheadline)
                    // Weight is the whole signal. A day where nothing differs
                    // should read as flat grey text you can skim past.
                    .fontWeight(field.isException ? .semibold : .regular)
                    .foregroundStyle(field.value.isEmpty ? .tertiary : (field.isException ? .primary : .secondary))
                    .fixedSize(horizontal: false, vertical: true)

                if field.isException, let provenance = field.provenance {
                    Text(provenance)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 0)

            if field.isException {
                Circle().fill(accent).frame(width: 6, height: 6)
            }
        }
    }
}

private struct ReminderRow: View {
    let text: String
    let isException: Bool
    let accent: Color

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: isException ? "exclamationmark.circle.fill" : "circle")
                .font(.caption2)
                .foregroundStyle(isException ? accent : Color.secondary)

            Text(text)
                .font(.caption)
                .fontWeight(isException ? .medium : .regular)
                .foregroundStyle(isException ? .primary : .secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
    }
}
