import SwiftUI
import SwiftData

struct CalendarView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(filter: #Predicate<SchoolEventRecord> { !$0.isDeletedByUser }, sort: \SchoolEventRecord.startDate)
    private var events: [SchoolEventRecord]
    @Query(sort: \KidRecord.name) private var kids: [KidRecord]
    @Query(sort: \SchoolRecord.name) private var schools: [SchoolRecord]

    @State private var isSyncing = false
    @State private var lastSyncResult: SyncResult?

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
                            Section(section.day.formatted(.dateTime.weekday(.wide).month().day())) {
                                ForEach(section.events) { event in
                                    NavigationLink {
                                        EditEventView(event: event, kid: kidsByID[event.kidID])
                                    } label: {
                                        eventRow(event)
                                    }
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

    private func eventRow(_ event: SchoolEventRecord) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(Color(hex: kidsByID[event.kidID]?.colorHex ?? "#4A90D9"))
                .frame(width: 10, height: 10)
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: 2) {
                Text(event.title).font(.body)
                Text(subtitle(for: event)).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func subtitle(for event: SchoolEventRecord) -> String {
        var parts: [String] = []
        if let kid = kidsByID[event.kidID] { parts.append(kid.name) }
        if let school = schoolsByID[event.schoolID] { parts.append(school.name) }
        if event.isAllDay {
            parts.append("All day")
        } else {
            parts.append(event.startDate.formatted(date: .omitted, time: .shortened))
        }
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
