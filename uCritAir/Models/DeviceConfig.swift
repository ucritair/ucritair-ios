import Foundation

/// Device configuration (16-byte struct over BLE).
///
/// Read from and written to BLE characteristic 0x0015 (Device Config). The 16-byte
/// layout is:
/// - Bytes 0-1: `sensor_wakeup_period` (uint16 LE)
/// - Bytes 2-3: `sleep_after_seconds` (uint16 LE)
/// - Bytes 4-5: `dim_after_seconds` (uint16 LE)
/// - Byte 6: `nox_sample_period` (uint8)
/// - Byte 7: `screen_brightness` (uint8)
/// - Bytes 8-15: `persist_flags` (uint64 LE, split as two uint32 LE halves)
///
/// Ported from `src/types/index.ts` -- `DeviceConfig`.
struct DeviceConfig: Equatable, Sendable {
    /// Interval in seconds between sensor wake-up cycles. Bytes 0-1 (uint16 LE).
    var sensorWakeupPeriod: UInt16

    /// Seconds of inactivity before the device enters sleep mode. Bytes 2-3 (uint16 LE).
    var sleepAfterSeconds: UInt16

    /// Seconds of inactivity before the screen dims. Bytes 4-5 (uint16 LE).
    var dimAfterSeconds: UInt16

    /// NOx sensor sampling period multiplier. Byte 6 (uint8).
    var noxSamplePeriod: UInt8

    /// LCD backlight brightness level (0-75). Byte 7 (uint8).
    var screenBrightness: UInt8

    /// Persistent feature flags stored in the device's non-volatile memory. Bytes 8-15 (uint64 LE).
    var persistFlags: PersistFlags

    /// Serialize to 16 bytes for writing to BLE characteristic 0x0015.
    ///
    /// - Returns: A 16-byte `Data` buffer containing all config fields in little-endian byte order.
    func serialize() -> Data {
        var data = Data(count: 16)
        data.writeUInt16LE(sensorWakeupPeriod, at: 0)
        data.writeUInt16LE(sleepAfterSeconds, at: 2)
        data.writeUInt16LE(dimAfterSeconds, at: 4)
        data.writeUInt8(noxSamplePeriod, at: 6)
        data.writeUInt8(screenBrightness, at: 7)
        data.writeUInt32LE(UInt32(persistFlags.rawValue & 0xFFFF_FFFF), at: 8)
        data.writeUInt32LE(UInt32((persistFlags.rawValue >> 32) & 0xFFFF_FFFF), at: 12)
        return data
    }

    /// Parse from 16-byte BLE characteristic 0x0015 data.
    ///
    /// - Parameter data: A 16-byte `Data` buffer read from the device config characteristic.
    /// - Returns: A fully populated ``DeviceConfig`` instance.
    static func parse(from data: Data) -> DeviceConfig {
        let flagsLow = UInt64(data.readUInt32LE(at: 8))
        let flagsHigh = UInt64(data.readUInt32LE(at: 12))
        return DeviceConfig(
            sensorWakeupPeriod: data.readUInt16LE(at: 0),
            sleepAfterSeconds: data.readUInt16LE(at: 2),
            dimAfterSeconds: data.readUInt16LE(at: 4),
            noxSamplePeriod: data.readUInt8(at: 6),
            screenBrightness: data.readUInt8(at: 7),
            persistFlags: PersistFlags(rawValue: (flagsHigh << 32) | flagsLow)
        )
    }
}

/// Device persistent flags stored in non-volatile memory (OptionSet matching firmware bit definitions).
///
/// These flags occupy bytes 8-15 of the 16-byte device config characteristic (0x0015)
/// as a uint64 LE value. Each flag controls a device behavior that persists across reboots.
///
/// Ported from `src/types/index.ts` -- `PersistFlag`.
struct PersistFlags: OptionSet, Equatable, Sendable {
    /// The raw 64-bit value of the combined flags.
    let rawValue: UInt64

    /// Bit 0: Enable low-battery alert notifications on the device.
    static let batteryAlert  = PersistFlags(rawValue: 1 << 0)

    /// Bit 1: Use manual screen orientation instead of auto-rotate.
    static let manualOrient  = PersistFlags(rawValue: 1 << 1)

    /// Bit 2: Display temperature in Fahrenheit instead of Celsius.
    static let useFahrenheit = PersistFlags(rawValue: 1 << 2)

    /// Bit 3: Show the air quality dashboard as the default screen instead of the pet view.
    static let aqFirst       = PersistFlags(rawValue: 1 << 3)

    /// Bit 4: Pause pet care interactions (pet stat changes are frozen).
    static let pauseCare     = PersistFlags(rawValue: 1 << 4)

    /// Bit 5: Keep the device permanently awake (disable sleep timer).
    static let eternalWake   = PersistFlags(rawValue: 1 << 5)

    /// Bit 6: Pause environmental data logging to flash storage.
    static let pauseLogging  = PersistFlags(rawValue: 1 << 6)
}
