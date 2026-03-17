import SwiftUI

struct DeviceCardRow: View {

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let profile: DeviceProfile

    let isConnected: Bool

    let aqResult: AQScoreResult?

    var onSettingsTap: (() -> Void)?

    var onDashboardTap: (() -> Void)?

    @ScaledMetric(relativeTo: .title3) private var gaugeSize: CGFloat = 52

    @ScaledMetric(relativeTo: .caption) private var lineWidth: CGFloat = 5

    @ScaledMetric(relativeTo: .title3) private var gaugeFontSize: CGFloat = 18

    @ScaledMetric(relativeTo: .body) private var placeholderGaugeFontSize: CGFloat = 16

    var body: some View {
        Group {
            if dynamicTypeSize.usesAccessibilityLayout {
                accessibilityLayout
            } else {
                regularLayout
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: isConnected ? .contain : .combine)
        .accessibilityLabel(deviceAccessibilityLabel)
    }

    private var regularLayout: some View {
        HStack(spacing: 14) {
            scoreCircle

            deviceIdentity

            Spacer()

            trailingAccessory
        }
    }

    private var accessibilityLayout: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                scoreCircle
                deviceIdentity
            }

            statusDetails

            if isConnected {
                ViewThatFits {
                    HStack(spacing: 12) {
                        settingsButton(labelStyle: .titleAndIcon)
                        dashboardButton(labelStyle: .titleAndIcon)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        settingsButton(labelStyle: .titleAndIcon)
                        dashboardButton(labelStyle: .titleAndIcon)
                    }
                }
            } else {
                Label("Tap to reconnect", systemImage: "arrow.clockwise")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var deviceIdentity: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(profile.petName.isEmpty ? "Unnamed" : profile.petName)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)

            if !profile.deviceName.isEmpty {
                Text(profile.deviceName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color(.systemGray5))
                    .clipShape(Capsule())
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let room = profile.roomLabel, !room.isEmpty {
                Text(room)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !dynamicTypeSize.usesAccessibilityLayout {
                statusDetails
            }
        }
    }

    private var statusDetails: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(isConnected ? .green : .gray.opacity(0.4))
                    .frame(width: 8, height: 8)

                if isConnected {
                    Text("Connected")
                        .font(.caption)
                        .foregroundStyle(.green)
                } else {
                    Text(lastConnectedLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if !isConnected && profile.lastKnownCellCount > 0 {
                Text("\(profile.lastKnownCellCount) cached cells")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var trailingAccessory: some View {
        if isConnected {
            HStack(spacing: 16) {
                settingsButton(labelStyle: .iconOnly)
                dashboardButton(labelStyle: .iconOnly)
            }
        } else {
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
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
                    .font(.system(size: gaugeFontSize, weight: .bold, design: .rounded))
                    .foregroundStyle(result.color)
            } else {
                Text("--")
                    .font(.system(size: placeholderGaugeFontSize, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: gaugeSize, height: gaugeSize)
    }

    @ViewBuilder
    private func settingsButton(labelStyle: DeviceRowActionLabelStyle) -> some View {
        if dynamicTypeSize.usesAccessibilityLayout {
            Button {
                onSettingsTap?()
            } label: {
                labelStyle.makeLabel(title: "Settings", systemImage: "gearshape", color: .secondary)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Device settings")
            .minimumAccessibleTapTarget()
        } else {
            Button {
                onSettingsTap?()
            } label: {
                labelStyle.makeLabel(title: "Settings", systemImage: "gearshape", color: .secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Device settings")
            .minimumAccessibleTapTarget()
        }
    }

    @ViewBuilder
    private func dashboardButton(labelStyle: DeviceRowActionLabelStyle) -> some View {
        if dynamicTypeSize.usesAccessibilityLayout {
            Button {
                onDashboardTap?()
            } label: {
                labelStyle.makeLabel(title: "Dashboard", systemImage: "square.grid.2x2", color: .blue)
            }
            .buttonStyle(.borderedProminent)
            .tint(.blue)
            .accessibilityLabel("Go to dashboard")
            .minimumAccessibleTapTarget()
        } else {
            Button {
                onDashboardTap?()
            } label: {
                labelStyle.makeLabel(title: "Dashboard", systemImage: "square.grid.2x2", color: .blue)
            }
            .buttonStyle(.plain)
            .tint(.blue)
            .accessibilityLabel("Go to dashboard")
            .minimumAccessibleTapTarget()
        }
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

private enum DeviceRowActionLabelStyle {
    case iconOnly
    case titleAndIcon

    @ViewBuilder
    func makeLabel(title: String, systemImage: String, color: Color) -> some View {
        switch self {
        case .iconOnly:
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(color)
        case .titleAndIcon:
            Label(title, systemImage: systemImage)
                .foregroundStyle(color)
        }
    }
}
