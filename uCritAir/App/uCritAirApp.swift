import SwiftUI
import SwiftData
import os

@main
struct uCritAirApp: App {

    @State private var bleManager = BLEManager()

    @State private var deviceVM = DeviceViewModel()

    @State private var sensorVM = SensorViewModel()

    @State private var historyVM = HistoryViewModel()

    @State private var hasAppliedDebugScenario = false

    let modelContainer: ModelContainer

    init() {
        let schema = Schema([LogCellEntity.self, DeviceProfile.self])
        let config = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: {
#if DEBUG
                DebugAppScenario.current.usesInMemoryStore
#else
                false
#endif
            }()
        )

        do {
            modelContainer = try ModelContainer(for: schema, configurations: [config])
#if DEBUG
            DebugAppScenarios.seedModelData(in: modelContainer.mainContext, scenario: DebugAppScenario.current)
#endif
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
#if DEBUG
                    if !hasAppliedDebugScenario {
                        hasAppliedDebugScenario = true
                        DebugAppScenarios.prepareBLEManager(bleManager, scenario: DebugAppScenario.current)
                    }
#endif

                    deviceVM.configure(bleManager: bleManager)
                    sensorVM.configure(bleManager: bleManager)

#if DEBUG
                    if DebugAppScenario.current != .live {
                        DebugAppScenarios.applyViewModelState(
                            bleManager: bleManager,
                            deviceVM: deviceVM,
                            sensorVM: sensorVM,
                            historyVM: historyVM,
                            modelContext: modelContainer.mainContext,
                            scenario: DebugAppScenario.current
                        )
                    }
#endif
                }
        }
    }
}
