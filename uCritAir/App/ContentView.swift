import SwiftUI

struct ContentView: View {

    @Environment(DeviceViewModel.self) private var deviceVM

    @Environment(BLEManager.self) private var bleManager

    @Environment(\.modelContext) private var modelContext

    @State private var selectedTab = 0

    @State private var hasCheckedInitialDevices = false

    @State private var hasRegisteredBluetoothReadyCallback = false

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
                AdvancedView()
            }
            .tabItem {
                Label("Advanced", systemImage: "gearshape.2")
            }
            .tag(3)
        }
        .onAppear {
            deviceVM.configureStorage(modelContext: modelContext)

            if !hasCheckedInitialDevices {
                hasCheckedInitialDevices = true
                if deviceVM.knownDevices.isEmpty {
                    selectedTab = 2
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
