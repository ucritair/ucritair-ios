// MARK: - ParsedLogCell.swift
// Part of the uCritAir iOS app — an air quality monitor companion.
//
// This file defines the **transient, in-memory** representation of a single
// log cell received from the uCrit device over BLE, *before* it is saved to
// the SwiftData database.
//
// It contains three types:
//
//   1. `ParsedLogCell` — the fully decoded 57-byte BLE log cell notification.
//   2. `StroopData`    — cognitive test metrics embedded within a log cell.
//   3. `LogCellFlag`   — bitmask constants indicating which data categories
//                        are present in a given log cell.
//
// **Data flow (log sync pipeline):**
//
//   BLE Log Stream characteristic (0x0006) notification
//     --> BLEManager receives 57 raw bytes
//       --> Data+Parsing.parseLogCell() decodes bytes into `ParsedLogCell`
//         --> LogCellEntity(from:deviceId:) persists it to SwiftData
//
// **57-byte notification layout:**
//
//   Offset  Size   Field
//   ------  ----   -----
//    0       4     cellNumber    (uint32 LE)
//    4       1     flags         (uint8)
//    5       3     (reserved)
//    8       4     timestamp     (uint32 LE — device-epoch seconds)
//   12       4     temperature   (int32 LE, x0.001 C)
//   16       2     pressure      (uint16 LE, x0.1 hPa)
//   18       2     humidity      (uint16 LE, x0.01 %)
//   20       2     co2           (uint16 LE, ppm)
//   22       8     pm[4]         (4x uint16 LE, x0.01 ug/m3)
//   30      10     pn[5]         (5x uint16 LE, x0.01 #/cm3)
//   40       1     voc           (uint8, index 0-510)
//   41       1     nox           (uint8, index 0-255)
//   42       2     co2Uncomp     (uint16 LE, ppm)
//   44       4     stroopMeanCong    (float32 LE, ms)
//   48       4     stroopMeanIncong  (float32 LE, ms)
//   52       4     stroopThroughput  (uint32 LE, count)
//   56       1     (padding to 57 bytes)

import Foundation

// MARK: - ParsedLogCell

/// A transient, in-memory representation of a single 57-byte log cell
/// received from the uCrit device over BLE.
///
/// ## Overview
///
/// The uCrit device stores environmental data in a circular log on its
/// internal flash memory. Each entry is called a **log cell** and contains
/// a complete snapshot of all sensor readings at a given time. When the iOS
/// app syncs with the device, it receives these log cells as 57-byte BLE
/// notifications on the Log Stream characteristic (`0x0006`).
///
/// `ParsedLogCell` is the **decoded** form of those raw bytes. The BLE
/// parsing layer (see `Data+Parsing`) converts the raw binary data into
/// this human-readable struct. It exists only in memory — to save it to
/// the database, wrap it in a ``LogCellEntity``.
///
/// ## Relationship to Other Types
///
/// - **Input:** Raw `Data` bytes from `BLEManager` (57 bytes per notification)
/// - **Output:** ``LogCellEntity`` for SwiftData persistence
/// - **Related:** ``SensorValues`` holds *live* readings; `ParsedLogCell`
///   holds *historical* readings from the device log
///
/// ## Why tuples for PM and PN?
///
/// The `pm` and `pn` properties use Swift tuples to group related sensor
/// values together, matching the firmware's packed binary layout. When
/// persisting to SwiftData (which does not support tuples), the
/// ``LogCellEntity`` init unpacks them into individual properties.
///
/// ## Conformances
///
/// - `Sendable` — safe to pass across concurrency boundaries (all stored
///   properties are simple value types).
///
/// Ported from `src/types/index.ts` -- `LogCell`.
struct ParsedLogCell: Sendable {

    // MARK: - Cell Identity

    /// Sequential log cell index on the device.
    ///
    /// This is a monotonically increasing counter starting from 0. It comes
    /// from the first 4 bytes of the 57-byte notification (uint32 little-endian).
    /// The app uses this to determine which cells have already been synced
    /// and which are new.
    let cellNumber: Int

