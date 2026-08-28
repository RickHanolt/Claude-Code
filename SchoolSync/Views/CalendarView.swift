import SwiftUI
import SwiftData

/// Per-weekday accent for the day number and the timeline rule. Indexed by
/// `Calendar`'s weekday (1 = Sunday) so a given day always looks the same
/// rather than shifting colour as events come and go around it.
private let weekdayAccents: [Color] = [
    Color(red: 0.85, green: 0.26, blue: 0.24),
    Color(red: 0.91, green: 0.30, blue: 0.24),
    Color(red: 0.95, green: 0.55, blue: 0.15),
    Color(red: 0.15, green: 0.62, blue: 0.35),
    Color(red: 0.13, green: 0.52, blue: 0.90),
    Color(red: 0.52, green: 0.27, blue: 0.84),
    Color(red: 0.00, green: 0.58, blue: 0.60),
]

private func weekdayAccent(for date: Date) -> Color {
    let weekday = Calendar.current.component(.weekday, from: date)
    return weekdayAccents[(weekday - 1) % weekdayAccents.count]
}

/// Toy-block colours, cycled per letter so "MON" reads red/yellow/green the
/// way a real set of children's blocks would, instead of three of one colour.
private let blockColors: [Color] = [
    Color(red: 0.85, green: 0.26, blue: 0.24),
    Color(red: 0.95, green: 0.70, blue: 0.15),
    Color(red: 0.15, green: 0.62, blue: 0.35),
    Color(red: 0.13, green: 0.52, blue: 0.90),
    Color(red: 0.52, green: 0.27, blue: 0.84),
]

/// One letter tile.
///
/// Drawn rather than shipped as image assets. The weekday abbreviation comes
/// from the device locale, so an image set would need every letter the user's
/// language can produce; and flat art can pick its own colours in dark mode,
/// where a photographic block would sit on a background it wasn't shot for.
private struct AlphabetBlock: View {
    let letter: String
    let color: Color
    let tilt: Double

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [color, color.opacity(0.72)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                .fill(Color.white.opacity(0.92))
                .padding(2.5)

            Text(letter)
                .font(.system(size: 11, weight: .black, design: .rounded))
                .foregroundStyle(color)
        }
        .frame(width: 19, height: 19)
        .rotationEffect(.degrees(tilt))
        .shadow(color: .black.opacity(0.18), radius: 1, x: 0, y: 1)
    }
}

/// The day's marker: letter blocks over a large day number.
private struct DayBlockLabel: View {
    let date: Date

    /// Uppercased short weekday, capped at three letters. Read from the
    /// formatter rather than hardcoded so it follows the device locale, and
    /// capped so a longer abbreviation can't widen the column and squeeze the
    /// event titles beside it.
    private var letters: [String] {
        date.formatted(.dateTime.weekday(.abbreviated))
            .uppercased()
            .prefix(3)
            .map(String.init)
    }

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 2) {
                ForEach(Array(letters.enumerated()), id: \.offset) { index, letter in
                    AlphabetBlock(
                        letter: letter,
                        // Offset by the day number so consecutive days don't
                        // repeat the same three colours down the screen.
                        color: blockColors[
                            (index + Calendar.current.component(.day, from: date)) % blockColors.count
                        ],
                        tilt: [-4.0, 2.5, -1.5][index % 3]
                    )
                }
            }

            Text(date.formatted(.dateTime.day()))
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundStyle(weekdayAccent(for: date))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(date.formatted(.dateTime.weekday(.wide).month().day()))
    }
}

