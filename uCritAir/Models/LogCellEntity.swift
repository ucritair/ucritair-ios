// MARK: - LogCellEntity.swift
// Part of the uCritAir iOS app — an air quality monitor companion.
//
// This file defines `LogCellEntity`, the **persistent database model** for
// historical sensor data. It is the SwiftData equivalent of the IndexedDB
// store used in the web app.
//
// **Data flow (how log cells get from the device to the database):**
//
//   BLE Log Stream notification (57 raw bytes)
//     --> Data+Parsing.parseLogCell() --> `ParsedLogCell` (in-memory struct)
//       --> `LogCellEntity(from:deviceId:)` --> SwiftData inserts to SQLite
//
// **Why a separate entity (instead of saving `ParsedLogCell` directly)?**
//
// 1. SwiftData requires `@Model` classes — it cannot persist plain structs.
// 2. SwiftData does not support **tuples**. The `ParsedLogCell` uses tuples
//    for PM and PN values (e.g., `pm: (Double, Double, Double, Double)`),
//    but `LogCellEntity` must unpack these into individual properties
//    (`pm1_0`, `pm2_5`, `pm4_0`, `pm10`).
// 3. `LogCellEntity` adds a `deviceId` and `compositeKey` for multi-device
//    support that `ParsedLogCell` does not need.
//
// **SwiftData crash course (for first-year CS students):**
//
// SwiftData is Apple's persistence framework. It automatically saves Swift
// objects to a local SQLite database file on the device.
//
// Key annotations used in this file:
//
//   @Model        — tells SwiftData "this class is a database table."
//                   Each property becomes a column. Each instance is a row.
//
//   @Attribute(.unique) — marks a column as the **primary key**. Two rows
//                   cannot have the same value in this column. If you try
//                   to insert a duplicate, SwiftData will update the
//                   existing row instead of creating a new one (upsert).
//
//   final class   — SwiftData models must be **reference types** (classes),
//                   not value types (structs). `final` prevents subclassing.
//
// **The composite key pattern:**
//
// Relational databases often use **compound primary keys** — a unique
// constraint that spans multiple columns (e.g., "deviceId + cellNumber"
// together must be unique). SwiftData does not support compound unique
// constraints natively.
//
// Our workaround: create a synthetic `compositeKey` string by concatenating
// the two values with a separator:
//
//   compositeKey = "\(deviceId)|\(cellNumber)"
//
// For example: "A1B2C3D4-E5F6-...|42"
//
// This single-column string uniqueness achieves the same effect as a
// compound (deviceId, cellNumber) unique constraint. The pipe character
// "|" is safe as a separator because neither UUIDs nor integers contain it.

import Foundation
import SwiftData

/// A persistently stored log cell in the SwiftData database.
///
/// ## Overview
///
/// `LogCellEntity` stores a single historical sensor snapshot downloaded from
/// the uCrit device. Each entity corresponds to one 57-byte BLE log cell
/// notification, decoded and flattened into individual SwiftData-compatible
/// properties.
///
/// The app syncs log cells from the device on each connection and stores
/// them locally so the user can view historical air quality data, charts,
/// and trends even when the device is not connected.
///
/// ## Uniqueness (the composite key pattern)
///
/// Each log cell is uniquely identified by the combination of:
/// 1. **Which device** produced it (`deviceId`)
/// 2. **Which cell number** it is on that device (`cellNumber`)
///
/// Since SwiftData does not support compound unique constraints (like SQL's
/// `UNIQUE(deviceId, cellNumber)`), we synthesize a ``compositeKey`` string
/// in the format `"deviceId|cellNumber"` and apply `@Attribute(.unique)`
/// to it. This ensures no duplicate cells are stored, even across multiple
/// devices.
///
/// ## Relationship to `ParsedLogCell`
///
/// - ``ParsedLogCell`` is the **transient** (in-memory) decoded form,
///   created during BLE parsing. It uses tuples for compactness.
/// - `LogCellEntity` is the **persistent** (database) form. It unpacks
///   tuples into individual properties because SwiftData cannot store tuples.
///
/// ## Why `var` instead of `let`?
///
/// SwiftData requires mutable (`var`) properties so it can update them
/// during upsert operations (when a log cell with the same composite key
/// is re-synced, SwiftData updates the existing row).
@Model
final class LogCellEntity {

