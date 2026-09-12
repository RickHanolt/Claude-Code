import SwiftUI
import SwiftData

struct AddSchoolView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let kids: [KidRecord]

    /// The school being edited, or nil when adding a new one.
    ///
    /// One form for both, because they ask exactly the same questions. A
    /// separate EditSchoolView would be the same fields twice, and the two
    /// copies would drift the first time a field is added to one of them.
    var existing: SchoolRecord? = nil

    @State private var selectedKidID: UUID?
    @State private var name = ""

    @State private var usesICSFeed = false
    @State private var icsFeedURLString = ""

    @State private var usesScrape = false
    @State private var scrapeURLString = ""
    @State private var eventContainerSelector = ""
    @State private var titleSelector = ""
    @State private var dateSelector = ""
    @State private var dateAttribute = ""
    @State private var locationSelector = ""
    @State private var dateFormat = ""

    @State private var acceptsEmailForwarding = false

    /// onAppear fires again on every re-appearance; seeding twice would
    /// discard whatever the user had typed and started editing.
    @State private var didSeed = false

    var body: some View {
        NavigationStack {
            Form {
                Section("School") {
                    TextField("School name", text: $name)
                    Picker("Kid", selection: $selectedKidID) {
                        ForEach(kids) { kid in
                            Text(kid.name).tag(Optional(kid.id))
                        }
                    }
                }

                Section {
                    Toggle("Subscribe to an ICS calendar feed", isOn: $usesICSFeed)
                    if usesICSFeed {
                        TextField("https://school.edu/calendar.ics", text: $icsFeedURLString)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                } footer: {
                    Text("Most reliable source. Check the school site for \"subscribe\" or \"export calendar\".")
                }

                Section {
                    Toggle("Scrape the calendar page", isOn: $usesScrape)
                    if usesScrape {
                        TextField("https://school.edu/calendar", text: $scrapeURLString)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("Event container CSS selector (required)", text: $eventContainerSelector)
                        TextField("Title selector (optional)", text: $titleSelector)
                        TextField("Date selector (optional)", text: $dateSelector)
                        TextField("Date attribute, e.g. data-date (optional)", text: $dateAttribute)
                        TextField("Location selector (optional)", text: $locationSelector)
                        TextField("Explicit date format (optional)", text: $dateFormat)
                    }
                } footer: {
                    Text("Requires inspecting the school's HTML. See README for how selectors are resolved.")
                }

                Section {
                    Toggle("Accept forwarded emails", isOn: $acceptsEmailForwarding)
                } footer: {
                    Text("Lets you pick this school as the destination when sharing an email into SchoolSync.")
                }
            }
            .navigationTitle(existing == nil ? "Add School" : "Edit School")
            .onAppear { seedIfNeeded() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!isValid)
                }
            }
        }
    }

    /// Fills the form from the school being edited.
    ///
    /// A school's feed URL was previously write-once: the list showed only
    /// that a feed existed, never what it pointed at, and there was no way to
    /// change it. Correcting a wrong URL meant deleting the school and
    /// re-adding it, which strands every event already attributed to the old
    /// school ID. That's how a school configured with its site's news RSS
    /// endpoint stayed broken without anyone being able to see it, let alone
    /// fix it.
    private func seedIfNeeded() {
        guard !didSeed else { return }
        didSeed = true

        guard let existing else {
            if selectedKidID == nil { selectedKidID = kids.first?.id }
            return
        }

        name = existing.name
        selectedKidID = existing.kidID
        acceptsEmailForwarding = existing.acceptsEmailForwarding

        icsFeedURLString = existing.icsFeedURLString ?? ""
        usesICSFeed = !icsFeedURLString.isEmpty

        scrapeURLString = existing.scrapeURLString ?? ""
        usesScrape = !scrapeURLString.isEmpty

        if let config = existing.scrapeConfig {
            eventContainerSelector = config.eventContainerSelector
            titleSelector = config.titleSelector ?? ""
            dateSelector = config.dateSelector ?? ""
            dateAttribute = config.dateAttribute ?? ""
            locationSelector = config.locationSelector ?? ""
            dateFormat = config.dateFormat ?? ""
        }
    }

    private var isValid: Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty, selectedKidID != nil else { return false }
        if usesICSFeed && URL(string: icsFeedURLString) == nil { return false }
        if usesScrape && (URL(string: scrapeURLString) == nil || eventContainerSelector.trimmingCharacters(in: .whitespaces).isEmpty) { return false }
        return usesICSFeed || usesScrape || acceptsEmailForwarding
    }

    private func save() {
        guard let kidID = selectedKidID else { return }

        let scrapeConfig: ScrapeConfig? = usesScrape ? ScrapeConfig(
            eventContainerSelector: eventContainerSelector.trimmingCharacters(in: .whitespaces),
            titleSelector: titleSelector.isEmpty ? nil : titleSelector,
            dateSelector: dateSelector.isEmpty ? nil : dateSelector,
            dateAttribute: dateAttribute.isEmpty ? nil : dateAttribute,
            locationSelector: locationSelector.isEmpty ? nil : locationSelector,
            dateFormat: dateFormat.isEmpty ? nil : dateFormat
        ) : nil

        if let existing {
            // Mutated rather than replaced: the school's id is what every
            // event of this kid's is attributed by, so a new record would
            // orphan all of them.
            existing.name = name.trimmingCharacters(in: .whitespaces)
            existing.kidID = kidID
            existing.icsFeedURLString = usesICSFeed ? icsFeedURLString : nil
            existing.scrapeURLString = usesScrape ? scrapeURLString : nil
            existing.scrapeConfig = scrapeConfig
            existing.acceptsEmailForwarding = acceptsEmailForwarding
        } else {
            modelContext.insert(
                SchoolRecord(
                    name: name.trimmingCharacters(in: .whitespaces),
                    kidID: kidID,
                    icsFeedURLString: usesICSFeed ? icsFeedURLString : nil,
                    scrapeURLString: usesScrape ? scrapeURLString : nil,
                    scrapeConfig: scrapeConfig,
                    acceptsEmailForwarding: acceptsEmailForwarding
                )
            )
        }

        try? modelContext.save()
        dismiss()
    }
}
