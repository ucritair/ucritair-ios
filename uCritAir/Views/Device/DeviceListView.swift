import SwiftUI

/// Device management screen — Awair-style list of known devices.
///
/// Connected devices show gear (settings) and dashboard action icons.
/// Disconnected devices show a chevron and tap to reconnect + navigate to dashboard.
struct DeviceListView: View {
    @Binding var selectedTab: Int

    @Environment(DeviceViewModel.self) private var deviceVM
    @Environment(SensorViewModel.self) private var sensorVM
    @Environment(\.modelContext) private var modelContext

    @State private var showDeleteConfirmation = false
    @State private var deviceToDelete: DeviceProfile?
    @State private var showScanSheet = false
    /// Drives NavigationStack push to DeviceView for settings.
    @State private var showSettings = false

    var body: some View {
        Group {
            if deviceVM.knownDevices.isEmpty {
                emptyState
            } else {
                deviceList
            }
        }
        .navigationTitle("Devices")
        .navigationDestination(isPresented: $showSettings) {
            DeviceView()
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showScanSheet = true
                    deviceVM.scan()
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showScanSheet, onDismiss: {
            // Stop scanning if user swipe-dismissed the sheet without selecting a device.
            if deviceVM.connectionState == .scanning {
                deviceVM.disconnect()
            }
        }) {
            DeviceListSheet()
        }
        .alert("Remove Device", isPresented: $showDeleteConfirmation) {
            Button("Remove Device Only", role: .destructive) {
                if let device = deviceToDelete {
                    deviceVM.removeDevice(device, deleteCachedData: false)
                }
            }
            Button("Remove & Delete Data", role: .destructive) {
                if let device = deviceToDelete {
                    deviceVM.removeDevice(device, deleteCachedData: true)
                }
            }
            Button("Cancel", role: .cancel) {
                deviceToDelete = nil
            }
        } message: {
            if let device = deviceToDelete {
                Text("Remove \"\(device.petName.isEmpty ? device.deviceName : device.petName)\" from your device list?")
            }
        }
        .onAppear {
            deviceVM.configureStorage(modelContext: modelContext)
        }
        .onChange(of: deviceVM.connectionState) { _, newState in
            // Reload device list when connection state changes.
            // upsertDeviceProfile runs on connect, so we need to refresh.
            if newState == .connected || newState == .disconnected {
                deviceVM.loadKnownDevices()
            }
        }
    }

    // MARK: - Empty State

    /// Full-screen placeholder shown when no devices have been paired, with a scan button.
    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Devices", systemImage: "antenna.radiowaves.left.and.right.slash")
        } description: {
            Text("Connect to a uCrit device to get started.")
        } actions: {
            Button {
                showScanSheet = true
                deviceVM.scan()
            } label: {
                Text("Scan for Devices")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Device List

    /// Scrollable list of known device profiles with swipe-to-delete and context menu actions.
    private var deviceList: some View {
        List {
            ForEach(deviceVM.knownDevices, id: \.deviceId) { profile in
                let isConnected = profile.deviceId == deviceVM.activeDeviceId
                let aqResult: AQScoreResult? = isConnected && sensorVM.current.hasAnyValue
                    ? AQIScoring.computeAQScore(sensorVM.current)
                    : nil

                Group {
                    if isConnected {
                        // Connected device: card with gear + dashboard icons (no outer button)
                        DeviceCardRow(
                            profile: profile,
                            isConnected: true,
                            aqResult: aqResult,
                            onSettingsTap: { showSettings = true },
                            onDashboardTap: { selectedTab = 0 }
                        )
                    } else {
                        // Disconnected device: tap to reconnect + navigate to dashboard
                        Button {
                            deviceVM.connectToKnownDevice(profile)
                            selectedTab = 0
                        } label: {
                            DeviceCardRow(
                                profile: profile,
                                isConnected: false,
                                aqResult: nil
                            )
                        }
                        .foregroundStyle(.primary)
                    }
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        deviceToDelete = profile
                        showDeleteConfirmation = true
                    } label: {
                        Label("Remove", systemImage: "trash")
                    }
                }
                .contextMenu {
                    if !isConnected {
                        Button {
                            deviceVM.connectToKnownDevice(profile)
                        } label: {
                            Label("Reconnect", systemImage: "antenna.radiowaves.left.and.right")
                        }
                    } else {
                        Button {
                            deviceVM.disconnect()
                        } label: {
                            Label("Disconnect", systemImage: "xmark.circle")
                        }
                    }

                    Button {
                        deviceToDelete = profile
                        showDeleteConfirmation = true
                    } label: {
                        Label("Remove", systemImage: "trash")
                    }
                }
            }
        }
    }
}
