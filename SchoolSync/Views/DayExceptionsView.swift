import SwiftUI
import SwiftData

/// Everything overriding a kid's ordinary day, and the means to undo it.
///
/// Day exceptions were written by the review screen and read by Morning Mode,
/// and that was the whole of it — no list, no delete, no way to see what a
/// document had actually put in the store. Assigning one email to the wrong
/// child wrote ninety-one rows that could not be reached from anywhere in the
/// app.
///
/// Grouped by where they came from, because that's the unit the mistake
/// happens in. Nobody misfiles one Tuesday; they misfile a semester.
struct DayExceptionsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \DayException.day) private var exceptions: [DayException]
    @Query(sort: \KidRecord.name) private var kids: [KidRecord]

    private var kidsByID: [UUID: KidRecord] { Dictionary(uniqueKeysWithValues: kids.map { ($0.id, $0) }) }

    /// One document's worth of exceptions for one kid.
    private struct Batch: Identifiable {
        let id: String
        let kidID: UUID
        let provenance: String
        let rows: [DayException]

        var count: Int { rows.count }
        var first: Date? { rows.map(\.day).min() }
        var last: Date? { rows.map(\.day).max() }
    }

    private var batches: [Batch] {
        let grouped = Dictionary(grouping: exceptions) { exception in
            "\(exception.kidID.uuidString)|\(exception.provenance ?? "")"
        }

        return grouped
            .map { key, rows in
                Batch(
                    id: key,
                    kidID: rows[0].kidID,
                    provenance: rows[0].provenance ?? "Added by hand",
                    rows: rows
                )
            }
            .sorted { ($0.last ?? .distantPast) > ($1.last ?? .distantPast) }
    }

    var body: some View {
        Group {
            if batches.isEmpty {
                ContentUnavailableView(
                    "No day changes",
                    systemImage: "calendar.badge.exclamationmark",
                    description: Text("Lunch calendars, rotation schedules and anything else that changes a single day will appear here once you save one.")
                )
            } else {
                List {
                    ForEach(batches) { batch in
                        Section {
                            row(for: batch)
                        }
                    }
                }
            }
        }
        .navigationTitle("Day changes")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func row(for batch: Batch) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(batch.provenance)
                .font(.callout)
                .lineLimit(2)

            Text(summary(for: batch))
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                // Moving rather than deleting and re-forwarding: the document
                // was read correctly, it was only filed under the wrong child.
                // Re-extracting it would cost another model call to produce
                // exactly the same rows.
                Menu {
                    ForEach(kids.filter { $0.id != batch.kidID }) { kid in
                        Button("Move to \(kid.name)") { move(batch, to: kid) }
                    }
                } label: {
                    Label("Move", systemImage: "arrow.left.arrow.right")
                        .font(.caption)
                }
                .disabled(kids.count < 2)

                Spacer()

                Button(role: .destructive) {
                    delete(batch)
                } label: {
                    Label("Delete \(batch.count)", systemImage: "trash")
                        .font(.caption)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func summary(for batch: Batch) -> String {
        let kidName = kidsByID[batch.kidID]?.name ?? "Unknown kid"
        let days = "\(batch.count) day\(batch.count == 1 ? "" : "s")"

        guard let first = batch.first, let last = batch.last else { return "\(kidName) · \(days)" }
        if Calendar.current.isDate(first, inSameDayAs: last) {
            return "\(kidName) · \(days) · \(first.formatted(date: .abbreviated, time: .omitted))"
        }
        return "\(kidName) · \(days) · \(first.formatted(date: .abbreviated, time: .omitted)) – \(last.formatted(date: .abbreviated, time: .omitted))"
    }

    /// Reassigns a whole batch to another kid.
    ///
    /// The stable id encodes the kid, so moving a row means recomputing it. If
    /// the destination already holds that day, field and source, the move would
    /// collide with the unique constraint — so the incoming row is dropped
    /// rather than overwriting what's already there.
    private func move(_ batch: Batch, to kid: KidRecord) {
        let existingIDs = Set(exceptions.filter { $0.kidID == kid.id }.map(\.id))

        for row in batch.rows {
            let newID = DayException.identity(
                kidID: kid.id,
                day: row.day,
                field: row.field,
                source: row.source
            )

            if existingIDs.contains(newID) {
                modelContext.delete(row)
            } else {
                row.id = newID
                row.kidID = kid.id
            }
        }

        try? modelContext.save()
    }

    private func delete(_ batch: Batch) {
        for row in batch.rows { modelContext.delete(row) }
        try? modelContext.save()
    }
}
