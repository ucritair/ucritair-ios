import SwiftUI

struct DeviceListView: View {

    @Binding var selectedTab: Int

    @Environment(DeviceViewModel.self) private var deviceVM

    @Environment(SensorViewModel.self) private var sensorVM

    @Environment(\.modelContext) private var modelContext

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var showDeleteConfirmation = false

    @State private var deviceToDelete: DeviceProfile?

    @State private var showScanSheet = false

    @State private var showSettings = false

    @State private var showAbout = false

    var body: some View {
        Group {
            if deviceVM.knownDevices.isEmpty {
                emptyState
            } else {
                deviceList
            }
        }
        .navigationTitle("Devices")
        .accessibilityIdentifier("devicesScreen")
        .navigationDestination(isPresented: $showSettings) {
            DeviceView()
        }
        .navigationDestination(isPresented: $showAbout) {
            AboutView()
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    showAbout = true
                } label: {
                    Image(systemName: "info.circle")
                }
            }
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
            if newState == .connected || newState == .disconnected {
                deviceVM.loadKnownDevices()
            }
        }
    }

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

    private var deviceList: some View {
        List {
            if dynamicTypeSize.usesAccessibilityLayout && deviceVM.connectionState == .connected {
                Section {
                    ConnectedDeviceHeader()
                }
            }

            ForEach(deviceVM.knownDevices, id: \.deviceId) { profile in
                let isConnected = profile.deviceId == deviceVM.activeDeviceId
                let aqResult: AQScoreResult? = isConnected && sensorVM.current.hasAnyValue
                    ? AQIScoring.computeAQScore(sensorVM.current)
                    : nil

                Group {
                    if isConnected {
                        DeviceCardRow(
                            profile: profile,
                            isConnected: true,
                            aqResult: aqResult,
                            onSettingsTap: { showSettings = true },
                            onDashboardTap: { selectedTab = 0 }
                        )
                    } else {
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
        .appTabBarScrollContentClearance()
    }
}
