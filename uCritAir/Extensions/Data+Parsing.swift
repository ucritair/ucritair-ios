import Foundation

// MARK: - File Overview
// ============================================================================
// Data+Parsing.swift
// uCritAir
//
// PURPOSE:
//   Extends Swift's `Data` type with methods for reading and writing numeric
//   values in little-endian byte order. These are the building blocks for
//   parsing raw BLE (Bluetooth Low Energy) characteristic data received from
//   the uCrit air quality monitor.
//
// WHAT IS BYTE ORDER (ENDIANNESS)?
//   When a number is larger than one byte (8 bits), the bytes must be stored
//   in some order in memory. There are two conventions:
//
//   **Little-endian**: The LEAST significant byte comes FIRST (at the lowest
//   memory address). Think of it as writing a number "backwards."
//
//   **Big-endian**: The MOST significant byte comes FIRST. This is the
//   "natural" human reading order.
//
//   Example: The number 0x01020304 (decimal 16,909,060) stored as 4 bytes:
//
//     Address:       [0]   [1]   [2]   [3]
//     Little-endian:  04    03    02    01    (least significant byte first)
//     Big-endian:     01    02    03    04    (most significant byte first)
//
//   Another example: The number 0x00FF (decimal 255) stored as 2 bytes:
//
//     Address:       [0]   [1]
//     Little-endian:  FF    00    (the 0xFF byte comes first)
//     Big-endian:     00    FF    (the 0x00 byte comes first)
//
// WHY DOES BLE USE LITTLE-ENDIAN?
//   The Bluetooth specification mandates little-endian byte order for all
//   standard GATT characteristic values. The uCrit firmware (running on an
//   ARM Cortex-M33 processor in the nRF5340 SoC) is also natively
//   little-endian. So both the BLE protocol and the hardware agree on
//   little-endian, making it the natural choice.
//
//   Apple's ARM-based iOS devices are also little-endian, but we still do
//   manual byte assembly (rather than unsafe memory casts) for safety and
//   clarity.
//
// HOW THE READ METHODS WORK:
//   Each read method takes a byte offset into the Data buffer and assembles
//   the value from individual bytes using bitwise OR and left-shift:
//
//     readUInt16LE at offset 0 from bytes [0x7D, 0xCA]:
//       byte[0] = 0x7D                     = 0x007D
//       byte[1] = 0xCA, shifted left 8     = 0xCA00
//       OR together:                        = 0xCA7D  (decimal 51,837)
//
//   The pattern extends to 32-bit and 64-bit values with more bytes.
//
// PRECONDITION SAFETY:
//   Every read method includes a `precondition` check that verifies enough
//   bytes are available before reading. If a BLE characteristic sends fewer
//   bytes than expected (firmware bug, transmission error), the precondition
//   will crash the app in debug builds with a clear error message rather than
//   silently reading garbage data. In release builds, precondition failures
//   cause a trap (crash), which is preferable to data corruption.
//
// DATA TYPE REFERENCE:
//   | Type    | Size    | Range                          | BLE Use Cases              |
//   |---------|---------|--------------------------------|----------------------------|
//   | UInt8   | 1 byte  | 0 to 255                       | Flags, brightness          |
//   | Int16   | 2 bytes | -32,768 to 32,767              | ESS temperature            |
//   | UInt16  | 2 bytes | 0 to 65,535                    | Humidity, CO2, PM values   |
//   | Int32   | 4 bytes | -2,147,483,648 to 2,147,483,647| Log cell temperature       |
//   | UInt32  | 4 bytes | 0 to 4,294,967,295             | Timestamps, cell numbers   |
//   | UInt64  | 8 bytes | 0 to 18,446,744,073,709,551,615| Persist flags              |
//   | Float32 | 4 bytes | IEEE 754 single precision       | Stroop task results        |
// ============================================================================

/// Little-endian binary read/write helpers for parsing BLE characteristic data.
///
/// The uCrit firmware transmits all multi-byte values in **little-endian** byte order
/// (least significant byte first), following both the Bluetooth GATT specification and
/// the ARM Cortex-M33 native byte order.
///
/// These extensions provide safe, offset-based access to raw `Data` buffers received
/// from or sent to BLE characteristics (e.g., log cells, device config, sensor readings).
///
/// ## Usage
/// ```swift
/// // Reading a 64-byte log cell from BLE:
/// let data: Data = characteristic.value!
/// let cellNumber = data.readUInt32LE(at: 0)   // bytes 0-3
/// let timestamp  = data.readUInt32LE(at: 4)   // bytes 4-7
/// let tempRaw    = data.readInt32LE(at: 8)     // bytes 8-11
/// let temperature = Double(tempRaw) / 1000.0   // Convert from millidegrees
///
/// // Writing a config payload to send to the device:
/// var payload = Data(count: 16)
/// payload.writeUInt16LE(300, at: 0)   // Wakeup period: 300 seconds
/// payload.writeUInt8(128, at: 6)      // Brightness: 128/255
/// ```
extension Data {
    // MARK: - Read (Little-Endian)

