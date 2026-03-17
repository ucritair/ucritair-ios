#if DEBUG
import SwiftUI
import SwiftData

enum DebugAppScenario: String {
    case live
    case uiDisconnected
    case uiConnected

    static var current: DebugAppScenario {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--uitest-connected") {
            return .uiConnected
        }
        if args.contains("--uitest-disconnected") {
            return .uiDisconnected
        }
        return .live
    }

    var usesInMemoryStore: Bool {
        self != .live
    }

    static var debugHistoryTimeRange: TimeRange? {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--debug-history-7d") {
            return .sevenDays
        }
        if args.contains("--debug-history-1d") {
            return .oneDay
        }
        if args.contains("--debug-history-1h") {
            return .oneHour
        }
        if args.contains("--debug-history-all") {
            return .all
        }
        return nil
    }

    static var initialTabSelection: Int? {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--debug-open-dashboard") {
            return 0
        }
        if args.contains("--debug-open-data") {
            return 1
        }
        if args.contains("--debug-open-devices") {
            return 2
        }
        if args.contains("--debug-open-advanced") {
            return 3
        }
        return nil
    }
}

enum DebugAppScenarios {
    static let primaryDeviceID = "6E6B78EE-2B2B-4A31-9FA8-7FDE1A1D0A11"
    static let secondaryDeviceID = "4D4B0191-FD46-4DF4-9F8C-D2B6F8EE0099"

    @MainActor
    static func seedModelData(in context: ModelContext, scenario: DebugAppScenario) {
        guard scenario != .live else { return }

        let profiles = [
            DeviceProfile(
                deviceId: primaryDeviceID,
                deviceName: "uCrit Alpha",
                petName: "Maple",
                roomLabel: "Living Room",
                lastConnectedAt: .now,
                lastKnownCellCount: 36,
                sortOrder: 0
            ),
            DeviceProfile(
                deviceId: secondaryDeviceID,
                deviceName: "uCrit Beta",
                petName: "Juniper",
                roomLabel: "Bedroom",
                lastConnectedAt: .now.addingTimeInterval(-7200),
                lastKnownCellCount: 12,
                sortOrder: 1
            ),
        ]

        for profile in profiles {
            context.insert(profile)
        }

        for cell in sampleLogCells(deviceId: primaryDeviceID) {
            context.insert(cell)
        }

        try? context.save()
    }

    @MainActor
    static func prepareBLEManager(_ bleManager: BLEManager, scenario: DebugAppScenario) {
        switch scenario {
        case .live:
            break
        case .uiDisconnected:
            bleManager._testSetMockConnectionState(.disconnected)
        case .uiConnected:
            bleManager._testSetMockConnectionState(.connected, deviceId: primaryDeviceID)
        }
    }

    @MainActor
    static func applyViewModelState(
        bleManager: BLEManager,
        deviceVM: DeviceViewModel,
        sensorVM: SensorViewModel,
        historyVM: HistoryViewModel,
        modelContext: ModelContext,
        scenario: DebugAppScenario
    ) {
        guard scenario != .live else { return }

        deviceVM.configureStorage(modelContext: modelContext)
        historyVM.configure(bleManager: bleManager, modelContext: modelContext)
        historyVM.syncDeviceId(from: bleManager)
        historyVM.selectedSensor = "co2"
        historyVM.setTimeRange(DebugAppScenario.debugHistoryTimeRange ?? .oneDay)

        switch scenario {
        case .live:
            break
        case .uiDisconnected:
            sensorVM.current = .empty
            sensorVM.history = []
            historyVM.currentDeviceId = nil
            historyVM.allCells = []
            historyVM.cachedCount = 0
            deviceVM.error = nil
        case .uiConnected:
            deviceVM.deviceName = "uCrit Alpha"
            deviceVM.petName = "Maple"
            deviceVM.deviceTime = UnitFormatters.getLocalTimeAsEpoch()
            deviceVM.petStats = PetStats(vigour: 188, focus: 164, spirit: 201, age: 48, interventions: 5)
            deviceVM.config = DeviceConfig(
                sensorWakeupPeriod: 30,
                sleepAfterSeconds: 120,
                dimAfterSeconds: 20,
                noxSamplePeriod: 4,
                screenBrightness: 64,
                persistFlags: [.aqFirst, .batteryAlert]
            )
            deviceVM.bonus = 240
            deviceVM.cellCount = 36
            deviceVM.connectionState = .connected

            sensorVM.current = sampleSensorValues
            sensorVM.history = sampleSensorHistory

            historyVM.loadCachedCells()
        }
    }

