import SwiftUI

struct AQGaugeView: View {

    @Environment(SensorViewModel.self) private var sensorVM

    private let gaugeSize: CGFloat = 180

    private let lineWidth: CGFloat = 12

    private let startAngle = Angle.degrees(135)

    private let endAngle = Angle.degrees(405)

    var body: some View {
        let result = AQIScoring.computeAQScore(sensorVM.current)
        let hasData = sensorVM.current.hasAnyValue

        VStack(spacing: 8) {
            ZStack {
                arcPath
                    .stroke(Color.gray.opacity(0.2), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))

                if hasData {
                    arcPath
                        .trim(from: 0, to: CGFloat(result.goodness) / 100.0)
                        .stroke(result.color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                }

                VStack(spacing: 2) {
                    Text(hasData ? result.grade : "--")
                        .font(.system(size: 48, weight: .bold, design: .rounded))
                        .foregroundStyle(hasData ? result.color : .secondary)

                    Text(hasData ? "\(result.goodness)%" : "")
                        .font(.title3)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: gaugeSize, height: gaugeSize)

            if hasData {
                Text(result.label)
                    .font(.headline)
                    .foregroundStyle(result.color)
            } else {
                Text("Waiting for data...")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(hasData
            ? "Air quality: \(result.label), grade \(result.grade), \(result.goodness) percent"
            : "Air quality: waiting for data")
    }

    private var arcPath: Path {
        Path { path in
            path.addArc(
                center: CGPoint(x: gaugeSize / 2, y: gaugeSize / 2),
                radius: (gaugeSize - lineWidth) / 2,
                startAngle: startAngle,
                endAngle: endAngle,
                clockwise: false
            )
        }
    }
}