    /// Reads a single unsigned byte (8 bits) at the given byte offset.
    ///
    /// Since a `UInt8` is exactly one byte, no endianness conversion is needed.
    /// This method exists for API consistency with the multi-byte read methods.
    ///
    /// - Parameter offset: Byte offset from `startIndex` into the data buffer.
    /// - Returns: The `UInt8` value at that offset (range: 0 to 255).
    /// - Precondition: `offset` must be within the data's bounds. Crashes with a
    ///   descriptive message if not.
    func readUInt8(at offset: Int) -> UInt8 {
        precondition(count > offset, "Data.readUInt8: need \(offset + 1) bytes, have \(count)")
        return self[startIndex + offset]
    }

    /// Reads a signed 16-bit integer (2 bytes) in little-endian byte order.
    ///
    /// **Memory layout** (little-endian):
    /// ```
    /// Offset:   [offset]  [offset+1]
    /// Content:  low byte  high byte
    /// ```
    ///
    /// **Assembly formula**: `result = byte[0] | (byte[1] << 8)`
    ///
    /// The result is signed (`Int16`), meaning the high bit represents the sign.
    /// Range: -32,768 to 32,767.
    ///
    /// **BLE use case**: ESS (Environmental Sensing Service) temperature characteristic,
    /// which encodes temperature as `sint16` in units of 0.01 degrees Celsius.
    /// Example: raw value 2250 = 22.50 degrees C.
    ///
    /// - Parameter offset: Byte offset from `startIndex` (2 bytes will be read).
    /// - Returns: The `Int16` value assembled from bytes `[offset, offset+1]` in little-endian order.
    /// - Precondition: At least `offset + 2` bytes must be available.
    func readInt16LE(at offset: Int) -> Int16 {
        precondition(count >= offset + 2, "Data.readInt16LE: need \(offset + 2) bytes, have \(count)")
        let i = startIndex + offset
        // Assemble from two bytes: low byte at offset, high byte at offset+1
        return Int16(self[i]) | (Int16(self[i + 1]) << 8)
    }

    /// Reads an unsigned 16-bit integer (2 bytes) in little-endian byte order.
    ///
    /// **Memory layout** (little-endian):
    /// ```
    /// Offset:   [offset]  [offset+1]
    /// Content:  low byte  high byte
    /// ```
    ///
    /// Range: 0 to 65,535.
    ///
    /// **BLE use cases**: Humidity (uint16 x 0.01%), CO2 concentration (uint16 ppm),
    /// and PM mass concentrations (uint16 x 0.01 ug/m3) within log cell payloads.
    ///
    /// - Parameter offset: Byte offset from `startIndex` (2 bytes will be read).
    /// - Returns: The `UInt16` value assembled from bytes `[offset, offset+1]` in little-endian order.
    /// - Precondition: At least `offset + 2` bytes must be available.
    func readUInt16LE(at offset: Int) -> UInt16 {
        precondition(count >= offset + 2, "Data.readUInt16LE: need \(offset + 2) bytes, have \(count)")
        let i = startIndex + offset
        return UInt16(self[i]) | (UInt16(self[i + 1]) << 8)
    }

    /// Reads a signed 32-bit integer (4 bytes) in little-endian byte order.
    ///
    /// **Memory layout** (little-endian):
    /// ```
    /// Offset:   [offset]  [offset+1]  [offset+2]  [offset+3]
    /// Content:  byte 0    byte 1      byte 2      byte 3
    ///           (lowest)                           (highest / sign bit)
    /// ```
    ///
    /// **Assembly formula**:
    /// ```
    /// result = byte[0] | (byte[1] << 8) | (byte[2] << 16) | (byte[3] << 24)
    /// ```
    ///
    /// Range: -2,147,483,648 to 2,147,483,647.
    ///
    /// **BLE use case**: Log cell temperature, encoded as `int32` in units of 0.001
    /// degrees Celsius (millidegrees). Example: raw value 22150 = 22.150 degrees C.
    /// Signed to support negative (below-freezing) temperatures.
    ///
    /// - Parameter offset: Byte offset from `startIndex` (4 bytes will be read).
    /// - Returns: The `Int32` value assembled from bytes `[offset..offset+3]` in little-endian order.
    /// - Precondition: At least `offset + 4` bytes must be available.
    func readInt32LE(at offset: Int) -> Int32 {
        precondition(count >= offset + 4, "Data.readInt32LE: need \(offset + 4) bytes, have \(count)")
        let i = startIndex + offset
        return Int32(self[i])
            | (Int32(self[i + 1]) << 8)    // Shift byte 1 left by 8 bits
            | (Int32(self[i + 2]) << 16)   // Shift byte 2 left by 16 bits
            | (Int32(self[i + 3]) << 24)   // Shift byte 3 left by 24 bits (sign bit)
    }

