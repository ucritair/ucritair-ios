import SwiftUI

/// BLE connection control button — shown in the navigation toolbar.
/// Ported from src/components/ConnectButton.tsx
struct ConnectButton: View {
    @Environment(BLEManager.self) private var bleManager
    @Environment(DeviceViewModel.self) private var deviceVM
    @State private var showingDeviceList = false

    var body: some View {
        Button {
            switch bleManager.connectionState {
            case .disconnected:
                showingDeviceList = true
                bleManager.scan()
            case .connected:
                deviceVM.disconnect()
            default:
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
            .background(connectionColor.opacity(0.15))
            .foregroundStyle(connectionColor)
            .clipShape(Capsule())
        }
        .accessibilityLabel("Bluetooth: \(connectionLabel)")
        .disabled(bleManager.connectionState == .connecting || bleManager.connectionState == .reconnecting)
        .sheet(isPresented: $showingDeviceList) {
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

/// Sheet showing discovered BLE peripherals for selection.
struct DeviceListSheet: View {
    @Environment(BLEManager.self) private var bleManager
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
                                VStack(alignment: .leading) {
                                    Text(peripheral.name ?? "Unknown Device")
                                        .fontWeight(.medium)
                                    Text(peripheral.identifier.uuidString.prefix(8) + "...")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(.secondary)
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