    // MARK: - Identity & Device Scoping

    /// Synthetic unique key in the format `"deviceId|cellNumber"`.
    ///
    /// This field serves as the **primary key** for the SwiftData table.
    /// It implements a **composite key pattern** — encoding two values
    /// (device identity + cell number) into a single unique string because
    /// SwiftData does not support multi-column unique constraints.
    ///
    /// - **Format:** `"<CBPeripheral UUID string>|<cell number integer>"`
    /// - **Example:** `"A1B2C3D4-E5F6-7890-ABCD-EF1234567890|42"`
    /// - **SwiftData annotation:** `@Attribute(.unique)` prevents duplicate
    ///   rows. Inserting a cell with the same key updates the existing row.
    @Attribute(.unique) var compositeKey: String

    /// The `CBPeripheral.identifier.uuidString` of the device that produced
    /// this log cell.
    ///
    /// Acts as a **foreign key** linking back to the ``DeviceProfile`` with
    /// the same `deviceId`. (Note: this is a logical relationship enforced
    /// by application code, not a formal SwiftData `@Relationship`.)
    ///
    /// Used to filter log cells by device:
    /// ```swift
    /// let predicate = #Predicate<LogCellEntity> { $0.deviceId == myDeviceId }
    /// ```
    var deviceId: String

    /// Sequential log cell index on the device (0-based, monotonically
    /// increasing).
    ///
    /// The device increments this counter each time it records a new log
    /// cell. The app uses the highest `cellNumber` it has stored to know
    /// where to resume syncing on the next connection.
    var cellNumber: Int

    // MARK: - Data Validity Flags

    /// Bitmask of active data categories in this log cell.
    ///
    /// Check the relevant ``LogCellFlag`` bits before trusting data from
    /// a particular category. For example:
    ///
    /// ```swift
    /// if entity.flags & LogCellFlag.hasCO2 != 0 {
    ///     // entity.co2 is a valid reading
    /// }
    /// ```
    ///
    /// See ``LogCellFlag`` for the meaning of each bit.
    var flags: Int

    // MARK: - Timestamp

    /// Unix timestamp in seconds using the device's **local-as-epoch**
    /// convention.
    ///
    /// The uCrit firmware uses a custom epoch offset of
    /// **59,958,144,000 seconds**. To convert to a standard Unix timestamp
    /// (seconds since January 1, 1970 UTC):
    ///
    /// ```swift
    /// let unixSeconds = entity.timestamp - 59_958_144_000
    /// let date = Date(timeIntervalSince1970: TimeInterval(unixSeconds))
    /// ```
    var timestamp: Int

    // MARK: - Environmental Sensors

    /// Temperature in degrees Celsius.
    ///
    /// - **Source:** Log cell byte offset 12, int32 LE, scaled by x 0.001
    /// - **Typical range:** -40.0 to +85.0 C
    /// - **Requires flag:** ``LogCellFlag/hasTempRHParticles``
    var temperature: Double

    /// Barometric pressure in hectopascals (hPa).
    ///
    /// - **Source:** Log cell byte offset 16, uint16 LE, scaled by x 0.1
    /// - **Typical range:** 300.0 to 1100.0 hPa
    /// - **Requires flag:** ``LogCellFlag/hasTempRHParticles``
    var pressure: Double

    /// Relative humidity as a percentage (0-100%).
    ///
    /// - **Source:** Log cell byte offset 18, uint16 LE, scaled by x 0.01
    /// - **Valid range:** 0.0 to 100.0 %
    /// - **Requires flag:** ``LogCellFlag/hasTempRHParticles``
    var humidity: Double