    /// Bitmask indicating which data categories are present in this cell.
    ///
    /// Not all log cells contain data for every sensor — for example, the CO2
    /// sensor may not have been active. Check the relevant ``LogCellFlag``
    /// bits before trusting data from a particular category.
    ///
    /// - **Byte offset:** 4 (uint8)
    /// - **See also:** ``LogCellFlag`` for the meaning of each bit
    ///
    /// ## Example
    ///
    /// ```swift
    /// if cell.flags & LogCellFlag.hasCO2 != 0 {
    ///     // CO2 data is valid in this cell
    ///     print("CO2: \(cell.co2) ppm")
    /// }
    /// ```
    let flags: Int

    // MARK: - Timestamp

    /// Unix timestamp in seconds using the device's **local-as-epoch** convention.
    ///
    /// The uCrit firmware stores RTC (Real Time Clock) time with a custom epoch
    /// offset of **59,958,144,000 seconds**. To convert to a standard Unix
    /// timestamp (seconds since January 1, 1970):
    ///
    /// ```swift
    /// let unixTime = cell.timestamp - 59_958_144_000
    /// let date = Date(timeIntervalSince1970: TimeInterval(unixTime))
    /// ```
    ///
    /// - **Byte offset:** 8 (uint32 LE)
    let timestamp: Int

    // MARK: - Environmental Sensors

    /// Temperature in degrees Celsius.
    ///
    /// - **Byte offset:** 12
    /// - **Wire format:** Signed 32-bit integer (int32 LE), scaled by x 0.001
    /// - **Conversion:** Divide the raw int32 value by 1000
    /// - **Typical range:** -40.0 to +85.0 C
    /// - **Requires flag:** ``LogCellFlag/hasTempRHParticles``
    let temperature: Double

    /// Barometric pressure in hectopascals (hPa).
    ///
    /// - **Byte offset:** 16
    /// - **Wire format:** Unsigned 16-bit integer (uint16 LE), scaled by x 0.1
    /// - **Conversion:** Divide the raw uint16 value by 10
    /// - **Typical range:** 300.0 to 1100.0 hPa
    /// - **Requires flag:** ``LogCellFlag/hasTempRHParticles``
    let pressure: Double

    /// Relative humidity as a percentage (0-100%).
    ///
    /// - **Byte offset:** 18
    /// - **Wire format:** Unsigned 16-bit integer (uint16 LE), scaled by x 0.01
    /// - **Conversion:** Divide the raw uint16 value by 100
    /// - **Typical range:** 0.0 to 100.0 %
    /// - **Requires flag:** ``LogCellFlag/hasTempRHParticles``
    let humidity: Double

    /// CO2 concentration in parts per million (ppm).
    ///
    /// This is the **compensated** (calibrated) CO2 reading. For the raw,
    /// uncompensated reading, see ``co2Uncomp``.
    ///
    /// - **Byte offset:** 20
    /// - **Wire format:** Unsigned 16-bit integer (uint16 LE), direct ppm
    /// - **Typical range:** 400 to 5000 ppm
    /// - **Requires flag:** ``LogCellFlag/hasCO2``
    let co2: Int

    /// Particulate matter mass concentrations in micrograms per cubic meter (ug/m3).
    ///
    /// This tuple packs four PM size categories in order:
    ///
    /// | Index | Meaning | Description                              |
    /// |-------|---------|------------------------------------------|
    /// | `.0`  | PM1.0   | Particles <= 1.0 micrometers             |
    /// | `.1`  | PM2.5   | Particles <= 2.5 micrometers (fine)      |
    /// | `.2`  | PM4.0   | Particles <= 4.0 micrometers             |
    /// | `.3`  | PM10    | Particles <= 10.0 micrometers (coarse)   |
    ///
    /// - **Byte offset:** 22 (4 consecutive uint16 LE values, 8 bytes total)
    /// - **Wire format:** Each uint16 LE, scaled by x 0.01
    /// - **Conversion:** Divide each raw uint16 value by 100
    /// - **Requires flag:** ``LogCellFlag/hasTempRHParticles``
    let pm: (Double, Double, Double, Double)

