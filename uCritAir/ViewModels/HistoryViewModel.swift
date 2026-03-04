import Foundation
import SwiftData
import SwiftUI
import os.log

/// Sensor definition for chart display and data extraction.
struct SensorDef: Identifiable {
    let id: String
    let label: String
    let shortLabel: String
    let color: String       // hex color
    let unit: String
    let extract: (LogCellEntity) -> Double
    let format: (Double) -> String
}

/// Time range options for filtering.
enum TimeRange: String, CaseIterable, Identifiable {
    case oneHour = "1h"
    case twentyFourHours = "24h"
    case sevenDays = "7d"
    case thirtyDays = "30d"
    case all = "All"

    var id: String { rawValue }

    var seconds: Int {
        switch self {
        case .oneHour: return 3_600
        case .twentyFourHours: return 86_400
        case .sevenDays: return 7 * 86_400
        case .thirtyDays: return 30 * 86_400
        case .all: return .max
        }
    }
}

/// A point in the chart timeline. nil value = gap marker.
struct ChartPoint: Identifiable {
    let id = UUID()
    let timestamp: Int      // Unix seconds
    let value: Double?      // nil for gap
}

/// Stats for a single sensor in the filtered range.
struct SensorStats {
    let latest: Double
    let avg: Double
    let min: Double
    let max: Double
}

/// View model for the Data tab (history + charts).
/// Ported from src/stores/logs.ts + History.tsx state.
@Observable
final class HistoryViewModel {

    // MARK: - State

    /// All log cell entities loaded from the local SwiftData cache for the current device.
    var allCells: [LogCellEntity] = []

    /// Whether a BLE log cell download is currently in progress.
    var isStreaming = false

    /// Current progress of the active log cell download stream, if any.
    var streamProgress: LogStreamProgress?

    /// Total number of log cells stored in the local SwiftData cache for the current device.
    var cachedCount = 0

    /// User-facing error message from the most recent failed operation, or `nil` if no error.
    var error: String?

    // UI state

    /// The sensor key currently selected for detailed chart display (e.g., `"co2"`, `"pm2_5"`).
    var selectedSensor: String? = "co2"

    /// Set of sensor keys currently toggled on for multi-sensor overlay display.
    var visibleSensors: Set<String> = ["co2", "pm2_5", "temperature"]

    /// The active time range filter applied to the chart and stats.
    var timeRange: TimeRange = .twentyFourHours

    /// Calendar day offset for 24-hour mode navigation. `0` = today, `-1` = yesterday, etc.
    var dayOffset = 0

    // Multi-device: which device's data to show
    var currentDeviceId: String?

    // MARK: - Dependencies

    private var bleManager: BLEManager?
    private var modelContext: ModelContext?
    private var autoPollTimer: Timer?
    private var isConfigured = false
    private var hasAutoDownloaded = false

    /// Cached CSV file URL — regenerated only when `allCells.count` changes.
    private var cachedCSVURL: URL?
    /// Cell count when ``cachedCSVURL`` was last generated.
    private var csvCellCountSnapshot: Int = 0

    private let logger = Logger(subsystem: "com.ucritter.ucritair", category: "History")

    // MARK: - Sensor Definitions (matching web app colors/scales)

    static let sensorDefs: [SensorDef] = [
        SensorDef(id: "co2", label: "CO\u{2082}", shortLabel: "CO\u{2082}",
                  color: "#ef4444", unit: "ppm",
                  extract: { Double($0.co2) },
                  format: { String(format: "%.0f", $0) }),
        SensorDef(id: "pm2_5", label: "PM2.5", shortLabel: "PM2.5",
                  color: "#f97316", unit: "µg/m³",
                  extract: { $0.pm2_5 },
                  format: { String(format: "%.1f", $0) }),
        SensorDef(id: "pm10", label: "PM10", shortLabel: "PM10",
                  color: "#eab308", unit: "µg/m³",
                  extract: { $0.pm10 },
                  format: { String(format: "%.1f", $0) }),
        SensorDef(id: "temperature", label: "Temperature", shortLabel: "Temp",
                  color: "#3b82f6", unit: "°C",
                  extract: { $0.temperature },
                  format: { String(format: "%.1f", $0) }),
        SensorDef(id: "humidity", label: "Humidity", shortLabel: "RH",
                  color: "#06b6d4", unit: "%",
                  extract: { $0.humidity },
                  format: { String(format: "%.1f", $0) }),
        SensorDef(id: "voc", label: "VOC Index", shortLabel: "VOC",
                  color: "#8b5cf6", unit: "",
                  extract: { Double($0.voc) },
                  format: { String(format: "%.0f", $0) }),
        SensorDef(id: "nox", label: "NOx Index", shortLabel: "NOx",
                  color: "#ec4899", unit: "",
                  extract: { Double($0.nox) },
                  format: { String(format: "%.0f", $0) }),
        SensorDef(id: "pressure", label: "Pressure", shortLabel: "Press",
                  color: "#6b7280", unit: "hPa",
                  extract: { $0.pressure },
                  format: { String(format: "%.1f", $0) }),
    ]