    /// Reads an unsigned 32-bit integer (4 bytes) in little-endian byte order.
    ///
    /// **Memory layout** (little-endian):
    /// ```
    /// Offset:   [offset]  [offset+1]  [offset+2]  [offset+3]
    /// Content:  byte 0    byte 1      byte 2      byte 3
    ///           (lowest)                           (highest)
    /// ```
    ///
    /// Range: 0 to 4,294,967,295 (enough for Unix timestamps until year 2106).
    ///
    /// **BLE use cases**: Unix timestamps (`uint32`), log cell numbers, ESS pressure
    /// (`uint32` x 0.1 Pa), and the lower/upper 32-bit halves of 64-bit persist flags.
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

    /// Reads an unsigned 64-bit integer (8 bytes) in little-endian byte order.
    ///
    /// **Implementation**: Composed from two consecutive 32-bit little-endian reads
    /// rather than assembling 8 individual bytes. The low 32 bits come from the first
    /// 4 bytes, and the high 32 bits come from the next 4 bytes.
    ///
    /// ```
    /// Offset:   [offset .. offset+3]  [offset+4 .. offset+7]
    /// Content:  low 32 bits           high 32 bits
    /// ```
    ///
    /// **BLE use case**: The 64-bit persist flags bitmask in the device config
    /// characteristic (0x0015), where each bit controls whether a specific
    /// sensor's data is persisted to the device's flash memory.
    ///
    /// - Parameter offset: Byte offset from `startIndex` (8 bytes will be read).
    /// - Returns: The `UInt64` value assembled from bytes `[offset..offset+7]` in little-endian order.
    func readUInt64LE(at offset: Int) -> UInt64 {
        let low = UInt64(readUInt32LE(at: offset))          // First 4 bytes = low word
        let high = UInt64(readUInt32LE(at: offset + 4))     // Next 4 bytes = high word
        return (high << 32) | low                            // Combine: high word shifted up, OR'd with low word
    }

    /// Reads a 32-bit IEEE 754 floating-point value (4 bytes) in little-endian byte order.
    ///
    /// **How it works**: Reads the raw 4-byte bit pattern as a `UInt32` using
    /// `readUInt32LE`, then reinterprets those same bits as a `Float` using Swift's
    /// `Float(bitPattern:)` initializer. This is a type-level reinterpretation, not
    /// a numeric conversion -- the bits don't change, only their interpretation does.
    ///
    /// **IEEE 754 format** (32-bit single precision):
    /// ```
    /// Bit 31:    Sign (0 = positive, 1 = negative)
    /// Bits 30-23: Exponent (8 bits, biased by 127)
    /// Bits 22-0:  Mantissa/fraction (23 bits)
    /// ```
    ///
    /// **BLE use case**: Stroop task results (mean reaction times in milliseconds),
    /// which are stored as 32-bit floats in the log cell payload.
    ///
    /// - Parameter offset: Byte offset from `startIndex` (4 bytes will be read).
    /// - Returns: The `Float` value decoded from the little-endian bit pattern.
    func readFloat32LE(at offset: Int) -> Float {
        let bits = readUInt32LE(at: offset)  // Read raw bit pattern as UInt32
        return Float(bitPattern: bits)        // Reinterpret bits as IEEE 754 float
    }

    // MARK: - Hex Conversion

