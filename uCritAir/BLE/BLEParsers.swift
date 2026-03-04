import Foundation

/// Binary data parsers for uCrit BLE protocol.
/// Direct port of src/ble/parsers.ts — byte offsets and formats must match exactly.
enum BLEParsers {

    // MARK: - IEEE 754 Half-Precision Float

    /// Parse IEEE 754 half-precision (binary16) float from two bytes (little-endian).
    /// Ported from parsers.ts → parseFloat16()
    static func parseFloat16(_ b0: UInt8, _ b1: UInt8) -> Double {
        let val = UInt16(b0) | (UInt16(b1) << 8)
        let sign = (val >> 15) & 1
        let exp = (val >> 10) & 0x1F
        let frac = val & 0x3FF

        if exp == 0 {
            // Subnormal
            return Double(sign != 0 ? -1 : 1) * (Double(frac) / 1024.0) * pow(2.0, -14.0)
        }
        if exp == 31 {
            return frac != 0 ? .nan : (sign != 0 ? -.infinity : .infinity)
        }
        return Double(sign != 0 ? -1 : 1) * (1.0 + Double(frac) / 1024.0) * pow(2.0, Double(exp) - 15.0)
    }

    // MARK: - ESS Characteristic Parsers

    /// Parse ESS Temperature: sint16, 0.01°C resolution → °C
    static func parseTemperature(_ data: Data) -> Double {
        Double(data.readInt16LE(at: 0)) / 100.0
    }

    /// Parse ESS Humidity: uint16, 0.01% resolution → %
    static func parseHumidity(_ data: Data) -> Double {
        Double(data.readUInt16LE(at: 0)) / 100.0
    }

    /// Parse ESS Pressure: uint32, 0.1 Pa resolution → hPa
    static func parsePressure(_ data: Data) -> Double {
        Double(data.readUInt32LE(at: 0)) / 1000.0
    }

    /// Parse ESS CO2: uint16, ppm
    static func parseCO2(_ data: Data) -> Double {
        Double(data.readUInt16LE(at: 0))
    }

    /// Parse ESS PM (fp16): half-precision float → µg/m³
    static func parsePM(_ data: Data) -> Double {
        parseFloat16(data.readUInt8(at: 0), data.readUInt8(at: 1))
    }

    // MARK: - Timestamp Conversion

    /// Convert internal RTC timestamp (seconds) to Unix timestamp (seconds).
    static func rtcToUnix(_ rtcTime: UInt64) -> Int {
        Int(rtcTime) - Int(BLEConstants.rtcEpochOffset)
    }

    // MARK: - Log Cell Parser

    /// Parse a log cell from BLE notification payload.
    /// 57 bytes: 4-byte cell_nr + 53-byte cell data.
    /// Ported from parsers.ts → parseLogCell() — byte offsets must match exactly.
    static func parseLogCell(_ data: Data) -> ParsedLogCell {
        let cellNumber = Int(data.readUInt32LE(at: 0))

        // Cell data starts at offset 4
        let o = 4
        let flags = Int(data.readUInt8(at: o + 0))

        // timestamp: uint64 at offset 4 (relative to cell start)
        let rtcTimestamp = data.readUInt64LE(at: o + 4)
        let timestamp = rtcToUnix(rtcTimestamp)

        let temperature = Double(data.readInt32LE(at: o + 12)) / 1000.0
        let pressure = Double(data.readUInt16LE(at: o + 16)) / 10.0
        let humidity = Double(data.readUInt16LE(at: o + 18)) / 100.0
        let co2 = Int(data.readUInt16LE(at: o + 20))

        let pm = (
            Double(data.readUInt16LE(at: o + 22)) / 100.0,   // PM1.0
            Double(data.readUInt16LE(at: o + 24)) / 100.0,   // PM2.5
            Double(data.readUInt16LE(at: o + 26)) / 100.0,   // PM4.0
            Double(data.readUInt16LE(at: o + 28)) / 100.0    // PM10.0
        )

        let pn = (
            Double(data.readUInt16LE(at: o + 30)) / 100.0,   // PN0.5
            Double(data.readUInt16LE(at: o + 32)) / 100.0,   // PN1.0
            Double(data.readUInt16LE(at: o + 34)) / 100.0,   // PN2.5
            Double(data.readUInt16LE(at: o + 36)) / 100.0,   // PN4.0
            Double(data.readUInt16LE(at: o + 38)) / 100.0    // PN10.0
        )

        let voc = Int(data.readUInt8(at: o + 40))
        let nox = Int(data.readUInt8(at: o + 41))
        let co2Uncomp = Int(data.readUInt16LE(at: o + 42))

        let stroop = StroopData(
            meanTimeCong: data.readFloat32LE(at: o + 44),
            meanTimeIncong: data.readFloat32LE(at: o + 48),
            throughput: Int(data.readUInt8(at: o + 52))
        )

        return ParsedLogCell(
            cellNumber: cellNumber,
            flags: flags,
            timestamp: timestamp,
            temperature: temperature,
            pressure: pressure,
            humidity: humidity,
            co2: co2,
            pm: pm,
            pn: pn,
            voc: voc,
            nox: nox,
            co2Uncomp: co2Uncomp,
            stroop: stroop
        )
    }

    // MARK: - Pet Stats Parser

    /// Parse pet stats from 6-byte characteristic read.
    /// Ported from parsers.ts → parseStats()
    static func parseStats(_ data: Data) -> PetStats {
        PetStats(
            vigour: data.readUInt8(at: 0),
            focus: data.readUInt8(at: 1),
            spirit: data.readUInt8(at: 2),
            age: data.readUInt16LE(at: 3),
            interventions: data.readUInt8(at: 5)
        )
    }

    // MARK: - Bitmap Helpers

    /// Count set bits in a bitmap.
    /// Ported from characteristics.ts → countBitmapItems()
    static func countBitmapItems(_ data: Data) -> Int {
        var count = 0
        for byte in data {
            var b = byte
            while b != 0 {
                count += Int(b & 1)
                b >>= 1
            }
        }
        return count
    }
}
