import Foundation

/// Current sensor readings from the uCrit device.
///
/// All values are optional (`nil` = not yet received from BLE).
/// Populated from ESS (Environmental Sensing Service, UUID 0x181A) characteristic
/// notifications: temperature (0x2A6E), humidity (0x2A6F), pressure (0x2A6D),
/// CO2 (0x2B8C), PM1.0 (0x2BD5), PM2.5 (0x2BD6), PM10 (0x2BD7).
///
/// Ported from `src/types/index.ts` -- `SensorValues`.
struct SensorValues: Equatable, Sendable {
    /// Ambient temperature in degrees Celsius. ESS characteristic 0x2A6E (sint16 x 0.01 degrees C).
    var temperature: Double?

    /// Relative humidity as a percentage (0-100). ESS characteristic 0x2A6F (uint16 x 0.01%).
    var humidity: Double?

    /// CO2 concentration in parts per million. ESS characteristic 0x2B8C (uint16 ppm).
    var co2: Double?

    /// PM1.0 particulate matter concentration in micrograms per cubic meter. ESS characteristic 0x2BD5 (fp16).
    var pm1_0: Double?

    /// PM2.5 particulate matter concentration in micrograms per cubic meter. ESS characteristic 0x2BD6 (fp16).
    var pm2_5: Double?

    /// PM4.0 particulate matter concentration in micrograms per cubic meter. Not in standard ESS; derived from log data.
    var pm4_0: Double?

    /// PM10 particulate matter concentration in micrograms per cubic meter. ESS characteristic 0x2BD7 (fp16).
    var pm10: Double?

    /// Barometric pressure in hectopascals (hPa). ESS characteristic 0x2A6D (uint32 x 0.1 Pa).
    var pressure: Double?

    /// Volatile organic compound index (0-510). Higher values indicate more VOCs.
    var voc: Double?

    /// Nitrogen oxide index (0-255). Higher values indicate more NOx.
    var nox: Double?

    /// A default instance with all sensor values set to `nil`.
    static let empty = SensorValues()

    /// Merge partial updates into this value (non-nil fields overwrite).
    ///
    /// - Parameter update: A partial update containing only the fields that changed.
    mutating func merge(_ update: PartialSensorUpdate) {
        if let v = update.temperature { temperature = v }
        if let v = update.humidity { humidity = v }
        if let v = update.co2 { co2 = v }
        if let v = update.pm1_0 { pm1_0 = v }
        if let v = update.pm2_5 { pm2_5 = v }
        if let v = update.pm4_0 { pm4_0 = v }
        if let v = update.pm10 { pm10 = v }
        if let v = update.pressure { pressure = v }
        if let v = update.voc { voc = v }
        if let v = update.nox { nox = v }
    }

    /// Whether at least one sensor value is present.
    var hasAnyValue: Bool {
        temperature != nil || humidity != nil || co2 != nil ||
        pm1_0 != nil || pm2_5 != nil || pm4_0 != nil || pm10 != nil ||
        pressure != nil || voc != nil || nox != nil
    }
}

/// A partial sensor update containing only the fields that changed.
///
/// Created when individual ESS characteristic notifications arrive. Passed to
/// ``SensorValues/merge(_:)`` to update the current sensor state without
/// overwriting fields that were not included in this notification.
struct PartialSensorUpdate: Sendable {
    /// Updated temperature in degrees Celsius, or `nil` if unchanged.
    var temperature: Double?

    /// Updated relative humidity percentage, or `nil` if unchanged.
    var humidity: Double?

    /// Updated CO2 concentration in ppm, or `nil` if unchanged.
    var co2: Double?

    /// Updated PM1.0 concentration in micrograms per cubic meter, or `nil` if unchanged.
    var pm1_0: Double?

    /// Updated PM2.5 concentration in micrograms per cubic meter, or `nil` if unchanged.
    var pm2_5: Double?

    /// Updated PM4.0 concentration in micrograms per cubic meter, or `nil` if unchanged.
    var pm4_0: Double?

    /// Updated PM10 concentration in micrograms per cubic meter, or `nil` if unchanged.
    var pm10: Double?

    /// Updated barometric pressure in hPa, or `nil` if unchanged.
    var pressure: Double?

    /// Updated VOC index, or `nil` if unchanged.
    var voc: Double?

    /// Updated NOx index, or `nil` if unchanged.
    var nox: Double?
}
