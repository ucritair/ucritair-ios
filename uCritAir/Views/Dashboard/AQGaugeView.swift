import SwiftUI

struct AQGaugeView: View {

    @Environment(SensorViewModel.self) private var sensorVM

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @ScaledMetric(relativeTo: .title2) private var gaugeSize: CGFloat = 180

    @ScaledMetric(relativeTo: .title3) private var lineWidth: CGFloat = 12

    @ScaledMetric(relativeTo: .largeTitle) private var gradeFontSize: CGFloat = 48

    @ScaledMetric(relativeTo: .title3) private var placeholderFontSize: CGFloat = 16

    private let startAngle = Angle.degrees(135)

    private let endAngle = Angle.degrees(405)

    var body: some View {
        let result = AQIScoring.computeAQScore(sensorVM.current)
        let hasData = sensorVM.current.hasAnyValue
        let effectiveGaugeSize = dynamicTypeSize.usesAccessibilityLayout ? gaugeSize * 0.82 : gaugeSize

        VStack(spacing: dynamicTypeSize.usesAccessibilityLayout ? 14 : 8) {
            ZStack {
                arcPath(size: effectiveGaugeSize)
                    .stroke(Color.gray.opacity(0.2), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))

                if hasData {
                    arcPath(size: effectiveGaugeSize)
                        .trim(from: 0, to: CGFloat(result.goodness) / 100.0)
                        .stroke(result.color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                }

                VStack(spacing: dynamicTypeSize.usesAccessibilityLayout ? 4 : 2) {
                    Text(hasData ? result.grade : "--")
                        .font(.system(size: hasData ? gradeFontSize : placeholderFontSize, weight: .bold, design: .rounded))
                        .foregroundStyle(hasData ? result.color : .secondary)

                    if hasData && !dynamicTypeSize.usesAccessibilityLayout {
                        Text("\(result.goodness)%")
                            .font(.title3)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: effectiveGaugeSize, height: effectiveGaugeSize)

            if hasData {
                VStack(spacing: 4) {
                    if dynamicTypeSize.usesAccessibilityLayout {
                        Text("\(result.goodness)%")
                            .font(.title3)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                    }

                    Text(result.label)
                        .font(.headline)
                        .foregroundStyle(result.color)
                        .multilineTextAlignment(.center)
                }
            } else {
                Text("Waiting for data...")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(hasData
            ? "Air quality: \(result.label), grade \(result.grade), \(result.goodness) percent"
            : "Air quality: waiting for data")
    }

    private func arcPath(size: CGFloat) -> Path {
        Path { path in
            path.addArc(
                center: CGPoint(x: size / 2, y: size / 2),
                radius: (size - lineWidth) / 2,
                startAngle: startAngle,
                endAngle: endAngle,
                clockwise: false
            )
        }
    }
}