    static let gapThreshold = 360   // 6 minutes — insert chart gap if exceeded

    // MARK: - Configuration

    /// Wire up dependencies. Called from HistoryView.onAppear.
    /// Idempotent — safe to call multiple times.
    func configure(bleManager: BLEManager, modelContext: ModelContext) {
        self.bleManager = bleManager
        self.modelContext = modelContext
        isConfigured = true
    }

    // MARK: - Computed Properties

    /// Monotonically filtered cells (removes clock discontinuities).
    var monotonicCells: [LogCellEntity] {
        TimelineFilter.filterMonotonic(allCells)
    }

    /// Cells filtered by the current time range and day offset.
    var filteredCells: [LogCellEntity] {
        let mono = monotonicCells
        guard !mono.isEmpty else { return [] }

        // 24h mode: calendar-based midnight-to-midnight boundaries
        if timeRange == .twentyFourHours {
            let (dayStart, dayEnd) = calendarDayBounds(for: dayOffset)
            let startTs = Int(dayStart.timeIntervalSince1970)
            let endTs = Int(dayEnd.timeIntervalSince1970)
            return mono.filter { $0.timestamp >= startTs && $0.timestamp < endTs }
        }

        if timeRange == .all { return mono }

        guard let latestTs = mono.last?.timestamp else { return [] }
        let cutoff = latestTs - timeRange.seconds
        return mono.filter { $0.timestamp >= cutoff }
    }

    /// Compute midnight-to-midnight boundaries for a given day offset.
    /// dayOffset 0 = today, -1 = yesterday, etc.
    ///
    /// Device timestamps use "local time as epoch" — the device's local clock
    /// stored as if it were UTC. So day boundaries must be midnight of the
    /// *local calendar date*, expressed as a UTC epoch.
    private func calendarDayBounds(for offset: Int) -> (start: Date, end: Date) {
        let local = Calendar.current
        // Get the local calendar date (e.g., March 3) with offset applied
        let today = local.startOfDay(for: Date())
        guard let targetDay = local.date(byAdding: .day, value: offset, to: today) else {
            return (today, today)
        }
        let components = local.dateComponents([.year, .month, .day], from: targetDay)

        // Construct midnight of that calendar date in UTC
        // This matches the device's "local-as-epoch" scheme
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = .gmt
        guard let start = utc.date(from: components),
              let end = utc.date(byAdding: .day, value: 1, to: start) else {
            return (today, today)
        }
        return (start, end)
    }

    /// Build chart points for a sensor, inserting nil gaps for breaks > 6 min.
    func chartPoints(for sensorDef: SensorDef) -> [ChartPoint] {
        let cells = filteredCells
        guard !cells.isEmpty else { return [] }

        // Downsample if too many points for chart performance
        let maxPoints = 2000
        let stride = max(1, cells.count / maxPoints)
        let sampled = stride > 1
            ? Swift.stride(from: 0, to: cells.count, by: stride).map { cells[$0] }
            : cells

        var points: [ChartPoint] = []
        for i in 0..<sampled.count {
            if i > 0 && sampled[i].timestamp - sampled[i - 1].timestamp > Self.gapThreshold {
                // Insert nil gap marker at midpoint
                let midTs = (sampled[i - 1].timestamp + sampled[i].timestamp) / 2
                points.append(ChartPoint(timestamp: midTs, value: nil))
            }
            points.append(ChartPoint(
                timestamp: sampled[i].timestamp,
                value: sensorDef.extract(sampled[i])
            ))
        }
        return points
    }

    /// Stats for a sensor in the current filtered range.
    func stats(for sensorDef: SensorDef) -> SensorStats? {
        let cells = filteredCells
        guard !cells.isEmpty else { return nil }
        let values = cells.map { sensorDef.extract($0) }
        guard let latest = values.last,
              let minVal = values.min(),
              let maxVal = values.max() else { return nil }
        let sum = values.reduce(0, +)
        return SensorStats(
            latest: latest,
            avg: sum / Double(values.count),
            min: minVal,
            max: maxVal
        )
    }

    /// Sensor def for the currently selected individual sensor.
    var selectedSensorDef: SensorDef? {
        guard let key = selectedSensor else { return nil }
        return Self.sensorDefs.first { $0.id == key }
    }

