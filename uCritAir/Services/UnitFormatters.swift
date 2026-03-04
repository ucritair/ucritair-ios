import Foundation

// MARK: - File Overview
// ============================================================================
// UnitFormatters.swift
// uCritAir
//
// PURPOSE:
//   Provides consistent formatting of sensor values with their physical units
//   for display in the app's UI. Every sensor reading in the app passes through
//   one of these formatters before being shown to the user.
//
// DESIGN PATTERNS:
//   - **Nil-safe**: Every formatter accepts an `Optional` (`Double?`). When the
//     sensor value is `nil` (device not connected or sensor unavailable), the
//     formatter returns `"--"` as a placeholder. This eliminates nil-checking
//     at every call site in the UI.
//
//   - **Paired formatters**: Most sensor types have two formatters:
//     1. `fmtXxx(_:)` -- Returns value + unit suffix (e.g., `"22.5 °C"`)
//        Used in detail views and list rows.
//     2. `fmtXxxValue(_:)` -- Returns just the numeric value (e.g., `"22.5"`)
//        Used in charts and compact layouts where the unit is shown elsewhere.
//
//   - **Temperature conversion**: Temperature formatters accept a `useFahrenheit`
//     flag. The conversion formula is: F = C * 9/5 + 32.
//
// DEVICE TIMESTAMP CONVENTION:
//   The uCrit firmware has an unusual timestamp convention called "local time
//   as epoch." Instead of storing true UTC Unix timestamps, it stores the
//   local wall-clock time as if it were UTC. For example:
//
//     Actual time: 3:00 PM EST (UTC-5)
//     True UTC:    8:00 PM UTC  -> Unix timestamp 1709319600
//     Device:      3:00 PM UTC  -> Unix timestamp 1709301600
//
//   This means we must use GMT timezone when formatting device timestamps
//   (to avoid double-applying the timezone offset) and must add the local
//   timezone offset when sending the current time to the device.
//
// ORIGIN:
//   Ported from the web app's `src/lib/units.ts`.
// ============================================================================

/// Stateless utility providing consistent formatting of sensor values with physical
/// units for UI display.
///
/// `UnitFormatters` is declared as a caseless `enum` to prevent instantiation.
/// All methods are static and side-effect-free (pure functions), except for
/// `getLocalTimeAsEpoch()` which reads the current time.
///
/// Ported from `src/lib/units.ts`.
///
/// ## Usage
/// ```swift
/// // With unit suffix (for detail views):
/// UnitFormatters.fmtTemp(22.5)              // "22.5 °C"
/// UnitFormatters.fmtTemp(22.5, useFahrenheit: true)  // "72.5 °F"
/// UnitFormatters.fmtCO2(814)                // "814 ppm"
/// UnitFormatters.fmtTemp(nil)               // "--"
///
/// // Without unit suffix (for charts):
/// UnitFormatters.fmtTempValue(22.5)         // "22.5"
/// UnitFormatters.fmtCO2Value(814)           // "814"
/// ```
enum UnitFormatters {

    // MARK: - Temperature

    /// Format a temperature reading with its unit suffix (`°C` or `°F`).
    ///
    /// When `useFahrenheit` is true, converts from Celsius using the standard formula:
    /// `F = C * 9/5 + 32`. All sensor readings are stored in Celsius internally;
    /// conversion to Fahrenheit is purely a display concern.
    ///
    /// - Parameters:
    ///   - value: Temperature in degrees Celsius, or `nil` for a placeholder.
    ///   - useFahrenheit: If `true`, convert to Fahrenheit before formatting. Defaults to `false`.
    /// - Returns: Formatted string like `"22.5 °C"`, `"72.5 °F"`, or `"--"` if nil.
    static func fmtTemp(_ value: Double?, useFahrenheit: Bool = false) -> String {
        guard let v = value else { return "--" }
        if useFahrenheit {
            let f = v * 9.0 / 5.0 + 32.0  // Celsius to Fahrenheit conversion
            return String(format: "%.1f °F", f)
        }
        return String(format: "%.1f °C", v)
    }

    /// Format a temperature value without the unit suffix (for charts/compact layouts).
    ///
    /// - Parameters:
    ///   - value: Temperature in degrees Celsius, or `nil` for a placeholder.
    ///   - useFahrenheit: If `true`, convert to Fahrenheit before formatting.
    /// - Returns: Numeric string like `"22.5"` or `"--"` if nil.
    static func fmtTempValue(_ value: Double?, useFahrenheit: Bool = false) -> String {
        guard let v = value else { return "--" }
        if useFahrenheit {
            let f = v * 9.0 / 5.0 + 32.0
            return String(format: "%.1f", f)
        }
        return String(format: "%.1f", v)
    }

