import SwiftUI

struct HistoryView: View {

    @Environment(HistoryViewModel.self) private var historyVM

    @Environment(BLEManager.self) private var bleManager

    @Environment(DeviceViewModel.self) private var deviceVM

    @Environment(\.modelContext) private var modelContext

    @State private var showClearConfirmation = false

    @State private var sensorScrollTarget: String?

    @State private var showDatePicker = false

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(spacing: 6) {
                    progressBar
                    errorBanner
                    sensorTabs
                    compactStats
                    chartSection
                        .frame(height: chartHeight(in: geo.size.height))
                }
                .padding(.horizontal, 12)
                .padding(.top, 4)
                .padding(.bottom, 8)
            }
            .scrollBounceBehavior(.basedOnSize)
            .refreshable {
                await historyVM.downloadNewCells()
            }
            .safeAreaInset(edge: .bottom) {
                timeRangeRow
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.bar)
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Data")
        .navigationBarTitleDisplayMode(.inline)
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
            historyVM.loadCachedCells()
            if bleManager.connectionState == .connected {
                historyVM.startAutoPoll()
                Task { await historyVM.autoDownloadIfNeeded() }
            }
        }
        .onDisappear {
            historyVM.stopAutoPoll()
        }
        .onChange(of: bleManager.connectionState) { _, newState in
            if newState == .connected {
                historyVM.syncDeviceId(from: bleManager)
                historyVM.loadCachedCells()
                historyVM.startAutoPoll()
                Task { await historyVM.autoDownloadIfNeeded() }
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
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .accessibilityHidden(true)
                Text(error)
                    .font(.caption)
                    .lineLimit(2)
                Spacer()
                Button {
                    historyVM.error = nil
                } label: {
                    Image(systemName: "xmark")
                }
                .accessibilityLabel("Dismiss error")
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
    }

    @ViewBuilder
    private var compactStats: some View {
        if let sensor = historyVM.selectedSensorDef,
           let stats = historyVM.stats(for: sensor) {
            HStack(alignment: .firstTextBaseline) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(sensor.format(stats.latest))
                        .font(.title2.weight(.bold))
                        .foregroundStyle(Color(hex: sensor.color))
                    Text(sensor.unit)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                HStack(spacing: 12) {
                    miniStat(label: "Avg", value: sensor.format(stats.avg))
                    miniStat(label: "Min", value: sensor.format(stats.min))
                    miniStat(label: "Max", value: sensor.format(stats.max))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func miniStat(label: String, value: String) -> some View {
        VStack(spacing: 1) {
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
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach(TimeRange.allCases) { range in
                    Button {
                        historyVM.setTimeRange(range)
                    } label: {
                        Text(range.rawValue)
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .foregroundStyle(historyVM.timeRange == range ? .white : .primary)
                            .background(
                                historyVM.timeRange == range ? Color.accentColor : Color(.systemGray5),
                                in: RoundedRectangle(cornerRadius: 6)
                            )
                    }
                }
            }

            Spacer(minLength: 8)

            if historyVM.timeRange == .oneDay {
                HStack(spacing: 6) {
                    Button {
                        historyVM.goBack()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.caption.weight(.semibold))
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Previous day")
                    .disabled(!historyVM.canGoBack)

                    Text(historyVM.dayLabel)
                        .font(.caption.weight(.medium))
                        .frame(minWidth: 60)
                        .accessibilityLabel("Showing \(historyVM.dayLabel)")

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
                .transition(.opacity.combined(with: .move(edge: .trailing)))
            }

            Button {
                showDatePicker = true
            } label: {
                Image(systemName: "calendar")
                    .font(.caption.weight(.semibold))
                    .padding(8)
                    .background(Color(.systemGray5), in: RoundedRectangle(cornerRadius: 6))
            }
            .accessibilityLabel("Pick a date")
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

    @ViewBuilder
    private var chartSection: some View {
        if historyVM.filteredCells.isEmpty {
            ContentUnavailableView(
                "No Data",
                systemImage: "chart.line.downtrend.xyaxis",
                description: Text(historyVM.cachedCount == 0
                    ? "Download log cells from your device to see historical data."
                    : "No data in the selected time range.")
            )
        } else if let sensor = historyVM.selectedSensorDef {
            SensorChartView(
                points: historyVM.chartPoints(for: sensor),
                color: Color(hex: sensor.color),
                unit: sensor.unit,
                timeRange: historyVM.timeRange,
                formatValue: sensor.format,
                xDomain: historyVM.chartXDomain
            )
        }
    }

    private func chartHeight(in containerHeight: CGFloat) -> CGFloat {
        // Reserve space for: sensorTabs (~44) + compactStats (~52)
        // + VStack spacing (6*3=18) + vertical padding (4+8=12) + bottom bar (~52) = ~178
        let reserved: CGFloat = 180
        return max(containerHeight - reserved, 250)
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
        .presentationDetents([.height(460)])
    }
}
