// ────────────────────────────────────────────────────────────────────────────
// SensorChartView.swift
// uCritAir
// ────────────────────────────────────────────────────────────────────────────
//
// PURPOSE:
//   Renders a full-size interactive line chart for a single sensor's
//   historical data. This is the main chart shown in the History tab.
//
//   Features:
//   - Data-scaled Y-axis with 5% padding (does not force zero).
//   - Adaptive X-axis labels that change format based on the time range
//     (hour:minute for 1h, day names for 7d, month+day for 30d, etc.).
//   - Touch-to-inspect: dragging horizontally on the chart shows a tooltip
//     with the exact value and timestamp of the nearest data point.
//   - Selection overlay: a dashed vertical rule and a highlighted dot mark
//     the inspected point.
//
// SWIFT CHARTS FRAMEWORK CONCEPTS:
//   The Swift Charts framework (imported as `Charts`) is Apple's declarative
//   charting library, available from iOS 16+. Key concepts used here:
//
//   - **Chart**: The container view that holds all mark declarations.
//   - **LineMark**: Draws a connected line through data points. Each point
//     is defined by x and y values using `.value("Label", data)`.
//   - **PointMark**: Draws a dot at a single data point. Used here for the
//     selection indicator (a colored dot with a white center).
//   - **RuleMark**: Draws a line (rule) across the chart. Used here for the
//     vertical dashed line at the selected point.
//   - **AxisMarks / AxisValueLabel / AxisGridLine**: Customize the chart's
//     axes — which tick marks to show and how to format their labels.
//   - **.chartOverlay**: Adds an invisible overlay on top of the chart for
//     handling touch gestures. The `ChartProxy` converts screen coordinates
//     to data coordinates (e.g., x-position to Date).
//   - **.chartYScale(domain:)** / **.chartXScale(domain:)**: Explicitly set
//     the range of values shown on each axis.
//   - **.interpolationMethod(.catmullRom)**: Smooths the line through points
//     using Catmull-Rom spline interpolation.
//   - **.annotation**: Attaches a view (the tooltip) to a specific mark.
//
// SWIFTUI CONCEPTS USED:
//   - @State: Tracks the currently selected (inspected) point.
//   - DragGesture: Detects horizontal drags for the touch-to-inspect feature.
//   - GeometryReader (inside chartOverlay): Reads the chart's frame origin
//     to convert gesture coordinates to chart-relative coordinates.
//
// TIMEZONE NOTE:
//   All date formatters use UTC timezone. This is intentional because the
//   device stores timestamps as "local time as Unix epoch" — the device's
//   local clock value stored as if it were UTC. Displaying in UTC recovers
//   the original local time without double-converting through time zones.
//
// ────────────────────────────────────────────────────────────────────────────

import SwiftUI
import Charts

// MARK: - ChartPoint Extension

/// Convenience extension to convert a `ChartPoint`'s integer timestamp to a `Date`.
///
/// `ChartPoint.timestamp` is stored as seconds-since-epoch (Int). Swift Charts
/// needs a `Date` for its x-axis. This computed property performs the conversion.
extension ChartPoint {
    var date: Date {
        Date(timeIntervalSince1970: TimeInterval(timestamp))
    }
}

/// An interactive single-sensor line chart with data-scaled axes, adaptive
/// x-axis labels, and touch-to-inspect tooltips.
///
/// This view is the main chart component in the History tab. It receives
/// pre-filtered data points from `HistoryViewModel` and renders them as a
/// smooth line chart using the Swift Charts framework.
///
/// ## Parameters (passed in by the parent `HistoryView`)
/// - `points`: The array of `ChartPoint` values to plot.
/// - `color`: The sensor's theme color for the line and selection indicator.
/// - `unit`: The measurement unit string (e.g., "ppm", "°C") for axis labels.
/// - `timeRange`: The currently selected time window, used to format x-axis labels.
/// - `formatValue`: A closure that formats a Double value for display (e.g., "423").
/// - `xDomain`: The explicit x-axis date range from the parent view model.
///
/// ## Interaction
/// Dragging horizontally on the chart triggers the touch-to-inspect feature:
/// a dashed vertical line and tooltip appear showing the exact value and
/// timestamp of the nearest data point. Releasing the finger dismisses it.
struct SensorChartView: View {

