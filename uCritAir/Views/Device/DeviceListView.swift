// ────────────────────────────────────────────────────────────────────────────
// DeviceListView.swift
// uCritAir
// ────────────────────────────────────────────────────────────────────────────
//
// PURPOSE:
//   The Devices tab (tab index 2 in the root TabView) manages the list of
//   known (previously paired) uCrit devices. It shows each device as a card
//   with its pet name, connection status, and air quality score.
//
//   From this screen, users can:
//   - See all devices they have ever connected to.
//   - Tap a disconnected device to reconnect and jump to the Dashboard.
//   - Tap the gear icon on a connected device to navigate to DeviceView (settings).
//   - Tap the grid icon on a connected device to navigate to the Dashboard.
//   - Swipe-to-delete or long-press to remove a device from the list.
//   - Tap the "+" button to scan for new devices.
//
// SWIFTUI CONCEPTS USED:
//   - @Binding: Two-way connection to `selectedTab` in the parent TabView,
//     allowing this view to switch to the Dashboard tab.
//   - @Environment: Reads shared view models and the SwiftData model context.
//   - @State: Private view state for controlling sheets, alerts, and navigation.
//   - .sheet: Presents a modal overlay (the BLE scan sheet).
//   - .alert: Presents a confirmation dialog before deleting a device.
//   - .navigationDestination(isPresented:): Programmatically pushes a new
//     view onto the NavigationStack when `showSettings` becomes true.
//   - .swipeActions: Adds swipe-to-delete gestures on list rows.
//   - .contextMenu: Adds a long-press context menu with reconnect/remove options.
//   - List / ForEach: Renders a scrollable list of device profiles.
//   - ContentUnavailableView: Built-in empty-state view shown when no devices exist.
//   - .onChange(of:): Reloads the device list when BLE connection state changes.
//
// ────────────────────────────────────────────────────────────────────────────

import SwiftUI

/// The device management list view — the third tab in the app.
///
/// Displays all known (previously paired) devices as cards. Connected devices
/// show action icons for settings and dashboard navigation. Disconnected devices
/// show a chevron and reconnect on tap.
///
/// ## Dependencies
/// - `DeviceViewModel`: Provides the list of known devices, connection state,
///   and methods for connecting, disconnecting, and removing devices.
/// - `SensorViewModel`: Provides current sensor data for computing the AQ score
///   shown on the connected device's card.
/// - `ModelContext`: SwiftData context for persisting device profiles.
///
/// ## Navigation
/// - Tapping a disconnected device calls `connectToKnownDevice()` and switches
///   to the Dashboard tab (index 0) via the `selectedTab` binding.
/// - Tapping the gear icon on a connected device pushes `DeviceView` onto the
///   NavigationStack via `.navigationDestination(isPresented:)`.
/// - Tapping the "+" toolbar button opens the BLE scan sheet.
struct DeviceListView: View {

    // MARK: - Properties

    /// Two-way binding to the selected tab index in the parent TabView.
    ///
    /// **SwiftUI concept — @Binding:**
    /// This allows DeviceListView to switch tabs programmatically. When the
    /// user taps a disconnected device, this view sets `selectedTab = 0` to
    /// navigate to the Dashboard.
    @Binding var selectedTab: Int

    /// The device view model providing the list of known devices and connection management.
    @Environment(DeviceViewModel.self) private var deviceVM

    /// The sensor view model providing current readings for the AQ score on device cards.
    @Environment(SensorViewModel.self) private var sensorVM

    /// The SwiftData model context for persistent storage of device profiles.
    @Environment(\.modelContext) private var modelContext

    // MARK: - State

    /// Controls whether the "Remove Device" confirmation alert is shown.
    @State private var showDeleteConfirmation = false

    /// The device profile that the user has chosen to delete.
    /// Stored here so the alert can reference it when the user confirms.
    @State private var deviceToDelete: DeviceProfile?

    /// Controls whether the BLE scan sheet is presented.
    ///
    /// **SwiftUI concept — @State + .sheet:**
    /// When `showScanSheet` becomes `true`, SwiftUI presents `DeviceListSheet()`
    /// as a modal sheet. When the sheet is dismissed (by swiping down or tapping
    /// Cancel), `showScanSheet` is automatically set back to `false`.
    @State private var showScanSheet = false

    /// Controls programmatic navigation push to the DeviceView (settings screen).
    ///
    /// **SwiftUI concept — @State + .navigationDestination(isPresented:):**
    /// When `showSettings` becomes `true`, the NavigationStack pushes the
    /// `DeviceView()` onto its stack. When the user taps "Back", `showSettings`
    /// is automatically set back to `false`.
    @State private var showSettings = false

    // MARK: - Body

    /// The main view body — conditionally shows an empty state or the device list.
    var body: some View {
        Group {
            if deviceVM.knownDevices.isEmpty {
                emptyState
            } else {
                deviceList
            }
        }
        .navigationTitle("Devices")
        // **SwiftUI concept — .navigationDestination(isPresented:):**
        // This modifier tells the NavigationStack to push DeviceView when
        // `showSettings` becomes true. When the user navigates back,
        // `showSettings` is automatically reset to false.
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
        // **SwiftUI concept — .sheet:**
        // `.sheet` presents a modal view that slides up from the bottom.
        // `isPresented` is bound to a @State Boolean. The `onDismiss` closure
        // runs when the sheet is dismissed (by swipe or programmatically),
        // allowing cleanup actions like stopping the BLE scan.
        .sheet(isPresented: $showScanSheet, onDismiss: {
            // Stop scanning if user swipe-dismissed the sheet without selecting a device.
            if deviceVM.connectionState == .scanning {
                deviceVM.disconnect()
            }
        }) {
            DeviceListSheet()
        }
        // **SwiftUI concept — .alert:**
        // `.alert` shows a system confirmation dialog. `isPresented` is bound
        // to a @State Boolean. The alert body defines buttons (destructive,
        // cancel) and a message. The `role: .destructive` parameter makes the
        // button red to warn the user about irreversible actions.
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

    /// A scrollable list of all known device profiles.
    ///
    /// Each device is rendered as a `DeviceCardRow`. The list supports two
    /// interaction patterns:
    ///
    /// 1. **Connected devices** — Displayed with action icons (gear for settings,
    ///    grid for dashboard). No outer tap gesture since the icons handle actions.
    /// 2. **Disconnected devices** — Wrapped in a `Button` that reconnects to the
    ///    device and switches to the Dashboard tab on tap.
    ///
    /// Both types support:
    /// - **Swipe-to-delete**: Swiping left reveals a red "Remove" button.
    /// - **Context menu**: Long-pressing shows Reconnect/Disconnect and Remove options.
    ///
    /// **SwiftUI concept — .swipeActions:**
    /// Adds swipe gesture actions to list rows. `edge: .trailing` means swipe
    /// from right to left. `allowsFullSwipe: false` prevents accidental deletion.
    ///
    /// **SwiftUI concept — .contextMenu:**
    /// Adds a long-press context menu with custom actions. The menu items are
    /// conditionally shown based on whether the device is connected.
    private var deviceList: some View {
        List {
            ForEach(deviceVM.knownDevices, id: \.deviceId) { profile in
                // Determine if this profile is the currently connected device.
                let isConnected = profile.deviceId == deviceVM.activeDeviceId
                // Compute AQ score only for the connected device with available data.
                let aqResult: AQScoreResult? = isConnected && sensorVM.current.hasAnyValue
                    ? AQIScoring.computeAQScore(sensorVM.current)
                    : nil

                Group {
                    if isConnected {
                        // Connected device: card with gear + dashboard action icons.
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
