import Foundation

// MARK: - File Overview
// ============================================================================
// CSVExporter.swift
// uCritAir
//
// PURPOSE:
//   Exports log cell data (air quality sensor readings over time) to CSV
//   (Comma-Separated Values) files that can be opened in spreadsheet apps
//   like Excel, Google Sheets, or Numbers.
//
// CSV FORMAT:
//   CSV is one of the simplest data exchange formats. Each line is a row,
//   and values within a row are separated by commas. The first row is always
//   a header that names each column.
//
//   Example output:
//     cell_number,timestamp,datetime,flags,temperature_C,...
//     0,1709500800,2024-03-03T20:00:00Z,0x00,22.150,...
//     1,1709500980,2024-03-03T20:03:00Z,0x00,22.200,...
//
// TEMPORARY FILE PATTERN:
//   The exported CSV is written to the system's temporary directory with
//   the naming pattern: `ucrit-logs-YYYY-MM-DD.csv`
//   (e.g., `ucrit-logs-2024-03-03.csv`). This file persists until the OS
//   cleans up temporary files, and is intended to be shared immediately
//   via iOS share sheet.
//
// ORIGIN:
//   Ported from the web app's `src/lib/export.ts` -> `logCellsToCSV()`.
// ============================================================================

/// Exports arrays of `LogCellEntity` objects to CSV format for data sharing and analysis.
///
/// `CSVExporter` is a stateless utility (declared as an `enum` with no cases to prevent
/// instantiation). It provides two operations:
/// 1. **`toCSV(_:)`** -- Convert an array of log cell entities to a CSV string.
/// 2. **`writeTemporaryFile(_:)`** -- Write a CSV string to a temporary file and return
///    its URL for use with `UIActivityViewController` (the iOS share sheet).
///
/// Ported from `src/lib/export.ts` -> `logCellsToCSV()`.
///
/// ## Usage
/// ```swift
/// let cells = try LogCellStore.fetchAllCells(deviceId: "ABCD", context: context)
/// let csv = CSVExporter.toCSV(cells)
/// let fileURL = try CSVExporter.writeTemporaryFile(csv)
/// // Present fileURL via share sheet
/// ```
enum CSVExporter {

    /// The CSV header row as a single comma-separated string.
    ///
    /// **Column reference** (23 columns total):
    ///
    /// | Column | Description | Units / Format |
    /// |--------|-------------|----------------|
    /// | `cell_number` | Sequential log cell index on the device | Integer |
    /// | `timestamp` | Unix epoch seconds (device local-as-UTC) | Integer |
    /// | `datetime` | Human-readable ISO 8601 timestamp | `YYYY-MM-DDTHH:MM:SSZ` |
    /// | `flags` | Bitmask of cell status flags | Hex (e.g., `0x00`) |
    /// | `temperature_C` | Ambient temperature | Degrees Celsius |
    /// | `pressure_hPa` | Atmospheric pressure | Hectopascals |
    /// | `humidity_pct` | Relative humidity | Percent |
    /// | `co2_ppm` | Compensated CO2 concentration | Parts per million |
    /// | `co2_uncomp_ppm` | Uncompensated CO2 concentration | Parts per million |
    /// | `pm1_0` .. `pm10` | Particulate mass concentrations | Micrograms per cubic meter |
    /// | `pn0_5` .. `pn10` | Particle number concentrations | Particles per cubic centimeter |
    /// | `voc_index` | Sensirion VOC index | Unitless (1-500) |
    /// | `nox_index` | Sensirion NOx index | Unitless (1-500) |
    /// | `stroop_cong_ms` | Stroop task congruent mean reaction time | Milliseconds |
    /// | `stroop_incong_ms` | Stroop task incongruent mean reaction time | Milliseconds |
    /// | `stroop_throughput` | Stroop task throughput score | Integer |
    static let header = [
        "cell_number", "timestamp", "datetime", "flags",
        "temperature_C", "pressure_hPa", "humidity_pct",
        "co2_ppm", "co2_uncomp_ppm",
        "pm1_0", "pm2_5", "pm4_0", "pm10",
        "pn0_5", "pn1_0", "pn2_5", "pn4_0", "pn10",
        "voc_index", "nox_index",
        "stroop_cong_ms", "stroop_incong_ms", "stroop_throughput",
    ].joined(separator: ",")