    /// The array of data points to plot on the chart.
    let points: [ChartPoint]

    /// The sensor's theme color used for the line stroke and selection indicator.
    let color: Color

    /// The measurement unit string (e.g., "ppm", "µg/m³") shown in axis labels and tooltips.
    let unit: String

    /// The currently active time range, used to determine x-axis label formatting.
    let timeRange: TimeRange

    /// A closure that formats a raw Double value into a display string (e.g., 423.0 -> "423").
    let formatValue: (Double) -> String

    /// The explicit x-axis domain (date range) provided by the parent view model.
    /// If `nil`, the domain is derived from the first and last data points.
    let xDomain: ClosedRange<Date>?

    // MARK: - State

    /// The data point currently being inspected via the touch-to-inspect gesture.
    ///
    /// **SwiftUI concept — @State:**
    /// This is private view state that only this chart view owns. When the user
    /// drags on the chart, `selectedPoint` is set to the nearest data point;
    /// when they release, it is set back to `nil`. SwiftUI re-renders the
    /// selection overlay and tooltip whenever this value changes.
    @State private var selectedPoint: ChartPoint?

    // MARK: - Date Formatters

    // Shared date formatters (created once as static properties to avoid
    // re-creating them every time the view re-renders — a performance optimization).
    //
    // All formatters use UTC timezone. See the file header comment for why.
    private static let utc: TimeZone = .gmt

