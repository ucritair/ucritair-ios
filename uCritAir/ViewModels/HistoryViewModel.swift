// MARK: - HistoryViewModel.swift
// uCritAir iOS App
//
// ============================================================================
// FILE OVERVIEW
// ============================================================================
//
// This file defines `HistoryViewModel` and its supporting types, which together
// power the "Data" tab of the uCritAir iOS app. The Data tab lets users:
//
//   - View historical sensor data as interactive charts
//   - Filter data by time range (1h, 24h, 7d, 30d, all)
//   - Navigate day-by-day in 24-hour mode
//   - See summary statistics (latest, average, min, max) for each sensor
//   - Download new log cells from the device via BLE
//   - Export data as CSV for external analysis
//
// The file contains four supporting types and one ViewModel class:
//
//   1. `SensorDef` — Describes a single sensor type (CO2, PM2.5, etc.) with
//      its display properties and data extraction logic. Think of it as a
//      "column definition" for a table or chart.
//
//   2. `TimeRange` — An enum representing the available time filter options.
//      Each case knows its duration in seconds.
//
//   3. `ChartPoint` — A single data point for a Swift Charts line chart.
//      Can represent either a real value or a gap marker (nil value).
//
//   4. `SensorStats` — Computed summary statistics for a sensor within the
//      currently visible time range.
//
//   5. `HistoryViewModel` — The main ViewModel class that manages data loading,
//      BLE streaming, filtering, chart generation, and CSV export.
//
// Data Flow:
//
//   [Device Flash Memory]
//       |
//       | BLE log cell streaming (57 bytes per cell)
//       v
//   [BLELogStream] ──parse──> [ParsedLogCell] ──persist──> [SwiftData / LogCellEntity]
//                                                               |
//                                                               | fetch
//                                                               v
//                                                     [HistoryViewModel.allCells]
//                                                               |
//                                                               |-- filterMonotonic
//                                                               |-- filter by time range
//                                                               |-- chartPoints()
//                                                               |-- stats()
//                                                               v
//                                                          [SwiftUI Charts]
//
// The device stores sensor readings in flash memory as "log cells" -- 57-byte
// binary records containing a timestamp and all sensor values. The iOS app
// downloads these cells via BLE, persists them in SwiftData (SQLite), and then
// queries the local database for chart display. This means historical data is
// available even when the device is not connected.
//
// Ported from the web prototype's `src/stores/logs.ts` + `History.tsx` state.
// ============================================================================

import Foundation
import SwiftData
import SwiftUI
import os.log

// ============================================================================
// MARK: - Supporting Types
// ============================================================================

/// Describes a single sensor type for chart display and data extraction.
///
/// Think of `SensorDef` as a "column definition" for the chart system. It tells
/// the chart how to extract a sensor's value from a ``LogCellEntity``, how to
/// format it for display, and what color/label to use.
///
/// ## Why closures?
///
/// The `extract` and `format` properties are closures (functions stored as values)
/// rather than method overrides. This is the **Strategy pattern** -- each sensor
/// definition carries its own extraction and formatting logic without requiring
/// subclasses. For example:
///
/// ```swift
/// // CO2: extract as Int, format with no decimals
/// extract: { Double($0.co2) },
/// format: { String(format: "%.0f", $0) }
///
/// // Temperature: already a Double, format with one decimal
/// extract: { $0.temperature },
/// format: { String(format: "%.1f", $0) }
/// ```
///
/// This makes it trivial to add new sensors: just add a new `SensorDef` to the
/// ``HistoryViewModel/sensorDefs`` array.
///
/// ## Properties
///
/// - `id`: Unique key string (e.g., `"co2"`, `"pm2_5"`, `"temperature"`).
///   Used as a dictionary key and for SwiftUI identification.
/// - `label`: Full display name (e.g., "CO2", "PM2.5", "Temperature").
/// - `shortLabel`: Abbreviated name for compact displays (e.g., "Temp", "RH").
/// - `color`: Hex color string (e.g., "#ef4444") matching the web app's palette.
/// - `unit`: The measurement unit (e.g., "ppm", "ug/m3", "degC", "%").
/// - `extract`: A closure that pulls this sensor's value from a ``LogCellEntity``.
/// - `format`: A closure that converts a `Double` value to a display string.
struct SensorDef: Identifiable {
    let id: String
    let label: String
    let shortLabel: String
    let color: String       // hex color
    let unit: String
    let extract: (LogCellEntity) -> Double
    let format: (Double) -> String
}

/// Enumeration of time range filter options for the history chart.
///
/// Each case represents a selectable time window. The ``seconds`` property
/// converts the range to an integer duration, which is used to compute the
/// cutoff timestamp for filtering log cells.
///
/// Conforms to `CaseIterable` so SwiftUI can generate a picker with all options,
/// and to `Identifiable` (via `id`) for use in `ForEach` and `List`.
///
/// The `.twentyFourHours` case has special behavior: instead of a rolling window
/// relative to the latest data point, it uses **calendar day boundaries**
/// (midnight-to-midnight) with forward/backward navigation via ``HistoryViewModel/dayOffset``.
enum TimeRange: String, CaseIterable, Identifiable {
    case oneHour = "1h"
    case twentyFourHours = "24h"
    case sevenDays = "7d"
    case thirtyDays = "30d"
    case all = "All"

    /// Identifiable conformance — uses the raw string value as the ID.
    var id: String { rawValue }

