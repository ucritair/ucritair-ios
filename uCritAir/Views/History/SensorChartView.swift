import SwiftUI
import Charts

// MARK: - ChartPoint Extension

extension ChartPoint {
    var date: Date {
        Date(timeIntervalSince1970: TimeInterval(timestamp))
    }
}

/// Single-sensor line chart with data-scaled Y-axis, adaptive X-axis labels,
/// and touch-to-inspect interaction.
struct SensorChartView: View {
    let points: [ChartPoint]
    let color: Color
    let unit: String
    let timeRange: TimeRange
    let formatValue: (Double) -> String
    let xDomain: ClosedRange<Date>?

    @State private var selectedPoint: ChartPoint?

    // Shared date formatters (avoid creating per-label).
    // All use UTC timezone because device timestamps are "local time as epoch" —
    // the device's local clock stored as if it were UTC. Displaying in UTC
    // recovers the original local time without double-converting.
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

    /// Scale Y-axis to actual data range with 5% padding.
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

    /// Explicit stride values per time range for predictable axis labels.
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

    var body: some View {
        Chart {
            // Data line
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

            // Selection overlay
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
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Color.clear
                    .contentShape(Rectangle())
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 12)
                            .onChanged { drag in
                                // Only capture horizontal drags — let vertical ones pass to ScrollView
                                guard abs(drag.translation.width) > abs(drag.translation.height) else {
                                    if selectedPoint != nil { selectedPoint = nil }
                                    return
                                }
                                guard let plotFrame = proxy.plotFrame else { return }
                                let origin = geometry[plotFrame].origin
                                let x = drag.location.x - origin.x
                                guard let date: Date = proxy.value(atX: x) else { return }
                                selectedPoint = nearestPoint(to: date)
                            }
                            .onEnded { _ in
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
