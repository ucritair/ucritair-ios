// MARK: - DeviceConfig.swift
// Part of the uCritAir iOS app — an air quality monitor companion.
//
// This file defines the device configuration model — the settings that
// control how the uCrit hardware behaves (sensor intervals, screen
// brightness, sleep timers, feature flags, etc.).
//
// It contains two types:
//
//   1. `DeviceConfig`  — the full 16-byte configuration struct
//   2. `PersistFlags`  — the bit-flag sub-field within the config
//
// **How configuration works over BLE:**
//
// The device exposes a single BLE characteristic (UUID 0x0015) that is
// **readable and writable**. The app can:
//
//   - **Read** it to learn the device's current settings.
//   - **Write** it to change settings (e.g., the user adjusts brightness
//     in the iOS settings screen, and the app writes the new config back).
//
// The characteristic payload is exactly **16 bytes**. Both read and write
// use the same binary layout.
//
// **16-byte binary layout (little-endian throughout):**
//
//   Byte(s)  Type       Field                Description
//   -------  --------   -------------------  ---------------------------------
//    0 - 1   uint16 LE  sensorWakeupPeriod   Seconds between sensor readings
//    2 - 3   uint16 LE  sleepAfterSeconds    Inactivity timeout for sleep mode
//    4 - 5   uint16 LE  dimAfterSeconds      Inactivity timeout for screen dim
//    6       uint8      noxSamplePeriod      NOx sampling period multiplier
//    7       uint8      screenBrightness     LCD backlight level (0-75)
//    8 - 11  uint32 LE  persistFlags (low)   Lower 32 bits of feature flags
//   12 - 15  uint32 LE  persistFlags (high)  Upper 32 bits of feature flags
//
// **Why is persistFlags split into two uint32 halves?**
//
// The flags are logically a single uint64 (64-bit) value, but the firmware
// transmits them as two consecutive 32-bit little-endian words. This is a
// common pattern on 32-bit microcontrollers (like the nRF5340) where 64-bit
// aligned writes may not be atomic.
//
// **What is "little-endian" (LE)?**
//
// Little-endian means the *least significant byte comes first*. For example,
// the uint16 value 300 (0x012C) is stored as bytes [0x2C, 0x01]. This is
// the native byte order of ARM processors (used in the nRF5340 and iPhones).

import Foundation

// MARK: - DeviceConfig

/// The device's configuration settings, read from and written to BLE
/// characteristic `0x0015` as a 16-byte binary payload.
///
/// ## Overview
///
/// `DeviceConfig` represents the user-adjustable settings on the uCrit
/// device. It controls hardware behaviors like:
///
/// - How often sensors take readings
/// - When the screen dims and when the device sleeps
/// - Screen brightness level
/// - Feature toggles (temperature units, default screen, logging, etc.)
///
/// ## Binary Serialization
///
/// This struct can **round-trip** between Swift and raw bytes:
///
/// - ``parse(from:)`` — converts 16 raw bytes from BLE into a `DeviceConfig`
/// - ``serialize()`` — converts a `DeviceConfig` back into 16 bytes for BLE
///
/// Both methods use the helper extensions in `Data+Parsing.swift`
/// (`readUInt16LE`, `writeUInt16LE`, etc.) to handle byte-level encoding.
///
/// ## Usage
///
/// ```swift
/// // Reading: BLE data -> DeviceConfig
/// let config = DeviceConfig.parse(from: bleData)
/// print("Brightness: \(config.screenBrightness)")
///
/// // Modifying and writing back
/// var newConfig = config
/// newConfig.screenBrightness = 50
/// let bytes = newConfig.serialize()
/// peripheral.writeValue(bytes, for: configCharacteristic, type: .withResponse)
/// ```
///
/// ## Conformances
///
/// - `Equatable` — enables detecting when settings actually changed.
/// - `Sendable` — safe to pass between concurrency contexts.
///
/// Ported from `src/types/index.ts` -- `DeviceConfig`.
struct DeviceConfig: Equatable, Sendable {

    // MARK: - Sensor Timing