    /// Day navigation label.
    var dayLabel: String {
        guard timeRange == .twentyFourHours else { return "" }
        if dayOffset == 0 { return "Today" }
        if dayOffset == -1 { return "Yesterday" }
        let (start, _) = calendarDayBounds(for: dayOffset)
        let fmt = DateFormatter()
        fmt.dateFormat = "MMM d"
        fmt.timeZone = .gmt  // Match device's local-as-epoch scheme
        return fmt.string(from: start)
    }

    /// Whether backward day navigation is possible.
    var canGoBack: Bool {
        guard timeRange == .twentyFourHours,
              let earliest = monotonicCells.first else { return false }
        let (currentDayStart, _) = calendarDayBounds(for: dayOffset)
        // Can go back if earliest data is before the current day's start
        return earliest.timestamp < Int(currentDayStart.timeIntervalSince1970)
    }

    /// Whether forward day navigation is possible (can't go past today).
    var canGoForward: Bool {
        dayOffset < 0
    }

    /// Explicit x-axis domain for the chart.
    /// For 24h: midnight-to-midnight (shows partial graph for today).
    /// For other ranges: data bounds with 2% right padding to prevent edge clipping.
    var chartXDomain: ClosedRange<Date>? {
        if timeRange == .twentyFourHours {
            let (start, end) = calendarDayBounds(for: dayOffset)
            return start...end
        }
        let cells = filteredCells
        guard let first = cells.first, let last = cells.last else { return nil }
        let minDate = Date(timeIntervalSince1970: TimeInterval(first.timestamp))
        let maxDate = Date(timeIntervalSince1970: TimeInterval(last.timestamp))
        let span = maxDate.timeIntervalSince(minDate)
        let paddedMax = maxDate.addingTimeInterval(max(span * 0.02, 60))
        return minDate...paddedMax
    }

    // MARK: - Device Scoping

    /// Effective device ID for data operations.
    /// Falls back to BLE-connected device if no explicit override.
    private var effectiveDeviceId: String? {
        currentDeviceId ?? bleManager?.connectedDeviceId
    }

    /// Update currentDeviceId from the connected peripheral.
    func syncDeviceId(from bleManager: BLEManager) {
        let newId = bleManager.connectedDeviceId
        logger.info("syncDeviceId: current=\(self.currentDeviceId ?? "nil") new=\(newId ?? "nil")")
        if newId != currentDeviceId {
            currentDeviceId = newId
        }
    }

    // MARK: - Actions

    /// Load all cached cells from SwiftData for the current device.
    @MainActor
    func loadCachedCells() {
        let deviceId = effectiveDeviceId
        logger.info("loadCachedCells: deviceId=\(deviceId ?? "nil") hasContext=\(self.modelContext != nil)")
        guard let ctx = modelContext, let deviceId else {
            logger.warning("loadCachedCells: skipping — missing context or deviceId")
            allCells = []
            cachedCount = 0
            return
        }
        do {
            allCells = try LogCellStore.fetchAllCells(deviceId: deviceId, context: ctx)
            cachedCount = allCells.count
            logger.info("loadCachedCells: loaded \(self.allCells.count) cells for device \(deviceId)")
        } catch {
            self.error = "Failed to load cached data. Try restarting the app."
            logger.error("loadCachedCells failed: \(error)")
        }
    }

    /// Download new cells from the device (incremental sync).
    @MainActor
    func downloadNewCells() async {
        let deviceId = effectiveDeviceId
        logger.info("downloadNewCells: deviceId=\(deviceId ?? "nil") isStreaming=\(self.isStreaming) hasContext=\(self.modelContext != nil) hasBLE=\(self.bleManager != nil)")
        guard !isStreaming,
              let manager = bleManager,
              let ctx = modelContext,
              let deviceId else {
            logger.warning("downloadNewCells: guard failed — skipping")
            return
        }
        isStreaming = true
        streamProgress = nil
        error = nil

        do {
            let deviceCellCount = try await BLECharacteristics.readCellCount(using: manager)
            let maxCached = try LogCellStore.maxCachedCellNumber(deviceId: deviceId, context: ctx)
            let startCell = maxCached + 1
            let count = Int(deviceCellCount) - startCell + 1

            logger.info("downloadNewCells: deviceCells=\(deviceCellCount) maxCached=\(maxCached) startCell=\(startCell) count=\(count)")

            if count <= 0 {
                logger.info("No new cells to download")
                isStreaming = false
                streamProgress = nil
                return
            }

            let newCells = try await BLELogStream.streamLogCells(
                startCell: startCell,
                count: count,
                using: manager
            ) { [weak self] progress in
                DispatchQueue.main.async {
                    self?.streamProgress = progress
                }
            }

            logger.info("Received \(newCells.count) cells — saving to database for device \(deviceId)")
            try LogCellStore.saveCells(newCells, deviceId: deviceId, context: ctx)

            // Reload from database to get sorted, deduplicated results
            allCells = try LogCellStore.fetchAllCells(deviceId: deviceId, context: ctx)
            cachedCount = allCells.count
            logger.info("downloadNewCells: fetchAllCells returned \(self.allCells.count) cells")
            isStreaming = false
            streamProgress = nil
        } catch {
            self.error = "Download failed. Check that the device is nearby and try again."
            logger.error("Download failed: \(error)")
            isStreaming = false
            streamProgress = nil
        }
    }

