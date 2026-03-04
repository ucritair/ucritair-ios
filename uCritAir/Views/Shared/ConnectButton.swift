// ────────────────────────────────────────────────────────────────────────────
// ConnectButton.swift
// uCritAir
// ────────────────────────────────────────────────────────────────────────────
//
// PURPOSE:
//   A reusable BLE connection control button that appears in the navigation
//   toolbar across multiple tabs (Dashboard, History, Device Settings, Developer).
//   It serves as the app's primary way to initiate and manage BLE connections.
//
//   The button has different visual states and behaviors:
//   - **Disconnected** (blue): Tapping starts a BLE scan and presents the
//     device selection sheet.
//   - **Scanning** (orange, with spinner): Scan in progress — button disabled.
//   - **Connecting / Reconnecting** (gray, with spinner): Connection in progress — disabled.
//   - **Connected** (green, with checkmark): Tapping disconnects the device.
//
//   The button is styled as a pill-shaped capsule with a colored background,
//   an icon on the left, and a text label on the right.
//
// SWIFTUI CONCEPTS USED:
//   - @Environment: Reads the shared BLEManager and DeviceViewModel.
//   - @State: Controls whether the device scan sheet is presented.
//   - .sheet: Presents the DeviceListSheet as a modal overlay.
//   - .disabled: Prevents interaction during connecting/reconnecting states.
//   - Group: A transparent container used to return different view types
//     (Image vs ProgressView) from the `connectionIcon` computed property.
//   - Capsule(): A shape used with .clipShape to create rounded pill buttons.
//
// ────────────────────────────────────────────────────────────────────────────

import SwiftUI

/// A pill-shaped BLE connection control button used across the app's navigation toolbars.
///
/// This button is the primary interface for managing the BLE connection. It adapts
/// its appearance and behavior to the current connection state:
///
/// | State         | Color  | Icon       | Label          | Tap Action       |
/// |---------------|--------|------------|----------------|------------------|
/// | Disconnected  | Blue   | Antenna    | "Connect"      | Scan + show sheet|
/// | Scanning      | Orange | Spinner    | "Scanning..."  | Disabled         |
/// | Connecting    | Gray   | Spinner    | "Connecting..."| Disabled         |
/// | Reconnecting  | Gray   | Spinner    | "Reconnecting" | Disabled         |
/// | Connected     | Green  | Checkmark  | "Connected"    | Disconnect       |
///
/// ## Dependencies
/// - `BLEManager`: Provides the connection state and scan/connect/disconnect methods.
/// - `DeviceViewModel`: Provides the `disconnect()` method that also cleans up device state.
///
/// ## Usage
/// Place this button in any toolbar:
/// ```swift
/// .toolbar {
///     ToolbarItem(placement: .topBarLeading) {
///         ConnectButton()
///     }
/// }
/// ```
struct ConnectButton: View {

    // MARK: - Environment

    /// The shared BLE manager providing connection state and scan/connect methods.
    @Environment(BLEManager.self) private var bleManager

    /// The shared device view model providing the disconnect method.
    @Environment(DeviceViewModel.self) private var deviceVM

    // MARK: - State

    /// Controls whether the device selection sheet is presented.
    ///
    /// **SwiftUI concept — @State + .sheet:**
    /// When the user taps the button in disconnected state, `showingDeviceList`
    /// is set to `true`, which causes the `.sheet` modifier to present
    /// `DeviceListSheet()`. When the sheet is dismissed, this is automatically
    /// set back to `false`.
    @State private var showingDeviceList = false

    // MARK: - Body

