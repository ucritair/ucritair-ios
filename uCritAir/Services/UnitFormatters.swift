import Foundation

/// Unit formatting functions matching the web app.
/// Ported from src/lib/units.ts
enum UnitFormatters {

    /// Format temperature in °C (or °F if flag set).
    static func fmtTemp(_ value: Double?, useFahrenheit: Bool = false) -> String {
        guard let v = value else { return "--" }
        if useFahrenheit {
            let f = v * 9.0 / 5.0 + 32.0
            return String(format: "%.1f °F", f)
        }
        return String(format: "%.1f °C", v)
    }

    /// Format temperature value only (no unit suffix).
    static func fmtTempValue(_ value: Double?, useFahrenheit: Bool = false) -> String {
        guard let v = value else { return "--" }
        if useFahrenheit {
            let f = v * 9.0 / 5.0 + 32.0
            return String(format: "%.1f", f)
        }
        return String(format: "%.1f", v)
    }

    /// Format humidity percentage.
    static func fmtHumidity(_ value: Double?) -> String {
        guard let v = value else { return "--" }
        return String(format: "%.1f%%", v)
    }

    /// Format humidity as a numeric string without the `%` suffix (e.g. `"52.3"`).
    ///
    /// - Parameter value: Relative humidity percentage, or `nil` for a placeholder.
    /// - Returns: Formatted value or `"--"` when `nil`.
    static func fmtHumidityValue(_ value: Double?) -> String {
        guard let v = value else { return "--" }
        return String(format: "%.1f", v)
    }

    /// Format CO2 in ppm.
    static func fmtCO2(_ value: Double?) -> String {
        guard let v = value else { return "--" }
        return String(format: "%.0f ppm", v)
    }

    /// Format CO2 as a numeric string without the `ppm` suffix (e.g. `"814"`).
    ///
    /// - Parameter value: CO2 concentration in ppm, or `nil` for a placeholder.
    /// - Returns: Formatted value or `"--"` when `nil`.
    static func fmtCO2Value(_ value: Double?) -> String {
        guard let v = value else { return "--" }
        return String(format: "%.0f", v)
    }

    /// Format particulate matter in µg/m³.
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

    /// Format pressure in hPa.
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

    /// Format VOC/NOx index (rounded).
    static func fmtIndex(_ value: Double?) -> String {
        guard let v = value else { return "--" }
        return String(format: "%.0f", v)
    }

    /// Temperature unit suffix.
    static func tempUnit(useFahrenheit: Bool = false) -> String {
        useFahrenheit ? "°F" : "°C"
    }

    /// Get local time as epoch-like number matching device convention.
    ///
    /// The uCrit firmware stores timestamps as "local time as epoch" — the local clock
    /// reading expressed as if it were UTC. For example, if it's 3 PM local, the device
    /// stores the Unix timestamp corresponding to 3 PM UTC regardless of the actual timezone.
    ///
    /// Formula: `utc_epoch + secondsFromGMT` (arithmetic done in signed `Int` to avoid
    /// unsigned overflow for negative offsets in western-hemisphere timezones).
    ///
    /// Ported from units.ts → getLocalTimeAsEpoch()
    static func getLocalTimeAsEpoch() -> UInt32 {
        let now = Date()
        let offsetSeconds = TimeZone.current.secondsFromGMT(for: now)
        let localEpoch = Int(now.timeIntervalSince1970) + offsetSeconds
        return UInt32(clamping: localEpoch)
    }
}