    /// Generate a complete CSV string from an array of log cell entities.
    ///
    /// The output starts with the header row followed by one data row per cell.
    /// Each row contains 23 comma-separated values matching the columns defined
    /// in ``header``.
    ///
    /// **Formatting details:**
    /// - `timestamp`: Raw integer (Unix epoch seconds)
    /// - `datetime`: ISO 8601 format via `ISO8601DateFormatter` (e.g., `"2024-03-03T20:00:00Z"`)
    /// - `flags`: Two-digit hexadecimal with `0x` prefix (e.g., `"0x00"`)
    /// - `temperature`: 3 decimal places (millidegree precision from the sensor)
    /// - `pressure`: 1 decimal place
    /// - `humidity`, PM, PN values: 2 decimal places
    /// - `co2`, `voc`, `nox`: Integer values (no decimal)
    /// - Stroop reaction times: 3 decimal places (sub-millisecond precision)
    ///
    /// - Parameter cells: Array of `LogCellEntity` objects to export. Order is preserved
    ///   in the output (typically sorted by `cellNumber` ascending).
    /// - Returns: A multi-line CSV string ready to be written to a file or displayed.
    static func toCSV(_ cells: [LogCellEntity]) -> String {
        // Start with the header row
        var lines = [header]
        let isoFormatter = ISO8601DateFormatter()

        for c in cells {
            // Convert the Unix timestamp to an ISO 8601 datetime string
            // for the human-readable "datetime" column
            let datetime = isoFormatter.string(
                from: Date(timeIntervalSince1970: TimeInterval(c.timestamp))
            )
            // Build each row as an array of formatted strings, then join with commas
            let row = [
                "\(c.cellNumber)",
                "\(c.timestamp)",
                datetime,
                String(format: "0x%02X", c.flags),          // Hex flags (e.g., 0x00)
                String(format: "%.3f", c.temperature),       // 3 dp for millidegree precision
                String(format: "%.1f", c.pressure),
                String(format: "%.2f", c.humidity),
                "\(c.co2)",
                "\(c.co2Uncomp)",
                String(format: "%.2f", c.pm1_0),
                String(format: "%.2f", c.pm2_5),
                String(format: "%.2f", c.pm4_0),
                String(format: "%.2f", c.pm10),
                String(format: "%.2f", c.pn0_5),
                String(format: "%.2f", c.pn1_0),
                String(format: "%.2f", c.pn2_5),
                String(format: "%.2f", c.pn4_0),
                String(format: "%.2f", c.pn10),
                "\(c.voc)",
                "\(c.nox)",
                String(format: "%.3f", c.stroopMeanCong),    // Sub-ms precision
                String(format: "%.3f", c.stroopMeanIncong),
                "\(c.stroopThroughput)",
            ].joined(separator: ",")
            lines.append(row)
        }
        // Join all rows with newline characters to form the complete CSV document
        return lines.joined(separator: "\n")
    }

    /// Write a CSV string to a temporary file and return its URL for sharing via the
    /// iOS share sheet (`UIActivityViewController`).
    ///
    /// **File naming convention:**
    /// The filename follows the pattern `ucrit-logs-YYYY-MM-DD.csv`, where the date
    /// is today's date in ISO 8601 format. For example: `ucrit-logs-2024-03-03.csv`.
    ///
    /// **Temporary directory:**
    /// The file is written to `FileManager.default.temporaryDirectory`, which is a
    /// sandboxed directory the OS may clean up at any time after the app exits. This
    /// is appropriate because the file only needs to exist long enough for the user
    /// to share or save it via the share sheet.
    ///
    /// **Atomic writes:**
    /// The `atomically: true` parameter means the data is first written to a temporary
    /// intermediate file, then renamed to the final path. This prevents a partially-written
    /// file from existing if the write is interrupted (e.g., by the app being killed).
    ///
    /// - Parameter csv: The CSV string to write (typically from ``toCSV(_:)``).
    /// - Returns: A `URL` pointing to the temporary CSV file.
    /// - Throws: Any file system error from `String.write(to:atomically:encoding:)`.
    static func writeTemporaryFile(_ csv: String) throws -> URL {
        // Extract just the date portion (first 10 chars) from the ISO 8601 string
        // e.g., "2024-03-03T20:00:00Z" -> "2024-03-03"
        let dateStr = String(ISO8601DateFormatter().string(from: Date()).prefix(10))
        let filename = "ucrit-logs-\(dateStr).csv"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        try csv.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
