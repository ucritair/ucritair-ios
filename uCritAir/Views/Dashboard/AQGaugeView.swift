// ────────────────────────────────────────────────────────────────────────────
// AQGaugeView.swift
// uCritAir
// ────────────────────────────────────────────────────────────────────────────
//
// PURPOSE:
//   Renders a large circular "speedometer-style" gauge that communicates
//   the overall indoor air quality at a glance. It is the hero element at
//   the top of the Dashboard tab.
//
//   The gauge is a 270-degree arc (gap at the bottom, like a car speedometer).
//   The arc fills proportionally to the "goodness" percentage (0–100 %).
//   Inside the arc, a large letter grade (A+ through F) and the percentage
//   are displayed. Below the gauge, a textual label (e.g., "Excellent",
//   "Poor") is shown.
//
//   When no sensor data is available yet, the gauge shows "--" and
//   "Waiting for data..." instead.
//
// SWIFTUI CONCEPTS USED:
//   - @Environment: Reads the shared SensorViewModel from the environment.
//   - ZStack: Layers views on top of each other (background arc, fill arc,
//     center text) to create the gauge visual.
//   - Path: A custom drawing primitive used to create the arc shape.
//   - .trim(from:to:): Clips a shape to show only a portion of it,
//     used here to animate the arc fill proportionally to the score.
//   - .accessibilityElement / .accessibilityLabel: Combines child views
//     into a single VoiceOver element with a descriptive label.
//
// ────────────────────────────────────────────────────────────────────────────

import SwiftUI

/// A circular air quality gauge that displays the composite AQ score as a
/// letter grade (A+ through F) inside a colored arc.
///
/// The gauge reads from `SensorViewModel.current` to compute an aggregate
/// air quality score using `AQIScoring.computeAQScore()`. The result includes:
/// - `goodness`: An integer 0–100 representing overall air quality.
/// - `grade`: A letter grade string (e.g., "A+", "B", "D").
/// - `color`: A SwiftUI `Color` ranging from green (excellent) to red (hazardous).
/// - `label`: A human-readable description (e.g., "Excellent", "Very Poor").
///
/// ## Visual Design
/// The arc sweeps 270 degrees, starting at the 7-o'clock position and ending
/// at the 5-o'clock position, leaving a gap at the bottom. A gray background
/// track shows the full arc, and a colored foreground arc fills proportionally
/// to the goodness score.
///
/// ## Accessibility
/// The entire gauge is collapsed into a single VoiceOver element with a
/// descriptive label like "Air quality: Good, grade B, 72 percent".
struct AQGaugeView: View {

    // MARK: - Environment

    /// The shared sensor view model providing the latest readings from all sensors.
    ///
    /// **SwiftUI concept — @Environment:**
    /// This property is automatically populated by SwiftUI from the nearest
    /// ancestor that called `.environment(sensorVM)`. When `sensorVM.current`
    /// changes (e.g., new BLE data arrives), this view re-renders automatically.
    @Environment(SensorViewModel.self) private var sensorVM

    // MARK: - Layout Constants

    /// Diameter of the circular gauge view in points.
    private let gaugeSize: CGFloat = 180

    /// Stroke width of the arc track and fill in points.
    private let lineWidth: CGFloat = 12

    /// Start angle of the arc (7 o'clock position), creating a gap at the bottom.
    /// In SwiftUI, 0 degrees points to the right (3 o'clock). 135 degrees
    /// rotates to the lower-left, which is the 7 o'clock position.
    private let startAngle = Angle.degrees(135)

    /// End angle of the arc (5 o'clock position), completing the 270-degree sweep.
    /// 405 degrees = 360 + 45, which wraps around to the lower-right (5 o'clock).
    private let endAngle = Angle.degrees(405)

    // MARK: - Body

    /// The main view body — renders the gauge arc, center text, and status label.
    ///
    /// The body computes the AQ score result once at the top, then uses it
    /// throughout the view tree. `hasData` is `true` when at least one sensor
    /// has reported a value; until then, the gauge shows a placeholder.
    var body: some View {
        // Compute the aggregate AQ score from all current sensor readings.
        let result = AQIScoring.computeAQScore(sensorVM.current)
        // Check whether any sensor has reported data yet.
        let hasData = sensorVM.current.hasAnyValue

        VStack(spacing: 8) {
            // ZStack layers three elements on top of each other to form the gauge.
            ZStack {
                // Layer 1: Background arc (gray track showing the full 270-degree sweep).
                arcPath
                    .stroke(Color.gray.opacity(0.2), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))

                // Layer 2: Foreground arc (colored fill proportional to the goodness score).
                // .trim(from:to:) clips the arc shape. A goodness of 75 means
                // trim(from: 0, to: 0.75), showing 75% of the arc filled.
                if hasData {
                    arcPath
                        .trim(from: 0, to: CGFloat(result.goodness) / 100.0)
                        .stroke(result.color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                }

                // Layer 3: Center content — the letter grade and percentage number.
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

            // Status label below the gauge (e.g., "Excellent", "Poor", or "Waiting for data...").
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
        // Collapse all children into a single VoiceOver element so screen
        // readers announce the gauge as one coherent description.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(hasData
            ? "Air quality: \(result.label), grade \(result.grade), \(result.goodness) percent"
            : "Air quality: waiting for data")
    }

    // MARK: - Arc Path

    /// A `Path` that traces the 270-degree arc centered in the gauge frame.
    ///
    /// **SwiftUI concept — Path:**
    /// `Path` is SwiftUI's equivalent of Core Graphics paths. You build a path
    /// by calling methods like `addArc`, `addLine`, etc. The resulting shape
    /// can then be stroked or filled. Here we stroke it with a rounded line cap
    /// to create the gauge track.
    private var arcPath: Path {
        Path { path in
            path.addArc(
                center: CGPoint(x: gaugeSize / 2, y: gaugeSize / 2),
                radius: (gaugeSize - lineWidth) / 2,
                startAngle: startAngle,
                endAngle: endAngle,
                clockwise: false  // Counter-clockwise = the "normal" direction for arcs.
            )
        }
    }
}
