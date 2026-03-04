import SwiftUI
import Charts

struct SensorCardView: View {

    let item: SensorItem

    @Environment(SensorViewModel.self) private var sensorVM

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(item.label)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)

                Spacer()

                if let score = item.score {
                    let grade = AQIScoring.sensorBadnessToGrade(score)
                    let status = AQIScoring.sensorStatus(score)
                    Text(grade)
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundStyle(status.color)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(status.color.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(item.value)
                    .font(.title2)
                    .fontWeight(.bold)
                    .monospacedDigit()

                Text(item.unit)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let score = item.score {
                let status = AQIScoring.sensorStatus(score)
                HStack(spacing: 6) {
                    Circle()
                        .fill(status.color)
                        .frame(width: 6, height: 6)
                    Text(status.label)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(status.color)
                }
            } else {
                HStack(spacing: 6) {
                    Circle()
                        .frame(width: 6, height: 6)
                    Text(" ")
                        .font(.caption2.weight(.medium))
                }
                .hidden()
            }

            HStack(alignment: .bottom) {
                sparkline
                    .frame(height: 24)

                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.quaternary)
                    .padding(.bottom, 2)
                    .accessibilityHidden(true)
            }
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
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
