import SwiftUI
import Charts

struct SensorCardView: View {

    let item: SensorItem

    @Environment(SensorViewModel.self) private var sensorVM

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @ScaledMetric(relativeTo: .caption) private var sparklineHeight = 24

    var body: some View {
        VStack(alignment: .leading, spacing: dynamicTypeSize.usesAccessibilityLayout ? 12 : 8) {
            headerRow
            valueRow
            statusRow

            if !dynamicTypeSize.usesAccessibilityLayout || sparklineData.count >= 2 {
                HStack(alignment: .bottom, spacing: 8) {
                    sparkline
                        .frame(height: dynamicTypeSize.usesAccessibilityLayout ? sparklineHeight * 1.4 : sparklineHeight)

                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.quaternary)
                        .accessibilityHidden(true)
                }
            }
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var headerRow: some View {
        Group {
            if dynamicTypeSize.usesAccessibilityLayout {
                VStack(alignment: .leading, spacing: 8) {
                    sensorLabel
                    gradeBadge
                }
            } else {
                HStack {
                    sensorLabel
                    Spacer()
                    gradeBadge
                }
            }
        }
    }

    private var sensorLabel: some View {
        Text(item.label)
            .font(.caption)
            .fontWeight(.medium)
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }

    @ViewBuilder
    private var gradeBadge: some View {
        if let score = item.score {
            let grade = AQIScoring.sensorBadnessToGrade(score)
            let status = AQIScoring.sensorStatus(score)
            Text(grade)
                .font(.caption)
                .fontWeight(.bold)
                .foregroundStyle(status.color)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(status.color.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private var valueRow: some View {
        AdaptiveStack(
            vertical: dynamicTypeSize.usesAccessibilityLayout,
            verticalAlignment: .leading,
            horizontalAlignment: .firstTextBaseline,
            spacing: 4
        ) {
            Text(item.value)
                .font(.title2)
                .fontWeight(.bold)
                .monospacedDigit()

            if !item.unit.isEmpty {
                Text(item.unit)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        if let score = item.score {
            let status = AQIScoring.sensorStatus(score)
            HStack(spacing: 6) {
                Circle()
                    .fill(status.color)
                    .frame(width: 6, height: 6)
                Text(status.label)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(status.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var sparkline: some View {
        let points = sparklineData
        if points.count >= 2 {
            Chart(points, id: \.timestamp) { point in
                LineMark(
                    x: .value("Time", point.timestamp),
                    y: .value("Value", point.value)
                )
                .foregroundStyle(sparklineColor)
                .interpolationMethod(.catmullRom)
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartLegend(.hidden)
            .chartYScale(domain: .automatic(includesZero: false))
        } else {
            Color.clear
        }
    }

    private var sparklineData: [(timestamp: Date, value: Double)] {
        sensorVM.history.compactMap { reading in
            let value: Double? = switch item.key {
            case "co2": reading.values.co2
            case "pm2_5": reading.values.pm2_5
            case "pm10": reading.values.pm10
            case "temperature": reading.values.temperature
            case "humidity": reading.values.humidity
            case "voc": reading.values.voc
            case "nox": reading.values.nox
            case "pressure": reading.values.pressure
            default: nil
            }
            if let v = value {
                return (timestamp: reading.timestamp, value: v)
            }
            return nil
        }
    }

    private var sparklineColor: Color {
        if let score = item.score {
            return AQIScoring.sensorStatus(score).color
        }
        return .blue
    }
}