    private static let fmtHourMinute: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"   // "3:42 PM"
        f.timeZone = utc
        return f
    }()

    private static let fmtHour24: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:00"    // "06:00", "12:00", "18:00" (Aranet4-style)
        f.timeZone = utc
        return f
    }()

    private static let fmtDayShort: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE"      // "Mon", "Tue" (Aranet4-style)
        f.timeZone = utc
        return f
    }()

    private static let fmtMonthDay: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM dd"   // "Feb 05"
        f.timeZone = utc
        return f
    }()

    private static let fmtAnnotationShort: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm:ss a"  // "3:42:15 PM"
        f.timeZone = utc
        return f
    }()

    private static let fmtAnnotationDay: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE dd, h:mm a"  // "Wed 25, 3:42 PM"
        f.timeZone = utc
        return f
    }()

    private static let fmtAnnotationFull: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM dd, h:mm a"  // "Feb 05, 3:42 PM"
        f.timeZone = utc
        return f
    }()

    // MARK: - Y-axis Domain

    /// Computes the Y-axis range from the data, with 5% padding above and below.
    ///
    /// Unlike many charts that always start at zero, this gauge scales the Y-axis
    /// to the actual data range so that small variations are clearly visible.
    /// For example, if CO2 readings range from 400 to 500, the Y-axis shows
    /// roughly 395 to 505 rather than 0 to 505.
    ///
    /// Edge cases:
    /// - If all values are the same (lo == hi), adds +/- 1 to prevent a zero-height axis.
    /// - If there are no valid values, falls back to 0...1.
    private var yDomain: ClosedRange<Double> {
        let values = points.compactMap(\.value)
        guard let lo = values.min(), let hi = values.max() else {
            return 0...1
        }
        if lo == hi {
            return (lo - 1)...(hi + 1)
        }
        let padding = (hi - lo) * 0.05
        return (lo - padding)...(hi + padding)
    }

    // MARK: - X-axis Domain & Stride

    /// Returns the explicit tick-mark spacing for the x-axis based on the current time range.
    ///
    /// **Swift Charts concept — AxisMarkValues:**
    /// `AxisMarkValues` tells the chart framework where to place tick marks and
    /// labels along an axis. `.stride(by:count:)` spaces them at regular
    /// calendar intervals (e.g., every 15 minutes, every 6 hours, every 1 day).
    /// `.automatic` lets the framework choose the best spacing.
    private var xAxisStride: AxisMarkValues {
        switch timeRange {
        case .oneHour:         return .stride(by: .minute, count: 15)
        case .twentyFourHours: return .stride(by: .hour, count: 6)
        case .sevenDays:       return .stride(by: .day, count: 1)
        case .thirtyDays:      return .stride(by: .day, count: 7)
        case .all:             return .automatic
        }
    }

    /// X-axis scale domain from the parent HistoryViewModel.
    private var xScaleDomain: ClosedRange<Date> {
        if let domain = xDomain {
            return domain
        }
        // Fallback: derive from points
        guard let first = points.first, let last = points.last else {
            let now = Date()
            return now...now
        }
        return first.date...last.date
    }

    // MARK: - Body

    /// The chart view body — renders the data line, selection overlay, and axes.
    ///
    /// The chart body contains three logical sections:
    /// 1. **Data line** — A `LineMark` for each valid data point, forming the main line.
    /// 2. **Selection overlay** — A `RuleMark` (vertical dashed line) and two
    ///    `PointMark`s (colored dot with white center) shown at the inspected point,
    ///    plus an `.annotation` tooltip displaying the value and time.
    /// 3. **Axes** — Custom x-axis with adaptive date labels and a y-axis with
    ///    the unit label on the leading edge.
    ///
    /// The `.chartOverlay` adds an invisible gesture layer that converts touch
    /// coordinates to data coordinates using the `ChartProxy`.
    var body: some View {
        Chart {
            // Section 1: Data line — iterates over all data points and draws a LineMark
            // for each one that has a non-nil value.
            ForEach(points) { point in
                if let value = point.value {
                    LineMark(
                        x: .value("Time", point.date),
                        y: .value(unit, value)
                    )
                    .foregroundStyle(color)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                    .interpolationMethod(.catmullRom)
                }
            }

            // Section 2: Selection overlay — shown when the user is dragging on the chart.
            // This consists of a dashed vertical line (RuleMark), a colored dot
            // (outer PointMark), a white center dot (inner PointMark), and a
            // tooltip annotation displaying the value and timestamp.
            if let selected = selectedPoint, let value = selected.value {
                RuleMark(x: .value("Selected", selected.date))
                    .foregroundStyle(.gray.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))

                PointMark(
                    x: .value("Selected", selected.date),
                    y: .value(unit, value)
                )
                .foregroundStyle(color)
                .symbolSize(60)

                PointMark(
                    x: .value("Selected", selected.date),
                    y: .value(unit, value)
                )
                .foregroundStyle(.white)
                .symbolSize(25)
                .annotation(position: .top, spacing: 8) {
                    VStack(spacing: 2) {
                        Text("\(formatValue(value)) \(unit)")
                            .font(.caption.weight(.bold))
                            .monospacedDigit()
                        Text(annotationDateLabel(selected.date))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
        .chartYScale(domain: yDomain)
        .chartXScale(domain: xScaleDomain)
        .chartXAxis {
            AxisMarks(values: xAxisStride) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(xAxisLabel(for: date))
                            .font(.caption2)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { _ in
                AxisGridLine()
                AxisValueLabel()
            }
        }
        .chartYAxisLabel(position: .leading, alignment: .center) {
            if !unit.isEmpty {
                Text(unit)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        // Touch-to-inspect gesture overlay.
        //
        // **Swift Charts concept — .chartOverlay:**
        // `.chartOverlay` adds a transparent layer on top of the chart.
        // The closure receives a `ChartProxy` that can convert between
        // screen coordinates and data values. For example,
        // `proxy.value(atX: x)` converts an x pixel offset to a `Date`.
        //
        // **SwiftUI concept — DragGesture:**
        // `DragGesture` detects finger drags. `.simultaneousGesture` is used
        // instead of `.gesture` so that vertical drags can still scroll the
        // parent ScrollView — only horizontal drags are captured for inspection.
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Color.clear
                    .contentShape(Rectangle())
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 12)
                            .onChanged { drag in
                                // Only capture horizontal drags — let vertical ones pass to ScrollView.
                                guard abs(drag.translation.width) > abs(drag.translation.height) else {
                                    if selectedPoint != nil { selectedPoint = nil }
                                    return
                                }
                                // Convert the gesture's x-position to a chart data coordinate (Date).
                                guard let plotFrame = proxy.plotFrame else { return }
                                let origin = geometry[plotFrame].origin
                                let x = drag.location.x - origin.x
                                guard let date: Date = proxy.value(atX: x) else { return }
                                // Find the nearest data point to the touch position.
                                selectedPoint = nearestPoint(to: date)
                            }
                            .onEnded { _ in
                                // Clear the selection when the user lifts their finger.
                                selectedPoint = nil
                            }
                    )
            }
        }
    }

    // MARK: - X-axis Labels (Aranet4-style)

    /// Adaptive x-axis label format matching Aranet4 patterns:
    /// - 1h: "3:42 PM" (hour:minute)
    /// - 24h: "06:00", "12:00" (24h clock, Aranet4-style)
    /// - 7d: "Mon", "Tue" (short day name)
    /// - 30d: "Feb 05", "Mar 01" (month + day)
    /// - All: adaptive based on data span
    private func xAxisLabel(for date: Date) -> String {
        switch timeRange {
        case .oneHour:
            return Self.fmtHourMinute.string(from: date)
        case .twentyFourHours:
            return Self.fmtHour24.string(from: date)
        case .sevenDays:
            return Self.fmtDayShort.string(from: date)
        case .thirtyDays:
            return Self.fmtMonthDay.string(from: date)
        case .all:
            let spanDays = dataSpanDays
            if spanDays <= 1 {
                return Self.fmtHour24.string(from: date)
            } else if spanDays <= 14 {
                return Self.fmtDayShort.string(from: date)
            } else {
                return Self.fmtMonthDay.string(from: date)
            }
        }
    }

    /// Total number of whole days spanned by the current chart data, used to select the x-axis label format in "All" mode.
    private var dataSpanDays: Int {
        guard let first = points.first, let last = points.last else { return 0 }
        return (last.timestamp - first.timestamp) / 86400
    }

    // MARK: - Annotation Date Label

    /// Contextual timestamp for the touch-to-inspect tooltip.
    private func annotationDateLabel(_ date: Date) -> String {
        switch timeRange {
        case .oneHour, .twentyFourHours:
            return Self.fmtAnnotationShort.string(from: date)
        case .sevenDays:
            return Self.fmtAnnotationDay.string(from: date)
        case .thirtyDays, .all:
            return Self.fmtAnnotationFull.string(from: date)
        }
    }

    // MARK: - Nearest Point Lookup

    /// Finds the data point closest in time to the given date.
    ///
    /// Uses binary search for efficiency (O(log n) instead of O(n)). The points
    /// array is sorted by timestamp, so binary search is applicable.
    ///
    /// After the binary search narrows down to a candidate index, the function
    /// checks the candidate and its immediate neighbors to find the one with
    /// the smallest absolute time difference from the target date.
    ///
    /// - Parameter date: The date to search for (from the chart gesture).
    /// - Returns: The nearest `ChartPoint` with a non-nil value, or `nil` if no valid points exist.
    private func nearestPoint(to date: Date) -> ChartPoint? {
        let target = Int(date.timeIntervalSince1970)
        let validPoints = points.filter { $0.value != nil }
        guard !validPoints.isEmpty else { return nil }

        // Binary search for closest timestamp
        var lo = 0, hi = validPoints.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if validPoints[mid].timestamp < target {
                lo = mid + 1
            } else {
                hi = mid
            }
        }

        // Check neighbors for closest
        let candidates = Set([max(0, lo - 1), lo, min(validPoints.count - 1, lo + 1)])
        return candidates
            .map { validPoints[$0] }
            .min(by: { abs($0.timestamp - target) < abs($1.timestamp - target) })
    }
}