    /// How often the device wakes its sensors to take a new reading.
    ///
    /// The device spends most of its time in a low-power sleep state.
    /// Every `sensorWakeupPeriod` seconds, it powers on the sensors, takes
    /// readings, records a log cell, and goes back to sleep.
    ///
    /// - **Byte offset:** 0-1 (uint16 LE)
    /// - **Unit:** Seconds
    /// - **Valid range:** 1 to 65,535 seconds
    /// - **Typical value:** 60 (one reading per minute)
    /// - **Trade-off:** Lower values give more frequent data but drain the
    ///   battery faster.
    var sensorWakeupPeriod: UInt16

    // MARK: - Power Management

    /// Seconds of user inactivity before the device enters deep sleep mode.
    ///
    /// After this timeout with no touchscreen interaction, the device powers
    /// down its display and non-essential peripherals to conserve battery.
    /// Sensors may still wake periodically (per `sensorWakeupPeriod`).
    ///
    /// - **Byte offset:** 2-3 (uint16 LE)
    /// - **Unit:** Seconds
    /// - **Valid range:** 0 to 65,535 (0 = never sleep, but see
    ///   ``PersistFlags/eternalWake`` for a permanent override)
    /// - **Typical value:** 300 (5 minutes)
    var sleepAfterSeconds: UInt16

    /// Seconds of user inactivity before the screen dims (reduces backlight).
    ///
    /// Dimming happens before full sleep as a visual cue that the device
    /// will soon go to sleep. The dim level is typically much lower than
    /// ``screenBrightness``.
    ///
    /// - **Byte offset:** 4-5 (uint16 LE)
    /// - **Unit:** Seconds
    /// - **Valid range:** 0 to 65,535 (should be <= `sleepAfterSeconds`)
    /// - **Typical value:** 30 (dim after 30 seconds of no interaction)
    var dimAfterSeconds: UInt16

    // MARK: - Sensor Configuration

    /// NOx sensor sampling period multiplier.
    ///
    /// The SGP41 NOx sensor can be sampled at different rates. This value
    /// acts as a multiplier on the base sensor wakeup period to control
    /// how often NOx readings are taken (since the NOx sensor requires
    /// a longer conditioning time).
    ///
    /// - **Byte offset:** 6 (uint8)
    /// - **Valid range:** 0 to 255
    /// - **Interpretation:** Actual NOx period = `sensorWakeupPeriod` x
    ///   `noxSamplePeriod` seconds
    var noxSamplePeriod: UInt8

    // MARK: - Display

    /// LCD backlight brightness level.
    ///
    /// Controls the intensity of the LCD backlight LED via PWM (Pulse Width
    /// Modulation). Higher values = brighter screen.
    ///
    /// - **Byte offset:** 7 (uint8)
    /// - **Valid range:** 0 (off / minimum) to 75 (maximum brightness)
    /// - **Note:** The maximum is 75, not 100 or 255. This is a hardware
    ///   limitation of the backlight driver circuit.
    var screenBrightness: UInt8

    // MARK: - Feature Flags

    /// Persistent feature flags stored in the device's non-volatile memory.
    ///
    /// These boolean settings survive device reboots because they are saved
    /// to flash memory (not RAM). See ``PersistFlags`` for the meaning of
    /// each individual flag bit.
    ///
    /// - **Byte offset:** 8-15 (uint64 LE, transmitted as two uint32 LE halves)
    /// - **See also:** ``PersistFlags`` for individual flag definitions
    var persistFlags: PersistFlags

    // MARK: - Serialization