    /// The button view — a pill-shaped capsule that adapts to the BLE connection state.
    ///
    /// The button action uses a `switch` statement to determine what to do
    /// based on the current connection state. In the `default` case (scanning,
    /// connecting, reconnecting), the button does nothing — it is also disabled
    /// via the `.disabled()` modifier for these states.
    var body: some View {
        Button {
            switch bleManager.connectionState {
            case .disconnected:
                // Start scanning and present the device list sheet.
                showingDeviceList = true
                bleManager.scan()
            case .connected:
                // Disconnect from the current device.
                deviceVM.disconnect()
            default:
                // Scanning, connecting, or reconnecting — do nothing (button is disabled).
                break
            }
        } label: {
            HStack(spacing: 4) {
                connectionIcon
                Text(connectionLabel)
                    .font(.caption)
                    .fontWeight(.semibold)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            // Semi-transparent colored background for the pill shape.
            .background(connectionColor.opacity(0.15))
            .foregroundStyle(connectionColor)
            // **SwiftUI concept — .clipShape(Capsule()):**
            // Clips the view to a capsule (stadium) shape — a rectangle with
            // fully rounded ends, creating the "pill button" appearance.
            .clipShape(Capsule())
        }
        .accessibilityLabel("Bluetooth: \(connectionLabel)")
        // Disable the button during connection transitions to prevent double-taps.
        .disabled(bleManager.connectionState == .connecting || bleManager.connectionState == .reconnecting)
        // **SwiftUI concept — .sheet:**
        // Presents a modal view that slides up from the bottom. `onDismiss`
        // runs when the sheet is dismissed, allowing cleanup (stopping the scan).
        .sheet(isPresented: $showingDeviceList, onDismiss: {
            // Stop scanning if user swipe-dismissed the sheet without selecting a device.
            if bleManager.connectionState == .scanning {
                bleManager.disconnect()
            }
        }) {
            DeviceListSheet()
        }
    }

    /// Icon reflecting the current BLE connection state (antenna, spinner, or checkmark).
    private var connectionIcon: some View {
        Group {
            switch bleManager.connectionState {
            case .disconnected:
                Image(systemName: "antenna.radiowaves.left.and.right")
            case .scanning:
                ProgressView()
                    .controlSize(.mini)
            case .connecting, .reconnecting:
                ProgressView()
                    .controlSize(.mini)
            case .connected:
                Image(systemName: "checkmark.circle.fill")
            }
        }
    }

    /// Human-readable label for the current BLE connection state (e.g., "Connect", "Connected").
    private var connectionLabel: String {
        switch bleManager.connectionState {
        case .disconnected: return "Connect"
        case .scanning: return "Scanning..."
        case .connecting: return "Connecting..."
        case .reconnecting: return "Reconnecting..."
        case .connected: return "Connected"
        }
    }

    /// Tint color for the button background and label, varying by connection state.
    private var connectionColor: Color {
        switch bleManager.connectionState {
        case .disconnected: return .blue
        case .scanning: return .orange
        case .connecting, .reconnecting: return .gray
        case .connected: return .green
        }
    }
}

// MARK: - Device List Sheet

/// A modal sheet that displays discovered BLE peripherals for the user to select.
///
/// This sheet is presented by `ConnectButton` when the user taps "Connect".
/// It shows a scrollable list of nearby uCrit devices found during the BLE scan.
///
/// ## Behavior
/// - While scanning with no results, shows a spinner with "Scanning for uCrit devices..."
/// - As devices are discovered, they appear in the list with their name and identifier.
/// - Tapping a device calls `bleManager.connect(to:)` and dismisses the sheet.
/// - Tapping "Cancel" stops the scan and dismisses the sheet.
///
/// ## SwiftUI Concepts
/// - `@Environment(\.dismiss)`: A special environment value that provides a
///   closure to programmatically dismiss the current presentation (sheet, navigation push, etc.).
/// - `NavigationStack`: Wraps the list to provide a navigation bar with the title and Cancel button.
/// - `.presentationDetents([.medium])`: Constrains the sheet to half-screen height.
struct DeviceListSheet: View {

    /// The shared BLE manager providing discovered peripherals and connection methods.
    @Environment(BLEManager.self) private var bleManager

    /// Environment action to programmatically dismiss this sheet.
    ///
    /// **SwiftUI concept — @Environment(\.dismiss):**
    /// This is a special environment value (not a custom object) that provides
    /// a `DismissAction` callable as a function. Calling `dismiss()` closes
    /// the current modal sheet or pops the navigation stack.
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if bleManager.discoveredPeripherals.isEmpty {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Scanning for uCrit devices...")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                } else {
                    ForEach(bleManager.discoveredPeripherals, id: \.identifier) { peripheral in
                        Button {
                            bleManager.connect(to: peripheral)
                            dismiss()
                        } label: {
                            HStack {
                                Image(systemName: "antenna.radiowaves.left.and.right")
                                    .foregroundStyle(.blue)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading) {
                                    Text(peripheral.name ?? "Unknown Device")
                                        .fontWeight(.medium)
                                        .lineLimit(1)
                                    Text(peripheral.identifier.uuidString.prefix(8) + "...")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(.secondary)
                                    .accessibilityHidden(true)
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                }
            }
            .navigationTitle("Select Device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        bleManager.disconnect()
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