    /// CO2 concentration in parts per million (ppm), compensated (calibrated).
    ///
    /// - **Source:** Log cell byte offset 20, uint16 LE, direct ppm
    /// - **Typical range:** 400 to 5000 ppm
    /// - **Requires flag:** ``LogCellFlag/hasCO2``
    var co2: Int

    // MARK: - Particulate Matter (Mass Concentration)
    // These are the individual properties unpacked from ParsedLogCell.pm tuple.

    /// PM1.0 mass concentration: particles <= 1.0 um, in micrograms per
    /// cubic meter (ug/m3).
    ///
    /// - **Source:** Log cell byte offset 22, uint16 LE, scaled by x 0.01
    /// - **Unpacked from:** `ParsedLogCell.pm.0`
    var pm1_0: Double

    /// PM2.5 mass concentration: particles <= 2.5 um, in ug/m3.
    ///
    /// This is the most commonly reported particulate metric worldwide.
    ///
    /// - **Source:** Log cell byte offset 24, uint16 LE, scaled by x 0.01
    /// - **Unpacked from:** `ParsedLogCell.pm.1`
    var pm2_5: Double

    /// PM4.0 mass concentration: particles <= 4.0 um, in ug/m3.
    ///
    /// - **Source:** Log cell byte offset 26, uint16 LE, scaled by x 0.01
    /// - **Unpacked from:** `ParsedLogCell.pm.2`
    var pm4_0: Double

    /// PM10 mass concentration: particles <= 10.0 um, in ug/m3.
    ///
    /// - **Source:** Log cell byte offset 28, uint16 LE, scaled by x 0.01
    /// - **Unpacked from:** `ParsedLogCell.pm.3`
    var pm10: Double

    // MARK: - Particle Number Concentration
    // These are the individual properties unpacked from ParsedLogCell.pn tuple.

    /// PN0.5: count of particles <= 0.5 um per cubic centimeter (#/cm3).
    ///
    /// - **Source:** Log cell byte offset 30, uint16 LE, scaled by x 0.01
    /// - **Unpacked from:** `ParsedLogCell.pn.0`
    var pn0_5: Double

    /// PN1.0: count of particles <= 1.0 um per cubic centimeter (#/cm3).
    ///
    /// - **Source:** Log cell byte offset 32, uint16 LE, scaled by x 0.01
    /// - **Unpacked from:** `ParsedLogCell.pn.1`
    var pn1_0: Double

    /// PN2.5: count of particles <= 2.5 um per cubic centimeter (#/cm3).
    ///
    /// - **Source:** Log cell byte offset 34, uint16 LE, scaled by x 0.01
    /// - **Unpacked from:** `ParsedLogCell.pn.2`
    var pn2_5: Double

    /// PN4.0: count of particles <= 4.0 um per cubic centimeter (#/cm3).
    ///
    /// - **Source:** Log cell byte offset 36, uint16 LE, scaled by x 0.01
    /// - **Unpacked from:** `ParsedLogCell.pn.3`
    var pn4_0: Double

    /// PN10: count of particles <= 10.0 um per cubic centimeter (#/cm3).
    ///
    /// - **Source:** Log cell byte offset 38, uint16 LE, scaled by x 0.01
    /// - **Unpacked from:** `ParsedLogCell.pn.4`
    var pn10: Double

    // MARK: - Gas Indices

    /// Volatile organic compound (VOC) index.
    ///
    /// A unitless index from the Sensirion SGP41 gas sensor (0-510).
    /// 100 = baseline; higher = more VOCs detected.
    var voc: Int

    /// Nitrogen oxide (NOx) index.
    ///
    /// A unitless index from the Sensirion SGP41 gas sensor (0-255).
    /// 1 = baseline; higher = more NOx from combustion sources.
    var nox: Int

    /// Uncompensated (raw, pre-calibration) CO2 reading in ppm.
    ///
    /// Comparing this with the compensated ``co2`` value can help diagnose
    /// sensor drift or calibration problems. If the two values diverge
    /// significantly, the temperature/humidity compensation may be off.
    ///
    /// - **Requires flag:** ``LogCellFlag/hasCO2``
    var co2Uncomp: Int

