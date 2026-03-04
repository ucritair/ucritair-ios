import Foundation
import SwiftData

/// Persisted log cell in SwiftData (replaces IndexedDB in the web app).
///
/// Stores the decoded contents of a 57-byte BLE log cell notification as individual
/// properties (tuples are not supported by SwiftData). Each entity is scoped to a
/// specific device via ``deviceId``.
///
/// The ``compositeKey`` field provides compound uniqueness (`"deviceId|cellNumber"`)
/// since SwiftData lacks native compound unique constraints.
@Model
final class LogCellEntity {
    /// Synthetic unique key in the format `"deviceId|cellNumber"` for compound uniqueness.
    @Attribute(.unique) var compositeKey: String

    /// The `CBPeripheral.identifier.uuidString` of the device that produced this log cell.
    var deviceId: String

    /// Sequential log cell index on the device.
    var cellNumber: Int

    /// Bitmask of active data categories. See ``LogCellFlag`` for bit definitions.
    var flags: Int

    /// Unix timestamp in seconds using the device's local-as-epoch convention.
    /// Subtract the RTC epoch offset (59,958,144,000) to convert to standard Unix time.
    var timestamp: Int

    /// Temperature in degrees Celsius. Log cell byte offset 12 (int32 LE x 0.001).
    var temperature: Double

    /// Barometric pressure in hectopascals. Log cell byte offset 16 (uint16 LE x 0.1).
    var pressure: Double

    /// Relative humidity as a percentage. Log cell byte offset 18 (uint16 LE x 0.01).
    var humidity: Double

    /// CO2 concentration in parts per million. Log cell byte offset 20 (uint16 LE).
    var co2: Int

    /// PM1.0 particulate matter in micrograms per cubic meter (uint16 LE x 0.01).
    var pm1_0: Double

    /// PM2.5 particulate matter in micrograms per cubic meter (uint16 LE x 0.01).
    var pm2_5: Double

    /// PM4.0 particulate matter in micrograms per cubic meter (uint16 LE x 0.01).
    var pm4_0: Double

    /// PM10 particulate matter in micrograms per cubic meter (uint16 LE x 0.01).
    var pm10: Double

    /// PN0.5 particle number concentration in counts per cubic centimeter (uint16 LE x 0.01).
    var pn0_5: Double

    /// PN1.0 particle number concentration in counts per cubic centimeter (uint16 LE x 0.01).
    var pn1_0: Double

    /// PN2.5 particle number concentration in counts per cubic centimeter (uint16 LE x 0.01).
    var pn2_5: Double

    /// PN4.0 particle number concentration in counts per cubic centimeter (uint16 LE x 0.01).
    var pn4_0: Double

    /// PN10 particle number concentration in counts per cubic centimeter (uint16 LE x 0.01).
    var pn10: Double

    /// Volatile organic compound index (0-510).
    var voc: Int

    /// Nitrogen oxide index (0-255).
    var nox: Int

    /// Uncompensated CO2 reading in parts per million. Useful for sensor diagnostics.
    var co2Uncomp: Int

    /// Stroop test mean reaction time for congruent stimuli in milliseconds.
    var stroopMeanCong: Float

    /// Stroop test mean reaction time for incongruent stimuli in milliseconds.
    var stroopMeanIncong: Float

    /// Stroop test throughput (number of correct responses).
    var stroopThroughput: Int

    /// Creates a persisted log cell entity from a transient parsed log cell.
    ///
    /// Maps all fields from the ``ParsedLogCell`` (including tuple elements for PM and PN
    /// values) into individual SwiftData-compatible stored properties. The ``compositeKey``
    /// is automatically generated as `"deviceId|cellNumber"`.
    ///
    /// - Parameters:
    ///   - cell: The parsed log cell containing decoded BLE data.
    ///   - deviceId: The `CBPeripheral.identifier.uuidString` of the source device.
    init(from cell: ParsedLogCell, deviceId: String) {
        self.compositeKey = "\(deviceId)|\(cell.cellNumber)"
        self.deviceId = deviceId
        self.cellNumber = cell.cellNumber
        self.flags = cell.flags
        self.timestamp = cell.timestamp
        self.temperature = cell.temperature
        self.pressure = cell.pressure
        self.humidity = cell.humidity
        self.co2 = cell.co2
        self.pm1_0 = cell.pm.0
        self.pm2_5 = cell.pm.1
        self.pm4_0 = cell.pm.2
        self.pm10 = cell.pm.3
        self.pn0_5 = cell.pn.0
        self.pn1_0 = cell.pn.1
        self.pn2_5 = cell.pn.2
        self.pn4_0 = cell.pn.3
        self.pn10 = cell.pn.4
        self.voc = cell.voc
        self.nox = cell.nox
        self.co2Uncomp = cell.co2Uncomp
        self.stroopMeanCong = cell.stroop.meanTimeCong
        self.stroopMeanIncong = cell.stroop.meanTimeIncong
        self.stroopThroughput = cell.stroop.throughput
    }
}