    /// Duration of this time range in seconds.
    ///
    /// Used to compute the cutoff timestamp: `latestTimestamp - seconds`.
    /// The `.all` case returns `Int.max` to include all data.
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

/// A single data point for a Swift Charts line chart.
///
/// Each `ChartPoint` represents one position on the chart's x-y plane.
/// The ``value`` field is optional: when it is `nil`, the chart renders a
/// **gap** (a break in the line) rather than a data point. Gaps are inserted
/// by ``HistoryViewModel/chartPoints(for:)`` when consecutive log cells are
/// more than 6 minutes apart, indicating the device was powered off or out of range.
///
/// ## Why nil for gaps?
///
/// Swift Charts' `LineMark` can be configured to break the line when it encounters
/// a `nil` y-value. By inserting a `ChartPoint` with `value: nil` at the midpoint
/// between two distant timestamps, we get a clean visual break instead of a
/// misleading straight line connecting data from different time periods.
struct ChartPoint: Identifiable {
    /// Unique identifier for SwiftUI list diffing.
    let id = UUID()
    /// Unix timestamp in seconds (using the device's local-as-epoch convention).
    let timestamp: Int
    /// The sensor value at this timestamp, or `nil` to indicate a gap in the data.
    let value: Double?
}

/// Summary statistics for a single sensor within the currently filtered time range.
///
/// Computed by ``HistoryViewModel/stats(for:)`` for display in the stats panel
/// below the chart. All four values are derived from the same filtered dataset.
struct SensorStats {
    /// The most recent value (last element in the filtered array).
    let latest: Double
    /// The arithmetic mean of all values in the filtered range.
    let avg: Double
    /// The minimum value in the filtered range.
    let min: Double
    /// The maximum value in the filtered range.
    let max: Double
}

// ============================================================================
// MARK: - HistoryViewModel
// ============================================================================

/// ViewModel for the Data tab, managing historical sensor data, charts, and CSV export.
///
/// ## Responsibilities
///
/// - **Data Loading**: Fetches persisted ``LogCellEntity`` records from SwiftData
///   for the current device and stores them in ``allCells``.
///
/// - **BLE Streaming**: Downloads new log cells from the device via
///   ``BLELogStream/streamLogCells(startCell:count:using:onProgress:)``. Uses
///   an **incremental sync** strategy: only downloads cells newer than the highest
///   cell number already cached locally.
///
/// - **Time Filtering**: Applies the selected ``TimeRange`` and ``dayOffset`` to
///   produce ``filteredCells`` -- the subset of data visible in the chart.
///
/// - **Chart Point Generation**: Converts filtered cells into ``ChartPoint`` arrays
///   suitable for Swift Charts, including downsampling for performance and gap
///   insertion for data discontinuities.
///
/// - **Statistics**: Computes ``SensorStats`` (latest, average, min, max) for any
///   sensor within the filtered range.
///
/// - **CSV Export**: Generates a CSV file from all cached cells, with smart caching
///   to avoid regenerating on every toolbar render.
///
/// - **Auto-Polling**: Periodically checks for new cells every 240 seconds while
///   the device is connected, matching the web app's behavior.
///
/// ## Dependencies
///
/// - ``BLEManager``: For reading cell count and streaming log cells over BLE.
/// - ``ModelContext`` (SwiftData): For persisting and querying ``LogCellEntity`` records.
/// - ``BLELogStream``: The streaming helper that manages the notification-based
///   bulk download of log cells.
/// - ``LogCellStore``: The data access layer for ``LogCellEntity`` CRUD operations.
/// - ``CSVExporter``: Converts log cells to CSV format and writes temporary files.
/// - ``TimelineFilter``: Filters out clock discontinuities from the cell timeline.
///
/// ## Threading
///
/// Like the other ViewModels, all mutating operations are `@MainActor`. The BLE
/// streaming callbacks use `DispatchQueue.main.async` to hop to the main thread
/// for progress updates.
///
/// ## The @Observable Macro
///
/// All stored properties are automatically tracked by SwiftUI. When `allCells`,
/// `timeRange`, `dayOffset`, or `selectedSensor` change, the computed properties
/// (`filteredCells`, `chartPoints`, `stats`) are re-evaluated, and any SwiftUI
/// views reading them will re-render.
@Observable
final class HistoryViewModel {

    // MARK: - Data State
    //
    // These properties hold the raw and derived data from the SwiftData cache.
    // They are populated by `loadCachedCells()` and `downloadNewCells()`.

    /// All log cell entities loaded from the local SwiftData cache for the current device.
    ///
    /// This is the **master dataset** from which all filtered views, charts, and
    /// statistics are derived. Cells are sorted by ``LogCellEntity/cellNumber``
    /// (ascending) and scoped to a single device via ``effectiveDeviceId``.
    ///
    /// - Read by: ``monotonicCells``, ``filteredCells``, ``chartPoints(for:)``,
    ///   ``stats(for:)``, ``csvFileURL()``
    /// - Written by: ``loadCachedCells()``, ``downloadNewCells()``,
    ///   ``downloadNewCellsQuiet()``, ``clearCache()``
    var allCells: [LogCellEntity] = []

    /// Whether a BLE log cell download is currently in progress.
    ///
    /// Used as a guard to prevent overlapping downloads (only one stream can run
    /// at a time) and to show/hide the progress indicator in the UI.
    ///
    /// - Read by: `HistoryView` (progress UI, button state)
    /// - Written by: ``downloadNewCells()``, ``downloadNewCellsQuiet()``
    var isStreaming = false

    /// Current progress of the active log cell download stream, if any.
    ///
    /// The ``LogStreamProgress`` struct contains fields like `downloaded`,
    /// `total`, and `percentage`. Updated via the progress callback in
    /// ``BLELogStream/streamLogCells(startCell:count:using:onProgress:)``.
    ///
    /// - Read by: `HistoryView` (progress bar and text)
    /// - Written by: ``downloadNewCells()`` and ``downloadNewCellsQuiet()`` progress callbacks
    var streamProgress: LogStreamProgress?