    /// Particle number concentrations in counts per cubic centimeter (#/cm3).
    ///
    /// Unlike PM (mass), PN (number) counts how many individual particles of
    /// each size are present in a cubic centimeter of air.
    ///
    /// | Index | Meaning | Description                              |
    /// |-------|---------|------------------------------------------|
    /// | `.0`  | PN0.5   | Particles <= 0.5 micrometers             |
    /// | `.1`  | PN1.0   | Particles <= 1.0 micrometers             |
    /// | `.2`  | PN2.5   | Particles <= 2.5 micrometers             |
    /// | `.3`  | PN4.0   | Particles <= 4.0 micrometers             |
    /// | `.4`  | PN10    | Particles <= 10.0 micrometers            |
    ///
    /// - **Byte offset:** 30 (5 consecutive uint16 LE values, 10 bytes total)
    /// - **Wire format:** Each uint16 LE, scaled by x 0.01
    /// - **Conversion:** Divide each raw uint16 value by 100
    /// - **Requires flag:** ``LogCellFlag/hasTempRHParticles``
    let pn: (Double, Double, Double, Double, Double)

    // MARK: - Gas Indices

    /// Volatile organic compound (VOC) index.
    ///
    /// A unitless index from the Sensirion SGP41 gas sensor. Values above
    /// 100 indicate increasing VOC levels relative to the sensor's baseline.
    ///
    /// - **Byte offset:** 40 (uint8)
    /// - **Valid range:** 0 to 510
    /// - **Requires flag:** ``LogCellFlag/hasTempRHParticles``
    let voc: Int

    /// Nitrogen oxide (NOx) index.
    ///
    /// A unitless index from the Sensirion SGP41 gas sensor. Higher values
    /// indicate more NOx (from combustion sources like gas stoves or traffic).
    ///
    /// - **Byte offset:** 41 (uint8)
    /// - **Valid range:** 0 to 255
    /// - **Requires flag:** ``LogCellFlag/hasTempRHParticles``
    let nox: Int

    /// Uncompensated (raw) CO2 reading in parts per million.
    ///
    /// This is the raw sensor output before temperature/humidity compensation
    /// is applied. Comparing ``co2`` (compensated) with `co2Uncomp` can help
    /// diagnose sensor calibration issues.
    ///
    /// - **Byte offset:** 42 (uint16 LE)
    /// - **Typical range:** 400 to 5000 ppm
    /// - **Requires flag:** ``LogCellFlag/hasCO2``
    let co2Uncomp: Int

    // MARK: - Cognitive Test Data

    /// Stroop cognitive test metrics recorded during this log cell's time interval.
    ///
    /// The uCrit device includes a built-in Stroop test that measures cognitive
    /// performance. If the user completed a test during this logging interval,
    /// the results are embedded here. Check ``LogCellFlag/hasCogPerf`` before
    /// using these values.
    ///
    /// - **See also:** ``StroopData`` for field details
    let stroop: StroopData
}

// MARK: - StroopData

/// Cognitive test metrics from the Stroop color-word interference test.
///
/// ## What is the Stroop Test?
///
/// The Stroop test is a classic cognitive psychology experiment. The user is
/// shown color words (e.g., "RED", "BLUE") printed in different ink colors.
/// In **congruent** trials, the word matches its color (e.g., "RED" in red ink).
/// In **incongruent** trials, they mismatch (e.g., "RED" in blue ink).
///
/// Incongruent trials take longer because the brain must resolve the conflict
/// between reading the word and naming the color. The difference in reaction
/// times (called the **Stroop effect**) is a measure of cognitive flexibility
/// and executive function.
///
/// ## How it fits in uCritAir
///
/// The uCrit device has a touchscreen that can administer Stroop tests. By
/// correlating cognitive performance with air quality data over time, the app
/// can help users understand how their indoor environment affects their
/// thinking and focus.
///
/// ## Conformances
///
/// - `Sendable` — safe for concurrency.
/// - `Equatable` — enables value comparisons and SwiftUI diffing.
///
/// Ported from `src/types/index.ts` -- `StroopData`.
struct StroopData: Sendable, Equatable {

