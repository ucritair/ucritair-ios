import Foundation
import Testing
@testable import uCritAir

/// Unit tests for BLE data parsers including IEEE 754 half-precision floats,
/// ESS characteristic decoding (temperature, humidity, pressure, CO2),
/// RTC timestamp conversion, pet stats parsing, bitmap counting,
/// and ``DeviceConfig`` serialization round-trips.
@Suite("BLE Parsers")
struct BLEParsersTests {

    // MARK: - Float16 Parsing

    @Test("parseFloat16 — zero")
    func testFloat16Zero() {
        let result = BLEParsers.parseFloat16(0x00, 0x00)
        #expect(result == 0.0)
    }

    @Test("parseFloat16 — one")
    func testFloat16One() {
        // IEEE 754 half: 1.0 = 0x3C00
        let result = BLEParsers.parseFloat16(0x00, 0x3C)
        #expect(abs(result - 1.0) < 0.001)
    }

    @Test("parseFloat16 — negative one")
    func testFloat16NegativeOne() {
        // -1.0 = 0xBC00
        let result = BLEParsers.parseFloat16(0x00, 0xBC)
        #expect(abs(result - (-1.0)) < 0.001)
    }

    @Test("parseFloat16 — typical PM value ~12.5")
    func testFloat16PMValue() {
        // 12.5 in half-float: 0x4A40 (LE: 0x40, 0x4A)
        let result = BLEParsers.parseFloat16(0x40, 0x4A)
        #expect(abs(result - 12.5) < 0.1)
    }

    @Test("parseFloat16 — infinity")
    func testFloat16Infinity() {
        // +Inf = 0x7C00
        let result = BLEParsers.parseFloat16(0x00, 0x7C)
        #expect(result == .infinity)
    }

    @Test("parseFloat16 — NaN")
    func testFloat16NaN() {
        // NaN = 0x7C01
        let result = BLEParsers.parseFloat16(0x01, 0x7C)
        #expect(result.isNaN)
    }

    // MARK: - ESS Parsers

    @Test("parseTemperature — 25.00°C")
    func testParseTemperature() {
        // sint16: 2500 = 0x09C4 (LE)
        var data = Data(count: 2)
        data.writeUInt16LE(2500, at: 0)
        let result = BLEParsers.parseTemperature(data)
        #expect(abs(result - 25.0) < 0.01)
    }

    @Test("parseHumidity — 50.00%")
    func testParseHumidity() {
        // uint16: 5000 = 0x1388 (LE)
        var data = Data(count: 2)
        data.writeUInt16LE(5000, at: 0)
        let result = BLEParsers.parseHumidity(data)
        #expect(abs(result - 50.0) < 0.01)
    }

    @Test("parsePressure — 1013.25 hPa")
    func testParsePressure() {
        // uint32: 1013250 (0.1 Pa) = 1013.25 hPa
        var data = Data(count: 4)
        data.writeUInt32LE(1013250, at: 0)
        let result = BLEParsers.parsePressure(data)
        #expect(abs(result - 1013.25) < 0.01)
    }

    @Test("parseCO2 — 420 ppm")
    func testParseCO2() {
        var data = Data(count: 2)
        data.writeUInt16LE(420, at: 0)
        let result = BLEParsers.parseCO2(data)
        #expect(result == 420.0)
    }

    // MARK: - RTC Timestamp Conversion

    @Test("rtcToUnix — subtracts epoch offset")
    func testRtcToUnix() {
        let rtcTime: UInt64 = 59_958_144_000 + 1_700_000_000
        let unix = BLEParsers.rtcToUnix(rtcTime)
        #expect(unix == 1_700_000_000)
    }

    // MARK: - Pet Stats

    @Test("parseStats — known bytes")
    func testParseStats() {
        var data = Data(count: 6)
        data[0] = 80    // vigour
        data[1] = 90    // focus
        data[2] = 70    // spirit
        data.writeUInt16LE(365, at: 3)  // age
        data[5] = 5     // interventions

        let stats = BLEParsers.parseStats(data)
        #expect(stats.vigour == 80)
        #expect(stats.focus == 90)
        #expect(stats.spirit == 70)
        #expect(stats.age == 365)
        #expect(stats.interventions == 5)
    }

    // MARK: - Bitmap Count

    @Test("countBitmapItems — counts set bits")
    func testCountBitmapItems() {
        let data = Data([0xFF, 0x00, 0x0F, 0x01])
        let count = BLEParsers.countBitmapItems(data)
        #expect(count == 13) // 8 + 0 + 4 + 1
    }

    // MARK: - Device Config Round-Trip

    @Test("DeviceConfig serialize/parse round-trip")
    func testConfigRoundTrip() throws {
        let original = DeviceConfig(
            sensorWakeupPeriod: 300,
            sleepAfterSeconds: 60,
            dimAfterSeconds: 30,
            noxSamplePeriod: 10,
            screenBrightness: 50,
            persistFlags: [.useFahrenheit, .eternalWake]
        )

        let data = original.serialize()
        #expect(data.count == 16)

        let parsed = try #require(DeviceConfig.parse(from: data))
        #expect(parsed == original)
    }
}
