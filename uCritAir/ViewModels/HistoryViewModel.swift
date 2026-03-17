import Foundation
import SwiftData
import SwiftUI
import os.log

// MARK: - Supporting Types

struct SensorDef: Identifiable {
    let id: String
    let label: String
    let shortLabel: String
    let color: String
    let unit: String
    let extract: (LogCellEntity) -> Double
    let format: (Double) -> String
}

enum TimeRange: String, CaseIterable, Identifiable {
    case oneHour = "1H"
    case oneDay = "1D"
    case sevenDays = "7D"
    case all = "All"

    var id: String { rawValue }

    var seconds: Int {
        switch self {
        case .oneHour: return 3_600
        case .oneDay: return 86_400
        case .sevenDays: return 7 * 86_400
        case .all: return .max
        }
    }
}

struct ChartPoint: Identifiable {
    let id = UUID()
    let timestamp: Int
    let value: Double?
}

struct SensorStats {
    let latest: Double
    let avg: Double
    let min: Double
    let max: Double
}

// MARK: - HistoryViewModel

@Observable
final class HistoryViewModel {

    var allCells: [LogCellEntity] = []

    var isStreaming = false

    var streamProgress: LogStreamProgress?

    var cachedCount = 0

    var error: String?

    var selectedSensor: String? = "co2"

    var timeRange: TimeRange = .oneDay

    var dayOffset = 0

    var currentDeviceId: String?

    private var bleManager: BLEManager?

    private var modelContext: ModelContext?

    private var autoPollTimer: Timer?

    private var hasAutoDownloaded = false

    private var cachedCSVURL: URL?

    private var csvCacheKeySnapshot: Int?

    private var lastLoadedCacheDeviceId: String??

    private let logger = Logger(subsystem: "com.ucritter.ucritair", category: "History")