    /// Mean reaction time for **congruent** (matching) stimuli in milliseconds.
    ///
    /// In a congruent trial, the word text matches its displayed color
    /// (e.g., "RED" shown in red ink). This is the "easy" condition.
    ///
    /// - **Wire format:** IEEE 754 float32 LE (4 bytes at offset 44 in the log cell)
    /// - **Unit:** Milliseconds (ms)
    /// - **Typical range:** 500 to 2000 ms
    let meanTimeCong: Float

    /// Mean reaction time for **incongruent** (mismatched) stimuli in milliseconds.
    ///
    /// In an incongruent trial, the word text differs from its displayed color
    /// (e.g., "RED" shown in blue ink). This is the "hard" condition that
    /// requires more cognitive effort to resolve.
    ///
    /// - **Wire format:** IEEE 754 float32 LE (4 bytes at offset 48 in the log cell)
    /// - **Unit:** Milliseconds (ms)
    /// - **Typical range:** 600 to 3000 ms (usually longer than congruent)
    ///
    /// The difference `meanTimeIncong - meanTimeCong` is the **Stroop effect**
    /// — a larger difference indicates more cognitive interference.
    let meanTimeIncong: Float

    /// Number of correct responses completed during the test period.
    ///
    /// Higher throughput with lower reaction times indicates better cognitive
    /// performance. This metric combines speed and accuracy.
    ///
    /// - **Wire format:** uint32 LE (4 bytes at offset 52 in the log cell)
    /// - **Typical range:** 0 to ~50 responses per test session
    let throughput: Int
}

// MARK: - LogCellFlag

/// Bitmask constants that indicate which data categories are present in a
/// ``ParsedLogCell``.
///
/// ## Overview
///
/// Not every log cell contains data for every sensor. For example, the CO2
/// sensor might have been powered off, or the user might not have taken a
/// Stroop test during that interval. The `flags` bitmask tells consumers
/// which data categories are valid.
///
/// ## How bitmasks work
///
/// A **bitmask** uses individual bits of an integer as on/off flags. Each
/// bit position represents a different yes/no question:
///
/// ```
/// flags byte:  0 0 0 0 0 1 1 1
///              ^             ^
///              bit 7         bit 0
///
/// Bit 0 (0x01) = hasTempRHParticles
/// Bit 1 (0x02) = hasCO2
/// Bit 2 (0x04) = hasCogPerf
/// ```
///
/// To check if a flag is set, use the bitwise AND operator (`&`):
///
/// ```swift
/// let hasTemp = (cell.flags & LogCellFlag.hasTempRHParticles) != 0
/// let hasCO2  = (cell.flags & LogCellFlag.hasCO2) != 0
/// ```
///
/// ## Why not use an `OptionSet`?
///
/// The flags field is a single uint8 from the firmware. A plain struct with
/// static integer constants keeps the code simple and matches the firmware's
/// C-style flag definitions directly.
///
/// Ported from `src/types/index.ts` -- `LogCellFlag`.
struct LogCellFlag {

    /// Bit 0 (`0x01`): Temperature, relative humidity, pressure, particulate
    /// matter (PM), particle number (PN), VOC, and NOx data are present.
    ///
    /// This is the primary environmental data flag. When set, the following
    /// fields in ``ParsedLogCell`` are valid: `temperature`, `pressure`,
    /// `humidity`, `pm`, `pn`, `voc`, `nox`.
    static let hasTempRHParticles = 0x01

    /// Bit 1 (`0x02`): CO2 data (both compensated and uncompensated) is present.
    ///
    /// When set, the ``ParsedLogCell/co2`` and ``ParsedLogCell/co2Uncomp``
    /// fields contain valid readings.
    static let hasCO2 = 0x02

    /// Bit 2 (`0x04`): Cognitive performance (Stroop test) data is present.
    ///
    /// When set, the ``ParsedLogCell/stroop`` field contains valid test results.
    /// When not set, the Stroop fields may contain zeros or stale data and
    /// should be ignored.
    static let hasCogPerf = 0x04
}
