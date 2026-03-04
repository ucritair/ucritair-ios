import SwiftUI

/// Device management screen — Awair-style list of known devices.
/// Replaces the old DevicePlaceholderView.
struct DeviceListView: View {
    @Binding var selectedTab: Int

    @Environment(DeviceViewModel.self) private var deviceVM
    @Environment(BLEManager.self) private var bleManager
    @Environment(SensorViewModel.self) private var sensorVM
    @Environment(\.modelContext) private var modelContext

    @State private var showDeleteConfirmation = false
    @State private var deviceToDelete: DeviceProfile?
    @State private var showScanSheet = false

    var body: some View {
        Group {
            if deviceVM.knownDevices.isEmpty {
                emptyState
            } else {
                deviceList
            }
        }
        .navigationTitle("Devices")
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
        .sheet(isPresented: $showScanSheet) {
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

                Button {
                    handleDeviceTap(profile, isConnected: isConnected)
                } label: {
                    DeviceCardRow(
                        profile: profile,
                        isConnected: isConnected,
                        aqResult: aqResult
                    )
                }
                .foregroundStyle(.primary)
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

    // MARK: - Actions

    /// Handles a tap on a device row: navigates to the Dashboard if already connected, or initiates reconnection first.
    /// - Parameters:
    ///   - profile: The tapped device's persisted profile.
    ///   - isConnected: Whether this device is the currently connected peripheral.
    private func handleDeviceTap(_ profile: DeviceProfile, isConnected: Bool) {
        if isConnected {
            // Navigate to Dashboard for this device
            selectedTab = 0
        } else {
            // Attempt reconnect, then navigate to Dashboard
            deviceVM.connectToKnownDevice(profile)
            selectedTab = 0
        }
    }
}