    /// Background download for auto-poll (no error banner, swallows errors).
    @MainActor
    func downloadNewCellsQuiet() async {
        let deviceId = effectiveDeviceId
        guard !isStreaming,
              let manager = bleManager,
              let ctx = modelContext,
              let deviceId else {
            logger.info("downloadNewCellsQuiet: guard failed — deviceId=\(deviceId ?? "nil")")
            return
        }
        guard manager.connectionState == .connected else { return }

        do {
            let deviceCellCount = try await BLECharacteristics.readCellCount(using: manager)
            let maxCached = try LogCellStore.maxCachedCellNumber(deviceId: deviceId, context: ctx)
            let startCell = maxCached + 1
            let count = Int(deviceCellCount) - startCell + 1

            guard count > 0 else { return }

            // Use the progress-showing path so UI isn't stuck on "Starting download..."
            isStreaming = true
            streamProgress = nil

            let newCells = try await BLELogStream.streamLogCells(
                startCell: startCell, count: count, using: manager
            ) { [weak self] progress in
                DispatchQueue.main.async {
                    self?.streamProgress = progress
                }
            }

            try LogCellStore.saveCells(newCells, deviceId: deviceId, context: ctx)
            allCells = try LogCellStore.fetchAllCells(deviceId: deviceId, context: ctx)
            cachedCount = allCells.count
            logger.info("downloadNewCellsQuiet: saved \(newCells.count) cells, fetched \(self.allCells.count)")
            isStreaming = false
            streamProgress = nil
        } catch {
            logger.error("downloadNewCellsQuiet failed: \(error)")
            isStreaming = false
            streamProgress = nil
        }
    }

    /// Clear all cached cells for the current device.
    @MainActor
    func clearCache() {
        guard let ctx = modelContext, let deviceId = effectiveDeviceId else { return }
        do {
            try LogCellStore.clearAllCells(deviceId: deviceId, context: ctx)
            allCells = []
            cachedCount = 0
        } catch {
            self.error = "Failed to clear cache. Try again."
        }
    }

    /// Generate CSV file URL for sharing.
    /// Caches the result and only regenerates when the cell count changes,
    /// since this is called from the toolbar on every view render.
    func csvFileURL() -> URL? {
        let cells = allCells
        guard !cells.isEmpty else { return nil }
        if cells.count == csvCellCountSnapshot, let url = cachedCSVURL {
            return url
        }
        let csv = CSVExporter.toCSV(cells)
        let url = try? CSVExporter.writeTemporaryFile(csv)
        cachedCSVURL = url
        csvCellCountSnapshot = cells.count
        return url
    }

    // MARK: - Auto-Poll

    /// Start auto-polling every 240 seconds (matches web app).
    func startAutoPoll() {
        stopAutoPoll()
        autoPollTimer = Timer.scheduledTimer(withTimeInterval: 240, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.downloadNewCellsQuiet()
            }
        }
    }

    func stopAutoPoll() {
        autoPollTimer?.invalidate()
        autoPollTimer = nil
        hasAutoDownloaded = false
    }

    /// One-shot quiet download on first appear when connected.
    @MainActor
    func autoDownloadIfNeeded() async {
        guard !hasAutoDownloaded, bleManager?.connectionState == .connected else { return }
        hasAutoDownloaded = true
        await downloadNewCellsQuiet()
    }

    // MARK: - UI Toggles

    func toggleSensor(_ key: String) {
        if visibleSensors.contains(key) {
            visibleSensors.remove(key)
        } else {
            visibleSensors.insert(key)
        }
    }

    func goBack() {
        dayOffset -= 1
    }

    func goForward() {
        dayOffset = min(0, dayOffset + 1)
    }

    func setTimeRange(_ range: TimeRange) {
        timeRange = range
        if range != .twentyFourHours { dayOffset = 0 }
    }
}