    /// Total number of log cells stored in the local SwiftData cache for the current device.
    ///
    /// This is a convenience property that mirrors `allCells.count` and is set
    /// at the same time as ``allCells``. It exists separately so the UI can
    /// display the count without triggering a dependency on the full array.
    ///
    /// - Read by: `HistoryView` (sync status display)
    /// - Written by: ``loadCachedCells()``, ``downloadNewCells()``,
    ///   ``downloadNewCellsQuiet()``, ``clearCache()``
    var cachedCount = 0

    /// User-facing error message from the most recent failed operation, or `nil` if no error.
    ///
    /// - Read by: `HistoryView` (error banner)
    /// - Written by: Various methods on error.
    var error: String?

    // MARK: - UI State
    //
    // These properties control the chart's visual configuration: which sensor
    // is selected, which sensors are visible, and what time window is shown.
    // They are written by user interactions (picker changes, button taps) and
    // read by the chart rendering logic.

    /// The sensor key currently selected for detailed (single-sensor) chart display.
    ///
    /// When non-nil, the chart shows a single sensor's data with full y-axis
    /// resolution and detailed statistics. Examples: `"co2"`, `"pm2_5"`, `"temperature"`.
    /// Defaults to `"co2"` (carbon dioxide).
    ///
    /// - Read by: ``selectedSensorDef``, `HistoryView` (chart rendering)
    /// - Written by: User selection in the sensor picker.
    var selectedSensor: String? = "co2"

    /// Set of sensor keys currently toggled on for multi-sensor overlay display.
    ///
    /// In the overview mode, multiple sensors can be displayed simultaneously on
    /// the same chart (each with its own color). This set tracks which ones are
    /// visible. Defaults to CO2, PM2.5, and temperature.
    ///
    /// - Read by: `HistoryView` (multi-sensor chart)
    /// - Written by: ``toggleSensor(_:)``
    var visibleSensors: Set<String> = ["co2", "pm2_5", "temperature"]

    /// The active time range filter applied to the chart and statistics.
    ///
    /// Determines how much historical data is shown. The ``filteredCells`` computed
    /// property uses this to filter ``monotonicCells`` by timestamp.
    ///
    /// - Read by: ``filteredCells``, ``calendarDayBounds(for:)``, ``chartXDomain``,
    ///   ``dayLabel``, ``canGoBack``, `HistoryView` (range picker)
    /// - Written by: ``setTimeRange(_:)``
    var timeRange: TimeRange = .twentyFourHours

    /// Calendar day offset for 24-hour mode navigation.
    ///
    /// Only meaningful when ``timeRange`` is `.twentyFourHours`. Values:
    ///   - `0` = today
    ///   - `-1` = yesterday
    ///   - `-2` = two days ago
    ///   - etc.
    ///
    /// Positive values are not allowed (cannot navigate into the future).
    ///
    /// - Read by: ``filteredCells``, ``calendarDayBounds(for:)``, ``dayLabel``,
    ///   ``canGoForward``
    /// - Written by: ``goBack()``, ``goForward()``, ``setTimeRange(_:)``
    var dayOffset = 0

    /// The device ID whose data is currently displayed.
    ///
    /// In a multi-device setup, the user can switch between devices on the Data tab.
    /// This property overrides the connected device when set. If `nil`, falls back
    /// to the currently BLE-connected device via ``effectiveDeviceId``.
    ///
    /// - Read by: ``effectiveDeviceId``
    /// - Written by: ``syncDeviceId(from:)``, external assignment from parent views
    var currentDeviceId: String?

    // MARK: - Dependencies
    //
    // Private properties for service dependencies and internal bookkeeping.

    /// Reference to the shared BLE manager for reading cell count and streaming.
    private var bleManager: BLEManager?

    /// SwiftData model context for persisting and querying log cell entities.
    ///
    /// - Important: Not thread-safe. All access must be on `@MainActor`.
    private var modelContext: ModelContext?

    /// Timer for the automatic periodic download (every 240 seconds).
    /// See ``startAutoPoll()`` and ``stopAutoPoll()``.
    private var autoPollTimer: Timer?

    /// Guard flag to prevent redundant calls to ``configure(bleManager:modelContext:)``.
    private var isConfigured = false

    /// Guard flag ensuring ``autoDownloadIfNeeded()`` only fires once per session.
    private var hasAutoDownloaded = false

    /// Cached CSV file URL -- regenerated only when `allCells.count` changes.
    ///
    /// CSV generation is expensive for large datasets. Since ``csvFileURL()`` is
    /// called from the toolbar on every SwiftUI render cycle, we cache the result
    /// and only regenerate when the data actually changes (detected by comparing
    /// `allCells.count` with ``csvCellCountSnapshot``).
    private var cachedCSVURL: URL?

    /// The `allCells.count` value when ``cachedCSVURL`` was last generated.
    /// Used to detect when the CSV needs to be regenerated.
    private var csvCellCountSnapshot: Int = 0

    /// Unified logger for this ViewModel. Messages appear in Console.app under
    /// the subsystem "com.ucritter.ucritair" with category "History".
    private let logger = Logger(subsystem: "com.ucritter.ucritair", category: "History")

    // MARK: - Sensor Definitions
    //
    // This static array defines the complete catalog of sensors that the app
    // can display in charts. Each `SensorDef` acts like a "column definition"
    // that tells the chart system:
    //   - How to identify this sensor (id, label, shortLabel)
    //   - How to display it (color, unit)
    //   - How to extract the value from a LogCellEntity (extract closure)
    //   - How to format the value for display (format closure)
    //
    // The order of this array determines the order sensors appear in the UI
    // (picker, legend, stats panel). Colors are chosen to match the web app's
    // Tailwind CSS palette for visual consistency across platforms.
    //
    // To add a new sensor in the future:
    //   1. Add the property to LogCellEntity (and its parsing in BLEParsers).
    //   2. Add a new SensorDef entry here with appropriate extract/format closures.
    //   3. The chart and stats UI will automatically pick it up.

