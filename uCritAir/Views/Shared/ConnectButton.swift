import SwiftUI

struct ConnectButton: View {

    @Environment(BLEManager.self) private var bleManager

    @Environment(DeviceViewModel.self) private var deviceVM

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

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
            if dynamicTypeSize.usesAccessibilityLayout {
                buttonLabel
                    .background(connectionColor.opacity(0.15))
                    .foregroundStyle(connectionColor)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                buttonLabel
                    .background(connectionColor.opacity(0.15))
                    .foregroundStyle(connectionColor)
                    .clipShape(Capsule())
            }
        }
        .accessibilityLabel("Bluetooth: \(connectionLabel)")
        .accessibilityIdentifier("connectButton")
        .disabled(bleManager.connectionState == .connecting || bleManager.connectionState == .reconnecting)
        .sheet(isPresented: $showingDeviceList, onDismiss: {
            if bleManager.connectionState == .scanning {
                bleManager.disconnect()
            }
        }) {
            DeviceListSheet()
        }
    }

    @ViewBuilder
    private var buttonLabel: some View {
        if dynamicTypeSize.usesAccessibilityLayout {
            connectionIcon
                .frame(width: 22, height: 22)
                .padding(10)
                .minimumAccessibleTapTarget()
        } else {
            HStack(spacing: 4) {
                connectionIcon
                Text(connectionLabel)
                    .font(.caption)
                    .fontWeight(.semibold)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .minimumAccessibleTapTarget()
        }
    }

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

    private var connectionLabel: String {
        switch bleManager.connectionState {
        case .disconnected: return "Connect"
        case .scanning: return "Scanning..."
        case .connecting: return "Connecting..."
        case .reconnecting: return "Reconnecting..."
        case .connected: return "Connected"
        }
    }

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
                            .fixedSize(horizontal: false, vertical: true)
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
                                        .fixedSize(horizontal: false, vertical: true)
                                    Text(peripheral.identifier.uuidString.prefix(8) + "...")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
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
        .accessibilityIdentifier("scanSheet")
        .presentationDetents([.medium, .large])
    }
}