    // MARK: - Stroop Cognitive Test Data

    /// Mean reaction time for **congruent** Stroop test stimuli, in
    /// milliseconds (ms).
    ///
    /// - **Requires flag:** ``LogCellFlag/hasCogPerf``
    /// - **See also:** ``StroopData/meanTimeCong`` for a full explanation
    var stroopMeanCong: Float

    /// Mean reaction time for **incongruent** Stroop test stimuli, in
    /// milliseconds (ms).
    ///
    /// - **Requires flag:** ``LogCellFlag/hasCogPerf``
    /// - **See also:** ``StroopData/meanTimeIncong`` for a full explanation
    var stroopMeanIncong: Float

    /// Number of correct Stroop test responses completed.
    ///
    /// - **Requires flag:** ``LogCellFlag/hasCogPerf``
    /// - **See also:** ``StroopData/throughput`` for a full explanation
    var stroopThroughput: Int

    // MARK: - Initializer

    /// Creates a persisted `LogCellEntity` from a transient ``ParsedLogCell``.
    ///
    /// This initializer is the bridge between the BLE parsing layer (which
    /// produces ``ParsedLogCell`` structs) and the persistence layer (which
    /// stores `LogCellEntity` objects in SwiftData).
    ///
    /// It performs two key transformations:
    ///
    /// 1. **Tuple unpacking:** `ParsedLogCell` stores PM values as a
    ///    4-element tuple and PN values as a 5-element tuple. Since SwiftData
    ///    cannot persist tuples, this initializer unpacks them into individual
    ///    named properties (`pm1_0`, `pm2_5`, ..., `pn0_5`, `pn1_0`, ...).
    ///
    /// 2. **Composite key generation:** Concatenates `deviceId` and
    ///    `cellNumber` with a pipe separator to create the unique
    ///    ``compositeKey`` used as the primary key.
    ///
    /// - Parameters:
    ///   - cell: The transient parsed log cell containing all decoded sensor
    ///     data from the 57-byte BLE notification.
    ///   - deviceId: The `CBPeripheral.identifier.uuidString` of the device
    ///     that produced this log cell. Used for device scoping and composite
    ///     key generation.
    init(from cell: ParsedLogCell, deviceId: String) {
        // Build the composite key: "deviceId|cellNumber"
        self.compositeKey = "\(deviceId)|\(cell.cellNumber)"
        self.deviceId = deviceId
        self.cellNumber = cell.cellNumber
        self.flags = cell.flags
        self.timestamp = cell.timestamp
        self.temperature = cell.temperature
        self.pressure = cell.pressure
        self.humidity = cell.humidity
        self.co2 = cell.co2

        // Unpack the PM tuple into individual SwiftData-compatible properties.
        // ParsedLogCell.pm is (PM1.0, PM2.5, PM4.0, PM10) — indexed .0 through .3.
        self.pm1_0 = cell.pm.0
        self.pm2_5 = cell.pm.1
        self.pm4_0 = cell.pm.2
        self.pm10 = cell.pm.3

        // Unpack the PN tuple into individual properties.
        // ParsedLogCell.pn is (PN0.5, PN1.0, PN2.5, PN4.0, PN10) — indexed .0 through .4.
        self.pn0_5 = cell.pn.0
        self.pn1_0 = cell.pn.1
        self.pn2_5 = cell.pn.2
        self.pn4_0 = cell.pn.3
        self.pn10 = cell.pn.4

        self.voc = cell.voc
        self.nox = cell.nox
        self.co2Uncomp = cell.co2Uncomp

        // Map StroopData struct fields to flat SwiftData properties.
        self.stroopMeanCong = cell.stroop.meanTimeCong
        self.stroopMeanIncong = cell.stroop.meanTimeIncong
        self.stroopThroughput = cell.stroop.throughput
    }
}
