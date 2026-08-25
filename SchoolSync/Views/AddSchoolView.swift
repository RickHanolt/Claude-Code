import SwiftUI
import SwiftData

struct AddSchoolView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let kids: [KidRecord]

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
            .navigationTitle("Add School")
            .onAppear {
                if selectedKidID == nil { selectedKidID = kids.first?.id }
            }
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

        let school = SchoolRecord(
            name: name.trimmingCharacters(in: .whitespaces),
            kidID: kidID,
            icsFeedURLString: usesICSFeed ? icsFeedURLString : nil,
            scrapeURLString: usesScrape ? scrapeURLString : nil,
            scrapeConfig: scrapeConfig,
            acceptsEmailForwarding: acceptsEmailForwarding
        )
        modelContext.insert(school)
        try? modelContext.save()
        dismiss()
    }
}
