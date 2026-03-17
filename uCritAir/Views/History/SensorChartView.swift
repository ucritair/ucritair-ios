import SwiftUI
import Charts

// MARK: - ChartPoint Extension

extension ChartPoint {
    var date: Date {
        Date(timeIntervalSince1970: TimeInterval(timestamp))
    }
}

struct SensorChartView: View {

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let points: [ChartPoint]

    let color: Color

    let unit: String

    let timeRange: TimeRange

    let formatValue: (Double) -> String

    let xDomain: ClosedRange<Date>?

    @State private var selectedPoint: ChartPoint?

    @State private var visibleDomainLength: TimeInterval = 0

    @State private var visibleStart: Date = .distantPast

    @State private var isZoomed = false

    // Zoom gesture state
    @State private var baselineDomainLength: TimeInterval?
    @State private var zoomAnchorDate: Date?
    @State private var zoomAnchorFraction: CGFloat = 0

    // Pan gesture state
    @State private var panStartDate: Date?

    private static let utc: TimeZone = .gmt

    private static let fmtHourMinute: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "h:mm a"
        f.timeZone = utc
        return f
    }()

    private static let fmtHourMinuteCompact: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "h:mm"
        f.timeZone = utc
        return f
    }()

    private static let fmtHour24: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:00"
        f.timeZone = utc
        return f
    }()

    private static let fmtDayShort: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE"
        f.timeZone = utc
        return f
    }()

    private static let fmtMonthDay: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM dd"
        f.timeZone = utc
        return f
    }()

    private static let fmtAnnotationShort: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "h:mm:ss a"
        f.timeZone = utc
        return f
    }()

    private static let fmtAnnotationDay: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE dd, h:mm a"
        f.timeZone = utc
        return f
    }()

    private static let fmtAnnotationFull: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM dd, h:mm a"
        f.timeZone = utc
        return f
    }()

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

    private var fullDomain: ClosedRange<Date> {
        if let domain = xDomain {
            return domain
        }
        guard let first = points.first, let last = points.last else {
            let now = Date()
            return now...now
        }
        return first.date...last.date
    }

    private var fullDomainLength: TimeInterval {
        max(fullDomain.upperBound.timeIntervalSince(fullDomain.lowerBound), 1)
    }

    private var minDomainLength: TimeInterval {
        max(60, fullDomainLength * 0.02)
    }

    private var effectiveDomainLength: TimeInterval {
        let length = visibleDomainLength > 0 ? visibleDomainLength : fullDomainLength
        return max(length, 1)
    }

    private var visibleXDomain: ClosedRange<Date> {
        guard isZoomed else { return fullDomain }
        let start = visibleStart
        let end = start.addingTimeInterval(effectiveDomainLength)
        return start...end
    }

    private var xAxisDesiredCount: Int {
        let visibleHours = effectiveDomainLength / 3600

        if dynamicTypeSize.usesAccessibilityLayout {
            switch visibleHours {
            case ..<3:
                return 2
            case ..<12:
                return 3
            default:
                return 4
            }
        }

        switch visibleHours {
        case ..<2:
            return 3
        case ..<6:
            return 4
        case ..<18:
            return 5
        default:
            return 6
        }
    }

    private var lineInterpolation: InterpolationMethod {
        isZoomed ? .linear : .catmullRom
    }

    var body: some View {
        Group {
            if dynamicTypeSize.usesAccessibilityLayout {
                VStack(alignment: .leading, spacing: 12) {
                    accessibilitySummary
                    chartBody
                }
            } else {
                chartBody
            }
        }
    }

    private var chartBody: some View {
        Chart {
            ForEach(points) { point in
                if let value = point.value {
                    LineMark(
                        x: .value("Time", point.date),
                        y: .value(unit, value)
                    )
                    .foregroundStyle(color)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                    .interpolationMethod(lineInterpolation)
                }
            }

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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .chartYScale(domain: yDomain)
        .chartXScale(domain: visibleXDomain)
        .chartPlotStyle { plotArea in
            plotArea
                .clipped()
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: xAxisDesiredCount)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(adaptiveXAxisLabel(for: date))
                            .font(.caption2)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(
                position: .leading,
                values: .automatic(desiredCount: dynamicTypeSize.usesAccessibilityLayout ? 3 : 5)
            ) { _ in
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
                    .onTapGesture { location in
                        guard let plotFrame = proxy.plotFrame else { return }
                        let origin = geometry[plotFrame].origin
                        let x = location.x - origin.x
                        guard let date: Date = proxy.value(atX: x) else { return }
                        if let nearest = nearestPoint(to: date) {
                            selectedPoint = selectedPoint?.id == nearest.id ? nil : nearest
                        }
                    }
                    .simultaneousGesture(
                        MagnifyGesture()
                            .onChanged { gesture in
                                if baselineDomainLength == nil {
                                    baselineDomainLength = effectiveDomainLength
                                    selectedPoint = nil

                                    if let plotFrame = proxy.plotFrame {
                                        let plotRect = geometry[plotFrame]
                                        let anchorXInView = geometry.size.width * gesture.startAnchor.x
                                        let anchorXInPlot = anchorXInView - plotRect.origin.x
                                        let fraction = anchorXInPlot / plotRect.width
                                        zoomAnchorFraction = max(0, min(1, fraction))

                                        if let date: Date = proxy.value(atX: anchorXInPlot) {
                                            zoomAnchorDate = date
                                        } else {
                                            zoomAnchorDate = isZoomed
                                                ? visibleStart.addingTimeInterval(effectiveDomainLength * zoomAnchorFraction)
                                                : fullDomain.lowerBound.addingTimeInterval(fullDomainLength * zoomAnchorFraction)
                                        }
                                    }
                                }

                                let newLength = (baselineDomainLength ?? effectiveDomainLength) / gesture.magnification
                                let clamped = max(minDomainLength, min(fullDomainLength, newLength))
                                visibleDomainLength = clamped

                                if let anchor = zoomAnchorDate {
                                    visibleStart = anchor.addingTimeInterval(-Double(zoomAnchorFraction) * clamped)
                                }
                                clampVisibleRange()
                                isZoomed = clamped < fullDomainLength * 0.98
                            }
                            .onEnded { _ in
                                baselineDomainLength = nil
                                zoomAnchorDate = nil
                                zoomAnchorFraction = 0
                            }
                    )
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 10)
                            .onChanged { drag in
                                // Don't pan during an active pinch-zoom
                                guard baselineDomainLength == nil else { return }
                                guard isZoomed else { return }
                                guard let plotFrame = proxy.plotFrame else { return }

                                if panStartDate == nil {
                                    panStartDate = visibleStart
                                    selectedPoint = nil
                                }

                                let plotWidth = geometry[plotFrame].width
                                guard plotWidth > 0 else { return }
                                guard let panStart = panStartDate else { return }
                                let timePerPixel = effectiveDomainLength / plotWidth
                                let timeDelta = -Double(drag.translation.width) * timePerPixel
                                visibleStart = panStart.addingTimeInterval(timeDelta)
                                clampVisibleRange()
                            }
                            .onEnded { _ in
                                panStartDate = nil
                            }
                    )
            }
        }
        .padding(.bottom, dynamicTypeSize.usesAccessibilityLayout ? 10 : 14)
        .overlay(alignment: .topTrailing) {
            if isZoomed {
                Button {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        resetToFullDomain()
                    }
                } label: {
                    if dynamicTypeSize.usesAccessibilityLayout {
                        Label("Reset zoom", systemImage: "arrow.up.left.and.arrow.down.right")
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(.ultraThinMaterial, in: Capsule())
                    } else {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.caption2)
                            .padding(6)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                }
                .padding(8)
                .accessibilityLabel("Reset zoom")
                .minimumAccessibleTapTarget()
            }
        }
        .onAppear {
            resetToFullDomain()
        }
        .onChange(of: timeRange) { _, _ in
            resetToFullDomain()
        }
        .onChange(of: xDomain) { _, _ in
            if !isZoomed {
                resetToFullDomain()
            }
        }
    }

    @ViewBuilder
    private var accessibilitySummary: some View {
        if let point = summaryPoint, let value = point.value {
            VStack(alignment: .leading, spacing: 4) {
                Text(selectedPoint == nil ? "Latest Value" : "Selected Value")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(summaryValueText(for: value))
                    .font(.headline)
                    .monospacedDigit()
                Text(annotationDateLabel(point.date))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private var summaryPoint: ChartPoint? {
        selectedPoint ?? points.last(where: { $0.value != nil })
    }

    private func summaryValueText(for value: Double) -> String {
        if unit.isEmpty {
            return formatValue(value)
        }
        return "\(formatValue(value)) \(unit)"
    }

    private func resetToFullDomain() {
        visibleDomainLength = fullDomainLength
        visibleStart = fullDomain.lowerBound
        isZoomed = false
        selectedPoint = nil
    }

    private func clampVisibleRange() {
        let earliest = fullDomain.lowerBound
        let latest = fullDomain.upperBound
        let domainLen = effectiveDomainLength
        let maxStart = latest.addingTimeInterval(-domainLen)

        if visibleStart < earliest {
            visibleStart = earliest
        } else if visibleStart > maxStart {
            visibleStart = maxStart
        }
    }

    private func adaptiveXAxisLabel(for date: Date) -> String {
        let spanHours = effectiveDomainLength / 3600
        let spanDays = effectiveDomainLength / 86400

        if spanHours <= 6 {
            return Self.fmtHourMinuteCompact.string(from: date)
        } else if spanDays <= 0.125 {
            return Self.fmtHourMinute.string(from: date)
        } else if spanDays <= 2 {
            return Self.fmtHour24.string(from: date)
        } else if spanDays <= 14 {
            return Self.fmtDayShort.string(from: date)
        } else {
            return Self.fmtMonthDay.string(from: date)
        }
    }


    private func annotationDateLabel(_ date: Date) -> String {
        let spanDays = effectiveDomainLength / 86400
        if spanDays <= 2 {
            return Self.fmtAnnotationShort.string(from: date)
        } else if spanDays <= 14 {
            return Self.fmtAnnotationDay.string(from: date)
        } else {
            return Self.fmtAnnotationFull.string(from: date)
        }
    }

    private func nearestPoint(to date: Date) -> ChartPoint? {
        let target = Int(date.timeIntervalSince1970)
        let validPoints = points.filter { $0.value != nil }
        guard !validPoints.isEmpty else { return nil }

        var lo = 0, hi = validPoints.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if validPoints[mid].timestamp < target {
                lo = mid + 1
            } else {
                hi = mid
            }
        }

        let candidates = Set([max(0, lo - 1), lo, min(validPoints.count - 1, lo + 1)])
        return candidates
            .map { validPoints[$0] }
            .min(by: { abs($0.timestamp - target) < abs($1.timestamp - target) })
    }
}
