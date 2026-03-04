import Foundation

enum BLEParsers {

    static func parseFloat16(_ b0: UInt8, _ b1: UInt8) -> Double {
        let val = UInt16(b0) | (UInt16(b1) << 8)

        let sign = (val >> 15) & 1
        let exp = (val >> 10) & 0x1F
        let frac = val & 0x3FF

        if exp == 0 {
            return Double(sign != 0 ? -1 : 1) * (Double(frac) / 1024.0) * pow(2.0, -14.0)
        }
        if exp == 31 {
            return frac != 0 ? .nan : (sign != 0 ? -.infinity : .infinity)
        }

        return Double(sign != 0 ? -1 : 1) * (1.0 + Double(frac) / 1024.0) * pow(2.0, Double(exp) - 15.0)
    }

    static func parseTemperature(_ data: Data) throws -> Double {
        Double(try data.tryReadInt16LE(at: 0)) / 100.0
    }

    static func parseHumidity(_ data: Data) throws -> Double {
        Double(try data.tryReadUInt16LE(at: 0)) / 100.0
    }

    static func parsePressure(_ data: Data) throws -> Double {
        Double(try data.tryReadUInt32LE(at: 0)) / 1000.0
    }

    static func parseCO2(_ data: Data) throws -> Double {
        Double(try data.tryReadUInt16LE(at: 0))
    }

    static func parsePM(_ data: Data) throws -> Double {
        parseFloat16(try data.tryReadUInt8(at: 0), try data.tryReadUInt8(at: 1))
    }

    static func rtcToUnix(_ rtcTime: UInt64) -> Int {
        Int(rtcTime) - Int(BLEConstants.rtcEpochOffset)
    }

    static func parseLogCell(_ data: Data) throws -> ParsedLogCell {
        let cellNumber = Int(try data.tryReadUInt32LE(at: 0))

        let o = 4

        let flags = Int(try data.tryReadUInt8(at: o + 0))

        let rtcTimestamp = try data.tryReadUInt64LE(at: o + 4)
        let timestamp = rtcToUnix(rtcTimestamp)

        let temperature = Double(try data.tryReadInt32LE(at: o + 12)) / 1000.0

        let pressure = Double(try data.tryReadUInt16LE(at: o + 16)) / 10.0

        let humidity = Double(try data.tryReadUInt16LE(at: o + 18)) / 100.0

        let co2 = Int(try data.tryReadUInt16LE(at: o + 20))

        let pm = (
            pm1_0: Double(try data.tryReadUInt16LE(at: o + 22)) / 100.0,
            pm2_5: Double(try data.tryReadUInt16LE(at: o + 24)) / 100.0,
            pm4_0: Double(try data.tryReadUInt16LE(at: o + 26)) / 100.0,
            pm10:  Double(try data.tryReadUInt16LE(at: o + 28)) / 100.0
        )

        let pn = (
            pn0_5: Double(try data.tryReadUInt16LE(at: o + 30)) / 100.0,
            pn1_0: Double(try data.tryReadUInt16LE(at: o + 32)) / 100.0,
            pn2_5: Double(try data.tryReadUInt16LE(at: o + 34)) / 100.0,
            pn4_0: Double(try data.tryReadUInt16LE(at: o + 36)) / 100.0,
            pn10:  Double(try data.tryReadUInt16LE(at: o + 38)) / 100.0
        )

        let voc = Int(try data.tryReadUInt8(at: o + 40))

        let nox = Int(try data.tryReadUInt8(at: o + 41))

        let co2Uncomp = Int(try data.tryReadUInt16LE(at: o + 42))

        let stroop = StroopData(
            meanTimeCong: try data.tryReadFloat32LE(at: o + 44),
            meanTimeIncong: try data.tryReadFloat32LE(at: o + 48),
            throughput: Int(try data.tryReadUInt8(at: o + 52))
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

    static func parseStats(_ data: Data) throws -> PetStats {
        PetStats(
            vigour: try data.tryReadUInt8(at: 0),
            focus: try data.tryReadUInt8(at: 1),
            spirit: try data.tryReadUInt8(at: 2),
            age: try data.tryReadUInt16LE(at: 3),
            interventions: try data.tryReadUInt8(at: 5)
        )
    }

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
