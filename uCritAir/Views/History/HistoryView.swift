import SwiftUI

struct HistoryView: View {

    @Environment(HistoryViewModel.self) private var historyVM

    @Environment(BLEManager.self) private var bleManager

    @Environment(DeviceViewModel.self) private var deviceVM

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @Environment(\.modelContext) private var modelContext

    @State private var showClearConfirmation = false

    @State private var sensorScrollTarget: String?

    @State private var showDatePicker = false

    @State private var initialLoadTask: Task<Void, Never>?

    var body: some View {
        historyScreen()
    }

    private func historyScreen() -> some View {
        ScrollView {
            historyContent()
        }
        .scrollBounceBehavior(.basedOnSize)
        .refreshable {
            await historyVM.downloadNewCells()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Data")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("historyScreen")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                ConnectButton()
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                if bleManager.connectionState == .connected {
                    Button {
                        Task { await historyVM.downloadNewCells() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("Download new data")
                    .disabled(historyVM.isStreaming)
                }

                Button {
                    showClearConfirmation = true
                } label: {
                    Image(systemName: "trash")
                }
                .accessibilityLabel("Clear cached data")
                .disabled(historyVM.cachedCount == 0)

                if let url = historyVM.csvFileURL() {
                    ShareLink(item: url) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("Export CSV")
                }
            }
        }
        .onAppear {
            historyVM.configure(bleManager: bleManager, modelContext: modelContext)
            historyVM.syncDeviceId(from: bleManager)
            scheduleInitialHistoryLoad()
        }
        .onDisappear {
            initialLoadTask?.cancel()
            initialLoadTask = nil
            historyVM.stopAutoPoll()
        }
        .onChange(of: bleManager.connectionState) { _, newState in
            if newState == .connected {
                historyVM.syncDeviceId(from: bleManager)
                scheduleInitialHistoryLoad(forceCacheReload: true)
            } else {
                historyVM.stopAutoPoll()
            }
        }
        .alert("Clear Cache", isPresented: $showClearConfirmation) {
            Button("Clear", role: .destructive) { historyVM.clearCache() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Delete all \(historyVM.cachedCount) cached log cells? This cannot be undone.")
        }
    }

    private var footerContainer: some View {
        timeRangeRow
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 8)
            .background(
                Color(.systemGroupedBackground)
                    .overlay(alignment: .top) {
                        Divider()
                    }
            )
    }

    private func historyContent() -> some View {
        VStack(spacing: dynamicTypeSize.usesAccessibilityLayout ? 12 : 6) {
            if dynamicTypeSize.usesAccessibilityLayout {
                ConnectedDeviceHeader()
            }

            progressBar
            errorBanner

            if !dynamicTypeSize.usesAccessibilityLayout {
                sensorTabs
            }

            compactStats

            chartSection(height: chartHeight)

            footerContainer
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 12)
    }

    private var chartHeight: CGFloat {
        if dynamicTypeSize.usesAccessibilityLayout {
            switch historyVM.timeRange {
            case .oneHour, .sevenDays, .all:
                return 450
            case .oneDay:
                return 420
            }
        }

        switch historyVM.timeRange {
        case .oneHour, .sevenDays, .all:
            return 430
        case .oneDay:
            return 400
        }
    }

    @ViewBuilder
    private var progressBar: some View {
        if historyVM.isStreaming, let progress = historyVM.streamProgress {
            VStack(spacing: 4) {
                ProgressView(value: Double(progress.received), total: Double(max(progress.total, 1)))
                    .tint(.blue)
                Text("\(progress.received) / \(progress.total) cells")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else if historyVM.isStreaming {
            ProgressView("Starting download...")
                .font(.caption)
        }
    }

    @ViewBuilder
    private var errorBanner: some View {
        if let error = historyVM.error {
            Group {
                if dynamicTypeSize.usesAccessibilityLayout {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .accessibilityHidden(true)
                            Text(error)
                                .font(.caption)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Button("Dismiss Error") {
                            historyVM.error = nil
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.white.opacity(0.2))
                        .foregroundStyle(.white)
                        .minimumAccessibleTapTarget()
                    }
                } else {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .accessibilityHidden(true)
                        Text(error)
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button {
                            historyVM.error = nil
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .accessibilityLabel("Dismiss error")
                        .minimumAccessibleTapTarget()
                    }
                }
            }
            .foregroundStyle(.white)
            .padding(10)
            .background(.red, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var sensorTabs: some View {
        let defs = HistoryViewModel.sensorDefs

        return HStack(spacing: 2) {
            Button { navigateSensor(direction: -1, defs: defs) } label: {
                Image(systemName: "chevron.left")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Previous sensor")

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(defs) { def in
                            sensorTab(
                                label: def.shortLabel,
                                isActive: historyVM.selectedSensor == def.id,
                                color: Color(hex: def.color)
                            ) {
                                historyVM.selectedSensor = def.id
                                sensorScrollTarget = def.id
                            }
                            .id(def.id)
                        }
                    }
                }
                .onChange(of: sensorScrollTarget) { _, target in
                    if let target {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            proxy.scrollTo(target, anchor: .center)
                        }
                        sensorScrollTarget = nil
                    }
                }
            }

            Button { navigateSensor(direction: 1, defs: defs) } label: {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Next sensor")
        }
    }

    private func navigateSensor(direction: Int, defs: [SensorDef]) {
        guard let currentId = historyVM.selectedSensor,
              let currentIdx = defs.firstIndex(where: { $0.id == currentId }) else { return }
        let targetIdx = min(max(currentIdx + direction, 0), defs.count - 1)
        let targetId = defs[targetIdx].id
        historyVM.selectedSensor = targetId
        sensorScrollTarget = targetId
    }

    private func sensorTab(label: String, isActive: Bool, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .foregroundStyle(isActive ? .white : color)
                .background(isActive ? color : color.opacity(0.12), in: Capsule())
        }
        .minimumAccessibleTapTarget()
    }

    @ViewBuilder
    private var compactStats: some View {
        if let sensor = historyVM.selectedSensorDef,
           let stats = historyVM.stats(for: sensor) {
            ViewThatFits(in: .horizontal) {
                compactStatsInlineLayout(sensor: sensor, stats: stats)
                compactStatsStackedLayout(sensor: sensor, stats: stats)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func compactStatsInlineLayout(sensor: SensorDef, stats: SensorStats) -> some View {
        HStack(alignment: .center, spacing: 14) {
            compactStatsPrimaryValue(sensor: sensor, stats: stats)
                .fixedSize(horizontal: true, vertical: false)

            Divider()
                .frame(height: 52)

            HStack(spacing: 12) {
                miniStat(label: "Avg", value: sensor.format(stats.avg))
                miniStat(label: "Min", value: sensor.format(stats.min))
                miniStat(label: "Max", value: sensor.format(stats.max))
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func compactStatsStackedLayout(sensor: SensorDef, stats: SensorStats) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            compactStatsPrimaryValue(sensor: sensor, stats: stats)

            if dynamicTypeSize.usesAccessibilityLayout {
                VStack(alignment: .leading, spacing: 8) {
                    miniStat(label: "Avg", value: sensor.format(stats.avg))
                    miniStat(label: "Min", value: sensor.format(stats.min))
                    miniStat(label: "Max", value: sensor.format(stats.max))
                }
            } else {
                HStack(spacing: 12) {
                    miniStat(label: "Avg", value: sensor.format(stats.avg))
                    miniStat(label: "Min", value: sensor.format(stats.min))
                    miniStat(label: "Max", value: sensor.format(stats.max))
                }
            }
        }
    }

    private func compactStatsPrimaryValue(sensor: SensorDef, stats: SensorStats) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(sensor.label)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            AdaptiveStack(
                vertical: dynamicTypeSize.usesAccessibilityLayout,
                verticalAlignment: .leading,
                horizontalAlignment: .firstTextBaseline,
                spacing: 4
            ) {
                Text(sensor.format(stats.latest))
                    .font(.title2.weight(.bold))
                    .foregroundStyle(Color(hex: sensor.color))

                if !sensor.unit.isEmpty {
                    Text(sensor.unit)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func miniStat(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.caption2.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    private var timeRangeRow: some View {
        Group {
            if dynamicTypeSize.usesAccessibilityLayout {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Sensor", selection: selectedSensorBinding) {
                        ForEach(HistoryViewModel.sensorDefs) { def in
                            Text(def.label).tag(def.id)
                        }
                    }
                    .pickerStyle(.menu)

                    Picker("Time Range", selection: timeRangeBinding) {
                        ForEach(TimeRange.allCases) { range in
                            Text(range.rawValue).tag(range)
                        }
                    }
                    .pickerStyle(.menu)

                    if historyVM.timeRange == .oneDay {
                        accessibilityDayControls
                    }

                    Button {
                        showDatePicker = true
                    } label: {
                        Label("Choose Date", systemImage: "calendar")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.bordered)
                    .minimumAccessibleTapTarget()
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    standardTimeRangeRow
                    compactTimeRangeRow
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: historyVM.timeRange)
        .sheet(isPresented: $showDatePicker) {
            DatePickerSheet(
                selectedDate: historyVM.selectedDate,
                dateRange: historyVM.dataDateRange
            ) { date in
                historyVM.jumpToDate(date)
            }
        }
    }

    private var selectedSensorBinding: Binding<String> {
        Binding(
            get: { historyVM.selectedSensor ?? HistoryViewModel.sensorDefs.first?.id ?? "" },
            set: { historyVM.selectedSensor = $0 }
        )
    }

    private var timeRangeBinding: Binding<TimeRange> {
        Binding(
            get: { historyVM.timeRange },
            set: { historyVM.setTimeRange($0) }
        )
    }

    private var accessibilityDayControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(historyVM.dayLabel)
                .font(.subheadline.weight(.semibold))
                .accessibilityLabel("Showing \(historyVM.dayLabel)")

            HStack(spacing: 12) {
                Button("Previous Day") {
                    historyVM.goBack()
                }
                .buttonStyle(.bordered)
                .disabled(!historyVM.canGoBack)
                .minimumAccessibleTapTarget()

                Button("Next Day") {
                    historyVM.goForward()
                }
                .buttonStyle(.bordered)
                .disabled(!historyVM.canGoForward)
                .minimumAccessibleTapTarget()
            }
        }
    }

    private var standardTimeRangeRow: some View {
        HStack(spacing: 0) {
            timeRangeButtons

            Spacer(minLength: 8)

            if historyVM.timeRange == .oneDay {
                standardDayControls
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            }

            calendarButton
        }
    }

    private var compactTimeRangeRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                timeRangeButtons
                    .layoutPriority(1)
                Spacer(minLength: 0)
                if historyVM.timeRange != .oneDay {
                    calendarButton
                }
            }

            if historyVM.timeRange == .oneDay {
                HStack(spacing: 12) {
                    previousDayButton

                    Text(historyVM.dayLabel)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .allowsTightening(true)
                        .accessibilityLabel("Showing \(historyVM.dayLabel)")

                    nextDayButton

                    Spacer(minLength: 0)

                    calendarButton
                }
            } else {
                EmptyView()
            }
        }
    }

    private var timeRangeButtons: some View {
        HStack(spacing: 6) {
            ForEach(TimeRange.allCases) { range in
                Button {
                    historyVM.setTimeRange(range)
                } label: {
                    Text(range.rawValue)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .foregroundStyle(historyVM.timeRange == range ? .white : .primary)
                        .background(
                            historyVM.timeRange == range ? Color.accentColor : Color(.systemGray5),
                            in: RoundedRectangle(cornerRadius: 6)
                        )
                }
                .minimumAccessibleTapTarget()
            }
        }
    }

    private var standardDayControls: some View {
        HStack(spacing: 6) {
            previousDayButton

            Text(historyVM.dayLabel)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityLabel("Showing \(historyVM.dayLabel)")

            nextDayButton
        }
    }

    private var previousDayButton: some View {
        Button {
            historyVM.goBack()
        } label: {
            Image(systemName: "chevron.left")
                .font(.caption.weight(.semibold))
                .frame(width: 44, height: 44)
        }
        .accessibilityLabel("Previous day")
        .disabled(!historyVM.canGoBack)
    }

    private var nextDayButton: some View {
        Button {
            historyVM.goForward()
        } label: {
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .frame(width: 44, height: 44)
        }
        .accessibilityLabel("Next day")
        .disabled(!historyVM.canGoForward)
    }

    private var calendarButton: some View {
        Button {
            showDatePicker = true
        } label: {
            Image(systemName: "calendar")
                .font(.caption.weight(.semibold))
                .padding(7)
                .background(Color(.systemGray5), in: RoundedRectangle(cornerRadius: 6))
        }
        .accessibilityLabel("Pick a date")
        .minimumAccessibleTapTarget()
    }

    private func scheduleInitialHistoryLoad(forceCacheReload: Bool = false) {
        initialLoadTask?.cancel()
        initialLoadTask = Task {
            await Task.yield()
            guard !Task.isCancelled else { return }

            await MainActor.run {
                historyVM.loadCachedCells(force: forceCacheReload)
            }

            let isConnected = await MainActor.run {
                bleManager.connectionState == .connected
            }

            await MainActor.run {
                if isConnected {
                    historyVM.startAutoPoll()
                } else {
                    historyVM.stopAutoPoll()
                }
            }

            guard isConnected, !Task.isCancelled else { return }
            await historyVM.autoDownloadIfNeeded()
        }
    }

    @ViewBuilder
    private func chartSection(height: CGFloat) -> some View {
        if historyVM.filteredCells.isEmpty {
            ContentUnavailableView(
                "No Data",
                systemImage: "chart.line.downtrend.xyaxis",
                description: Text(historyVM.cachedCount == 0
                    ? "Download log cells from your device to see historical data."
                    : "No data in the selected time range.")
            )
            .frame(maxWidth: .infinity)
            .frame(height: height, alignment: .top)
        } else if let sensor = historyVM.selectedSensorDef {
            SensorChartView(
                points: historyVM.chartPoints(for: sensor),
                color: Color(hex: sensor.color),
                unit: sensor.unit,
                timeRange: historyVM.timeRange,
                formatValue: sensor.format,
                xDomain: historyVM.chartXDomain
            )
            .frame(height: height)
        }
    }

}

// MARK: - Date Picker Sheet

private struct DatePickerSheet: View {

    let dateRange: ClosedRange<Date>
    let onSelect: (Date) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var pickedDate: Date
    @State private var ready = false

    init(selectedDate: Date, dateRange: ClosedRange<Date>, onSelect: @escaping (Date) -> Void) {
        self.dateRange = dateRange
        self.onSelect = onSelect
        _pickedDate = State(initialValue: selectedDate)
    }

    var body: some View {
        NavigationStack {
            DatePicker(
                "Select date",
                selection: $pickedDate,
                in: dateRange,
                displayedComponents: .date
            )
            .datePickerStyle(.graphical)
            .padding(.horizontal)
            .navigationTitle("Jump to Date")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .onAppear { ready = true }
        .onChange(of: pickedDate) { _, newDate in
            guard ready else { return }
            onSelect(newDate)
            dismiss()
        }
        .presentationDetents([.height(460), .large])
    }
}
