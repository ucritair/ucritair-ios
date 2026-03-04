import SwiftUI

/// History tab — log cell timeline, charts, and CSV export.
/// Ported from src/pages/History.tsx
struct HistoryView: View {
    @Environment(HistoryViewModel.self) private var historyVM
    @Environment(BLEManager.self) private var bleManager
    @Environment(DeviceViewModel.self) private var deviceVM
    @Environment(\.modelContext) private var modelContext

    @State private var showClearConfirmation = false
    /// Set to a sensor ID to programmatically scroll the pill strip and center that sensor.
    /// Consumed by `ScrollViewReader` inside `sensorTabs`; reset to nil after each scroll.
    @State private var sensorScrollTarget: String?

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
                    timeRangeRow
                }
                .padding(.horizontal, 12)
                .padding(.top, 4)
                .padding(.bottom, 8)
            }
            .refreshable {
                await historyVM.downloadNewCells()
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

    // MARK: - Progress Bar

    /// Displays a progress indicator during BLE log cell downloads, showing received/total counts.
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

    // MARK: - Error Banner

    /// Dismissible red banner that surfaces the most recent error from the history view model.
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

    // MARK: - Sensor Tabs

    /// Horizontal sensor picker: ‹ [CO₂] [PM2.5] [PM10] [Temp] ... ›
    /// Compact blue arrows navigate selection and auto-scroll the strip.
    private var sensorTabs: some View {
        let defs = HistoryViewModel.sensorDefs

        return HStack(spacing: 2) {
            Button { navigateSensor(direction: -1, defs: defs) } label: {
                Image(systemName: "chevron.left")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 28)
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
                    .frame(width: 20, height: 28)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Next sensor")
        }
    }

    /// Navigate to the previous (-1) or next (+1) sensor, selecting and scrolling to it.
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

    // MARK: - Compact Stats

    /// Compact inline stats: latest value (left) + avg/min/max (right).
    @ViewBuilder
    private var compactStats: some View {
        if let sensor = historyVM.selectedSensorDef,
           let stats = historyVM.stats(for: sensor) {
            HStack(alignment: .firstTextBaseline) {
                // Latest value — hero number
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(sensor.format(stats.latest))
                        .font(.title2.weight(.bold))
                        .foregroundStyle(Color(hex: sensor.color))
                    Text(sensor.unit)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // Avg / Min / Max — compact
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

    // MARK: - Time Range + Day Navigation (Combined Row)

    /// Single row: time range pills (left) + day navigation (right, 24h only).
    private var timeRangeRow: some View {
        HStack(spacing: 0) {
            // Time range pills
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

            // Day navigation (24h mode only)
            if historyVM.timeRange == .twentyFourHours {
                HStack(spacing: 6) {
                    Button {
                        historyVM.goBack()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.caption.weight(.semibold))
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
                    }
                    .accessibilityLabel("Next day")
                    .disabled(!historyVM.canGoForward)
                }
                .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: historyVM.timeRange)
    }

    // MARK: - Chart Section

    /// Renders the sensor line chart for the selected sensor, or an empty-state placeholder if no data is available.
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

    /// Dynamic chart height: fills available space minus the other UI elements.
    private func chartHeight(in containerHeight: CGFloat) -> CGFloat {
        // Reserve: sensor tabs (~34) + stats (~44) + time row (~34) + spacing (6*4=24) + padding (12)
        let reserved: CGFloat = 148
        return max(containerHeight - reserved, 250)
    }
}
