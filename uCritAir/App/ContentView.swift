// ────────────────────────────────────────────────────────────────────────────
// ContentView.swift
// uCritAir
// ────────────────────────────────────────────────────────────────────────────
//
// PURPOSE:
//   The root view of the entire app. ContentView defines the tab-based
//   navigation structure and is the first view rendered inside the WindowGroup
//   scene in uCritAirApp.swift.
//
//   The app has four tabs:
//
//   ┌─────────────┬─────────────┬─────────────┬─────────────┐
//   │  Dashboard   │    Data     │   Devices   │  Advanced   │
//   │  (tab 0)    │  (tab 1)    │  (tab 2)    │  (tab 3)    │
//   └─────────────┴─────────────┴─────────────┴─────────────┘
//
//   Each tab wraps its content in a NavigationStack, enabling drill-down
//   navigation within each tab (e.g., Device list -> Device settings).
//
//   On first launch (no devices paired), the app auto-navigates to the
//   Devices tab so the user can pair their first device. On subsequent
//   launches, it auto-connects to the last known device.
//
// SWIFTUI CONCEPTS USED:
//   - TabView(selection:): A tab bar interface that switches between views.
//     The `selection` parameter is bound to a @State integer, allowing
//     programmatic tab switching from any child view.
//   - NavigationStack: Each tab has its own NavigationStack, providing
//     independent navigation history per tab. This means pushing a view
//     in the Devices tab does not affect the Dashboard tab.
//   - .tag(): Associates an integer with each tab so the TabView knows
//     which tab corresponds to which @State value.
//   - .tabItem: Defines the icon and label shown in the tab bar.
//   - .toolbar: Adds buttons to the navigation bar within a NavigationStack.
//   - @Environment: Reads shared view models and the SwiftData model context.
//   - @State: Manages the selected tab index and the first-launch guard flag.
//   - .onAppear: Performs one-time setup when the view first appears.
//   - @ViewBuilder: Allows conditional view returns in `connectedDeviceInfo`.
//
// ────────────────────────────────────────────────────────────────────────────

import SwiftUI

/// The root view defining the app's four-tab navigation structure.
///
/// `ContentView` is the top-level view in the app's view hierarchy. It creates
/// a `TabView` with four tabs (Dashboard, Data, Devices, Developer), each wrapped
/// in its own `NavigationStack` for independent navigation.
///
/// ## First Launch Behavior
/// When the app launches for the first time with no paired devices,
/// `selectedTab` is set to 2 (Devices tab) so the user is guided to pair
/// their first device.
///
/// ## Auto-Connect
/// On subsequent launches, the app waits for Bluetooth to power on, then
/// automatically reconnects to the last connected device after a 1-second delay
/// (to allow the BLE radio to stabilize).
///
/// ## Dependencies
/// - `DeviceViewModel`: Provides device list, auto-connect, and storage configuration.
/// - `BLEManager`: Provides BLE connection state and the `whenBluetoothReady` callback.
/// - `ModelContext`: SwiftData context passed to the DeviceViewModel for storage setup.
struct ContentView: View {

    // MARK: - Environment

    /// The shared device view model for device management and auto-connect.
    @Environment(DeviceViewModel.self) private var deviceVM

    /// The shared BLE manager for monitoring connection state and Bluetooth readiness.
    @Environment(BLEManager.self) private var bleManager

    /// The SwiftData model context, passed to view models for persistent storage.
    @Environment(\.modelContext) private var modelContext

    // MARK: - State

    /// The index of the currently selected tab.
    ///
    /// **SwiftUI concept — @State + TabView(selection:):**
    /// Binding `selectedTab` to the TabView's `selection` parameter creates a
    /// two-way connection. Tapping a tab bar item updates `selectedTab`, and
    /// programmatically setting `selectedTab` (e.g., from DashboardView) switches
    /// the visible tab. The tab indices are: 0=Dashboard, 1=Data, 2=Devices, 3=Developer.
    @State private var selectedTab = 0

    /// A flag that ensures the first-launch device check runs only once.
    ///
    /// Without this guard, the check would run every time ContentView re-appears
    /// (e.g., when returning from a background state), potentially overriding
    /// the user's current tab selection.
    @State private var hasCheckedInitialDevices = false

    // MARK: - Body

    /// The root TabView containing all four app tabs.
    ///
    /// **SwiftUI concept — TabView:**
    /// `TabView` is a container that presents its children as selectable tabs
    /// with a tab bar at the bottom of the screen. Each child view is given a
    /// `.tag()` integer and a `.tabItem` that defines its icon and label.
    ///
    /// **SwiftUI concept — NavigationStack:**
    /// Each tab wraps its content in a `NavigationStack`, which provides a
    /// navigation bar and the ability to push/pop views (drill-down navigation).
    /// Each NavigationStack is independent — navigating in one tab does not
    /// affect the others.
    var body: some View {
        TabView(selection: $selectedTab) {
            // Tab 0: Dashboard — the main AQ overview screen.
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

            // Tab 1: Data — historical charts and CSV export.
            NavigationStack {
                HistoryView()
            }
            .tabItem {
                Label("Data", systemImage: "chart.xyaxis.line")
            }
            .tag(1)

            // Tab 2: Devices — list of known devices and pairing.
            NavigationStack {
                DeviceListView(selectedTab: $selectedTab)
            }
            .tabItem {
                Label("Devices", systemImage: "rectangle.stack")
            }
            .tag(2)

            // Tab 3: Advanced — power-user tools for device diagnostics.
            NavigationStack {
                AdvancedView()
            }
            .tabItem {
                Label("Advanced", systemImage: "gearshape.2")
            }
            .tag(3)
        }
        .onAppear {
            // Configure the DeviceViewModel with the SwiftData model context
            // so it can read and write DeviceProfile records.
            deviceVM.configureStorage(modelContext: modelContext)

            // On first launch with no paired devices, navigate to the Devices tab
            // so the user is prompted to scan and pair a device.
            if !hasCheckedInitialDevices {
                hasCheckedInitialDevices = true
                if deviceVM.knownDevices.isEmpty {
                    selectedTab = 2
                }
            }

            // Auto-connect to the last known device when Bluetooth powers on.
            // The 1-second delay gives the BLE radio time to stabilize after
            // powering on, improving connection reliability.
            bleManager.whenBluetoothReady {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    deviceVM.autoConnectToLastDevice()
                }
            }
        }
    }

    // MARK: - Connected Device Info (nav bar)

    /// Displays the connected device's pet name and device name in the Dashboard's navigation bar.
    ///
    /// When a device is connected, this shows:
    /// - The pet name in blue semibold text.
    /// - The device name as a small gray badge (capsule-shaped).
    ///
    /// When disconnected, this renders nothing (empty `@ViewBuilder`).
    ///
    /// **SwiftUI concept — @ViewBuilder:**
    /// The `@ViewBuilder` attribute allows this computed property to conditionally
    /// return different view types (HStack with content vs. nothing). Without it,
    /// Swift would require a single return type.
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
