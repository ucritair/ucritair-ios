import Foundation

/// Little-endian binary read/write helpers for parsing BLE characteristic data.
///
/// The uCrit firmware transmits all multi-byte values in little-endian byte order.
/// These extensions provide safe, offset-based access to raw `Data` buffers received
/// from or sent to BLE characteristics (e.g., log cells, device config, sensor readings).
extension Data {
    // MARK: - Read (Little-Endian)

    /// Reads a single unsigned byte at the given byte offset.
    ///
    /// - Parameter offset: Byte offset from `startIndex` into the data buffer.
    /// - Returns: The `UInt8` value at that offset.
    /// - Precondition: `offset` must be within the data's bounds.
    func readUInt8(at offset: Int) -> UInt8 {
        precondition(count > offset, "Data.readUInt8: need \(offset + 1) bytes, have \(count)")
        return self[startIndex + offset]
    }

    /// Reads a signed 16-bit integer in little-endian byte order.
    ///
    /// Used for BLE fields such as ESS temperature (sint16 x 0.01 degrees C).
    ///
    /// - Parameter offset: Byte offset from `startIndex` (2 bytes will be read).
    /// - Returns: The `Int16` value assembled from bytes `[offset, offset+1]` in little-endian order.
    /// - Precondition: At least `offset + 2` bytes must be available.
    func readInt16LE(at offset: Int) -> Int16 {
        precondition(count >= offset + 2, "Data.readInt16LE: need \(offset + 2) bytes, have \(count)")
        let i = startIndex + offset
        return Int16(self[i]) | (Int16(self[i + 1]) << 8)
    }

    /// Reads an unsigned 16-bit integer in little-endian byte order.
    ///
    /// Used for BLE fields such as humidity (uint16 x 0.01%), CO2 (uint16 ppm),
    /// and PM values (uint16 x 0.01 micrograms per cubic meter) within log cells.
    ///
    /// - Parameter offset: Byte offset from `startIndex` (2 bytes will be read).
    /// - Returns: The `UInt16` value assembled from bytes `[offset, offset+1]` in little-endian order.
    /// - Precondition: At least `offset + 2` bytes must be available.
    func readUInt16LE(at offset: Int) -> UInt16 {
        precondition(count >= offset + 2, "Data.readUInt16LE: need \(offset + 2) bytes, have \(count)")
        let i = startIndex + offset
        return UInt16(self[i]) | (UInt16(self[i + 1]) << 8)
    }

    /// Reads a signed 32-bit integer in little-endian byte order.
    ///
    /// Used for BLE fields such as log cell temperature (int32 x 0.001 degrees C).
    ///
    /// - Parameter offset: Byte offset from `startIndex` (4 bytes will be read).
    /// - Returns: The `Int32` value assembled from bytes `[offset..offset+3]` in little-endian order.
    /// - Precondition: At least `offset + 4` bytes must be available.
    func readInt32LE(at offset: Int) -> Int32 {
        precondition(count >= offset + 4, "Data.readInt32LE: need \(offset + 4) bytes, have \(count)")
        let i = startIndex + offset
        return Int32(self[i])
            | (Int32(self[i + 1]) << 8)
            | (Int32(self[i + 2]) << 16)
            | (Int32(self[i + 3]) << 24)
    }

    /// Reads an unsigned 32-bit integer in little-endian byte order.
    ///
    /// Used for BLE fields such as Unix timestamps (uint32), cell numbers,
    /// ESS pressure (uint32 x 0.1 Pa), and the lower/upper halves of persist flags.
    ///
    /// - Parameter offset: Byte offset from `startIndex` (4 bytes will be read).
    /// - Returns: The `UInt32` value assembled from bytes `[offset..offset+3]` in little-endian order.
    /// - Precondition: At least `offset + 4` bytes must be available.
    func readUInt32LE(at offset: Int) -> UInt32 {
        precondition(count >= offset + 4, "Data.readUInt32LE: need \(offset + 4) bytes, have \(count)")
        let i = startIndex + offset
        return UInt32(self[i])
            | (UInt32(self[i + 1]) << 8)
            | (UInt32(self[i + 2]) << 16)
            | (UInt32(self[i + 3]) << 24)
    }

