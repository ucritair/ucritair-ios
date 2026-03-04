import Foundation

// MARK: - File Overview
// ======================================================================================
// BLECharacteristics.swift — Typed Read/Write API for BLE Characteristics
// ======================================================================================
//
// This file provides a high-level, type-safe API for reading from and writing to
// each BLE characteristic on the uCrit device. It sits between the ViewModel layer
// (which works with Swift types like `String`, `UInt32`, `PetStats`) and the
// BLEManager layer (which works with raw `Data` bytes).
//
// ## Why This Layer Exists
//
// Without this layer, every ViewModel would need to:
// 1. Know the correct UUID for each characteristic
// 2. Know the correct byte size and format
// 3. Manually serialize/deserialize values
// 4. Handle minimum-length validation
//
// By centralizing this logic here, ViewModels simply call:
// ```swift
// let name = try await BLECharacteristics.readDeviceName(using: bleManager)
// ```
// ...instead of manually reading bytes and parsing UTF-8 strings with null trimming.
//
// ## Architecture Layer
//
//   ViewModel  -->  BLECharacteristics  -->  BLEManager  -->  CoreBluetooth
//   (Swift types)   (serialize/deserialize)  (raw Data)       (BLE radio)
//
// ## Pattern
//
// Every method follows the same pattern:
// 1. **Read**: Call `manager.readCharacteristic(uuid)` to get raw `Data`
// 2. **Validate**: Check minimum byte count (throw `BLEError.noData` if too short)
// 3. **Parse**: Use `BLEParsers` or `Data+Parsing` extensions to decode the value
//
// For writes, the pattern is reversed:
// 1. **Serialize**: Convert the Swift type to raw `Data` bytes
// 2. **Write**: Call `manager.writeCharacteristic(uuid, data:)` to send the bytes
//
// All methods are `async throws` because BLE operations are asynchronous (the radio
// must transmit and receive) and can fail (device disconnected, Bluetooth off, etc.).
//
// Ported from the web app's `src/ble/characteristics.ts`.
// ======================================================================================

/// Type-safe read/write API for each BLE characteristic on the uCrit device.
///
/// This caseless enum provides static methods that abstract away the raw byte
/// serialization and deserialization needed to communicate with BLE characteristics.
/// Each method handles UUID lookup, byte-level encoding/decoding, and payload validation.
///
/// All methods require a connected ``BLEManager`` instance and are `async throws`:
/// - `async` because BLE reads/writes involve radio communication with latency.
/// - `throws` because the device may be disconnected, the characteristic may not exist,
///   or the returned data may be too short (corrupted or truncated).
///
/// ## Usage
/// ```swift
/// // Read a typed value
/// let deviceName = try await BLECharacteristics.readDeviceName(using: bleManager)
///
/// // Write a typed value
/// try await BLECharacteristics.writeDeviceName("My uCrit", using: bleManager)
/// ```
enum BLECharacteristics {

    // MARK: - Device Name

