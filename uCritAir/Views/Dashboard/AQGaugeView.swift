import SwiftUI

/// Circular air quality gauge with letter grade.
/// Ported from src/components/AQScore.tsx
struct AQGaugeView: View {
    @Environment(SensorViewModel.self) private var sensorVM

    /// Diameter of the circular gauge view in points.
    private let gaugeSize: CGFloat = 180

    /// Stroke width of the arc track and fill in points.
    private let lineWidth: CGFloat = 12

    /// Start angle of the arc (7 o'clock position), creating a gap at the bottom.
    private let startAngle = Angle.degrees(135)

    /// End angle of the arc (5 o'clock position), completing the 270-degree sweep.
    private let endAngle = Angle.degrees(405)

    var body: some View {
        let result = AQIScoring.computeAQScore(sensorVM.current)
        let hasData = sensorVM.current.hasAnyValue

        VStack(spacing: 8) {
            ZStack {
                // Background arc (track)
                arcPath
                    .stroke(Color.gray.opacity(0.2), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))

                // Foreground arc (filled by goodness)
                if hasData {
                    arcPath
                        .trim(from: 0, to: CGFloat(result.goodness) / 100.0)
                        .stroke(result.color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                }

                // Center content
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

    /// Arc path centered in the gauge frame.
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
