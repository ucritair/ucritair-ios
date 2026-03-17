import SwiftUI
import SwiftData
import os

@main
struct uCritAirApp: App {

    private enum AppBootstrapState {
        case ready(ModelContainer)
        case failed(String)
    }

    @State private var bleManager = BLEManager()

    @State private var deviceVM = DeviceViewModel()

    @State private var sensorVM = SensorViewModel()

    @State private var historyVM = HistoryViewModel()

    @State private var hasAppliedDebugScenario = false

    private let bootstrapState: AppBootstrapState

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
            let modelContainer = try ModelContainer(for: schema, configurations: [config])
#if DEBUG
            DebugAppScenarios.seedModelData(in: modelContainer.mainContext, scenario: DebugAppScenario.current)
#endif
            bootstrapState = .ready(modelContainer)
        } catch {
            Logger(subsystem: "com.ucritter.ucritair", category: "App")
                .critical("SwiftData migration failed for persistent store at \(config.url.path, privacy: .public): \(error). Falling back to in-memory store without deleting on-disk data.")
            let memoryConfig = ModelConfiguration(isStoredInMemoryOnly: true)
            do {
                let modelContainer = try ModelContainer(for: schema, configurations: [memoryConfig])
                bootstrapState = .ready(modelContainer)
            } catch {
                let message = "The app could not initialize its local data store. Restart the app. If the problem continues, reinstall the app or contact support."
                Logger(subsystem: "com.ucritter.ucritair", category: "App")
                    .fault("Unable to create in-memory ModelContainer after persistent-store failure: \(error)")
                bootstrapState = .failed(message)
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            switch bootstrapState {
            case .ready(let modelContainer):
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
            case .failed(let message):
                LaunchFailureView(message: message)
            }
        }
    }
}

private struct LaunchFailureView: View {

    let message: String

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .font(.system(size: 42, weight: .semibold))
                .foregroundStyle(.orange)

            Text("Storage Unavailable")
                .font(.title2.weight(.semibold))

            Text(message)
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
        .background(Color(.systemBackground))
    }
}
