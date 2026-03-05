import Foundation

enum UnitFormatters {

    static func fmtTempValue(_ value: Double?, useFahrenheit: Bool = false) -> String {
        guard let v = value else { return "--" }
        if useFahrenheit {
            let f = v * 9.0 / 5.0 + 32.0
            return String(format: "%.1f", f)
        }
        return String(format: "%.1f", v)
    }

    static func fmtHumidityValue(_ value: Double?) -> String {
        guard let v = value else { return "--" }
        return String(format: "%.1f", v)
    }

    static func fmtCO2Value(_ value: Double?) -> String {
        guard let v = value else { return "--" }
        return String(format: "%.0f", v)
    }

    static func fmtPMValue(_ value: Double?) -> String {
        guard let v = value else { return "--" }
        return String(format: "%.1f", v)
    }

    static func fmtPressureValue(_ value: Double?) -> String {
        guard let v = value else { return "--" }
        return String(format: "%.1f", v)
    }

    static func fmtIndex(_ value: Double?) -> String {
        guard let v = value else { return "--" }
        return String(format: "%.0f", v)
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