    /// The complete catalog of sensor definitions for chart display.
    ///
    /// Each entry describes one sensor type with its display metadata and data
    /// extraction logic. The `extract` closure pulls the sensor's value from a
    /// ``LogCellEntity``, and the `format` closure converts it to a display string.
    ///
    /// Sensor order and colors match the web app for cross-platform consistency:
    ///   - **CO2** (red): Carbon dioxide concentration in parts per million.
    ///   - **PM2.5** (orange): Fine particulate matter (< 2.5 micrometers).
    ///   - **PM10** (yellow): Coarse particulate matter (< 10 micrometers).
    ///   - **Temperature** (blue): Ambient temperature in degrees Celsius.
    ///   - **Humidity** (cyan): Relative humidity as a percentage.
    ///   - **VOC** (purple): Volatile organic compound index (0-510, unitless).
    ///   - **NOx** (pink): Nitrogen oxide index (0-255, unitless).
    ///   - **Pressure** (gray): Barometric pressure in hectopascals.
    static let sensorDefs: [SensorDef] = [
        SensorDef(id: "co2", label: "CO\u{2082}", shortLabel: "CO\u{2082}",
                  color: "#ef4444", unit: "ppm",
                  extract: { Double($0.co2) },         // co2 is Int, convert to Double for charting
                  format: { String(format: "%.0f", $0) }),  // No decimals (e.g., "412")
        SensorDef(id: "pm2_5", label: "PM2.5", shortLabel: "PM2.5",
                  color: "#f97316", unit: "µg/m³",
                  extract: { $0.pm2_5 },               // Already a Double
                  format: { String(format: "%.1f", $0) }),  // One decimal (e.g., "12.3")
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
                  extract: { Double($0.voc) },         // voc is Int, convert to Double
                  format: { String(format: "%.0f", $0) }),
        SensorDef(id: "nox", label: "NOx Index", shortLabel: "NOx",
                  color: "#ec4899", unit: "",
                  extract: { Double($0.nox) },         // nox is Int, convert to Double
                  format: { String(format: "%.0f", $0) }),
        SensorDef(id: "pressure", label: "Pressure", shortLabel: "Press",
                  color: "#6b7280", unit: "hPa",
                  extract: { $0.pressure },
                  format: { String(format: "%.1f", $0) }),
    ]

    /// Time gap threshold in seconds (6 minutes) for chart gap insertion.
    ///
    /// When two consecutive log cells have timestamps more than 6 minutes apart,
    /// ``chartPoints(for:)`` inserts a gap marker (a ``ChartPoint`` with `nil` value)
    /// between them. This causes the chart line to break, visually indicating that
    /// the device was off, out of range, or not logging during that period.
    ///
    /// The threshold of 360 seconds (6 minutes) was chosen because the device's
    /// default logging interval is 60 seconds. A gap of 6x the logging interval
    /// strongly indicates a genuine data discontinuity rather than a minor timing
    /// variation.
    static let gapThreshold = 360

    // MARK: - Configuration

    /// Wire up the BLE manager and SwiftData context dependencies.
    ///
    /// Called from `HistoryView.onAppear`. **Idempotent** -- safe to call multiple
    /// times (e.g., if the view disappears and reappears). Simply overwrites the
    /// stored references. Does not perform any data loading; call ``loadCachedCells()``
    /// separately after configuration.
    ///
    /// - Parameters:
    ///   - bleManager: The shared ``BLEManager`` for BLE operations.
    ///   - modelContext: The SwiftData ``ModelContext`` for database operations.
    func configure(bleManager: BLEManager, modelContext: ModelContext) {
        self.bleManager = bleManager
        self.modelContext = modelContext
        isConfigured = true
    }

    // MARK: - Computed Properties
    //
    // These computed properties form a **data pipeline** that transforms the raw
    // `allCells` array into chart-ready data:
    //
    //   allCells → monotonicCells → filteredCells → chartPoints() / stats()
    //
    // Because these are computed properties on an @Observable class, SwiftUI
    // re-evaluates them only when their underlying dependencies change. For
    // example, changing `timeRange` causes `filteredCells` to be recomputed,
    // which in turn causes `chartPoints()` and `stats()` to produce new values,
    // and the chart view re-renders.

    /// The ``allCells`` array with clock discontinuities removed.
    ///
    /// The device's RTC (Real-Time Clock) can be reset or jump backwards when
    /// the user syncs time or replaces the battery. This produces "time travel"
    /// in the raw data: a cell at timestamp 1000, then another at timestamp 500.
    /// ``TimelineFilter/filterMonotonic(_:)`` removes cells where the timestamp
    /// decreases compared to the previous cell, ensuring a strictly increasing
    /// timeline for correct chart rendering.
    ///
    /// - Complexity: O(n) where n is the number of cells.
    var monotonicCells: [LogCellEntity] {
        TimelineFilter.filterMonotonic(allCells)
    }