    private static let dayLabelFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "MMM d"
        fmt.timeZone = .gmt
        return fmt
    }()

    deinit {
        autoPollTimer?.invalidate()
    }

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

    static let gapThreshold = 360

    func configure(bleManager: BLEManager, modelContext: ModelContext) {
        self.bleManager = bleManager
        self.modelContext = modelContext
    }

    var monotonicCells: [LogCellEntity] {
        TimelineFilter.filterMonotonic(allCells)
    }

    var filteredCells: [LogCellEntity] {
        let mono = monotonicCells
        guard !mono.isEmpty else { return [] }

        if timeRange == .oneDay {
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

    private func calendarDayBounds(for offset: Int) -> (start: Date, end: Date) {
        let local = Calendar.current
        let today = local.startOfDay(for: Date())
        guard let targetDay = local.date(byAdding: .day, value: offset, to: today) else {
            return (today, today)
        }
        let components = local.dateComponents([.year, .month, .day], from: targetDay)

        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = .gmt
        guard let start = utc.date(from: components),
              let end = utc.date(byAdding: .day, value: 1, to: start) else {
            return (today, today)
        }
        return (start, end)
    }

    func chartPoints(for sensorDef: SensorDef) -> [ChartPoint] {
        let cells = filteredCells
        guard !cells.isEmpty else { return [] }

        let maxPoints = 2000
        let stride = max(1, cells.count / maxPoints)
        let sampled = stride > 1
            ? Swift.stride(from: 0, to: cells.count, by: stride).map { cells[$0] }
            : cells

        var points: [ChartPoint] = []
        for i in 0..<sampled.count {
            if i > 0 && sampled[i].timestamp - sampled[i - 1].timestamp > Self.gapThreshold {
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

    var selectedSensorDef: SensorDef? {
        guard let key = selectedSensor else { return nil }
        return Self.sensorDefs.first { $0.id == key }
    }

    var dayLabel: String {
        guard timeRange == .oneDay else { return "" }
        if dayOffset == 0 { return "Today" }
        if dayOffset == -1 { return "Yesterday" }
        let (start, _) = calendarDayBounds(for: dayOffset)
        return Self.dayLabelFormatter.string(from: start)
    }

    var canGoBack: Bool {
        guard timeRange == .oneDay,
              let earliest = monotonicCells.first else { return false }
        let (currentDayStart, _) = calendarDayBounds(for: dayOffset)
        return earliest.timestamp < Int(currentDayStart.timeIntervalSince1970)
    }

    var canGoForward: Bool {
        dayOffset < 0
    }

    var chartXDomain: ClosedRange<Date>? {
        if timeRange == .oneDay {
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

    private var effectiveDeviceId: String? {
        currentDeviceId ?? bleManager?.connectedDeviceId
    }

    static func computeIncrementalDownloadPlan(
        deviceCellCount: Int,
        maxCachedCell: Int
    ) -> (startCell: Int, count: Int, requiresCacheReset: Bool) {
        let normalizedDeviceCount = max(0, deviceCellCount)

        // If the device reports fewer/equal cells than our max cached index,
        // assume the device counter was reset and force a full resync.
        if maxCachedCell >= normalizedDeviceCount, maxCachedCell >= 0 {
            return (startCell: 0, count: normalizedDeviceCount, requiresCacheReset: true)
        }

        let startCell = max(0, maxCachedCell + 1)
        let count = max(0, normalizedDeviceCount - startCell)
        return (startCell: startCell, count: count, requiresCacheReset: false)
    }

    @MainActor
    private func prepareDownloadPlan(
        using manager: BLEManager,
        context: ModelContext,
        deviceId: String
    ) async throws -> (startCell: Int, count: Int) {
        let deviceCellCount = Int(try await BLECharacteristics.readCellCount(using: manager))
        let maxCached = try LogCellStore.maxCachedCellNumber(deviceId: deviceId, context: context)
        let plan = Self.computeIncrementalDownloadPlan(
            deviceCellCount: deviceCellCount,
            maxCachedCell: maxCached
        )

        if plan.requiresCacheReset {
            logger.warning(
                "prepareDownloadPlan: detected cell-counter regression for \(deviceId) (deviceCount=\(deviceCellCount), maxCached=\(maxCached)); clearing cache and resyncing from zero"
            )
            try LogCellStore.clearAllCells(deviceId: deviceId, context: context)
            allCells = []
            cachedCount = 0
        }

        logger.info(
            "prepareDownloadPlan: deviceCount=\(deviceCellCount) maxCached=\(maxCached) startCell=\(plan.startCell) count=\(plan.count)"
        )
        return (startCell: plan.startCell, count: plan.count)
    }

    func syncDeviceId(from bleManager: BLEManager) {
        let newId = bleManager.connectedDeviceId
        logger.info("syncDeviceId: current=\(self.currentDeviceId ?? "nil") new=\(newId ?? "nil")")
        if newId != currentDeviceId {
            currentDeviceId = newId
        }
    }

    @MainActor
    func loadCachedCells(force: Bool = false) {
        let deviceId = effectiveDeviceId
        logger.info("loadCachedCells: deviceId=\(deviceId ?? "nil") hasContext=\(self.modelContext != nil)")
        if !force, lastLoadedCacheDeviceId == deviceId {
            logger.info("loadCachedCells: skipping reload for device \(deviceId ?? "nil")")
            return
        }

        lastLoadedCacheDeviceId = deviceId

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

        defer {
            isStreaming = false
            streamProgress = nil
        }

        do {
            let plan = try await prepareDownloadPlan(using: manager, context: ctx, deviceId: deviceId)

            if plan.count <= 0 {
                logger.info("No new cells to download")
                return
            }

            let newCells = try await BLELogStream.streamLogCells(
                startCell: plan.startCell,
                count: plan.count,
                using: manager
            ) { [weak self] progress in
                DispatchQueue.main.async {
                    self?.streamProgress = progress
                }
            }

            logger.info("Received \(newCells.count) cells — saving to database for device \(deviceId)")
            try LogCellStore.saveCells(newCells, deviceId: deviceId, context: ctx)

            allCells = try LogCellStore.fetchAllCells(deviceId: deviceId, context: ctx)
            cachedCount = allCells.count
            lastLoadedCacheDeviceId = deviceId
            logger.info("downloadNewCells: fetchAllCells returned \(self.allCells.count) cells")
        } catch {
            self.error = "Download failed. Check that the device is nearby and try again."
            logger.error("Download failed: \(error)")
        }
    }

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

        isStreaming = true
        streamProgress = nil

        defer {
            isStreaming = false
            streamProgress = nil
        }

        do {
            let plan = try await prepareDownloadPlan(using: manager, context: ctx, deviceId: deviceId)

            guard plan.count > 0 else { return }

            let newCells = try await BLELogStream.streamLogCells(
                startCell: plan.startCell,
                count: plan.count,
                using: manager
            ) { [weak self] progress in
                DispatchQueue.main.async {
                    self?.streamProgress = progress
                }
            }

            try LogCellStore.saveCells(newCells, deviceId: deviceId, context: ctx)
            allCells = try LogCellStore.fetchAllCells(deviceId: deviceId, context: ctx)
            cachedCount = allCells.count
            lastLoadedCacheDeviceId = deviceId
            logger.info("downloadNewCellsQuiet: saved \(newCells.count) cells, fetched \(self.allCells.count)")
        } catch {
            logger.error("downloadNewCellsQuiet failed: \(error)")
        }
    }

    @MainActor
    func clearCache() {
        guard let ctx = modelContext, let deviceId = effectiveDeviceId else { return }
        do {
            try LogCellStore.clearAllCells(deviceId: deviceId, context: ctx)
            allCells = []
            cachedCount = 0
            lastLoadedCacheDeviceId = deviceId
        } catch {
            self.error = "Failed to clear cache. Try again."
        }
    }

    func csvFileURL() -> URL? {
        let cells = allCells
        guard !cells.isEmpty else { return nil }
        let cacheKey = csvCacheKey(for: cells)
        if cacheKey == csvCacheKeySnapshot, let url = cachedCSVURL {
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
            cachedCSVURL = nil
        }
        let csv = CSVExporter.toCSV(cells)
        let url = try? CSVExporter.writeTemporaryFile(csv)
        cachedCSVURL = url
        csvCacheKeySnapshot = cacheKey
        return url
    }

    private func csvCacheKey(for cells: [LogCellEntity]) -> Int {
        var hasher = Hasher()
        hasher.combine(cells.count)
        if let first = cells.first {
            hasher.combine(first.cellNumber)
            hasher.combine(first.timestamp)
            hasher.combine(first.temperature.bitPattern)
        }
        if let last = cells.last {
            hasher.combine(last.cellNumber)
            hasher.combine(last.timestamp)
            hasher.combine(last.temperature.bitPattern)
        }
        return hasher.finalize()
    }

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

    @MainActor
    func autoDownloadIfNeeded() async {
        guard !hasAutoDownloaded, bleManager?.connectionState == .connected else { return }
        hasAutoDownloaded = true
        await downloadNewCellsQuiet()
    }


    func goBack() {
        dayOffset -= 1
    }

    func goForward() {
        dayOffset = min(0, dayOffset + 1)
    }

    func setTimeRange(_ range: TimeRange) {
        timeRange = range
        if range != .oneDay { dayOffset = 0 }
    }

    var selectedDate: Date {
        let local = Calendar.current
        let today = local.startOfDay(for: Date())
        return local.date(byAdding: .day, value: dayOffset, to: today) ?? today
    }

    var dataDateRange: ClosedRange<Date> {
        let local = Calendar.current
        let today = local.startOfDay(for: Date())
        guard let earliest = monotonicCells.first else {
            return today...today
        }
        let earliestDate = local.startOfDay(
            for: Date(timeIntervalSince1970: TimeInterval(earliest.timestamp))
        )
        return earliestDate...today
    }

    func jumpToDate(_ date: Date) {
        let local = Calendar.current
        let today = local.startOfDay(for: Date())
        let target = local.startOfDay(for: date)
        let offset = local.dateComponents([.day], from: today, to: target).day ?? 0
        dayOffset = min(0, offset)
        timeRange = .oneDay
    }
}
