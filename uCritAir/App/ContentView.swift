import SwiftUI

struct ContentView: View {

    private enum AppTab: Int, CaseIterable, Identifiable {
        case dashboard = 0
        case data = 1
        case devices = 2
        case advanced = 3

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .dashboard:
                return "Dashboard"
            case .data:
                return "Data"
            case .devices:
                return "Devices"
            case .advanced:
                return "Advanced"
            }
        }

        var systemImage: String {
            switch self {
            case .dashboard:
                return "square.grid.2x2"
            case .data:
                return "chart.xyaxis.line"
            case .devices:
                return "rectangle.stack"
            case .advanced:
                return "gearshape.2"
            }
        }
    }

    @Environment(DeviceViewModel.self) private var deviceVM
    @Environment(BLEManager.self) private var bleManager
    @Environment(SensorViewModel.self) private var sensorVM
    @Environment(HistoryViewModel.self) private var historyVM
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.modelContext) private var modelContext

    @State private var selectedTab = AppTab.dashboard.rawValue
    @State private var hasCheckedInitialDevices = false
    @State private var hasRegisteredBluetoothReadyCallback = false

    private var currentTab: AppTab {
        AppTab(rawValue: selectedTab) ?? .dashboard
    }

    var body: some View {
        NativeTabBarController(
            selectedTab: $selectedTab,
            tabs: tabConfigurations,
            bleManager: bleManager,
            deviceViewModel: deviceVM,
            sensorViewModel: sensorVM,
            historyViewModel: historyVM,
            modelContext: modelContext
        )
        .ignoresSafeArea(SafeAreaRegions.keyboard, edges: Edge.Set.bottom)
        .onAppear {
            deviceVM.configureStorage(modelContext: modelContext)

#if DEBUG
            if let debugTab = DebugAppScenario.initialTabSelection {
                selectedTab = debugTab
            }
#endif

            if !hasCheckedInitialDevices {
                hasCheckedInitialDevices = true
                if deviceVM.knownDevices.isEmpty {
                    selectedTab = AppTab.devices.rawValue
                }
            }

            if !hasRegisteredBluetoothReadyCallback {
                hasRegisteredBluetoothReadyCallback = true
                bleManager.whenBluetoothReady {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        deviceVM.autoConnectToLastDevice()
                    }
                }
            }
        }
    }

    private var tabConfigurations: [NativeTabBarController.Tab] {
        AppTab.allCases.map { tab in
            NativeTabBarController.Tab(
                id: tab.rawValue,
                title: tab.title,
                systemImage: tab.systemImage,
                accessibilityIdentifier: accessibilityIdentifier(for: tab),
                rootView: AnyView(rootView(for: tab))
            )
        }
    }

    private func accessibilityIdentifier(for tab: AppTab) -> String {
        switch tab {
        case .dashboard:
            return "tabDashboard"
        case .data:
            return "tabData"
        case .devices:
            return "tabDevices"
        case .advanced:
            return "tabAdvanced"
        }
    }

    @ViewBuilder
    private func rootView(for tab: AppTab) -> some View {
        switch tab {
        case .dashboard:
            dashboardTab
        case .data:
            historyTab
        case .devices:
            devicesTab
        case .advanced:
            advancedTab
        }
    }

    private var dashboardTab: some View {
        NavigationStack {
            DashboardView(selectedTab: $selectedTab)
                .navigationTitle("uCritAir")
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        ConnectButton()
                    }
                    if !dynamicTypeSize.usesAccessibilityLayout {
                        ToolbarItem(placement: .topBarTrailing) {
                            connectedDeviceInfo
                        }
                    }
                }
        }
    }

    private var historyTab: some View {
        NavigationStack {
            HistoryView()
        }
    }

    private var devicesTab: some View {
        NavigationStack {
            DeviceListView(selectedTab: $selectedTab)
        }
    }

    private var advancedTab: some View {
        NavigationStack {
            AdvancedView()
        }
    }

    @ViewBuilder
    private var connectedDeviceInfo: some View {
        if bleManager.connectionState == .connected {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    if let petName = deviceVM.petName, !petName.isEmpty {
                        Text(petName)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.blue)
                            .lineLimit(1)
                    }
                    if let deviceName = deviceVM.deviceName, !deviceName.isEmpty {
                        Text(deviceName)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color(.systemGray5))
                            .clipShape(Capsule())
                    }
                }

                if let petName = deviceVM.petName, !petName.isEmpty {
                    Text(petName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.blue)
                        .lineLimit(1)
                }
            }
        }
    }
}