    /// The subset of ``monotonicCells`` visible in the current time window.
    ///
    /// This is the primary data source for charts and statistics. The filtering
    /// logic depends on the current ``timeRange``:
    ///
    /// - **24-hour mode** (`.twentyFourHours`): Uses calendar-based midnight-to-midnight
    ///   boundaries computed by ``calendarDayBounds(for:)``. The ``dayOffset`` property
    ///   controls which day is shown (0 = today, -1 = yesterday, etc.).
    ///
    /// - **All mode** (`.all`): Returns all monotonic cells with no filtering.
    ///
    /// - **Other modes** (1h, 7d, 30d): Computes a cutoff timestamp relative to
    ///   the **latest** data point (not the current time). This means the window
    ///   is anchored to the most recent data, not to "now", which avoids showing
    ///   empty charts when the device has been offline.
    ///
    /// - Complexity: O(n) where n is the number of monotonic cells.
    var filteredCells: [LogCellEntity] {
        let mono = monotonicCells
        guard !mono.isEmpty else { return [] }

        // 24h mode: calendar-based midnight-to-midnight boundaries.
        if timeRange == .twentyFourHours {
            let (dayStart, dayEnd) = calendarDayBounds(for: dayOffset)
            let startTs = Int(dayStart.timeIntervalSince1970)
            let endTs = Int(dayEnd.timeIntervalSince1970)
            return mono.filter { $0.timestamp >= startTs && $0.timestamp < endTs }
        }

        // "All" mode: return everything.
        if timeRange == .all { return mono }

        // Rolling window: cutoff is relative to the latest data point.
        guard let latestTs = mono.last?.timestamp else { return [] }
        let cutoff = latestTs - timeRange.seconds
        return mono.filter { $0.timestamp >= cutoff }
    }

    /// Compute midnight-to-midnight boundaries for a given calendar day offset.
    ///
    /// This method handles the device's unusual "local time as epoch" timestamp
    /// convention. The device stores local wall-clock time as if it were UTC.
    /// For example, if the local time is 3:00 PM PST, the device stores the Unix
    /// epoch value for 3:00 PM **UTC** (not PST). This means:
    ///   - "Midnight March 3 local" should be compared against the UTC epoch
    ///     value for "midnight March 3 UTC".
    ///
    /// The algorithm:
    ///   1. Compute the local calendar date with the offset applied (e.g., today - 1 = yesterday).
    ///   2. Extract just the year/month/day components.
    ///   3. Reconstruct a `Date` from those components using a **UTC calendar**.
    ///   4. The result is "midnight of that local calendar date, expressed in UTC epoch".
    ///
    /// - Parameter offset: Day offset (0 = today, -1 = yesterday, etc.).
    /// - Returns: A tuple of (start, end) `Date` values representing the 24-hour window.
    private func calendarDayBounds(for offset: Int) -> (start: Date, end: Date) {
        let local = Calendar.current
        // Step 1: Get the local calendar date (e.g., March 3) with offset applied.
        let today = local.startOfDay(for: Date())
        guard let targetDay = local.date(byAdding: .day, value: offset, to: today) else {
            return (today, today)
        }
        // Step 2: Extract just the date components (ignore time zone).
        let components = local.dateComponents([.year, .month, .day], from: targetDay)

        // Step 3: Construct midnight of that calendar date in UTC.
        // This matches the device's "local-as-epoch" scheme.
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = .gmt
        guard let start = utc.date(from: components),
              let end = utc.date(byAdding: .day, value: 1, to: start) else {
            return (today, today)
        }
        // Step 4: Return the 24-hour window [start, end).
        return (start, end)
    }

    /// Build an array of ``ChartPoint`` values for a specific sensor, suitable for
    /// rendering with Swift Charts.
    ///
    /// This method performs three transformations on ``filteredCells``:
    ///
    /// **1. Downsampling**: If there are more than 2000 cells, every Nth cell is
    /// sampled (where N = cells.count / 2000). This prevents chart rendering from
    /// becoming sluggish with very large datasets. For example, 10,000 cells would
    /// be downsampled to every 5th cell (~2000 points).
    ///
    /// **2. Gap insertion**: When two consecutive cells are more than
    /// ``gapThreshold`` seconds (6 minutes) apart, a ``ChartPoint`` with `nil`
    /// value is inserted at the midpoint timestamp. This causes Swift Charts to
    /// break the line, visually indicating a data gap (device was off, etc.).
    ///
    /// **3. Value extraction**: Each cell's sensor value is extracted using the
    /// ``SensorDef/extract`` closure. This decouples the chart rendering from the
    /// specific sensor being displayed -- the same method works for CO2, temperature,
    /// humidity, etc.
    ///
    /// - Parameter sensorDef: The ``SensorDef`` describing which sensor to chart.
    /// - Returns: An array of ``ChartPoint`` values ready for Swift Charts.
    func chartPoints(for sensorDef: SensorDef) -> [ChartPoint] {
        let cells = filteredCells
        guard !cells.isEmpty else { return [] }

        // --- Downsampling ---
        // Limit to 2000 points max for chart performance.
        // `stride` determines how many cells to skip between samples.
        let maxPoints = 2000
        let stride = max(1, cells.count / maxPoints)
        let sampled = stride > 1
            ? Swift.stride(from: 0, to: cells.count, by: stride).map { cells[$0] }
            : cells

        var points: [ChartPoint] = []
        for i in 0..<sampled.count {
            // --- Gap insertion ---
            // If the time between this cell and the previous one exceeds 6 minutes,
            // insert a nil-valued ChartPoint at the midpoint to break the chart line.
            if i > 0 && sampled[i].timestamp - sampled[i - 1].timestamp > Self.gapThreshold {
                let midTs = (sampled[i - 1].timestamp + sampled[i].timestamp) / 2
                points.append(ChartPoint(timestamp: midTs, value: nil))
            }
            // --- Value extraction ---
            // Use the SensorDef's extract closure to pull the relevant value.
            points.append(ChartPoint(
                timestamp: sampled[i].timestamp,
                value: sensorDef.extract(sampled[i])
            ))
        }
        return points
    }