struct CalendarView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(filter: #Predicate<SchoolEventRecord> { !$0.isDeletedByUser }, sort: \SchoolEventRecord.startDate)
    private var events: [SchoolEventRecord]
    @Query(sort: \KidRecord.name) private var kids: [KidRecord]
    @Query(sort: \SchoolRecord.name) private var schools: [SchoolRecord]

    @State private var isSyncing = false
    @State private var lastSyncResult: SyncResult?

    /// Width reserved for the day marker. Three 19pt blocks plus their gaps
    /// come to 61pt, so this is the block strip plus a little breathing room —
    /// tight on purpose, because every point here is taken from the event
    /// title beside it, and real ones ("Parent/Teacher Conference 3-8pm") are
    /// long.
    private let dayColumnWidth: CGFloat = 64

    private var kidsByID: [UUID: KidRecord] { Dictionary(uniqueKeysWithValues: kids.map { ($0.id, $0) }) }
    private var schoolsByID: [UUID: SchoolRecord] { Dictionary(uniqueKeysWithValues: schools.map { ($0.id, $0) }) }

    private var upcomingByDay: [(day: Date, events: [SchoolEventRecord])] {
        let calendar = Calendar.current
        let upcoming = events.filter { $0.startDate >= calendar.startOfDay(for: .now) }
        let grouped = Dictionary(grouping: upcoming) { calendar.startOfDay(for: $0.startDate) }
        return grouped.keys.sorted().map { day in (day, grouped[day]!.sorted { $0.startDate < $1.startDate }) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if kids.isEmpty {
                    ContentUnavailableView(
                        "Add a kid to get started",
                        systemImage: "person.badge.plus",
                        description: Text("Head to the Kids tab, then add each kid's school.")
                    )
                } else if upcomingByDay.isEmpty {
                    ContentUnavailableView(
                        "No upcoming events yet",
                        systemImage: "calendar.badge.exclamationmark",
                        description: Text("Add a school with an ICS feed or scrape config, then tap Sync.")
                    )
                } else {
                    List {
                        ForEach(upcomingByDay, id: \.day) { section in
                            Section {
                                ForEach(Array(section.events.enumerated()), id: \.element.externalID) { index, event in
                                    NavigationLink {
                                        EditEventView(event: event, kid: kidsByID[event.kidID])
                                    } label: {
                                        dayRow(day: section.day, event: event, isFirstOfDay: index == 0)
                                    }
                                    // A hairline above the first row of each
                                    // day is the only divider: it separates
                                    // days without drawing a line between
                                    // events that belong together.
                                    .listRowSeparator(index == 0 ? .visible : .hidden, edges: .top)
                                    .listRowSeparator(.hidden, edges: .bottom)
                                    .listRowInsets(EdgeInsets(top: 5, leading: 12, bottom: 5, trailing: 12))
                                    .swipeActions(edge: .trailing) {
                                        Button(role: .destructive) {
                                            delete(event)
                                        } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Calendar")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await sync() }
                    } label: {
                        if isSyncing {
                            ProgressView()
                        } else {
                            Label("Sync", systemImage: "arrow.triangle.2.circlepath")
                        }
                    }
                    .disabled(isSyncing)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let result = lastSyncResult, !result.errors.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(result.errors, id: \.self) { message in
                            Text(message).font(.caption)
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.yellow.opacity(0.2))
                }
            }
        }
    }

    private func dayRow(day: Date, event: SchoolEventRecord, isFirstOfDay: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            // The gutter keeps its width on EVERY row, not only the first.
            // The marker is drawn once per day, but without the reserved
            // space the day's second event would slide left and the timeline
            // rule would zig-zag down the screen.
            Group {
                if isFirstOfDay { DayBlockLabel(date: day) }
            }
            .frame(width: dayColumnWidth, alignment: .top)

            eventRow(event)
                .padding(.leading, 11)
                // The rule is an overlay rather than an HStack sibling with
                // `maxHeight: .infinity`, which fights the list row's height
                // proposal. An overlay is handed the content's own height, so
                // it matches the row exactly however far the title wraps.
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(weekdayAccent(for: day).opacity(0.55))
                        .frame(width: 3)
                }
        }
    }

    private func eventRow(_ event: SchoolEventRecord) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(Color(hex: kidsByID[event.kidID]?.colorHex ?? "#4A90D9"))
                .frame(width: 9, height: 9)
                .padding(.top, 6)

            Text(timeLabel(for: event))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 62, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                Text(event.title)
                    .font(.subheadline.weight(.semibold))
                    // School titles are long and the columns beside them are
                    // fixed, so let the title use as many lines as it needs
                    // instead of truncating the part that identifies it.
                    .fixedSize(horizontal: false, vertical: true)

                Text(subtitle(for: event))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func timeLabel(for event: SchoolEventRecord) -> String {
        event.isAllDay ? "All day" : event.startDate.formatted(date: .omitted, time: .shortened)
    }

    /// Kid, school and location. The time used to live here too and no longer
    /// does — it has its own column now, and repeating it just crowded out the
    /// location.
    private func subtitle(for event: SchoolEventRecord) -> String {
        var parts: [String] = []
        if let kid = kidsByID[event.kidID] { parts.append(kid.name) }
        if let school = schoolsByID[event.schoolID] { parts.append(school.name) }
        if let location = event.location, !location.isEmpty { parts.append(location) }
        return parts.joined(separator: " · ")
    }

    /// Removes the underlying Calendar-app event (if this record ever made
    /// it to EventKit) and tombstones the local record so a future sync
    /// from the same source doesn't bring it back — see
    /// `SchoolEventRecord.isDeletedByUser`.
    private func delete(_ event: SchoolEventRecord) {
        if let identifier = event.calendarSyncIdentifier {
            try? CalendarSyncService().delete(eventIdentifier: identifier)
        }
        event.isDeletedByUser = true
        event.calendarSyncIdentifier = nil
        try? modelContext.save()
    }

    private func sync() async {
        isSyncing = true
        defer { isSyncing = false }
        let coordinator = SyncCoordinator(modelContext: modelContext, calendarSyncService: CalendarSyncService())
        lastSyncResult = await coordinator.runFullSync()
    }
}
