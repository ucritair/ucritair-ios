// MARK: - SensorValues.swift
// Part of the uCritAir iOS app — an air quality monitor companion.
//
// This file defines the **live sensor state** for a connected uCrit device.
// It contains two types:
//
//   1. `SensorValues`        — the *complete* snapshot of every sensor reading.
//   2. `PartialSensorUpdate` — a *partial* update carrying only the fields that
//                              changed in a single BLE notification.
//
// **How they work together (the "merge" pattern):**
//
// BLE (Bluetooth Low Energy) sends sensor data one characteristic at a time.
// For example, a temperature notification arrives, then a humidity notification
// a moment later.  Rather than replacing the entire snapshot each time, we:
//
//   1. Create a `PartialSensorUpdate` with just the new value(s).
//   2. Call `SensorValues.merge(_:)` to overlay the update onto the current
//      snapshot, leaving all other fields untouched.
//
// This is similar to the "spread operator" merge pattern in JavaScript/TypeScript:
//   `sensorValues = { ...sensorValues, ...partialUpdate }`
//
// The `SensorValues` struct is the single source of truth displayed in the UI.
// Views observe it through `DeviceViewModel.sensors` (published via Combine).

import Foundation

/// The complete, current set of sensor readings from a connected uCrit device.
///
/// ## Overview
///
/// `SensorValues` acts as a **snapshot** of every environmental sensor on the
/// uCrit hardware. All properties are `Optional` — a `nil` value means the
/// app has not yet received that particular reading over BLE.
///
/// The readings are populated from the **Environmental Sensing Service (ESS)**
/// (Bluetooth SIG UUID `0x181A`). Each sensor maps to a standard ESS
/// characteristic:
///
/// | Sensor       | ESS UUID | Wire Format           |
/// |------------- |----------|-----------------------|
/// | Temperature  | 0x2A6E   | sint16, x 0.01 C     |
/// | Humidity     | 0x2A6F   | uint16, x 0.01 %     |
/// | Pressure     | 0x2A6D   | uint32, x 0.1 Pa     |
/// | CO2          | 0x2B8C   | uint16, ppm           |
/// | PM1.0        | 0x2BD5   | IEEE 754 binary16     |
/// | PM2.5        | 0x2BD6   | IEEE 754 binary16     |
/// | PM10         | 0x2BD7   | IEEE 754 binary16     |
///
/// VOC, NOx, and PM4.0 are not part of the standard ESS profile; they are
/// derived from log data or vendor-specific characteristics.
///
/// ## Conformances
///
/// - `Equatable` — enables SwiftUI diffing so the UI only redraws when values
///   actually change.
/// - `Sendable` — safe to pass between Swift concurrency contexts (e.g., from
///   the BLE actor to the main actor for UI updates).
///
/// ## Usage
///
/// ```swift
/// // Start with an empty snapshot (all nil)
/// var sensors = SensorValues.empty
///
/// // A temperature notification arrives from BLE
/// let update = PartialSensorUpdate(temperature: 22.5)
/// sensors.merge(update)
/// // sensors.temperature is now 22.5; all other fields remain nil
/// ```
///
/// Ported from `src/types/index.ts` -- `SensorValues`.
struct SensorValues: Equatable, Sendable {

    // MARK: - Environmental Sensor Properties

    /// Ambient temperature in degrees Celsius.
    ///
    /// - **BLE source:** ESS characteristic `0x2A6E`
    /// - **Wire format:** Signed 16-bit integer, scaled by x 0.01 (divide raw value by 100)
    /// - **Typical range:** -40.0 to +85.0 C (sensor hardware limits)
    /// - **Example:** A raw BLE value of `2250` becomes `22.50` C
    var temperature: Double?

    /// Relative humidity as a percentage of saturation.
    ///
    /// - **BLE source:** ESS characteristic `0x2A6F`
    /// - **Wire format:** Unsigned 16-bit integer, scaled by x 0.01
    /// - **Valid range:** 0.0 to 100.0 %
    /// - **Example:** A raw BLE value of `5500` becomes `55.00` %
    var humidity: Double?

