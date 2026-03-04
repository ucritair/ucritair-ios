import SwiftUI

struct DeviceCardRow: View {

    let profile: DeviceProfile

    let isConnected: Bool

    let aqResult: AQScoreResult?

    var onSettingsTap: (() -> Void)?

    var onDashboardTap: (() -> Void)?

    private let gaugeSize: CGFloat = 52

    private let lineWidth: CGFloat = 5

    var body: some View {
        HStack(spacing: 14) {
            scoreCircle

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(profile.petName.isEmpty ? "Unnamed" : profile.petName)
                        .font(.headline)
                        .lineLimit(1)

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

                if let room = profile.roomLabel, !room.isEmpty {
                    Text(room)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

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

    private var deviceAccessibilityLabel: String {
        let name = profile.petName.isEmpty ? "Unnamed device" : profile.petName
        let status = isConnected ? "Connected" : lastConnectedLabel
        if let result = aqResult {
            return "\(name), \(status), air quality grade \(result.grade)"
        }
        return "\(name), \(status)"
    }

    private var scoreCircle: some View {
        ZStack {
            Circle()
                .stroke(Color.gray.opacity(0.15), lineWidth: lineWidth)

            if isConnected, let result = aqResult {
                Circle()
                    .trim(from: 0, to: CGFloat(result.goodness) / 100.0)
                    .stroke(result.color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))

                Text(result.grade)
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(result.color)
            } else {
                Text("--")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: gaugeSize, height: gaugeSize)
    }

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