    /// Compute summary statistics for a sensor within the current filtered range.
    ///
    /// Extracts all values for the given sensor from ``filteredCells``, then computes:
    ///   - **latest**: The most recent value (last element).
    ///   - **avg**: Arithmetic mean of all values.
    ///   - **min**: Minimum value in the range.
    ///   - **max**: Maximum value in the range.
    ///
    /// Returns `nil` if there are no cells in the filtered range.
    ///
    /// - Parameter sensorDef: The ``SensorDef`` describing which sensor to compute stats for.
    /// - Returns: A ``SensorStats`` struct, or `nil` if no data is available.
    /// - Complexity: O(n) where n is the number of filtered cells.
    func stats(for sensorDef: SensorDef) -> SensorStats? {
        let cells = filteredCells
        guard !cells.isEmpty else { return nil }
        // Extract all values for this sensor using the SensorDef's extract closure.
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

    /// The ``SensorDef`` for the currently selected individual sensor.
    ///
    /// Looks up the sensor definition by matching ``selectedSensor`` against the
    /// ``sensorDefs`` array's `id` field. Returns `nil` if no sensor is selected
    /// or if the key does not match any known sensor.
    var selectedSensorDef: SensorDef? {
        guard let key = selectedSensor else { return nil }
        return Self.sensorDefs.first { $0.id == key }
    }

    /// Human-readable label for the current day in 24-hour navigation mode.
    ///
    /// Returns:
    ///   - `"Today"` when `dayOffset == 0`
    ///   - `"Yesterday"` when `dayOffset == -1`
    ///   - A formatted date string (e.g., `"Mar 1"`) for older days
    ///   - An empty string when not in 24-hour mode
    ///
    /// The date formatter uses GMT timezone to match the device's "local-as-epoch"
    /// convention (since ``calendarDayBounds(for:)`` returns UTC-based dates).
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

    /// Whether the user can navigate to the previous (older) day.
    ///
    /// Only applicable in 24-hour mode. Returns `true` if the earliest data point
    /// in ``monotonicCells`` predates the start of the currently displayed day.
    /// This prevents the user from navigating to empty days before any data exists.
    var canGoBack: Bool {
        guard timeRange == .twentyFourHours,
              let earliest = monotonicCells.first else { return false }
        let (currentDayStart, _) = calendarDayBounds(for: dayOffset)
        // Can go back if earliest data is before the current day's start.
        return earliest.timestamp < Int(currentDayStart.timeIntervalSince1970)
    }

    /// Whether the user can navigate to the next (newer) day.
    ///
    /// Only applicable in 24-hour mode. Returns `true` if ``dayOffset`` is negative
    /// (i.e., the user is viewing a past day). Cannot navigate forward past today
    /// (dayOffset 0).
    var canGoForward: Bool {
        dayOffset < 0
    }

    /// The explicit x-axis domain for the Swift Charts chart.
    ///
    /// By default, Swift Charts auto-scales the x-axis to fit the data. However,
    /// for the 24-hour mode, we want the x-axis to always show midnight-to-midnight
    /// even if data only covers part of the day. For other time ranges, we use the
    /// data bounds with 2% right padding to prevent the last data point from being
    /// clipped at the chart edge.
    ///
    /// - Returns: A `ClosedRange<Date>` for the chart x-axis, or `nil` if no data.
    var chartXDomain: ClosedRange<Date>? {
        // 24-hour mode: fixed midnight-to-midnight range.
        if timeRange == .twentyFourHours {
            let (start, end) = calendarDayBounds(for: dayOffset)
            return start...end
        }
        // Other modes: data bounds with right padding.
        let cells = filteredCells
        guard let first = cells.first, let last = cells.last else { return nil }
        let minDate = Date(timeIntervalSince1970: TimeInterval(first.timestamp))
        let maxDate = Date(timeIntervalSince1970: TimeInterval(last.timestamp))
        let span = maxDate.timeIntervalSince(minDate)
        // Add 2% padding on the right (minimum 60 seconds) to prevent edge clipping.
        let paddedMax = maxDate.addingTimeInterval(max(span * 0.02, 60))
        return minDate...paddedMax
    }

    // MARK: - Device Scoping
    //
    // In a multi-device setup, the user might be viewing data from a device that
    // is NOT currently connected (e.g., browsing cached history from a bedroom
    // device while connected to an office device). These properties manage which
    // device's data is displayed.

    /// The device ID used for all data operations (load, download, clear).
    ///
    /// This computed property implements a **fallback chain**:
    ///   1. If ``currentDeviceId`` is explicitly set (e.g., by the device picker),
    ///      use that.
    ///   2. Otherwise, fall back to the currently BLE-connected device's ID.
    ///
    /// Returns `nil` if no device is selected and no device is connected.
    private var effectiveDeviceId: String? {
        currentDeviceId ?? bleManager?.connectedDeviceId
    }

    /// Synchronize ``currentDeviceId`` with the BLE-connected peripheral.
    ///
    /// Called when the Data tab appears or when the connection state changes.
    /// If the connected device has changed (e.g., user switched devices), updates
    /// ``currentDeviceId`` to match. This triggers a data reload in the view.
    ///
    /// - Parameter bleManager: The ``BLEManager`` to read the connected device ID from.
    func syncDeviceId(from bleManager: BLEManager) {
        let newId = bleManager.connectedDeviceId
        logger.info("syncDeviceId: current=\(self.currentDeviceId ?? "nil") new=\(newId ?? "nil")")
        if newId != currentDeviceId {
            currentDeviceId = newId
        }
    }

    // MARK: - Data Actions
    //
    // Methods that load, download, and manage the log cell data.
    // All are @MainActor because they touch SwiftData and @Observable properties.

    /// Load all cached log cells from SwiftData for the current device.
    ///
    /// Queries the ``LogCellStore`` for all ``LogCellEntity`` records matching
    /// ``effectiveDeviceId``, sorted by cell number. The results are stored in
    /// ``allCells`` and ``cachedCount``.
    ///
    /// This is a **synchronous** operation (no BLE involved -- just a local
    /// database query). It is called:
    ///   - When the Data tab first appears
    ///   - After a download completes
    ///   - When the user switches devices
    ///
    /// If no device ID or model context is available, the method gracefully clears
    /// the data rather than crashing.
    ///
    /// - Side Effects: Updates ``allCells`` and ``cachedCount``. On failure, sets ``error``.
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

    /// Download new log cells from the connected device via BLE (incremental sync).
    ///
    /// This is the primary user-initiated download action. It uses an **incremental
    /// sync strategy** to avoid re-downloading cells that are already cached:
    ///
    /// 1. Read the device's total cell count from BLE.
    /// 2. Query SwiftData for the highest cell number already cached locally.
    /// 3. Calculate how many new cells need to be downloaded:
    ///    `count = deviceCellCount - maxCachedCellNumber`
    /// 4. If count > 0, stream the new cells via ``BLELogStream/streamLogCells(startCell:count:using:onProgress:)``.
    /// 5. Save the downloaded cells to SwiftData.
    /// 6. Reload ``allCells`` from the database to get a clean, sorted, deduplicated result.
    ///
    /// The streaming process uses BLE notifications for bulk transfer: the app
    /// writes a "start streaming" command to the device, and the device sends log
    /// cells back as a rapid sequence of BLE notifications. This is much faster
    /// than reading cells one-by-one.
    ///
    /// Progress updates are delivered via a callback closure that runs on the main
    /// thread, updating ``streamProgress`` for the UI progress bar.
    ///
    /// **Guard conditions**: The method is a no-op if:
    ///   - A download is already in progress (``isStreaming``)
    ///   - BLE manager, model context, or device ID is missing
    ///
    /// - Side Effects: Sets ``isStreaming``, ``streamProgress``, ``error``,
    ///   ``allCells``, ``cachedCount``.
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

        // Mark the download as in-progress and clear any previous error.
        isStreaming = true
        streamProgress = nil
        error = nil

        do {
            // Step 1: Read the device's total cell count.
            let deviceCellCount = try await BLECharacteristics.readCellCount(using: manager)

            // Step 2: Find the highest cell number already in our local cache.
            let maxCached = try LogCellStore.maxCachedCellNumber(deviceId: deviceId, context: ctx)

            // Step 3: Calculate the range of new cells to download.
            let startCell = maxCached + 1
            let count = Int(deviceCellCount) - startCell + 1

            logger.info("downloadNewCells: deviceCells=\(deviceCellCount) maxCached=\(maxCached) startCell=\(startCell) count=\(count)")

            // No new cells -- we are already up to date.
            if count <= 0 {
                logger.info("No new cells to download")
                isStreaming = false
                streamProgress = nil
                return
            }

            // Step 4: Stream the new cells from the device via BLE notifications.
            // The progress callback runs on the main thread to safely update the UI.
            let newCells = try await BLELogStream.streamLogCells(
                startCell: startCell,
                count: count,
                using: manager
            ) { [weak self] progress in
                DispatchQueue.main.async {
                    self?.streamProgress = progress
                }
            }

            // Step 5: Persist the downloaded cells to SwiftData.
            logger.info("Received \(newCells.count) cells — saving to database for device \(deviceId)")
            try LogCellStore.saveCells(newCells, deviceId: deviceId, context: ctx)

            // Step 6: Reload from database to get a sorted, deduplicated result.
            // This is safer than manually merging arrays because SwiftData handles
            // the composite key uniqueness constraint.
            allCells = try LogCellStore.fetchAllCells(deviceId: deviceId, context: ctx)
            cachedCount = allCells.count
            logger.info("downloadNewCells: fetchAllCells returned \(self.allCells.count) cells")
            isStreaming = false
            streamProgress = nil
        } catch {
            self.error = "Download failed. Check that the device is nearby and try again."
            logger.error("Download failed: \(error)")
            // Always clean up streaming state, even on error.
            isStreaming = false
            streamProgress = nil
        }
    }