    /// Carbon dioxide (CO2) concentration in parts per million (ppm).
    ///
    /// CO2 is a key indicator of indoor ventilation quality. Outdoor air is
    /// roughly 420 ppm; levels above 1000 ppm suggest poor ventilation.
    ///
    /// - **BLE source:** ESS characteristic `0x2B8C`
    /// - **Wire format:** Unsigned 16-bit integer, direct ppm value
    /// - **Typical range:** 400 to 5000 ppm
    var co2: Double?

    /// PM1.0 particulate matter mass concentration in micrograms per cubic meter (ug/m3).
    ///
    /// PM1.0 refers to airborne particles with a diameter of 1.0 micrometers or
    /// smaller. These ultra-fine particles can penetrate deep into lung tissue.
    ///
    /// - **BLE source:** ESS characteristic `0x2BD5`
    /// - **Wire format:** IEEE 754 binary16 (half-precision float)
    /// - **Typical range:** 0.0 to 500.0 ug/m3
    var pm1_0: Double?

    /// PM2.5 particulate matter mass concentration in micrograms per cubic meter (ug/m3).
    ///
    /// PM2.5 ("fine particles") are 2.5 micrometers or smaller. This is the most
    /// commonly reported particulate metric and the primary input to air quality
    /// index (AQI) calculations worldwide.
    ///
    /// - **BLE source:** ESS characteristic `0x2BD6`
    /// - **Wire format:** IEEE 754 binary16 (half-precision float)
    /// - **Typical range:** 0.0 to 500.0 ug/m3
    /// - **Health thresholds:** < 12 ug/m3 (good), 12-35 (moderate), > 35 (unhealthy)
    var pm2_5: Double?

    /// PM4.0 particulate matter mass concentration in micrograms per cubic meter (ug/m3).
    ///
    /// PM4.0 captures particles 4.0 micrometers or smaller. This metric is not
    /// part of the standard Bluetooth ESS profile; it is only available from
    /// historical log data downloaded from the device, not from live BLE
    /// notifications.
    ///
    /// - **BLE source:** Not available via ESS; derived from log cell data only
    /// - **Typical range:** 0.0 to 500.0 ug/m3
    var pm4_0: Double?

    /// PM10 particulate matter mass concentration in micrograms per cubic meter (ug/m3).
    ///
    /// PM10 ("coarse particles") are 10 micrometers or smaller. Sources include
    /// dust, pollen, and mold spores.
    ///
    /// - **BLE source:** ESS characteristic `0x2BD7`
    /// - **Wire format:** IEEE 754 binary16 (half-precision float)
    /// - **Typical range:** 0.0 to 500.0 ug/m3
    var pm10: Double?

    /// Barometric (atmospheric) pressure in hectopascals (hPa).
    ///
    /// 1 hPa = 1 millibar (mbar) = 100 Pascals. Standard sea-level pressure
    /// is approximately 1013.25 hPa.
    ///
    /// - **BLE source:** ESS characteristic `0x2A6D`
    /// - **Wire format:** Unsigned 32-bit integer, scaled by x 0.1 Pa
    ///   (divide raw value by 10 to get Pascals, then by 100 to get hPa)
    /// - **Typical range:** 300.0 to 1100.0 hPa
    var pressure: Double?

    /// Volatile organic compound (VOC) index.
    ///
    /// This is a **unitless index** (not a concentration) produced by the
    /// Sensirion SGP41 gas sensor algorithm. The index indicates relative
    /// VOC levels compared to the sensor's recent average.
    ///
    /// - **Range:** 0 to 510
    /// - **Interpretation:** 100 = average/baseline; values above 100 indicate
    ///   increasing VOC levels; values below 100 indicate improving air quality
    /// - **BLE source:** Not in standard ESS; vendor-specific or derived from logs
    var voc: Double?

    /// Nitrogen oxide (NOx) index.
    ///
    /// Like VOC, this is a **unitless index** from the Sensirion SGP41 sensor.
    /// It represents relative NOx levels compared to a rolling baseline.
    ///
    /// - **Range:** 0 to 255
    /// - **Interpretation:** 1 = baseline; values above 1 indicate increasing
    ///   NOx levels (e.g., from combustion sources like gas stoves or traffic)
    /// - **BLE source:** Not in standard ESS; vendor-specific or derived from logs
    var nox: Double?

    // MARK: - Factory Default

    /// A default instance with all sensor values set to `nil`.
    ///
    /// Use this as the initial state before any BLE data has been received.
    /// All properties will be `nil`, so the UI can show placeholder states
    /// (e.g., "--" or a loading indicator) for each sensor.
    static let empty = SensorValues()

