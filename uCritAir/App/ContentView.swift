import SwiftUI

/// Root tab-based navigation container for the app.
///
/// Hosts four tabs: Dashboard, Data (history/charts), Devices, and Developer.
/// On first launch with no known devices, auto-navigates to the Devices tab.
struct ContentView: View {
    @Environment(DeviceViewModel.self) private var deviceVM
    @Environment(BLEManager.self) private var bleManager
    @Environment(\.modelContext) private var modelContext

    /// Index of the currently selected tab (0 = Dashboard, 1 = Data, 2 = Devices, 3 = Developer).
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                DashboardView(selectedTab: $selectedTab)
                    .navigationTitle("uCritAir")
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            connectedDeviceInfo
                        }
                        ToolbarItem(placement: .topBarTrailing) {
                            ConnectButton()
                        }
                    }
            }
            .tabItem {
                Label("Dashboard", systemImage: "square.grid.2x2")
            }
            .tag(0)

            NavigationStack {
                HistoryView()
            }
            .tabItem {
                Label("Data", systemImage: "chart.xyaxis.line")
            }
            .tag(1)

            NavigationStack {
                DeviceListView(selectedTab: $selectedTab)
            }
            .tabItem {
                Label("Devices", systemImage: "rectangle.stack")
            }
            .tag(2)

            NavigationStack {
                DeveloperPlaceholderView()
                    .navigationTitle("Developer")
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            ConnectButton()
                        }
                    }
            }
            .tabItem {
                Label("Developer", systemImage: "wrench")
            }
            .tag(3)
        }
        .onAppear {
            deviceVM.configureStorage(modelContext: modelContext)
            // Auto-connect to last device when Bluetooth is ready.
            // Delay 1s after poweredOn so the BLE radio has time to discover nearby peripherals.
            bleManager.whenBluetoothReady {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    deviceVM.autoConnectToLastDevice()
                }
            }
        }
        .task {
            // Wait for configureStorage to load known devices from SwiftData
            try? await Task.sleep(for: .milliseconds(100))
            if deviceVM.knownDevices.isEmpty {
                selectedTab = 2  // Auto-navigate to Devices tab
            }
        }
    }

    // MARK: - Connected Device Info (nav bar)

    /// Shows pet name and device name in the navigation bar when connected.
    /// Matches web app's Layout.tsx header: petName (blue) + deviceName (gray badge).
    @ViewBuilder
    private var connectedDeviceInfo: some View {
        if bleManager.connectionState == .connected {
            HStack(spacing: 6) {
                if let petName = deviceVM.petName, !petName.isEmpty {
                    Text(petName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.blue)
                }
                if let deviceName = deviceVM.deviceName, !deviceName.isEmpty {
                    Text(deviceName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color(.systemGray5))
                        .clipShape(Capsule())
                }
            }
        }
    }
}

// MARK: - Developer Placeholder

/// Debug/diagnostic view showing internal stats (cached cell count, device ID, known devices).
struct DeveloperPlaceholderView: View {
    @Environment(HistoryViewModel.self) private var historyVM
    @Environment(DeviceViewModel.self) private var deviceVM

    var body: some View {
        List {
            Section("Log Cell Stats") {
                LabeledContent("Cached Cells", value: "\(historyVM.cachedCount)")
                if let cellCount = deviceVM.cellCount {
                    LabeledContent("On Device", value: "\(cellCount)")
                }
            }

            Section("Device Info") {
                if let id = deviceVM.activeDeviceId {
                    LabeledContent("Device ID", value: String(id.prefix(8)) + "...")
                }
                LabeledContent("Known Devices", value: "\(deviceVM.knownDevices.count)")
            }
        }
    }
}
