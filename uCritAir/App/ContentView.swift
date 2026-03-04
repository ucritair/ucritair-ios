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

    /// Guards the one-time auto-navigation to the Devices tab on first launch.
    @State private var hasCheckedInitialDevices = false

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                DashboardView(selectedTab: $selectedTab)
                    .navigationTitle("uCritAir")
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            ConnectButton()
                        }
                        ToolbarItem(placement: .topBarTrailing) {
                            connectedDeviceInfo
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
                DeveloperToolsView()
            }
            .tabItem {
                Label("Developer", systemImage: "wrench")
            }
            .tag(3)
        }
        .onAppear {
            deviceVM.configureStorage(modelContext: modelContext)

            // On first launch with no paired devices, navigate to Devices tab.
            if !hasCheckedInitialDevices {
                hasCheckedInitialDevices = true
                if deviceVM.knownDevices.isEmpty {
                    selectedTab = 2
                }
            }

            // Auto-connect to last device when Bluetooth is ready.
            // Delay 1s after poweredOn so the BLE radio has time to discover nearby peripherals.
            bleManager.whenBluetoothReady {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    deviceVM.autoConnectToLastDevice()
                }
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
        }
    }
}