    // MARK: - Merge Pattern

    /// Merges a partial update into this snapshot, overwriting only the
    /// fields that are non-`nil` in the update.
    ///
    /// This is the core of the **merge pattern**: BLE sends individual sensor
    /// notifications one at a time. Each notification produces a
    /// ``PartialSensorUpdate`` with only one or a few fields set. Calling
    /// `merge` applies those changed fields without discarding the rest
    /// of the snapshot.
    ///
    /// - Parameter update: A ``PartialSensorUpdate`` containing only the
    ///   fields that changed in the latest BLE notification. Any `nil` fields
    ///   in the update are skipped (the existing value is preserved).
    ///
    /// - Complexity: O(1) — checks and assigns a fixed number of fields.
    ///
    /// ## Example
    ///
    /// ```swift
    /// var sensors = SensorValues.empty
    /// sensors.merge(PartialSensorUpdate(temperature: 22.5))
    /// // sensors.temperature == 22.5, all others still nil
    ///
    /// sensors.merge(PartialSensorUpdate(humidity: 55.0))
    /// // sensors.temperature == 22.5 (preserved), sensors.humidity == 55.0
    /// ```
    mutating func merge(_ update: PartialSensorUpdate) {
        // Each `if let` guard ensures we only overwrite when the update
        // carries a new value. Fields left as `nil` in the update are skipped.
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

    // MARK: - Computed Properties

    /// Whether at least one sensor value has been received.
    ///
    /// Returns `true` if any property is non-`nil`. The UI uses this to decide
    /// whether to show a "Waiting for data..." placeholder or real sensor cards.
    var hasAnyValue: Bool {
        temperature != nil || humidity != nil || co2 != nil ||
        pm1_0 != nil || pm2_5 != nil || pm4_0 != nil || pm10 != nil ||
        pressure != nil || voc != nil || nox != nil
    }
}

// MARK: - PartialSensorUpdate

/// A partial sensor update carrying only the fields that changed in a
/// single BLE notification.
///
/// ## Overview
///
/// When the uCrit device sends a BLE notification for a single ESS
/// characteristic (e.g., temperature), the BLE manager creates a
/// `PartialSensorUpdate` with only that one field set. All other fields
/// remain `nil`, meaning "no change."
///
/// The update is then applied to the current ``SensorValues`` snapshot via
/// ``SensorValues/merge(_:)``, which overwrites only the non-`nil` fields.
///
/// ## Why not just update `SensorValues` directly?
///
/// Using a separate partial type makes the data flow explicit:
///
/// 1. **Clarity** — it is obvious which fields changed vs. which were preserved.
/// 2. **Thread safety** — the partial update is a small, immutable value that
///    can be safely passed between the BLE callback queue and the main actor.
/// 3. **Composability** — multiple partial updates can be merged in sequence
///    without losing intermediate state.
///
/// ## Conformances
///
/// - `Sendable` — safe to pass across concurrency boundaries (e.g., from a
///   BLE delegate callback to the `@MainActor` view model).
///
/// Ported from the web app's `Partial<SensorValues>` TypeScript pattern.
struct PartialSensorUpdate: Sendable {
    /// Updated temperature in degrees Celsius, or `nil` if this notification
    /// did not include a temperature reading.
    var temperature: Double?

    /// Updated relative humidity percentage (0-100), or `nil` if unchanged.
    var humidity: Double?

    /// Updated CO2 concentration in parts per million, or `nil` if unchanged.
    var co2: Double?

    /// Updated PM1.0 mass concentration in ug/m3, or `nil` if unchanged.
    var pm1_0: Double?

    /// Updated PM2.5 mass concentration in ug/m3, or `nil` if unchanged.
    var pm2_5: Double?

    /// Updated PM4.0 mass concentration in ug/m3, or `nil` if unchanged.
    var pm4_0: Double?

    /// Updated PM10 mass concentration in ug/m3, or `nil` if unchanged.
    var pm10: Double?

    /// Updated barometric pressure in hPa, or `nil` if unchanged.
    var pressure: Double?

    /// Updated VOC index (0-510), or `nil` if unchanged.
    var voc: Double?

    /// Updated NOx index (0-255), or `nil` if unchanged.
    var nox: Double?
}
