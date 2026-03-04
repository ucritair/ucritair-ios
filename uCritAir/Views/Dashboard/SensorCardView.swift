// ────────────────────────────────────────────────────────────────────────────
// SensorCardView.swift
// uCritAir
// ────────────────────────────────────────────────────────────────────────────
//
// PURPOSE:
//   Renders a single sensor card in the Dashboard's grid. Each card displays
//   one sensor's data in a compact, information-rich format:
//
//     ┌────────────────────┐
//     │  CO₂          [A+] │  ← Header: sensor label + letter grade badge
//     │  423 ppm           │  ← Value + unit
//     │  ● Excellent       │  ← Status indicator (colored dot + label)
//     │  ~~~sparkline~~~ > │  ← Mini trend chart + navigation chevron
//     └────────────────────┘
//
//   The card is used inside a `LazyVGrid` on the Dashboard. Tapping a card
//   navigates to the History tab with that sensor pre-selected for charting.
//
// SWIFTUI CONCEPTS USED:
//   - @Environment: Reads the shared SensorViewModel for sparkline history data.
//   - Swift Charts (LineMark): Used for the mini sparkline at the bottom.
//   - @ViewBuilder: Allows the sparkline computed property to conditionally
//     return different view types (a Chart or Color.clear).
//   - VStack / HStack: Vertical and horizontal layout containers.
//
// SWIFT CHARTS CONCEPTS:
//   - Chart: The container view from the Charts framework that renders data.
//   - LineMark: A mark type that draws a line connecting data points.
//   - .interpolationMethod(.catmullRom): Creates smooth curves through points
//     instead of straight line segments.
//   - .chartXAxis(.hidden) / .chartYAxis(.hidden): Hides axis labels and
//     grid lines, appropriate for a compact sparkline.
//
// ────────────────────────────────────────────────────────────────────────────

import SwiftUI
import Charts

/// A compact card view displaying a single sensor's current reading, quality grade,
/// status indicator, and a mini sparkline trend chart.
///
/// Each card shows four pieces of information:
/// 1. **Header** — The sensor label (e.g., "CO₂") and a colored letter grade badge (e.g., "A+").
/// 2. **Value** — The current reading in large bold text with its unit.
/// 3. **Status** — A colored dot and label (e.g., "Excellent", "Poor").
/// 4. **Sparkline** — A tiny line chart showing the sensor's recent trend, plus a
///    chevron indicating that the card is tappable.
///
/// ## Dependencies
/// - `item`: A `SensorItem` struct passed in from the parent `DashboardView`,
///   containing the sensor key, label, formatted value, unit, and badness score.
/// - `SensorViewModel` (via @Environment): Provides the rolling history buffer
///   used to build the sparkline data points.
///
/// ## Usage
/// This view is used inside a `LazyVGrid` in `DashboardView.connectedView`.
/// It is wrapped in a `Button` by the parent, so the entire card is tappable.
struct SensorCardView: View {

    /// The sensor data to display on this card, provided by the parent view.
    /// This is a plain value passed in (not a binding), because the card only
    /// reads the data — it does not modify it.
    let item: SensorItem

    /// The shared sensor view model providing the rolling history buffer for sparklines.
    ///
    /// **SwiftUI concept — @Environment:**
    /// This injects the `SensorViewModel` that was placed in the environment by
    /// `uCritAirApp`. The card uses it to read `sensorVM.history` for sparkline data.
    @Environment(SensorViewModel.self) private var sensorVM

    // MARK: - Body

    /// The card's main layout — a vertical stack of header, value, status, and sparkline.
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header row: sensor label on the left, letter grade badge on the right.
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

            // Value + unit — the main reading displayed in large bold text.
            // .firstTextBaseline alignment ensures the value and unit text
            // sit on the same typographic baseline despite different font sizes.
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(item.value)
                    .font(.title2)
                    .fontWeight(.bold)
                    .monospacedDigit()

                Text(item.unit)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            // Status indicator — a small colored dot and label (e.g., "● Excellent").
            // When the sensor has no scoring curve (e.g., pressure), a hidden
            // placeholder of the same size is rendered to keep all cards the same height.
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

            // Bottom row: sparkline chart on the left, navigation chevron on the right.
            // The chevron hints to the user that tapping the card navigates somewhere.
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

    // MARK: - Sparkline

    /// A mini line chart showing the sensor's recent value trend.
    ///
    /// **Swift Charts concept — LineMark:**
    /// `LineMark` is one of several mark types in the Swift Charts framework.
    /// It draws a line connecting data points. Each point is defined by an
    /// x-value (timestamp) and a y-value (sensor reading).
    ///
    /// **@ViewBuilder:**
    /// The `@ViewBuilder` attribute lets this computed property return different
    /// view types from different branches (`Chart` vs `Color.clear`). Without it,
    /// Swift would require a single return type.
    ///
    /// The sparkline requires at least 2 data points to draw a line. If fewer
    /// points are available, it renders a transparent placeholder (`Color.clear`)
    /// to maintain the card's layout dimensions.
    @ViewBuilder
    private var sparkline: some View {
        let points = sparklineData
        if points.count >= 2 {
            // Swift Charts — the `Chart` view takes a collection and a closure
            // that produces one or more marks per data element.
            Chart(points, id: \.timestamp) { point in
                LineMark(
                    x: .value("Time", point.timestamp),   // X-axis: time
                    y: .value("Value", point.value)        // Y-axis: sensor value
                )
                .foregroundStyle(sparklineColor)
                // .catmullRom creates smooth curves through data points instead
                // of straight line segments, giving the sparkline a polished look.
                .interpolationMethod(.catmullRom)
            }
            // Hide all axes and legends — a sparkline is a minimal chart.
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartLegend(.hidden)
            // Scale the Y-axis to the data range without forcing zero to be
            // included. This maximizes the visual variation in the sparkline.
            .chartYScale(domain: .automatic(includesZero: false))
        } else {
            // Not enough data points for a line — render an invisible placeholder.
            Color.clear
        }
    }

    /// Extracts timestamped values for this card's sensor key from the rolling history buffer.
    ///
    /// The `SensorViewModel` maintains a `history` array of recent readings.
    /// This computed property filters that array to extract only the values
    /// for the sensor represented by this card (identified by `item.key`).
    ///
    /// The `switch` expression maps the string key (e.g., "co2") to the
    /// corresponding property on the `SensorValues` struct. `compactMap`
    /// filters out readings where the value is `nil` (sensor not yet reporting).
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

    /// Stroke color for the sparkline, derived from the sensor's AQI status or a default blue.
    private var sparklineColor: Color {
        if let score = item.score {
            return AQIScoring.sensorStatus(score).color
        }
        return .blue
    }
}
