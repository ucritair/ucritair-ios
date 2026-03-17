import Foundation
import Testing
@testable import uCritAir

@Suite("Unit Formatters")
struct UnitFormattersTests {

    @Test("nil inputs format as placeholders")
    func nilInputs() {
        #expect(UnitFormatters.fmtTempValue(nil) == "--")
        #expect(UnitFormatters.fmtHumidityValue(nil) == "--")
        #expect(UnitFormatters.fmtCO2Value(nil) == "--")
        #expect(UnitFormatters.fmtPMValue(nil) == "--")
        #expect(UnitFormatters.fmtPressureValue(nil) == "--")
        #expect(UnitFormatters.fmtIndex(nil) == "--")
    }

    @Test("temperature conversion")
    func temperatureFormatting() {
        #expect(UnitFormatters.fmtTempValue(25.0) == "25.0")
        #expect(UnitFormatters.fmtTempValue(25.0, useFahrenheit: true) == "77.0")
    }

    @Test("basic numeric formatters")
    func basicNumericFormatting() {
        #expect(UnitFormatters.fmtHumidityValue(45.12) == "45.1")
        #expect(UnitFormatters.fmtCO2Value(412.8) == "413")
        #expect(UnitFormatters.fmtPMValue(12.34) == "12.3")
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

    @Test("local epoch helper honors DST offset changes for a fixed timezone")
    func localEpochHelperDSTBoundaries() throws {
        let chicago = try #require(TimeZone(identifier: "America/Chicago"))
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)

        let springBefore = try #require(formatter.date(from: "2026-03-08T07:59:59Z"))
        let springAfter = try #require(formatter.date(from: "2026-03-08T08:00:00Z"))
        let fallBefore = try #require(formatter.date(from: "2026-11-01T06:59:59Z"))
        let fallAfter = try #require(formatter.date(from: "2026-11-01T07:00:00Z"))

        #expect(chicago.secondsFromGMT(for: springBefore) == -21_600)
        #expect(chicago.secondsFromGMT(for: springAfter) == -18_000)
        #expect(chicago.secondsFromGMT(for: fallBefore) == -18_000)
        #expect(chicago.secondsFromGMT(for: fallAfter) == -21_600)

        #expect(
            Int(UnitFormatters.localEpoch(for: springBefore, timeZone: chicago))
                == Int(springBefore.timeIntervalSince1970) - 21_600
        )
        #expect(
            Int(UnitFormatters.localEpoch(for: springAfter, timeZone: chicago))
                == Int(springAfter.timeIntervalSince1970) - 18_000
        )
        #expect(
            Int(UnitFormatters.localEpoch(for: fallBefore, timeZone: chicago))
                == Int(fallBefore.timeIntervalSince1970) - 18_000
        )
        #expect(
            Int(UnitFormatters.localEpoch(for: fallAfter, timeZone: chicago))
                == Int(fallAfter.timeIntervalSince1970) - 21_600
        )
    }

    private static func expectedDateTimeString(epoch: UInt32) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        formatter.timeZone = .gmt
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(epoch)))
    }
}