    // MARK: - Humidity

    /// Format a relative humidity reading with the `%` suffix.
    ///
    /// - Parameter value: Relative humidity as a percentage (0-100), or `nil`.
    /// - Returns: Formatted string like `"52.3%"` or `"--"` if nil.
    static func fmtHumidity(_ value: Double?) -> String {
        guard let v = value else { return "--" }
        return String(format: "%.1f%%", v)  // Note: %% produces a literal % in format strings
    }

    /// Format humidity as a numeric string without the `%` suffix (e.g. `"52.3"`).
    ///
    /// - Parameter value: Relative humidity percentage, or `nil` for a placeholder.
    /// - Returns: Formatted value or `"--"` when `nil`.
    static func fmtHumidityValue(_ value: Double?) -> String {
        guard let v = value else { return "--" }
        return String(format: "%.1f", v)
    }

    // MARK: - CO2

    /// Format a CO2 concentration reading with the `ppm` (parts per million) suffix.
    ///
    /// CO2 values are displayed as whole numbers because the SCD41 sensor has
    /// a resolution of ~1 ppm, so decimal places would be false precision.
    ///
    /// - Parameter value: CO2 concentration in parts per million, or `nil`.
    /// - Returns: Formatted string like `"814 ppm"` or `"--"` if nil.
    static func fmtCO2(_ value: Double?) -> String {
        guard let v = value else { return "--" }
        return String(format: "%.0f ppm", v)  // %.0f = zero decimal places
    }

    /// Format CO2 as a numeric string without the `ppm` suffix (e.g. `"814"`).
    ///
    /// - Parameter value: CO2 concentration in ppm, or `nil` for a placeholder.
    /// - Returns: Formatted value or `"--"` when `nil`.
    static func fmtCO2Value(_ value: Double?) -> String {
        guard let v = value else { return "--" }
        return String(format: "%.0f", v)
    }

    // MARK: - Particulate Matter

    /// Format a particulate matter concentration with the `ug/m3` (micrograms per cubic meter) suffix.
    ///
    /// Used for PM1.0, PM2.5, PM4.0, and PM10 mass concentrations from the SPS30 sensor.
    /// One decimal place provides appropriate precision for these measurements.
    ///
    /// - Parameter value: PM concentration in micrograms per cubic meter, or `nil`.
    /// - Returns: Formatted string like `"12.4 ug/m3"` or `"--"` if nil.
    static func fmtPM(_ value: Double?) -> String {
        guard let v = value else { return "--" }
        return String(format: "%.1f µg/m³", v)
    }

    /// Format particulate matter as a numeric string without the `ug/m3` suffix (e.g. `"12.4"`).
    ///
    /// - Parameter value: PM concentration in ug/m3, or `nil` for a placeholder.
    /// - Returns: Formatted value or `"--"` when `nil`.
    static func fmtPMValue(_ value: Double?) -> String {
        guard let v = value else { return "--" }
        return String(format: "%.1f", v)
    }

    // MARK: - Pressure

    /// Format an atmospheric pressure reading with the `hPa` (hectopascals) suffix.
    ///
    /// Standard atmospheric pressure at sea level is approximately 1013.25 hPa.
    /// One hectopascal equals one millibar (mbar), a common unit in meteorology.
    ///
    /// - Parameter value: Pressure in hectopascals, or `nil`.
    /// - Returns: Formatted string like `"1013.2 hPa"` or `"--"` if nil.
    static func fmtPressure(_ value: Double?) -> String {
        guard let v = value else { return "--" }
        return String(format: "%.1f hPa", v)
    }

    /// Format pressure as a numeric string without the `hPa` suffix (e.g. `"1013.2"`).
    ///
    /// - Parameter value: Atmospheric pressure in hPa, or `nil` for a placeholder.
    /// - Returns: Formatted value or `"--"` when `nil`.
    static func fmtPressureValue(_ value: Double?) -> String {
        guard let v = value else { return "--" }
        return String(format: "%.1f", v)
    }

    // MARK: - Gas Indices (VOC / NOx)

