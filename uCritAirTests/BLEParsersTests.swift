import Foundation
import Testing
@testable import uCritAir

@Suite("BLE Parsers")
struct BLEParsersTests {

    @Test("parseFloat16 — zero")
    func testFloat16Zero() {
        let result = BLEParsers.parseFloat16(0x00, 0x00)
        #expect(result == 0.0)
    }

    @Test("parseFloat16 — one")
    func testFloat16One() {
        let result = BLEParsers.parseFloat16(0x00, 0x3C)
        #expect(abs(result - 1.0) < 0.001)
    }

    @Test("parseFloat16 — negative one")
    func testFloat16NegativeOne() {
        let result = BLEParsers.parseFloat16(0x00, 0xBC)
        #expect(abs(result - (-1.0)) < 0.001)
    }

    @Test("parseFloat16 — typical PM value ~12.5")
    func testFloat16PMValue() {
        let result = BLEParsers.parseFloat16(0x40, 0x4A)
        #expect(abs(result - 12.5) < 0.1)
    }

    @Test("parseFloat16 — infinity")
    func testFloat16Infinity() {
        let result = BLEParsers.parseFloat16(0x00, 0x7C)
        #expect(result == .infinity)
    }

    @Test("parseFloat16 — NaN")
    func testFloat16NaN() {
        let result = BLEParsers.parseFloat16(0x01, 0x7C)
        #expect(result.isNaN)
    }

    @Test("parseTemperature — 25.00°C")
    func testParseTemperature() throws {
        var data = Data(count: 2)
        data.writeUInt16LE(2500, at: 0)
        let result = try BLEParsers.parseTemperature(data)
        #expect(abs(result - 25.0) < 0.01)
    }

    @Test("parseHumidity — 50.00%")
    func testParseHumidity() throws {
        var data = Data(count: 2)
        data.writeUInt16LE(5000, at: 0)
        let result = try BLEParsers.parseHumidity(data)
        #expect(abs(result - 50.0) < 0.01)
    }

    @Test("parsePressure — 1013.25 hPa")
    func testParsePressure() throws {
        var data = Data(count: 4)
        data.writeUInt32LE(1013250, at: 0)
        let result = try BLEParsers.parsePressure(data)
        #expect(abs(result - 1013.25) < 0.01)
    }

    @Test("parseCO2 — 420 ppm")
    func testParseCO2() throws {
        var data = Data(count: 2)
        data.writeUInt16LE(420, at: 0)
        let result = try BLEParsers.parseCO2(data)
        #expect(result == 420.0)
    }

    @Test("parsePM — float16 payload")
    func testParsePM() throws {
        let data = Data([0x40, 0x4A])
        let result = try BLEParsers.parsePM(data)
        #expect(abs(result - 12.5) < 0.1)
    }

    @Test("rtcToUnix — subtracts epoch offset")
    func testRtcToUnix() {
        let rtcTime: UInt64 = 59_958_144_000 + 1_700_000_000
        let unix = BLEParsers.rtcToUnix(rtcTime)
        #expect(unix == 1_700_000_000)
    }

    @Test("parseStats — known bytes")
    func testParseStats() throws {
        var data = Data(count: 6)
        data[0] = 80
        data[1] = 90
        data[2] = 70
        data.writeUInt16LE(365, at: 3)
        data[5] = 5

        let stats = try BLEParsers.parseStats(data)
        #expect(stats.vigour == 80)
        #expect(stats.focus == 90)
        #expect(stats.spirit == 70)
        #expect(stats.age == 365)
        #expect(stats.interventions == 5)
    }

    @Test("countBitmapItems — counts set bits")
    func testCountBitmapItems() {
        let data = Data([0xFF, 0x00, 0x0F, 0x01])
        let count = BLEParsers.countBitmapItems(data)
        #expect(count == 13)
    }

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

    @Test("parseTemperature — truncated payload throws")
    func testParseTemperatureTruncatedThrows() {
        do {
            _ = try BLEParsers.parseTemperature(Data([0x01]))
            #expect(Bool(false))
        } catch {
            #expect(error is DataParsingError)
        }
    }

    @Test("parseLogCell — truncated payload throws")
    func testParseLogCellTruncatedThrows() {
        do {
            _ = try BLEParsers.parseLogCell(Data(count: 10))
            #expect(Bool(false))
        } catch {
            #expect(error is DataParsingError)
        }
    }

    @Test("parseLogCell — full payload")
    func testParseLogCellFullPayload() throws {
        var data = Data(count: 57)
        data.writeUInt32LE(7, at: 0)
        data[4] = 0x03

        let rtc = UInt64(BLEConstants.rtcEpochOffset) + 1_700_000_100
        data.writeUInt64LE(rtc, at: 8)

        data.writeUInt32LE(UInt32(bitPattern: Int32(21_500)), at: 16)
        data.writeUInt16LE(10_132, at: 20)
        data.writeUInt16LE(4_550, at: 22)
        data.writeUInt16LE(501, at: 24)

        data.writeUInt16LE(100, at: 26)
        data.writeUInt16LE(250, at: 28)
        data.writeUInt16LE(400, at: 30)
        data.writeUInt16LE(1_000, at: 32)

        data.writeUInt16LE(11, at: 34)
        data.writeUInt16LE(22, at: 36)
        data.writeUInt16LE(33, at: 38)
        data.writeUInt16LE(44, at: 40)
        data.writeUInt16LE(55, at: 42)

        data[44] = 17
        data[45] = 23
        data.writeUInt16LE(520, at: 46)
        data.writeUInt32LE(Float(123.5).bitPattern, at: 48)
        data.writeUInt32LE(Float(234.5).bitPattern, at: 52)
        data[56] = 9

        let cell = try BLEParsers.parseLogCell(data)
        #expect(cell.cellNumber == 7)
        #expect(cell.flags == 0x03)
        #expect(cell.timestamp == 1_700_000_100)
        #expect(abs(cell.temperature - 21.5) < 0.001)
        #expect(abs(cell.pressure - 1_013.2) < 0.001)
        #expect(abs(cell.humidity - 45.5) < 0.001)
        #expect(cell.co2 == 501)
        #expect(abs(cell.pm.pm1_0 - 1.0) < 0.001)
        #expect(abs(cell.pm.pm2_5 - 2.5) < 0.001)
        #expect(abs(cell.pm.pm4_0 - 4.0) < 0.001)
        #expect(abs(cell.pm.pm10 - 10.0) < 0.001)
        #expect(abs(cell.pn.pn10 - 0.55) < 0.0001)
        #expect(cell.voc == 17)
        #expect(cell.nox == 23)
        #expect(cell.co2Uncomp == 520)
        #expect(abs(cell.stroop.meanTimeCong - 123.5) < 0.001)
        #expect(abs(cell.stroop.meanTimeIncong - 234.5) < 0.001)
        #expect(cell.stroop.throughput == 9)
    }
}
