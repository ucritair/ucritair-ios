import Foundation

/// Transient parsed log cell from BLE data, before persistence.
///
/// Represents a single 57-byte log cell notification received via BLE characteristic
/// 0x0006 (Log Stream). The notification format is a 4-byte cell number (uint32 LE)
/// followed by 53 bytes of sensor data. This struct holds the decoded values before
/// they are persisted as a ``LogCellEntity`` in SwiftData.
///
/// Ported from `src/types/index.ts` -- `LogCell`.
struct ParsedLogCell: Sendable {
    /// Sequential log cell index on the device, from the first 4 bytes of the 57-byte notification (uint32 LE).
    let cellNumber: Int

    /// Bitmask indicating which data categories are present. See ``LogCellFlag`` for bit definitions.
    let flags: Int

    /// Unix timestamp in seconds using the device's local-as-epoch convention.
    ///
    /// The firmware stores RTC time with an epoch offset of 59,958,144,000 seconds.
    /// Subtract this offset to convert to standard Unix time.
    let timestamp: Int

    /// Temperature in degrees Celsius. Decoded from int32 LE at byte offset 12, scaled by x 0.001.
    let temperature: Double

    /// Barometric pressure in hectopascals. Decoded from uint16 LE at byte offset 16, scaled by x 0.1.
    let pressure: Double

    /// Relative humidity as a percentage. Decoded from uint16 LE at byte offset 18, scaled by x 0.01.
    let humidity: Double

    /// CO2 concentration in parts per million. Decoded from uint16 LE at byte offset 20.
    let co2: Int

    /// Particulate matter mass concentrations in micrograms per cubic meter.
    ///
    /// Tuple order: (PM1.0, PM2.5, PM4.0, PM10.0). Each value is decoded from a
    /// uint16 LE field scaled by x 0.01.
    let pm: (Double, Double, Double, Double)

    /// Particle number concentrations in counts per cubic centimeter.
    ///
    /// Tuple order: (PN0.5, PN1.0, PN2.5, PN4.0, PN10.0). Each value is decoded
    /// from a uint16 LE field scaled by x 0.01.
    let pn: (Double, Double, Double, Double, Double)

    /// Volatile organic compound index (0-510). Decoded from a uint8 byte.
    let voc: Int

    /// Nitrogen oxide index (0-255). Decoded from a uint8 byte.
    let nox: Int

    /// Uncompensated CO2 reading in parts per million. Decoded from uint16 LE. Useful for diagnostics.
    let co2Uncomp: Int

    /// Stroop cognitive test metrics recorded during this log interval.
    let stroop: StroopData
}

/// Stroop cognitive test metrics captured during a log cell interval.
///
/// The Stroop test measures cognitive interference by comparing reaction times between
/// congruent (matching) and incongruent (mismatched) color-word stimuli. These values
/// are recorded on the uCrit device and transmitted within the log cell data.
///
/// Ported from `src/types/index.ts` -- `StroopData`.
struct StroopData: Sendable, Equatable {
    /// Mean reaction time for congruent (matching) stimuli in milliseconds.
    let meanTimeCong: Float

    /// Mean reaction time for incongruent (mismatched) stimuli in milliseconds.
    let meanTimeIncong: Float

    /// Number of correct responses completed during the test period.
    let throughput: Int
}

/// Bitmask constants for log cell flags indicating which data categories are present.
///
/// The `flags` field in a ``ParsedLogCell`` uses these bits to indicate which sensor
/// groups were active when the cell was recorded. Consumers should check the relevant
/// flag before using data from that category.
///
/// Ported from `src/types/index.ts` -- `LogCellFlag`.
struct LogCellFlag {
    /// Bit 0: Temperature, relative humidity, and particulate matter data are present.
    static let hasTempRHParticles = 0x01

    /// Bit 1: CO2 (both compensated and uncompensated) data is present.
    static let hasCO2 = 0x02

    /// Bit 2: Cognitive performance (Stroop test) data is present.
    static let hasCogPerf = 0x04
}