    /// Read the user-configurable device name from the uCrit.
    ///
    /// Reads characteristic `0x0001` and decodes the raw bytes as a UTF-8 string.
    /// The firmware null-terminates the string, so trailing `\0` bytes are stripped.
    ///
    /// - Parameter manager: A connected ``BLEManager`` instance.
    /// - Returns: The device name as a Swift `String`, or an empty string if decoding fails.
    /// - Throws: ``BLEError/notConnected`` if no device is connected.
    ///           ``BLEError/characteristicNotFound(_:)`` if the characteristic was not discovered.
    static func readDeviceName(using manager: BLEManager) async throws -> String {
        let data = try await manager.readCharacteristic(BLEConstants.charDeviceName)
        // Decode UTF-8 bytes to String, then strip any null terminators the firmware appended.
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: CharacterSet(charactersIn: "\0")) ?? ""
    }

    /// Write a new device name to the uCrit.
    ///
    /// Encodes the string as UTF-8 bytes and writes to characteristic `0x0001`.
    /// The firmware accepts up to ~20 bytes; longer names will be truncated by the device.
    ///
    /// - Parameters:
    ///   - name: The new device name to set. Must be valid UTF-8.
    ///   - manager: A connected ``BLEManager`` instance.
    /// - Throws: ``BLEError/noData`` if the string cannot be encoded as UTF-8.
    ///           ``BLEError/notConnected`` if no device is connected.
    static func writeDeviceName(_ name: String, using manager: BLEManager) async throws {
        guard let data = name.data(using: .utf8) else { throw BLEError.noData }
        try await manager.writeCharacteristic(BLEConstants.charDeviceName, data: data)
    }

    // MARK: - Device Time

    /// Read the device's current RTC time as a Unix timestamp.
    ///
    /// Reads 4 bytes from characteristic `0x0002` and decodes as a `UInt32` little-endian
    /// value representing seconds since the device's internal epoch.
    ///
    /// - Parameter manager: A connected ``BLEManager`` instance.
    /// - Returns: The device time as a `UInt32` representing seconds.
    /// - Throws: ``BLEError/noData`` if the response contains fewer than 4 bytes.
    static func readTime(using manager: BLEManager) async throws -> UInt32 {
        let data = try await manager.readCharacteristic(BLEConstants.charTime)
        guard data.count >= 4 else { throw BLEError.noData }
        return data.readUInt32LE(at: 0)
    }

    /// Sync the device's clock by writing a Unix timestamp.
    ///
    /// Serializes the given value as 4 bytes (UInt32 little-endian) and writes to
    /// characteristic `0x0002`. Typically called at connection time to synchronize
    /// the device's RTC with the phone's current time.
    ///
    /// - Parameters:
    ///   - unixSeconds: Unix timestamp in seconds to write to the device.
    ///   - manager: A connected ``BLEManager`` instance.
    /// - Throws: ``BLEError/notConnected`` if no device is connected.
    static func writeTime(_ unixSeconds: UInt32, using manager: BLEManager) async throws {
        var data = Data(count: 4)
        data.writeUInt32LE(unixSeconds, at: 0)
        try await manager.writeCharacteristic(BLEConstants.charTime, data: data)
    }

    // MARK: - Log Cells

    /// Read the total number of log cells stored on the device's flash memory.
    ///
    /// Reads 4 bytes from characteristic `0x0003` and decodes as a `UInt32` LE.
    /// This count is used to determine how many cells to request during a bulk download
    /// via ``BLELogStream``, and to detect how many new cells have been recorded since
    /// the last sync.
    ///
    /// - Parameter manager: A connected ``BLEManager`` instance.
    /// - Returns: The total number of stored log cells.
    /// - Throws: ``BLEError/noData`` if the response contains fewer than 4 bytes.
    static func readCellCount(using manager: BLEManager) async throws -> UInt32 {
        let data = try await manager.readCharacteristic(BLEConstants.charCellCount)
        guard data.count >= 4 else { throw BLEError.noData }
        return data.readUInt32LE(at: 0)
    }

    /// Write a cell index to select which log cell to read next.
    ///
    /// After writing an index to characteristic `0x0004`, the selected cell's data
    /// becomes available by reading characteristic `0x0005` (cell data).
    ///
    /// - Special value: Writing `0xFFFFFFFF` selects the **live cell** — the most
    ///   recent sensor readings that have not yet been committed to flash. This is
    ///   used for real-time polling of VOC, NOx, and PM4.0 values.
    ///
    /// - Parameters:
    ///   - index: The zero-based cell index (0 to cellCount-1), or `0xFFFFFFFF` for the live cell.
    ///   - manager: A connected ``BLEManager`` instance.
    /// - Throws: ``BLEError/notConnected`` if no device is connected.
    static func writeCellSelector(_ index: UInt32, using manager: BLEManager) async throws {
        var data = Data(count: 4)
        data.writeUInt32LE(index, at: 0)
        try await manager.writeCharacteristic(BLEConstants.charCellSelector, data: data)
    }

    /// Read the currently selected log cell's full sensor data.
    ///
    /// Returns the 57-byte payload from characteristic `0x0005`, parsed into a
    /// ``ParsedLogCell`` struct. You must first call ``writeCellSelector(_:using:)``
    /// to select which cell to read.
    ///
    /// - Parameter manager: A connected ``BLEManager`` instance.
    /// - Returns: A ``ParsedLogCell`` with all sensor fields decoded.
    /// - Throws: ``BLEError/noData`` if the response is shorter than 57 bytes
    ///           (``BLEConstants/logCellNotificationSize``).
    static func readCellData(using manager: BLEManager) async throws -> ParsedLogCell {
        let data = try await manager.readCharacteristic(BLEConstants.charCellData)
        guard data.count >= BLEConstants.logCellNotificationSize else {
            throw BLEError.noData
        }
        return BLEParsers.parseLogCell(data)
    }

    // MARK: - Pet Stats

    /// Read the virtual pet's current stats from the device.
    ///
    /// Reads 6 bytes from characteristic `0x0010` and parses them into a ``PetStats``
    /// struct containing vigour, focus, spirit, age, and interventions.
    ///
    /// These stats are read-only — the firmware calculates them based on environmental
    /// conditions and user interactions. The app displays them but cannot modify them.
    ///
    /// - Parameter manager: A connected ``BLEManager`` instance.
    /// - Returns: A ``PetStats`` struct with all fields decoded.
    /// - Throws: ``BLEError/noData`` if the response contains fewer than 6 bytes.
    static func readStats(using manager: BLEManager) async throws -> PetStats {
        let data = try await manager.readCharacteristic(BLEConstants.charStats)
        guard data.count >= 6 else { throw BLEError.noData }
        return BLEParsers.parseStats(data)
    }

    // MARK: - Items

    /// Read the bitmap of items owned by the user in the virtual pet game.
    ///
    /// Returns the raw 32-byte (256-bit) bitmap from characteristic `0x0011`.
    /// Each bit represents one shop item: 1 = owned, 0 = not owned.
    /// Use ``BLEParsers/countBitmapItems(_:)`` to count how many items are owned.
    ///
    /// - Parameter manager: A connected ``BLEManager`` instance.
    /// - Returns: Raw 32-byte bitmap `Data`. Bit N being set means item N is owned.
    /// - Throws: ``BLEError/notConnected`` if no device is connected.
    static func readItemsOwned(using manager: BLEManager) async throws -> Data {
        try await manager.readCharacteristic(BLEConstants.charItemsOwned)
    }

    /// Read the bitmap of items currently placed/equipped in the virtual pet game.
    ///
    /// Returns the raw 32-byte (256-bit) bitmap from characteristic `0x0012`.
    /// Each bit represents one item: 1 = placed/equipped, 0 = not placed.
    ///
    /// - Parameter manager: A connected ``BLEManager`` instance.
    /// - Returns: Raw 32-byte bitmap `Data`. Bit N being set means item N is placed.
    /// - Throws: ``BLEError/notConnected`` if no device is connected.
    static func readItemsPlaced(using manager: BLEManager) async throws -> Data {
        try await manager.readCharacteristic(BLEConstants.charItemsPlaced)
    }

    // MARK: - Bonus

    /// Read the current bonus/reward value from the device.
    ///
    /// Reads 4 bytes from characteristic `0x0013` and decodes as `UInt32` LE.
    /// The bonus value is part of the virtual pet game reward system.
    ///
    /// - Parameter manager: A connected ``BLEManager`` instance.
    /// - Returns: The bonus value as a `UInt32`.
    /// - Throws: ``BLEError/noData`` if the response contains fewer than 4 bytes.
    static func readBonus(using manager: BLEManager) async throws -> UInt32 {
        let data = try await manager.readCharacteristic(BLEConstants.charBonus)
        guard data.count >= 4 else { throw BLEError.noData }
        return data.readUInt32LE(at: 0)
    }

    /// Write a new bonus/reward value to the device.
    ///
    /// Serializes the value as 4 bytes (UInt32 LE) and writes to characteristic `0x0013`.
    ///
    /// - Parameters:
    ///   - value: The new bonus value to set.
    ///   - manager: A connected ``BLEManager`` instance.
    /// - Throws: ``BLEError/notConnected`` if no device is connected.
    static func writeBonus(_ value: UInt32, using manager: BLEManager) async throws {
        var data = Data(count: 4)
        data.writeUInt32LE(value, at: 0)
        try await manager.writeCharacteristic(BLEConstants.charBonus, data: data)
    }

    // MARK: - Pet Name

    /// Read the virtual pet's display name from the device.
    ///
    /// Reads characteristic `0x0014` and decodes the raw bytes as a UTF-8 string,
    /// stripping any null-terminator bytes appended by the firmware.
    ///
    /// - Parameter manager: A connected ``BLEManager`` instance.
    /// - Returns: The pet name as a Swift `String`, or an empty string if decoding fails.
    /// - Throws: ``BLEError/notConnected`` if no device is connected.
    static func readPetName(using manager: BLEManager) async throws -> String {
        let data = try await manager.readCharacteristic(BLEConstants.charPetName)
        // Decode UTF-8 and strip firmware's null terminators.
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: CharacterSet(charactersIn: "\0")) ?? ""
    }

    /// Write a new name for the virtual pet on the device.
    ///
    /// Encodes the string as UTF-8 bytes and writes to characteristic `0x0014`.
    ///
    /// - Parameters:
    ///   - name: The new pet name. Must be valid UTF-8.
    ///   - manager: A connected ``BLEManager`` instance.
    /// - Throws: ``BLEError/noData`` if the string cannot be encoded as UTF-8.
    ///           ``BLEError/notConnected`` if no device is connected.
    static func writePetName(_ name: String, using manager: BLEManager) async throws {
        guard let data = name.data(using: .utf8) else { throw BLEError.noData }
        try await manager.writeCharacteristic(BLEConstants.charPetName, data: data)
    }

    // MARK: - Device Config

    /// Read the device's full configuration settings.
    ///
    /// Reads 16 bytes from characteristic `0x0015` and parses them into a
    /// ``DeviceConfig`` struct. The config includes settings like screen brightness,
    /// sleep timers, sensor wakeup intervals, and persist flags.
    ///
    /// - Parameter manager: A connected ``BLEManager`` instance.
    /// - Returns: A ``DeviceConfig`` struct with all settings decoded.
    /// - Throws: ``BLEError/noData`` if the response contains fewer than 16 bytes.
    static func readDeviceConfig(using manager: BLEManager) async throws -> DeviceConfig {
        let data = try await manager.readCharacteristic(BLEConstants.charDeviceConfig)
        guard data.count >= 16, let config = DeviceConfig.parse(from: data) else { throw BLEError.noData }
        return config
    }

    /// Write updated configuration settings to the device.
    ///
    /// Serializes the ``DeviceConfig`` struct into 16 bytes and writes to
    /// characteristic `0x0015`. Changes take effect immediately on the device
    /// (e.g., screen brightness adjusts, timers reset).
    ///
    /// - Parameters:
    ///   - config: The ``DeviceConfig`` to write, containing all settings.
    ///   - manager: A connected ``BLEManager`` instance.
    /// - Throws: ``BLEError/notConnected`` if no device is connected.
    static func writeDeviceConfig(_ config: DeviceConfig, using manager: BLEManager) async throws {
        let data = config.serialize()
        try await manager.writeCharacteristic(BLEConstants.charDeviceConfig, data: data)
    }
}
