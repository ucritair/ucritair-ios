// ────────────────────────────────────────────────────────────────────────────
// HistoryView.swift
// uCritAir
// ────────────────────────────────────────────────────────────────────────────
//
// PURPOSE:
//   The History tab (tab index 1 in the root TabView) lets users explore
//   historical sensor data stored on the device. It provides:
//
//     1. A horizontal sensor picker ("pill strip") to select which sensor
//        to chart (CO2, PM2.5, Temperature, etc.).
//     2. A compact stats row showing the latest value plus avg/min/max.
//     3. A full-width line chart (SensorChartView) with touch-to-inspect.
//     4. Time range controls (1h, 24h, 7d, 30d, All) and day navigation.
//     5. Toolbar actions: download data from device, clear cache, export CSV.
//
//   Data flows from the device via BLE, is cached in SwiftData (on-device
//   database), and is read by HistoryViewModel for chart rendering.
//
// SWIFTUI CONCEPTS USED:
//   - @Environment: Reads shared view models and the SwiftData model context.
//   - @State: Private view-level state for UI controls (confirmation dialogs,
//     scroll targets). These values are owned by this view alone.
//   - GeometryReader: Reads the available screen dimensions so the chart
//     height can be computed dynamically (fill available space).
//   - .refreshable: Adds pull-to-refresh support to the ScrollView.
//   - .toolbar: Adds buttons to the navigation bar.
//   - .sheet: Presents a modal overlay (not used directly here but relevant
//     to the scan sheet triggered from ConnectButton).
//   - .alert: Presents a system confirmation dialog with destructive actions.
//   - .onChange(of:): Reacts to changes in an observed value (BLE state).
//   - .onAppear / .onDisappear: Lifecycle callbacks for setup and teardown.
//   - ScrollViewReader / .scrollTo: Programmatic scrolling of the sensor tabs.
//   - ShareLink: A SwiftUI view that presents the system share sheet for
//     exporting the CSV file.
//
// ────────────────────────────────────────────────────────────────────────────

import SwiftUI

/// The History tab view providing sensor data charts, statistics, and CSV export.
///
/// This view is the second tab (index 1) in the app's root TabView. It displays
/// historical log cell data downloaded from the uCrit device over BLE, cached
/// locally via SwiftData, and visualized as interactive line charts.
///
/// ## Layout (top to bottom)
/// 1. **Progress bar** — Shown during BLE data downloads.
/// 2. **Error banner** — Dismissible red banner for download errors.
/// 3. **Sensor tabs** — Horizontal scrollable pills to select which sensor to chart.
/// 4. **Compact stats** — Latest value, average, min, and max for the selected sensor.
/// 5. **Chart** — A full-width `SensorChartView` with touch-to-inspect interaction.
/// 6. **Time range row** — Buttons to change the chart's time window (1h/24h/7d/30d/All)
///    and day navigation arrows (in 24h mode).
///
/// ## Toolbar Actions
/// - **ConnectButton** (leading): BLE connect/disconnect control.
/// - **Refresh** (trailing): Manually triggers a BLE download of new log cells.
/// - **Clear cache** (trailing): Deletes all cached data with a confirmation dialog.
/// - **CSV export** (trailing): Shares the cached data as a CSV file via the system share sheet.
///
/// ## Dependencies
/// - `HistoryViewModel`: The primary data source — provides filtered chart points,
///   statistics, sensor definitions, and manages BLE downloads.
/// - `BLEManager`: Provides the current connection state to enable/disable toolbar actions.
/// - `DeviceViewModel`: Used for Bluetooth status (not directly in the body, but
///   available for future use).
/// - `ModelContext`: The SwiftData context used by HistoryViewModel for persistent storage.
struct HistoryView: View {

    // MARK: - Environment

    /// The history view model — provides chart data, statistics, and download management.
    ///
    /// **SwiftUI concept — @Environment:**
    /// Reads the `HistoryViewModel` that was injected into the environment by
    /// `uCritAirApp`. This is the same instance shared across all views.
    @Environment(HistoryViewModel.self) private var historyVM

    /// The BLE manager — used to check connection state for enabling/disabling toolbar buttons.
    @Environment(BLEManager.self) private var bleManager

