import SwiftUI
import SwiftData
import os

@main
struct uCritAirApp: App {

    @State private var bleManager = BLEManager()

    @State private var deviceVM = DeviceViewModel()

    @State private var sensorVM = SensorViewModel()

    @State private var historyVM = HistoryViewModel()

    let modelContainer: ModelContainer

    init() {
        let schema = Schema([LogCellEntity.self, DeviceProfile.self])
        let config = ModelConfiguration(schema: schema)

        do {
            modelContainer = try ModelContainer(for: schema, configurations: [config])
        } catch {
            Logger(subsystem: "com.ucritter.ucritair", category: "App")
                .critical("SwiftData migration failed for persistent store at \(config.url.path, privacy: .public): \(error). Falling back to in-memory store without deleting on-disk data.")
            let memoryConfig = ModelConfiguration(isStoredInMemoryOnly: true)
            do {
                modelContainer = try ModelContainer(for: schema, configurations: [memoryConfig])
            } catch {
                fatalError("Unable to create even an in-memory ModelContainer: \(error)")
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(bleManager)
                .environment(deviceVM)
                .environment(sensorVM)
                .environment(historyVM)
                .modelContainer(modelContainer)
                .onAppear {
                    deviceVM.configure(bleManager: bleManager)
                    sensorVM.configure(bleManager: bleManager)
                }
        }
    }
}