    /// Serializes this configuration into a 16-byte `Data` buffer suitable
    /// for writing to BLE characteristic `0x0015`.
    ///
    /// The output uses **little-endian** byte order throughout, matching the
    /// ARM processor in the nRF5340 firmware. The layout is documented in
    /// the file header comment.
    ///
    /// - Returns: A 16-byte `Data` value containing all configuration fields
    ///   packed in the firmware's expected binary format.
    ///
    /// ## Example
    ///
    /// ```swift
    /// let config = DeviceConfig(
    ///     sensorWakeupPeriod: 60,
    ///     sleepAfterSeconds: 300,
    ///     dimAfterSeconds: 30,
    ///     noxSamplePeriod: 1,
    ///     screenBrightness: 50,
    ///     persistFlags: [.batteryAlert, .useFahrenheit]
    /// )
    /// let bytes = config.serialize()  // 16-byte Data
    /// peripheral.writeValue(bytes, for: configChar, type: .withResponse)
    /// ```
    func serialize() -> Data {
        var data = Data(count: 16)

        // Pack each field at its designated byte offset in little-endian order.
        data.writeUInt16LE(sensorWakeupPeriod, at: 0)   // bytes 0-1
        data.writeUInt16LE(sleepAfterSeconds, at: 2)     // bytes 2-3
        data.writeUInt16LE(dimAfterSeconds, at: 4)       // bytes 4-5
        data.writeUInt8(noxSamplePeriod, at: 6)          // byte 6
        data.writeUInt8(screenBrightness, at: 7)         // byte 7

        // Split the 64-bit persistFlags into two 32-bit halves for the wire format.
        // The firmware expects the lower 32 bits at offset 8 and upper 32 bits at offset 12.
        data.writeUInt32LE(UInt32(persistFlags.rawValue & 0xFFFF_FFFF), at: 8)          // bytes 8-11 (low)
        data.writeUInt32LE(UInt32((persistFlags.rawValue >> 32) & 0xFFFF_FFFF), at: 12) // bytes 12-15 (high)

        return data
    }

    // MARK: - Parsing

    /// Parses a 16-byte BLE payload into a `DeviceConfig` instance.
    ///
    /// This is the inverse of ``serialize()``. It reads each field from its
    /// designated byte offset using little-endian decoding, and reconstructs
    /// the full 64-bit `persistFlags` from its two 32-bit halves.
    ///
    /// - Parameter data: A `Data` buffer read from BLE characteristic
    ///   `0x0015`. Must be at least 16 bytes.
    /// - Returns: A ``DeviceConfig`` instance, or `nil` if the data is too short.
    ///
    /// ## Example
    ///
    /// ```swift
    /// // In the BLE delegate callback:
    /// func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, ...) {
    ///     guard let data = characteristic.value, data.count == 16 else { return }
    ///     let config = DeviceConfig.parse(from: data)
    ///     print("Sleep after: \(config.sleepAfterSeconds) seconds")
    /// }
    /// ```
    static func parse(from data: Data) -> DeviceConfig? {
        guard data.count >= 16 else { return nil }
        // Read the two 32-bit halves of the flags and combine them into one 64-bit value.
        // flagsLow = bits 0-31, flagsHigh = bits 32-63.
        let flagsLow = UInt64(data.readUInt32LE(at: 8))
        let flagsHigh = UInt64(data.readUInt32LE(at: 12))

        return DeviceConfig(
            sensorWakeupPeriod: data.readUInt16LE(at: 0),
            sleepAfterSeconds: data.readUInt16LE(at: 2),
            dimAfterSeconds: data.readUInt16LE(at: 4),
            noxSamplePeriod: data.readUInt8(at: 6),
            screenBrightness: data.readUInt8(at: 7),
            // Recombine the two halves: shift high bits left by 32 and OR with low bits.
            persistFlags: PersistFlags(rawValue: (flagsHigh << 32) | flagsLow)
        )
    }
}

// MARK: - PersistFlags