    /// Converts the entire data buffer to a space-separated uppercase hex string.
    ///
    /// Useful for debugging BLE data -- the hex representation makes it easy to
    /// compare against firmware documentation and Bluetooth packet captures.
    ///
    /// **Example**: `Data([0xCA, 0x7D, 0xF0, 0x01]).hexString` -> `"CA 7D F0 01"`
    ///
    /// Each byte is formatted as exactly 2 uppercase hex characters (`%02X`),
    /// so the output has a consistent width and is easy to read.
    var hexString: String {
        map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    /// Parses a space-separated hex string back into `Data`.
    ///
    /// This is the inverse of ``hexString``. Useful for unit tests and the developer
    /// tools view, where you can paste hex data to simulate BLE characteristic values.
    ///
    /// **Example**: `Data.fromHexString("CA 7D F0 01")` -> `Data([0xCA, 0x7D, 0xF0, 0x01])`
    ///
    /// - Parameter hex: Space-separated hex bytes. Each token must be exactly 2 hex
    ///   characters (e.g., `"0A"`, not `"A"`).
    /// - Returns: The decoded `Data`, or `nil` if any token is invalid (wrong length
    ///   or non-hex characters).
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
    //
    // The write methods are the mirror image of the read methods. They decompose
    // a numeric value into individual bytes and write them in little-endian order
    // (least significant byte first).
    //
    // These are used when building BLE payloads to send TO the device (e.g.,
    // writing device configuration settings).

    /// Writes an unsigned 16-bit integer (2 bytes) in little-endian byte order.
    ///
    /// **Decomposition**:
    /// ```
    /// value = 0xCA7D
    /// byte[0] = value & 0xFF       = 0x7D  (low byte)
    /// byte[1] = (value >> 8) & 0xFF = 0xCA  (high byte)
    /// ```
    ///
    /// **BLE use case**: Serializing `DeviceConfig` fields such as sensor wakeup
    /// period (seconds), sleep-after timeout, and dim-after timeout.
    ///
    /// - Parameters:
    ///   - value: The `UInt16` value to write.
    ///   - offset: Byte offset from `startIndex` where 2 bytes will be written.
    mutating func writeUInt16LE(_ value: UInt16, at offset: Int) {
        let i = startIndex + offset
        self[i] = UInt8(value & 0xFF)            // Low byte (bits 0-7)
        self[i + 1] = UInt8((value >> 8) & 0xFF) // High byte (bits 8-15)
    }

    /// Writes an unsigned 32-bit integer (4 bytes) in little-endian byte order.
    ///
    /// **Decomposition**:
    /// ```
    /// value = 0x01020304
    /// byte[0] = value & 0xFF         = 0x04  (lowest byte)
    /// byte[1] = (value >> 8) & 0xFF  = 0x03
    /// byte[2] = (value >> 16) & 0xFF = 0x02
    /// byte[3] = (value >> 24) & 0xFF = 0x01  (highest byte)
    /// ```
    ///
    /// **BLE use case**: Writing the lower and upper 32-bit halves of the 64-bit
    /// persist flags in the device config characteristic (0x0015).
    ///
    /// - Parameters:
    ///   - value: The `UInt32` value to write.
    ///   - offset: Byte offset from `startIndex` where 4 bytes will be written.
    mutating func writeUInt32LE(_ value: UInt32, at offset: Int) {
        let i = startIndex + offset
        self[i] = UInt8(value & 0xFF)              // Byte 0: bits 0-7
        self[i + 1] = UInt8((value >> 8) & 0xFF)   // Byte 1: bits 8-15
        self[i + 2] = UInt8((value >> 16) & 0xFF)  // Byte 2: bits 16-23
        self[i + 3] = UInt8((value >> 24) & 0xFF)  // Byte 3: bits 24-31
    }

    /// Writes a single unsigned byte at the given byte offset.
    ///
    /// Since a `UInt8` is exactly one byte, no endianness conversion is needed.
    /// This method exists for API consistency with the multi-byte write methods.
    ///
    /// **BLE use case**: Writing single-byte config fields such as NOx sample
    /// period (in number of wakeup cycles) and screen brightness (0-255).
    ///
    /// - Parameters:
    ///   - value: The `UInt8` value to write (range: 0 to 255).
    ///   - offset: Byte offset from `startIndex` where the byte will be written.
    mutating func writeUInt8(_ value: UInt8, at offset: Int) {
        self[startIndex + offset] = value
    }

    /// Writes an unsigned 64-bit integer (8 bytes) in little-endian byte order.
    ///
    /// **Implementation**: Composed from two consecutive 32-bit little-endian writes.
    /// The low 32 bits are written first (at `offset`), then the high 32 bits
    /// (at `offset + 4`). This mirrors how ``readUInt64LE(at:)`` reads them.
    ///
    /// ```
    /// value = 0x0102030405060708
    /// Low word:  0x05060708  -> written at offset
    /// High word: 0x01020304  -> written at offset + 4
    /// ```
    ///
    /// **BLE use case**: Writing the 64-bit persist flags bitmask in the device config
    /// characteristic (0x0015), which spans bytes 8-15 of the 16-byte config struct.
    ///
    /// - Parameters:
    ///   - value: The `UInt64` value to write.
    ///   - offset: Byte offset from `startIndex` where 8 bytes will be written.
    mutating func writeUInt64LE(_ value: UInt64, at offset: Int) {
        writeUInt32LE(UInt32(value & 0xFFFFFFFF), at: offset)            // Low 32 bits first
        writeUInt32LE(UInt32((value >> 32) & 0xFFFFFFFF), at: offset + 4) // High 32 bits second
    }
}
