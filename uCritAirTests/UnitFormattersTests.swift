import Foundation
import Testing
@testable import uCritAir

@Suite("Unit Formatters")
struct UnitFormattersTests {

    @Test("nil inputs format as placeholders")
    func nilInputs() {
        #expect(UnitFormatters.fmtTemp(nil) == "--")
        #expect(UnitFormatters.fmtHumidity(nil) == "--")
        #expect(UnitFormatters.fmtCO2(nil) == "--")
        #expect(UnitFormatters.fmtPM(nil) == "--")
        #expect(UnitFormatters.fmtPressure(nil) == "--")
        #expect(UnitFormatters.fmtIndex(nil) == "--")
    }

    @Test("temperature conversion and unit labeling")
    func temperatureFormatting() {
        #expect(UnitFormatters.fmtTemp(25.0) == "25.0 °C")
        #expect(UnitFormatters.fmtTemp(25.0, useFahrenheit: true) == "77.0 °F")
        #expect(UnitFormatters.fmtTempValue(25.0, useFahrenheit: true) == "77.0")
        #expect(UnitFormatters.tempUnit(useFahrenheit: false) == "°C")
        #expect(UnitFormatters.tempUnit(useFahrenheit: true) == "°F")
    }

    @Test("basic numeric formatters")
    func basicNumericFormatting() {
        #expect(UnitFormatters.fmtHumidity(45.12) == "45.1%")
        #expect(UnitFormatters.fmtHumidityValue(45.12) == "45.1")
        #expect(UnitFormatters.fmtCO2(412.8) == "413 ppm")
        #expect(UnitFormatters.fmtCO2Value(412.8) == "413")
        #expect(UnitFormatters.fmtPM(12.34) == "12.3 µg/m³")
        #expect(UnitFormatters.fmtPMValue(12.34) == "12.3")
        #expect(UnitFormatters.fmtPressure(1013.26) == "1013.3 hPa")
        #expect(UnitFormatters.fmtPressureValue(1013.26) == "1013.3")
        #expect(UnitFormatters.fmtIndex(98.7) == "99")
    }

    @Test("date-time formatter uses GMT and medium styles")
    func dateTimeFormatting() {
        let epoch: UInt32 = 1_700_000_000
        let expected = Self.expectedDateTimeString(epoch: epoch)
        #expect(UnitFormatters.fmtDateTime(epoch) == expected)
    }

    @Test("local epoch helper tracks current offset")
    func localEpochHelper() {
        let now = Date()
        let expected = Int(now.timeIntervalSince1970) + TimeZone.current.secondsFromGMT(for: now)
        let actual = Int(UnitFormatters.getLocalTimeAsEpoch())
        #expect(abs(actual - expected) <= 2)
    }

    private static func expectedDateTimeString(epoch: UInt32) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        formatter.timeZone = .gmt
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(epoch)))
    }
}