/// A set of boolean feature flags stored in the device's non-volatile
/// (flash) memory, persisting across reboots.
///
/// ## Overview
///
/// `PersistFlags` occupies bytes 8-15 of the 16-byte device config
/// characteristic (`0x0015`) as a 64-bit little-endian value. Each **bit
/// position** represents an independent on/off toggle:
///
/// ```
/// Bit:  63  62  ...  7   6   5   4   3   2   1   0
///       |   |        |   |   |   |   |   |   |   |
///       |   |        |   |   |   |   |   |   |   +-- batteryAlert
///       |   |        |   |   |   |   |   |   +------ manualOrient
///       |   |        |   |   |   |   |   +---------- useFahrenheit
///       |   |        |   |   |   |   +-------------- aqFirst
///       |   |        |   |   |   +------------------ pauseCare
///       |   |        |   |   +---------------------- eternalWake
///       |   |        |   +-------------------------- pauseLogging
///       |   |        +------------------------------ (reserved)
///       +------------------------------------------- (reserved)
/// ```
///
/// ## What is an `OptionSet`?
///
/// Swift's `OptionSet` protocol models a collection of flags stored as
/// bits in an integer. It works like a mathematical **set** — you can
/// insert, remove, and check for membership of individual flags:
///
/// ```swift
/// var flags: PersistFlags = [.batteryAlert, .useFahrenheit]
///
/// // Check if a flag is set
/// if flags.contains(.useFahrenheit) {
///     print("Temperature will be shown in Fahrenheit")
/// }
///
/// // Add a flag
/// flags.insert(.eternalWake)
///
/// // Remove a flag
/// flags.remove(.batteryAlert)
/// ```
///
/// Under the hood, `OptionSet` uses **bitwise operations**:
/// - `contains` uses bitwise AND (`&`)
/// - `insert` uses bitwise OR (`|`)
/// - `remove` uses bitwise AND with complement (`& ~`)
///
/// ## Conformances
///
/// - `OptionSet` — provides set-like operations on bit flags
/// - `Equatable` — enables comparison (e.g., detecting changes)
/// - `Sendable` — safe across concurrency boundaries
///
/// Ported from `src/types/index.ts` -- `PersistFlag`.
struct PersistFlags: OptionSet, Equatable, Sendable {

    /// The raw 64-bit unsigned integer holding all flag bits.
    ///
    /// Each bit at position N corresponds to a specific feature flag.
    /// Bits that are `1` mean the feature is **enabled**; `0` means
    /// **disabled**. Required by the `OptionSet` protocol.
    let rawValue: UInt64

    // MARK: - Individual Flag Definitions

    /// **Bit 0** (`0x01`): Enable low-battery alert notifications.
    ///
    /// When set, the device will display a warning on its screen and/or
    /// vibrate when the battery drops below a critical threshold.
    static let batteryAlert  = PersistFlags(rawValue: 1 << 0)

    /// **Bit 1** (`0x02`): Use manual screen orientation.
    ///
    /// When set, the device screen orientation is locked to the user's
    /// manual setting. When cleared, the device uses its accelerometer
    /// to auto-rotate the display.
    static let manualOrient  = PersistFlags(rawValue: 1 << 1)

    /// **Bit 2** (`0x04`): Display temperature in Fahrenheit.
    ///
    /// When set, the device's on-screen temperature display uses degrees
    /// Fahrenheit (F). When cleared, it uses degrees Celsius (C).
    /// This flag also affects the iOS app's temperature formatting via
    /// ``UnitFormatters``.
    static let useFahrenheit = PersistFlags(rawValue: 1 << 2)

    /// **Bit 3** (`0x08`): Show air quality dashboard as the default screen.
    ///
    /// When set, the device boots into the air quality data dashboard.
    /// When cleared, it boots into the virtual pet view. This lets users
    /// who prefer raw data skip the pet interface.
    static let aqFirst       = PersistFlags(rawValue: 1 << 3)

    /// **Bit 4** (`0x10`): Pause virtual pet care interactions.
    ///
    /// When set, the pet's stats (vigour, focus, spirit) are frozen and
    /// do not change in response to air quality conditions. Useful for
    /// calibration or when the device is being transported.
    static let pauseCare     = PersistFlags(rawValue: 1 << 4)

    /// **Bit 5** (`0x20`): Keep the device permanently awake.
    ///
    /// When set, the device ignores the ``DeviceConfig/sleepAfterSeconds``
    /// timer and never enters deep sleep mode. The screen stays on
    /// indefinitely. Useful for always-on display scenarios but drains
    /// the battery quickly.
    static let eternalWake   = PersistFlags(rawValue: 1 << 5)

    /// **Bit 6** (`0x40`): Pause environmental data logging.
    ///
    /// When set, the device continues to take sensor readings (for the
    /// live display) but does **not** write log cells to flash storage.
    /// This can be useful to avoid filling up storage during known
    /// periods of irrelevant data (e.g., while in transit).
    static let pauseLogging  = PersistFlags(rawValue: 1 << 6)
}
