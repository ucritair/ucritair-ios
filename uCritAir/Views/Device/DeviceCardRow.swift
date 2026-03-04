// ────────────────────────────────────────────────────────────────────────────
// DeviceCardRow.swift
// uCritAir
// ────────────────────────────────────────────────────────────────────────────
//
// PURPOSE:
//   Renders a single device card in the DeviceListView. Each card displays
//   a device's identity and status in a horizontal layout:
//
//     ┌──────────────────────────────────────────────┐
//     │  (AQ Ring)  Pet Name  [device-badge]         │
//     │             Room Label                ⚙  ⊞  │
//     │             ● Connected               or  >  │
//     └──────────────────────────────────────────────┘
//
//   - **Connected devices** show a colored AQ score ring with a letter grade,
//     a green "Connected" status, and gear + dashboard action icons.
//   - **Disconnected devices** show a gray "--" ring, a relative time label
//     (e.g., "2h ago"), and a chevron indicating the row is tappable.
//
//   This view is a pure display component — it does not own any state or
//   perform any actions directly. Callbacks (`onSettingsTap`, `onDashboardTap`)
//   are provided by the parent `DeviceListView`.
//
// SWIFTUI CONCEPTS USED:
//   - Initializer parameters (not @Binding): Since this view only displays
//     data and calls closures, it takes plain `let` properties rather than
//     bindings. The parent owns the state and passes data down.
//   - Optional closures: `onSettingsTap` and `onDashboardTap` are optional
//     closures — they are only provided for connected device cards.
//   - ZStack + Circle: The AQ score ring is built by layering a gray
//     background circle, a colored arc (trim), and centered text.
//   - .accessibilityElement(children:): Controls how VoiceOver treats
//     child views — `.contain` preserves children as separate elements
//     (connected mode with buttons), `.combine` merges them into one
//     (disconnected mode as a single tappable row).
//
// ────────────────────────────────────────────────────────────────────────────

import SwiftUI

/// A single device card row displayed in the device list.
///
/// This view renders a device profile as a horizontal card showing the AQ score
/// ring, pet name, device name badge, room label, connection status, and
/// action icons. It has two visual modes:
///
/// - **Connected**: Shows the live AQ score ring, green status dot, and
///   gear (settings) + grid (dashboard) action buttons.
/// - **Disconnected**: Shows a gray placeholder ring, relative time since
///   last connection, cached cell count, and a navigation chevron.
///
/// ## Parameters
/// - `profile`: The `DeviceProfile` data model with the device's stored information.
/// - `isConnected`: Whether this device is currently connected via BLE.
/// - `aqResult`: The computed AQ score (only available for connected devices with data).
/// - `onSettingsTap`: Optional callback invoked when the gear icon is tapped.
/// - `onDashboardTap`: Optional callback invoked when the dashboard icon is tapped.
struct DeviceCardRow: View {

    /// The device profile containing stored information (pet name, device name, etc.).
    let profile: DeviceProfile

    /// Whether this device is the currently active BLE connection.
    let isConnected: Bool

    /// The computed air quality score result, or `nil` if disconnected or no data available.
    let aqResult: AQScoreResult?

    /// Callback invoked when the gear (settings) icon is tapped. Only used for connected devices.
    var onSettingsTap: (() -> Void)?

    /// Callback invoked when the dashboard icon is tapped. Only used for connected devices.
    var onDashboardTap: (() -> Void)?

    /// Diameter of the inline AQ score circle in points.
    private let gaugeSize: CGFloat = 52

    /// Stroke width of the inline AQ score ring in points.
    private let lineWidth: CGFloat = 5

    // MARK: - Body

    /// The card's main layout — a horizontal stack with the score circle, device info, and actions.
    var body: some View {
        HStack(spacing: 14) {
            // AQ score circle
            scoreCircle

            // Device info
            VStack(alignment: .leading, spacing: 4) {
                // Pet name (headline)
                HStack(spacing: 6) {
                    Text(profile.petName.isEmpty ? "Unnamed" : profile.petName)
                        .font(.headline)
                        .lineLimit(1)

                    // Device name badge
                    if !profile.deviceName.isEmpty {
                        Text(profile.deviceName)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color(.systemGray5))
                            .clipShape(Capsule())
                    }
                }

                // Room label
                if let room = profile.roomLabel, !room.isEmpty {
                    Text(room)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                // Connection status
                HStack(spacing: 4) {
                    Circle()
                        .fill(isConnected ? .green : .gray.opacity(0.4))
                        .frame(width: 6, height: 6)

                    if isConnected {
                        Text("Connected")
                            .font(.caption)
                            .foregroundStyle(.green)
                    } else {
                        Text(lastConnectedLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if !isConnected && profile.lastKnownCellCount > 0 {
                        Text("·")
                            .foregroundStyle(.secondary)
                        Text("\(profile.lastKnownCellCount) cells")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            if isConnected {
                HStack(spacing: 16) {
                    Button {
                        onSettingsTap?()
                    } label: {
                        Image(systemName: "gearshape")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Device settings")

                    Button {
                        onDashboardTap?()
                    } label: {
                        Image(systemName: "square.grid.2x2")
                            .font(.title3)
                            .foregroundStyle(.blue)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Go to dashboard")
                }
            } else {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: isConnected ? .contain : .combine)
        .accessibilityLabel(deviceAccessibilityLabel)
    }

    /// Builds a concise VoiceOver description: pet name, connection status, and AQ grade if available.
    private var deviceAccessibilityLabel: String {
        let name = profile.petName.isEmpty ? "Unnamed device" : profile.petName
        let status = isConnected ? "Connected" : lastConnectedLabel
        if let result = aqResult {
            return "\(name), \(status), air quality grade \(result.grade)"
        }
        return "\(name), \(status)"
    }

    // MARK: - Score Circle

    /// A small circular gauge showing the AQ letter grade.
    ///
    /// For connected devices with data, shows a colored arc (proportional to
    /// the goodness score) and the letter grade in the center. For disconnected
    /// devices, shows a gray ring with "--".
    ///
    /// This is a miniature version of the `AQGaugeView` used on the Dashboard,
    /// simplified to a full circle (360 degrees) rotated to start at the top (-90 degrees).
    private var scoreCircle: some View {
        ZStack {
            // Background ring
            Circle()
                .stroke(Color.gray.opacity(0.15), lineWidth: lineWidth)

            if isConnected, let result = aqResult {
                // Filled ring based on goodness
                Circle()
                    .trim(from: 0, to: CGFloat(result.goodness) / 100.0)
                    .stroke(result.color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))

                // Grade letter
                Text(result.grade)
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(result.color)
            } else {
                // Disconnected placeholder
                Text("--")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: gaugeSize, height: gaugeSize)
    }

    // MARK: - Relative Time

    /// Computes a human-readable relative time string for when the device was last connected.
    ///
    /// Examples: "Just now", "5m ago", "2h ago", "Yesterday", "3d ago".
    /// This provides a quick sense of how recently the device was used,
    /// without showing a full date/time.
    private var lastConnectedLabel: String {
        let interval = Date.now.timeIntervalSince(profile.lastConnectedAt)

        if interval < 60 { return "Just now" }
        if interval < 3600 {
            let mins = Int(interval / 60)
            return "\(mins)m ago"
        }
        if interval < 86400 {
            let hours = Int(interval / 3600)
            return "\(hours)h ago"
        }
        let days = Int(interval / 86400)
        if days == 1 { return "Yesterday" }
        return "\(days)d ago"
    }
}