    /// Reads an unsigned 64-bit integer in little-endian byte order.
    ///
    /// Composed from two consecutive 32-bit little-endian reads. Used for BLE fields
    /// such as the RTC timestamp in log cells and persist flags in the device config.
    ///
    /// - Parameter offset: Byte offset from `startIndex` (8 bytes will be read).
    /// - Returns: The `UInt64` value assembled from bytes `[offset..offset+7]` in little-endian order.
    func readUInt64LE(at offset: Int) -> UInt64 {
        let low = UInt64(readUInt32LE(at: offset))
        let high = UInt64(readUInt32LE(at: offset + 4))
        return (high << 32) | low
    }

    /// Reads a 32-bit IEEE 754 floating-point value in little-endian byte order.
    ///
    /// Reads the raw 4-byte bit pattern as a `UInt32` and reinterprets it as a `Float`.
    ///
    /// - Parameter offset: Byte offset from `startIndex` (4 bytes will be read).
    /// - Returns: The `Float` value decoded from the little-endian bit pattern.
    func readFloat32LE(at offset: Int) -> Float {
        let bits = readUInt32LE(at: offset)
        return Float(bitPattern: bits)
    }

    // MARK: - Hex Conversion

    /// Converts the data to a space-separated uppercase hex string (e.g. `"CA 7D F0 01"`).
    var hexString: String {
        map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    /// Parses a space-separated hex string (e.g. `"CA 7D F0 01"`) back to `Data`.
    ///
    /// - Parameter hex: Space-separated hex bytes. Each token must be exactly 2 hex characters.
    /// - Returns: The decoded `Data`, or `nil` if any token is invalid.
    static func fromHexString(_ hex: String) -> Data? {
        let tokens = hex.split(separator: " ")
        var bytes: [UInt8] = []
        for token in tokens {
            guard token.count == 2, let byte = UInt8(token, radix: 16) else { return nil }
            bytes.append(byte)
        }
        return Data(bytes)
    }

    // MARK: - Write (Little-Endian)

    /// Writes an unsigned 16-bit integer in little-endian byte order.
    ///
    /// Used when serializing BLE payloads such as `DeviceConfig` fields
    /// (sensor wakeup period, sleep-after seconds, dim-after seconds).
    ///
    /// - Parameters:
    ///   - value: The `UInt16` value to write.
    ///   - offset: Byte offset from `startIndex` where 2 bytes will be written.
    mutating func writeUInt16LE(_ value: UInt16, at offset: Int) {
        let i = startIndex + offset
        self[i] = UInt8(value & 0xFF)
        self[i + 1] = UInt8((value >> 8) & 0xFF)
    }

    /// Writes an unsigned 32-bit integer in little-endian byte order.
    ///
    /// Used when serializing BLE payloads such as the lower and upper halves
    /// of the 64-bit persist flags in the device config characteristic (0x0015).
    ///
    /// - Parameters:
    ///   - value: The `UInt32` value to write.
    ///   - offset: Byte offset from `startIndex` where 4 bytes will be written.
    mutating func writeUInt32LE(_ value: UInt32, at offset: Int) {
        let i = startIndex + offset
        self[i] = UInt8(value & 0xFF)
        self[i + 1] = UInt8((value >> 8) & 0xFF)
        self[i + 2] = UInt8((value >> 16) & 0xFF)
        self[i + 3] = UInt8((value >> 24) & 0xFF)
    }

    /// Writes a single unsigned byte at the given byte offset.
    ///
    /// Used when serializing single-byte BLE fields such as NOx sample period
    /// and screen brightness in the device config.
    ///
    /// - Parameters:
    ///   - value: The `UInt8` value to write.
    ///   - offset: Byte offset from `startIndex` where the byte will be written.
    mutating func writeUInt8(_ value: UInt8, at offset: Int) {
        self[startIndex + offset] = value
    }

    /// Writes an unsigned 64-bit integer in little-endian byte order.
    ///
    /// Composed from two consecutive 32-bit little-endian writes (low word first).
    /// Used when serializing the persist flags in the device config characteristic (0x0015),
    /// which spans bytes 8-15 of the 16-byte config struct.
    ///
    /// - Parameters:
    ///   - value: The `UInt64` value to write.
    ///   - offset: Byte offset from `startIndex` where 8 bytes will be written.
    mutating func writeUInt64LE(_ value: UInt64, at offset: Int) {
        writeUInt32LE(UInt32(value & 0xFFFFFFFF), at: offset)
        writeUInt32LE(UInt32((value >> 32) & 0xFFFFFFFF), at: offset + 4)
    }
}