    static var sampleSensorValues: SensorValues {
        SensorValues(
            temperature: 22.4,
            humidity: 47.0,
            co2: 684,
            pm1_0: 2.6,
            pm2_5: 4.8,
            pm4_0: 6.1,
            pm10: 8.4,
            pressure: 1012.6,
            voc: 84,
            nox: 41
        )
    }

    static var sampleSensorHistory: [SensorReading] {
        var readings: [SensorReading] = []

        for step in 0..<18 {
            let values = SensorValues(
                temperature: 21.5 + Double(step % 5) * 0.2,
                humidity: 46.0 + Double(step % 4),
                co2: 640 + Double(step * 6),
                pm1_0: 2.0 + Double(step % 3) * 0.4,
                pm2_5: 4.0 + Double(step % 4) * 0.5,
                pm4_0: 5.5 + Double(step % 4) * 0.6,
                pm10: 7.0 + Double(step % 5) * 0.8,
                pressure: 1011.5 + Double(step % 3) * 0.4,
                voc: 76 + Double(step),
                nox: 36 + Double(step) * 0.5
            )

            readings.append(
                SensorReading(
                    timestamp: Date().addingTimeInterval(TimeInterval(-step * 240)),
                    values: values
                )
            )
        }

        return readings.reversed()
    }

    private static func sampleLogCells(deviceId: String) -> [LogCellEntity] {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: Date())

        return (0..<36).map { index in
            let timestamp = Int(startOfDay.addingTimeInterval(TimeInterval(index * 40 * 60)).timeIntervalSince1970)
            let parsed = ParsedLogCell(
                cellNumber: index,
                flags: LogCellFlag.hasTempRHParticles | LogCellFlag.hasCO2,
                timestamp: timestamp,
                temperature: 21.8 + Double(index % 6) * 0.25,
                pressure: 1011.8 + Double(index % 4) * 0.6,
                humidity: 44.0 + Double(index % 5) * 1.3,
                co2: 620 + index * 7,
                pm: (
                    pm1_0: 2.1 + Double(index % 3) * 0.3,
                    pm2_5: 4.2 + Double(index % 5) * 0.4,
                    pm4_0: 5.3 + Double(index % 5) * 0.5,
                    pm10: 6.9 + Double(index % 6) * 0.7
                ),
                pn: (
                    pn0_5: 110.0 + Double(index * 2),
                    pn1_0: 72.0 + Double(index),
                    pn2_5: 35.0 + Double(index % 6),
                    pn4_0: 19.0 + Double(index % 4),
                    pn10: 8.0 + Double(index % 3)
                ),
                voc: 80 + index,
                nox: 40 + index / 2,
                co2Uncomp: 640 + index * 7,
                stroop: StroopData(meanTimeCong: 1.0, meanTimeIncong: 1.2, throughput: 12)
            )
            return LogCellEntity(from: parsed, deviceId: deviceId)
        }
    }

    @MainActor
    static func makePreviewContainer(scenario: DebugAppScenario) -> ModelContainer {
        let schema = Schema([LogCellEntity.self, DeviceProfile.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try! ModelContainer(for: schema, configurations: [config])
        seedModelData(in: container.mainContext, scenario: scenario)
        return container
    }
}

@MainActor
struct PreviewAppHarness<Content: View>: View {

    @State private var bleManager: BLEManager

    @State private var deviceVM: DeviceViewModel

    @State private var sensorVM: SensorViewModel

    @State private var historyVM: HistoryViewModel

    let modelContainer: ModelContainer

    let content: Content

    init(scenario: DebugAppScenario, @ViewBuilder content: () -> Content) {
        let bleManager = BLEManager()
        let deviceVM = DeviceViewModel()
        let sensorVM = SensorViewModel()
        let historyVM = HistoryViewModel()
        let modelContainer = DebugAppScenarios.makePreviewContainer(scenario: scenario)

        DebugAppScenarios.prepareBLEManager(bleManager, scenario: scenario)
        deviceVM.configure(bleManager: bleManager)
        sensorVM.configure(bleManager: bleManager)
        DebugAppScenarios.applyViewModelState(
            bleManager: bleManager,
            deviceVM: deviceVM,
            sensorVM: sensorVM,
            historyVM: historyVM,
            modelContext: modelContainer.mainContext,
            scenario: scenario
        )

        _bleManager = State(initialValue: bleManager)
        _deviceVM = State(initialValue: deviceVM)
        _sensorVM = State(initialValue: sensorVM)
        _historyVM = State(initialValue: historyVM)
        self.modelContainer = modelContainer
        self.content = content()
    }

    var body: some View {
        content
            .environment(bleManager)
            .environment(deviceVM)
            .environment(sensorVM)
            .environment(historyVM)
            .modelContainer(modelContainer)
    }
}
#endif
