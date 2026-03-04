import SwiftUI
import SwiftData
import os

/// Main application entry point for the uCritAir iOS app.
///
/// Creates and owns the shared observable view models (``BLEManager``, ``DeviceViewModel``,
/// ``SensorViewModel``, ``HistoryViewModel``) and the SwiftData ``ModelContainer``,
/// injecting them into the environment for all child views.
@main
struct uCritAirApp: App {
    /// Shared BLE central manager that handles scanning, connecting, and characteristic I/O.
    @State private var bleManager = BLEManager()

    /// Shared view model for device connection state, info, and multi-device registry.
    @State private var deviceVM = DeviceViewModel()

    /// Shared view model for live sensor readings and rolling history.
    @State private var sensorVM = SensorViewModel()

    /// Shared view model for historical log cell data, charts, and CSV export.
    @State private var historyVM = HistoryViewModel()

    /// SwiftData container persisting ``LogCellEntity`` and ``DeviceProfile`` models.
    let modelContainer: ModelContainer

    /// Initializes the SwiftData model container.
    ///
    /// If schema migration fails (e.g., after adding new fields), the old store is deleted
    /// and recreated. The device retains all data, so the user can re-download.
    init() {
        // Pre-release: if the schema changed (new fields on LogCellEntity),
        // delete the old store and start fresh. The device still has all data
        // so the user can re-download.
        let schema = Schema([LogCellEntity.self, DeviceProfile.self])
        let config = ModelConfiguration(schema: schema)

        do {
            modelContainer = try ModelContainer(for: schema, configurations: [config])
        } catch {
            // Migration failed — nuke the store and retry
            Logger(subsystem: "com.ucritter.ucritair", category: "App")
                .error("SwiftData migration failed: \(error). Deleting old store.")
            let storeURL = config.url
            let fm = FileManager.default
            // Delete all SQLite-related files
            for suffix in ["", "-wal", "-shm"] {
                let fileURL = URL(fileURLWithPath: storeURL.path + suffix)
                try? fm.removeItem(at: fileURL)
            }

            do {
                modelContainer = try ModelContainer(for: schema, configurations: [config])
            } catch {
                // Last resort: fall back to in-memory store so the app can launch.
                // Data won't persist across launches but the user can still use BLE features.
                Logger(subsystem: "com.ucritter.ucritair", category: "App")
                    .critical("Failed to create ModelContainer after store reset: \(error). Using in-memory store.")
                let memoryConfig = ModelConfiguration(isStoredInMemoryOnly: true)
                // swiftlint:disable:next force_try
                modelContainer = try! ModelContainer(for: schema, configurations: [memoryConfig])
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
                    // Wire up BLE manager to ViewModels
                    deviceVM.configure(bleManager: bleManager)
                    sensorVM.configure(bleManager: bleManager)
                }
        }
    }
}
