import Foundation

// MARK: - ParsedLogCell

struct ParsedLogCell: Sendable {

    let cellNumber: Int

    let flags: Int

    let timestamp: Int

    let temperature: Double

    let pressure: Double

    let humidity: Double

    let co2: Int

    let pm: (pm1_0: Double, pm2_5: Double, pm4_0: Double, pm10: Double)

    let pn: (pn0_5: Double, pn1_0: Double, pn2_5: Double, pn4_0: Double, pn10: Double)

    let voc: Int

    let nox: Int

    let co2Uncomp: Int

    let stroop: StroopData
}

// MARK: - StroopData

struct StroopData: Sendable, Equatable {

    let meanTimeCong: Float

    let meanTimeIncong: Float

    let throughput: Int
}

// MARK: - LogCellFlag

struct LogCellFlag {

    static let hasTempRHParticles = 0x01

    static let hasCO2 = 0x02

    static let hasCogPerf = 0x04
}