    /// The device view model — available for Bluetooth status messages.
    @Environment(DeviceViewModel.self) private var deviceVM

    /// The SwiftData model context for reading and writing cached log cells.
    ///
    /// **SwiftUI concept — @Environment(\.modelContext):**
    /// This is a special environment key provided by the SwiftData framework.
    /// It gives access to the database context for performing queries and writes.
    /// The context is injected by the `.modelContainer()` modifier in `uCritAirApp`.
    @Environment(\.modelContext) private var modelContext

    // MARK: - State

    /// Controls whether the "Clear Cache" confirmation alert is shown.
    ///
    /// **SwiftUI concept — @State:**
    /// `@State` creates private, view-owned mutable state. When a `@State`
    /// property changes, SwiftUI automatically re-renders the view. The `private`
    /// keyword reinforces that this state belongs exclusively to this view.
    @State private var showClearConfirmation = false

    /// Set to a sensor ID to programmatically scroll the pill strip and center that sensor.
    ///
    /// This works together with `ScrollViewReader` inside `sensorTabs`. When set
    /// to a non-nil value, the `onChange` handler scrolls to that sensor's pill
    /// and then resets this property to `nil` (one-shot pattern).
    @State private var sensorScrollTarget: String?

    // MARK: - Body

    /// The main view body — a scrollable layout containing all History tab sections.
    ///
    /// **SwiftUI concept — GeometryReader:**
    /// `GeometryReader` is a container that exposes its parent's size via a
    /// `GeometryProxy`. Here it is used to compute the chart height dynamically
    /// so the chart fills the available vertical space after subtracting the
    /// height of the other UI elements (sensor tabs, stats row, time range row).
    ///
    /// **SwiftUI concept — .refreshable:**
    /// Adding `.refreshable` to a ScrollView enables iOS pull-to-refresh.
    /// The closure receives an `async` context so it can await BLE downloads.
    ///
    /// **SwiftUI concept — .alert:**
    /// `.alert` presents a system dialog. `isPresented` is bound to a `@State`
    /// Boolean — when it becomes `true`, the alert appears. The `role: .destructive`
    /// parameter on the "Clear" button renders it in red to warn the user.
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
            // Pull-to-refresh triggers a BLE download of new log cells.
            .refreshable {
                await historyVM.downloadNewCells()
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Data")
        .navigationBarTitleDisplayMode(.inline)
        // Navigation bar toolbar items.
        .toolbar {
            // Leading: BLE connect/disconnect button.
            ToolbarItem(placement: .topBarLeading) {
                ConnectButton()
            }
            // Trailing: refresh, clear cache, and CSV export buttons.
            ToolbarItemGroup(placement: .topBarTrailing) {
                // Manual refresh button — only shown when connected.
                if bleManager.connectionState == .connected {
                    Button {
                        Task { await historyVM.downloadNewCells() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("Download new data")
                    .disabled(historyVM.isStreaming)
                }

                // Clear cache button — triggers a confirmation alert before deleting.
                Button {
                    showClearConfirmation = true
                } label: {
                    Image(systemName: "trash")
                }
                .accessibilityLabel("Clear cached data")
                .disabled(historyVM.cachedCount == 0)

                // CSV export button — uses SwiftUI's built-in ShareLink to present
                // the system share sheet. Only shown when a CSV file URL is available.
                if let url = historyVM.csvFileURL() {
                    ShareLink(item: url) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("Export CSV")
                }
            }
        }
        // Lifecycle: configure the view model and load cached data when the view appears.
        .onAppear {
            historyVM.configure(bleManager: bleManager, modelContext: modelContext)
            historyVM.syncDeviceId(from: bleManager)
            historyVM.loadCachedCells()
            if bleManager.connectionState == .connected {
                historyVM.startAutoPoll()
                Task { await historyVM.autoDownloadIfNeeded() }
            }
        }
        // Lifecycle: stop polling when the view disappears (e.g., user switches tabs).
        .onDisappear {
            historyVM.stopAutoPoll()
        }
        // React to BLE connection state changes — start or stop auto-polling accordingly.
        //
        // **SwiftUI concept — .onChange(of:):**
        // Observes a value and calls the closure whenever it changes. The closure
        // receives the old and new values. Here we watch `bleManager.connectionState`.
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
        // Destructive confirmation alert for clearing the cache.
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

    /// A horizontal scrollable "pill strip" for selecting which sensor to chart.
    ///
    /// The layout is: ‹ [CO₂] [PM2.5] [PM10] [Temp] [Humidity] [VOC] [NOx] [Pressure] ›
    ///
    /// - Chevron buttons on the left and right cycle through sensors sequentially.
    /// - Each pill button selects that sensor and scrolls it into view.
    ///
    /// **SwiftUI concept — ScrollViewReader:**
    /// `ScrollViewReader` wraps a `ScrollView` and provides a `ScrollViewProxy`
    /// that can programmatically scroll to any child view identified by `.id()`.
    /// When `sensorScrollTarget` is set, the `onChange` handler calls
    /// `proxy.scrollTo(target, anchor: .center)` to smoothly center that pill.
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

    /// Navigate to the previous (-1) or next (+1) sensor in the pill strip.
    ///
    /// This function finds the current sensor's index in the `defs` array,
    /// adds the direction offset, clamps to valid bounds, and updates both
    /// `historyVM.selectedSensor` and `sensorScrollTarget` to trigger the
    /// selection change and scroll animation.
    ///
    /// - Parameters:
    ///   - direction: `-1` for previous, `+1` for next.
    ///   - defs: The array of sensor definitions to navigate through.
    private func navigateSensor(direction: Int, defs: [SensorDef]) {
        guard let currentId = historyVM.selectedSensor,
              let currentIdx = defs.firstIndex(where: { $0.id == currentId }) else { return }
        let targetIdx = min(max(currentIdx + direction, 0), defs.count - 1)
        let targetId = defs[targetIdx].id
        historyVM.selectedSensor = targetId
        sensorScrollTarget = targetId
    }

    /// Creates a single pill-shaped sensor tab button.
    ///
    /// When active (selected), the pill has a solid colored background with white text.
    /// When inactive, it has a faint tinted background with colored text.
    ///
    /// - Parameters:
    ///   - label: The short sensor name displayed on the pill (e.g., "CO₂").
    ///   - isActive: Whether this sensor is currently selected.
    ///   - color: The sensor's theme color.
    ///   - action: Closure called when the user taps this pill.
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

    /// A compact statistics row showing the latest value and summary statistics.
    ///
    /// Layout: `[423 ppm]          [Avg: 410  Min: 380  Max: 520]`
    ///
    /// The left side shows the most recent value in large bold text with the sensor's
    /// theme color. The right side shows average, minimum, and maximum values
    /// for the currently visible time range.
    ///
    /// This section only renders when a sensor is selected and data is available.
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

    /// A tiny vertical label+value pair used for the avg/min/max statistics.
    ///
    /// - Parameters:
    ///   - label: The statistic name ("Avg", "Min", or "Max").
    ///   - value: The formatted numeric value.
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

    /// A combined row containing time range selection pills and day navigation arrows.
    ///
    /// **Left side:** Time range buttons (1h, 24h, 7d, 30d, All). The active range
    /// is highlighted with the accent color; inactive ranges use a gray background.
    ///
    /// **Right side (24h mode only):** Day navigation arrows (< Today >) that let
    /// the user step back and forward through calendar days. This section only
    /// appears when the 24-hour time range is selected, since other ranges
    /// automatically show the most recent data.
    ///
    /// The `.animation()` modifier provides a smooth transition when the day
    /// navigation arrows appear or disappear.
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

    /// Renders the main sensor line chart, or an empty-state placeholder.
    ///
    /// This section has two states:
    /// 1. **No data** — Shows a `ContentUnavailableView` (an iOS 17+ built-in view)
    ///    with a chart icon and a message explaining how to get data.
    /// 2. **Has data** — Renders a `SensorChartView` with the filtered chart points,
    ///    the sensor's color and unit, and the current time range settings.
    ///
    /// **SwiftUI concept — ContentUnavailableView:**
    /// A system-provided empty state view with an icon, title, and description.
    /// It is commonly used when a list or chart has no data to display.
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
