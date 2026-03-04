import Foundation

enum UnitFormatters {

    static func fmtTemp(_ value: Double?, useFahrenheit: Bool = false) -> String {
        guard let v = value else { return "--" }
        if useFahrenheit {
            let f = v * 9.0 / 5.0 + 32.0
            return String(format: "%.1f °F", f)
        }
        return String(format: "%.1f °C", v)
    }

    static func fmtTempValue(_ value: Double?, useFahrenheit: Bool = false) -> String {
        guard let v = value else { return "--" }
        if useFahrenheit {
            let f = v * 9.0 / 5.0 + 32.0
            return String(format: "%.1f", f)
        }
        return String(format: "%.1f", v)
    }

    static func fmtHumidity(_ value: Double?) -> String {
        guard let v = value else { return "--" }
        return String(format: "%.1f%%", v)
    }

    static func fmtHumidityValue(_ value: Double?) -> String {
        guard let v = value else { return "--" }
        return String(format: "%.1f", v)
    }

    static func fmtCO2(_ value: Double?) -> String {
        guard let v = value else { return "--" }
        return String(format: "%.0f ppm", v)
    }

    static func fmtCO2Value(_ value: Double?) -> String {
        guard let v = value else { return "--" }
        return String(format: "%.0f", v)
    }

    static func fmtPM(_ value: Double?) -> String {
        guard let v = value else { return "--" }
        return String(format: "%.1f µg/m³", v)
    }

    static func fmtPMValue(_ value: Double?) -> String {
        guard let v = value else { return "--" }
        return String(format: "%.1f", v)
    }

    static func fmtPressure(_ value: Double?) -> String {
        guard let v = value else { return "--" }
        return String(format: "%.1f hPa", v)
    }

    static func fmtPressureValue(_ value: Double?) -> String {
        guard let v = value else { return "--" }
        return String(format: "%.1f", v)
    }

    static func fmtIndex(_ value: Double?) -> String {
        guard let v = value else { return "--" }
        return String(format: "%.0f", v)
    }

    static func tempUnit(useFahrenheit: Bool = false) -> String {
        useFahrenheit ? "°F" : "°C"
    }

    private static let dateTimeFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .medium
        fmt.timeZone = .gmt
        return fmt
    }()

    static func fmtDateTime(_ epoch: UInt32) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(epoch))
        return dateTimeFormatter.string(from: date)
    }

    /// Returns the current local wall-clock time expressed as a Unix-like epoch.
    /// The device RTC stores local time (not UTC), so we add the timezone offset
    /// to produce a value the device interprets correctly.
    static func getLocalTimeAsEpoch() -> UInt32 {
        let now = Date()
        let offsetSeconds = TimeZone.current.secondsFromGMT(for: now)
        let localEpoch = Int(now.timeIntervalSince1970) + offsetSeconds
        return UInt32(clamping: localEpoch)
    }
}
