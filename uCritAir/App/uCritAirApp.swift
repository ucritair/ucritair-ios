// ────────────────────────────────────────────────────────────────────────────
// uCritAirApp.swift
// uCritAir
// ────────────────────────────────────────────────────────────────────────────
//
// PURPOSE:
//   This is the app's entry point — the very first code that runs when the
//   user launches the app. It performs three critical responsibilities:
//
//   1. **Creates the shared view models** — The four observable objects
//      (BLEManager, DeviceViewModel, SensorViewModel, HistoryViewModel) are
//      created here as @State properties and injected into the SwiftUI
//      environment. Every view in the app reads these shared objects.
//
//   2. **Sets up the SwiftData database** — Creates a `ModelContainer` that
//      manages the on-device SQLite database for persisting log cells and
//      device profiles. Includes fallback logic if schema migration fails.
//
//   3. **Wires up dependencies** — In the `.onAppear` of the body, connects
//      the BLE manager to the view models so they can receive BLE events.
//
// SWIFTUI CONCEPTS USED:
//   - @main: The Swift attribute that marks this struct as the app's entry
//     point. When the system launches the app, it creates an instance of this
//     struct and calls its `body` property.
//   - App protocol: The top-level protocol that defines a SwiftUI application.
//     It requires a `body` property of type `some Scene`.
//   - WindowGroup: A scene that creates a window containing the app's root view.
//     On iPhone, there is exactly one window. On iPad, multiple windows are possible.
//   - @State: Creates and owns the observable view model objects. Using @State
//     at the App level ensures the view models persist for the entire app lifetime.
//   - .environment(): Injects objects into the SwiftUI environment so that
//     any descendant view can read them with @Environment.
//   - .modelContainer(): Injects the SwiftData ModelContainer, making the
//     `ModelContext` available to descendant views via @Environment(\.modelContext).
//
// SWIFTDATA CONCEPTS:
//   - Schema: Defines which model types (LogCellEntity, DeviceProfile) are
//     stored in the database.
//   - ModelConfiguration: Specifies database storage options (file-based vs.
//     in-memory, custom URL, etc.).
//   - ModelContainer: The top-level SwiftData object that manages the database
//     schema, storage, and provides ModelContext instances for reading/writing.
//
// ARCHITECTURE NOTE:
//   The view models follow the MVVM (Model-View-ViewModel) pattern:
//   - **Model**: SwiftData entities (LogCellEntity, DeviceProfile) and BLE data.
//   - **ViewModel**: BLEManager, DeviceViewModel, SensorViewModel, HistoryViewModel.
//   - **View**: All SwiftUI views in the Views/ directory.
//
//   The view models are created here at the App level (not in individual views)
//   because they need to be shared across multiple tabs and views. This is
//   sometimes called "dependency injection via the environment."
//
// ────────────────────────────────────────────────────────────────────────────

import SwiftUI
import SwiftData
import os

/// The main application entry point for the uCritAir iOS app.
///
/// This struct conforms to the `App` protocol and is marked with `@main`,
/// making it the starting point when the app launches. It creates and owns
/// all shared view models, sets up the SwiftData database, and defines the
/// app's scene structure.
///
/// ## View Model Ownership
/// The four shared view models are created as `@State` properties here:
/// - `bleManager`: Handles all Bluetooth Low Energy communication.
/// - `deviceVM`: Manages device connection state, info, and profiles.
/// - `sensorVM`: Processes live sensor readings from BLE notifications.
/// - `historyVM`: Manages historical log data, charts, and CSV export.
///
/// These are injected into the environment via `.environment()` modifiers
/// on `ContentView`, making them available to every view in the app.
///
/// ## Database Setup
/// The `modelContainer` property creates a SwiftData database for persisting
/// `LogCellEntity` (historical sensor data) and `DeviceProfile` (paired device info).
/// It includes resilient fallback logic:
/// 1. Try to create the container normally.
/// 2. If migration fails, delete the old store and try again.
/// 3. If that fails too, fall back to an in-memory store (data lost on relaunch).
@main
struct uCritAirApp: App {

    // MARK: - Shared View Models

    /// The shared BLE central manager that handles scanning, connecting, and characteristic I/O.
    ///
    /// **SwiftUI concept — @State at App level:**
    /// Using `@State` at the `App` level creates an object that lives for the
    /// entire lifetime of the application. This is different from `@State` in a
    /// `View`, which is recreated when the view is destroyed and re-created.
    @State private var bleManager = BLEManager()

    /// The shared view model for device connection state, device info, and the multi-device registry.
    @State private var deviceVM = DeviceViewModel()

    /// The shared view model for live sensor readings and the rolling in-memory history buffer.
    @State private var sensorVM = SensorViewModel()

    /// The shared view model for historical log cell data, chart rendering, and CSV export.
    @State private var historyVM = HistoryViewModel()

    // MARK: - SwiftData

    /// The SwiftData model container that manages the on-device SQLite database.
    ///
    /// This container persists two model types:
    /// - `LogCellEntity`: Individual sensor data log entries downloaded from the device.
    /// - `DeviceProfile`: Information about paired devices (name, last connection, etc.).
    let modelContainer: ModelContainer

    /// Initializes the SwiftData model container with resilient fallback logic.
    ///
    /// **Migration Strategy:**
    /// During development, the database schema changes frequently (new fields, etc.).
    /// Rather than writing complex migration code, the app uses a "delete and recreate"
    /// strategy: if the container fails to open (migration error), the old database
    /// files are deleted and a fresh container is created. This is acceptable because
    /// the device retains all log data, so the user can re-download it.
    ///
    /// **Fallback Chain:**
    /// 1. Normal file-based container.
    /// 2. Delete old store files, then try file-based again.
    /// 3. In-memory container (last resort — data lost on app termination).
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
                do {
                    modelContainer = try ModelContainer(for: schema, configurations: [memoryConfig])
                } catch {
                    // In-memory ModelContainer creation should never fail for a valid schema.
                    // If it does, the app cannot function at all.
                    fatalError("Unable to create even an in-memory ModelContainer: \(error)")
                }
            }
        }
    }

    // MARK: - Scene Body

    /// The app's scene definition — a single WindowGroup containing ContentView.
    ///
    /// **SwiftUI concept — WindowGroup:**
    /// `WindowGroup` is a Scene type that creates the app's main window. On
    /// iPhone, there is exactly one window. On iPad with multitasking, multiple
    /// windows can be created.
    ///
    /// **Environment Injection:**
    /// The four `.environment()` calls inject the shared view models into the
    /// SwiftUI environment tree. Any descendant view can then read these objects
    /// using `@Environment(BLEManager.self)`, etc.
    ///
    /// **SwiftData Injection:**
    /// `.modelContainer(modelContainer)` makes the SwiftData `ModelContext`
    /// available to all descendant views via `@Environment(\.modelContext)`.
    var body: some Scene {
        WindowGroup {
            ContentView()
                // Inject all four shared view models into the environment.
                .environment(bleManager)
                .environment(deviceVM)
                .environment(sensorVM)
                .environment(historyVM)
                // Inject the SwiftData model container (provides ModelContext to child views).
                .modelContainer(modelContainer)
                .onAppear {
                    // Wire up the BLE manager to the view models so they can
                    // receive BLE events (characteristic updates, connection changes).
                    // This two-step initialization pattern is used because the
                    // view models are created before the BLE manager is ready.
                    deviceVM.configure(bleManager: bleManager)
                    sensorVM.configure(bleManager: bleManager)
                }
        }
    }
}
