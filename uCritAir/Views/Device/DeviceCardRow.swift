import SwiftUI

/// A single device card in the device list — Awair-style layout.
/// Shows AQ score ring (if connected), pet name, device name, room label,
/// and connection status.
struct DeviceCardRow: View {
    let profile: DeviceProfile
    let isConnected: Bool
    let aqResult: AQScoreResult?

    /// Diameter of the inline AQ score circle in points.
    private let gaugeSize: CGFloat = 52

    /// Stroke width of the inline AQ score ring in points.
    private let lineWidth: CGFloat = 5

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

                    // Device name badge
                    if !profile.deviceName.isEmpty {
                        Text(profile.deviceName)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
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

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
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