    /// Download new log cells silently in the background (no error banner).
    ///
    /// This is the "quiet" variant of ``downloadNewCells()`` used by the
    /// auto-poll timer and the initial auto-download. It behaves identically
    /// except:
    ///   - It does **not** set ``error`` on failure (errors are logged but not
    ///     shown to the user, since background failures are expected when the
    ///     device goes out of range).
    ///   - It adds an extra guard: only proceeds if the device is `.connected`.
    ///
    /// This prevents the UI from showing error banners for routine background
    /// sync attempts that fail due to BLE range or timing issues.
    ///
    /// - Side Effects: Updates ``isStreaming``, ``streamProgress``, ``allCells``,
    ///   ``cachedCount``. Does NOT set ``error``.
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
        // Extra guard: only attempt background downloads when actually connected.
        guard manager.connectionState == .connected else { return }

        do {
            let deviceCellCount = try await BLECharacteristics.readCellCount(using: manager)
            let maxCached = try LogCellStore.maxCachedCellNumber(deviceId: deviceId, context: ctx)
            let startCell = maxCached + 1
            let count = Int(deviceCellCount) - startCell + 1

            guard count > 0 else { return }

            // Show progress UI even for background downloads so the user sees activity.
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
            // Silently log the error -- do NOT set self.error for background downloads.
            logger.error("downloadNewCellsQuiet failed: \(error)")
            isStreaming = false
            streamProgress = nil
        }
    }

    /// Delete all cached log cells for the current device from SwiftData.
    ///
    /// This is a destructive operation that frees disk space by removing all
    /// ``LogCellEntity`` records for ``effectiveDeviceId``. After clearing,
    /// the user can re-download from the device if needed.
    ///
    /// - Side Effects: Deletes from SwiftData, clears ``allCells`` and ``cachedCount``.
    ///   On failure, sets ``error``.
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

    /// Generate a CSV file URL for sharing via the iOS share sheet.
    ///
    /// Converts all cached cells to CSV format using ``CSVExporter`` and writes
    /// the result to a temporary file. The URL can be passed to `ShareLink` or
    /// `UIActivityViewController`.
    ///
    /// **Performance optimization**: This method is called from the toolbar button
    /// on every SwiftUI render cycle (because SwiftUI re-evaluates `body` frequently).
    /// To avoid regenerating the CSV on every render, we **cache** the result and
    /// only regenerate when `allCells.count` changes. This is tracked by comparing
    /// the current count against ``csvCellCountSnapshot``.
    ///
    /// - Returns: A file `URL` pointing to the temporary CSV file, or `nil` if no data.
    func csvFileURL() -> URL? {
        let cells = allCells
        guard !cells.isEmpty else { return nil }
        // Return cached URL if the data hasn't changed.
        if cells.count == csvCellCountSnapshot, let url = cachedCSVURL {
            return url
        }
        // Generate fresh CSV and cache it.
        let csv = CSVExporter.toCSV(cells)
        let url = try? CSVExporter.writeTemporaryFile(csv)
        cachedCSVURL = url
        csvCellCountSnapshot = cells.count
        return url
    }

    // MARK: - Auto-Poll
    //
    // The auto-poll system periodically checks for new log cells while the device
    // is connected. This matches the web app's behavior of polling every 240 seconds
    // (4 minutes). The device logs a new cell roughly every 60 seconds, so polling
    // every 4 minutes typically picks up ~4 new cells per poll.

    /// Start the automatic periodic download timer.
    ///
    /// Creates a repeating `Timer` that fires every 240 seconds (4 minutes) and
    /// calls ``downloadNewCellsQuiet()`` to fetch any new cells. The timer closure
    /// creates a `Task` to bridge from the synchronous timer callback to the async
    /// download method.
    ///
    /// Calling this method when a timer is already running is safe -- it stops the
    /// existing timer first via ``stopAutoPoll()``.
    ///
    /// - Note: The timer is scheduled on the current run loop, which is the main
    ///   run loop since this is called from a SwiftUI view.
    func startAutoPoll() {
        stopAutoPoll()
        autoPollTimer = Timer.scheduledTimer(withTimeInterval: 240, repeats: true) { [weak self] _ in
            // Bridge from synchronous Timer callback to async download method.
            Task { @MainActor [weak self] in
                await self?.downloadNewCellsQuiet()
            }
        }
    }

    /// Stop the automatic periodic download timer and reset the auto-download flag.
    ///
    /// Called when the Data tab disappears, the device disconnects, or before
    /// starting a new timer in ``startAutoPoll()``.
    func stopAutoPoll() {
        autoPollTimer?.invalidate()
        autoPollTimer = nil
        hasAutoDownloaded = false
    }

    /// Perform a one-shot quiet download on the first appearance of the Data tab.
    ///
    /// This ensures the user sees fresh data immediately when they navigate to the
    /// Data tab, without waiting for the first auto-poll tick (which could be up to
    /// 4 minutes away).
    ///
    /// The ``hasAutoDownloaded`` flag ensures this only fires once per session
    /// (reset by ``stopAutoPoll()`` when the tab disappears).
    ///
    /// - Guard: Only fires if connected and not already downloaded this session.
    @MainActor
    func autoDownloadIfNeeded() async {
        guard !hasAutoDownloaded, bleManager?.connectionState == .connected else { return }
        hasAutoDownloaded = true
        await downloadNewCellsQuiet()
    }

    // MARK: - UI Toggles
    //
    // Simple methods that modify UI state properties in response to user actions.
    // These are called by button tap handlers in the view layer.

    /// Toggle whether a sensor is visible in the multi-sensor overlay chart.
    ///
    /// If the sensor is currently in ``visibleSensors``, it is removed (hidden).
    /// If not present, it is added (shown). Uses Swift's `Set` for O(1) lookups.
    ///
    /// - Parameter key: The sensor key to toggle (e.g., `"co2"`, `"temperature"`).
    func toggleSensor(_ key: String) {
        if visibleSensors.contains(key) {
            visibleSensors.remove(key)
        } else {
            visibleSensors.insert(key)
        }
    }

    /// Navigate one day backward in 24-hour mode.
    ///
    /// Decrements ``dayOffset`` by 1 (e.g., from 0 to -1, showing yesterday).
    /// The view should check ``canGoBack`` before calling this to avoid navigating
    /// past the earliest available data.
    func goBack() {
        dayOffset -= 1
    }

    /// Navigate one day forward in 24-hour mode.
    ///
    /// Increments ``dayOffset`` by 1, clamped to a maximum of 0 (today).
    /// Cannot navigate into the future.
    func goForward() {
        dayOffset = min(0, dayOffset + 1)
    }

    /// Set the active time range filter and reset day navigation if needed.
    ///
    /// When switching away from 24-hour mode, ``dayOffset`` is reset to 0 (today)
    /// since day navigation is only meaningful in 24-hour mode.
    ///
    /// - Parameter range: The new ``TimeRange`` to apply.
    func setTimeRange(_ range: TimeRange) {
        timeRange = range
        // Reset day offset when leaving 24-hour mode to avoid stale offsets.
        if range != .twentyFourHours { dayOffset = 0 }
    }
}
