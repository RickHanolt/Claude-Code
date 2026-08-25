import SwiftUI
import SwiftData

@main
struct SchoolSyncApp: App {
    let sharedModelContainer: ModelContainer = {
        let schema = Schema([KidRecord.self, SchoolRecord.self, SchoolEventRecord.self])
        let configuration = ModelConfiguration(schema: schema, url: AppGroup.sharedModelStoreURL)
        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Could not create SwiftData ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(sharedModelContainer)
    }
}