    /// Format a VOC or NOx index value as a rounded integer string (no unit suffix).
    ///
    /// The Sensirion SGP41 sensor outputs VOC and NOx as dimensionless index values
    /// (typically 1-500). These are relative measures, not absolute concentrations,
    /// so they have no physical unit.
    ///
    /// - Parameter value: VOC or NOx index value, or `nil`.
    /// - Returns: Formatted string like `"142"` or `"--"` if nil.
    static func fmtIndex(_ value: Double?) -> String {
        guard let v = value else { return "--" }
        return String(format: "%.0f", v)
    }

    // MARK: - Unit Suffix Helpers

    /// Get the appropriate temperature unit suffix string.
    ///
    /// - Parameter useFahrenheit: If `true`, returns `"°F"`; otherwise `"°C"`.
    /// - Returns: The unit suffix string.
    static func tempUnit(useFahrenheit: Bool = false) -> String {
        useFahrenheit ? "°F" : "°C"
    }

    // MARK: - Date/Time Formatting

    /// Cached `DateFormatter` configured for displaying device timestamps.
    ///
    /// **Why cached?** Creating a `DateFormatter` is expensive (Apple's documentation
    /// warns against creating them repeatedly). By storing it as a static `let`, we
    /// create it once and reuse it for the lifetime of the app.
    ///
    /// **Why GMT?** The device stores "local time as epoch" -- see the file overview
    /// comment for details. By formatting in GMT, we display the local time the device
    /// recorded without accidentally adding the phone's timezone offset on top.
    private static let dateTimeFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateStyle = .medium    // e.g., "Mar 3, 2024"
        fmt.timeStyle = .medium    // e.g., "8:00:00 PM"
        fmt.timeZone = .gmt       // Crucial: avoids double-applying timezone offset
        return fmt
    }()

    /// Format a device timestamp (stored as "local time as epoch") to a human-readable
    /// date and time string.
    ///
    /// **Why use GMT for formatting?**
    /// The device stores timestamps as "local time pretending to be UTC." If the
    /// local time is 3:00 PM, the device stores the Unix timestamp for 3:00 PM UTC.
    /// If we format this with the phone's local timezone (e.g., UTC-5), iOS would
    /// show 10:00 AM -- wrong! By using GMT, we get back the original 3:00 PM.
    ///
    /// - Parameter epoch: A Unix timestamp (seconds since 1970-01-01) representing
    ///   the device's local time encoded as UTC. Stored as `UInt32`.
    /// - Returns: A formatted string like `"Mar 3, 2024 at 3:00:00 PM"`.
    static func fmtDateTime(_ epoch: UInt32) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(epoch))
        return dateTimeFormatter.string(from: date)
    }

    /// Compute the current local time encoded as a UTC epoch number, matching the
    /// device's timestamp convention.
    ///
    /// This is used when syncing the phone's clock to the device over BLE. The device
    /// expects a "local time as epoch" value, not a true UTC timestamp.
    ///
    /// **The "local time as epoch" convention explained:**
    ///
    /// Normal Unix timestamps count seconds since midnight UTC on January 1, 1970.
    /// The device instead counts seconds since midnight *local time* on January 1, 1970.
    /// The difference is exactly the timezone offset.
    ///
    /// **Example** (timezone = UTC-5, i.e., EST):
    /// ```
    /// True UTC epoch:         1709319600  (represents 8:00 PM UTC)
    /// Timezone offset:        -18000      (UTC-5 = -5 * 3600)
    /// Device expects:         1709319600 + (-18000) = 1709301600
    ///                         (represents 3:00 PM UTC, which is 3:00 PM local)
    /// ```
    ///
    /// **Signed arithmetic note**: The offset can be negative (western hemisphere),
    /// so we use `Int` for the addition to avoid unsigned integer underflow, then
    /// convert to `UInt32` with `clamping:` to safely handle edge cases.
    ///
    /// - Returns: A `UInt32` representing the current local time as a UTC epoch number.
    ///
    /// Ported from `units.ts` -> `getLocalTimeAsEpoch()`.
    static func getLocalTimeAsEpoch() -> UInt32 {
        let now = Date()
        let offsetSeconds = TimeZone.current.secondsFromGMT(for: now)
        // Add timezone offset to UTC epoch to get "local time as epoch"
        let localEpoch = Int(now.timeIntervalSince1970) + offsetSeconds
        return UInt32(clamping: localEpoch)  // clamping prevents crash on overflow
    }
}
