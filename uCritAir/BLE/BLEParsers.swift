import Foundation

// MARK: - File Overview
// ======================================================================================
// BLEParsers.swift — Binary Data Parsers for the uCrit BLE Protocol
// ======================================================================================
//
// This file converts raw byte arrays (`Data`) received from BLE characteristics into
// typed Swift values (Doubles, Ints, structs). Every parser corresponds to a specific
// BLE characteristic or data format defined by the uCrit firmware.
//
// ## Background: Why Binary Parsing Is Needed
//
// BLE transmits data as raw bytes — there is no JSON, no strings, no self-describing
// format. The firmware and the app must agree on exactly how bytes map to values:
// - Which byte offset holds which field
// - How many bytes each field occupies (1, 2, 4, or 8)
// - The byte order (little-endian: least significant byte first)
// - The scaling factor (e.g., raw `2350` means `23.50` degrees C at 0.01 resolution)
//
// This file is a **direct port** of the web app's `src/ble/parsers.ts`. Byte offsets
// and scaling factors must match the firmware exactly — any mismatch will produce
// garbled sensor readings.
//
// ## Data Formats Used
//
// | Format    | Size    | Description                                               |
// |-----------|---------|-----------------------------------------------------------|
// | uint8     | 1 byte  | Unsigned integer 0-255                                    |
// | sint16 LE | 2 bytes | Signed integer -32768 to 32767, little-endian              |
// | uint16 LE | 2 bytes | Unsigned integer 0-65535, little-endian                    |
// | int32 LE  | 4 bytes | Signed 32-bit integer, little-endian                       |
// | uint32 LE | 4 bytes | Unsigned 32-bit integer, little-endian                     |
// | uint64 LE | 8 bytes | Unsigned 64-bit integer, little-endian                     |
// | float16   | 2 bytes | IEEE 754 half-precision floating point, little-endian      |
// | float32   | 4 bytes | IEEE 754 single-precision floating point, little-endian    |
//
// "Little-endian" (LE) means the least significant byte comes first in memory.
// For example, the value `0x1234` is stored as bytes `[0x34, 0x12]`.
//
// ## How This File Fits in the Architecture
//
//   BLE Radio  -->  BLEManager (raw Data)  -->  BLEParsers (typed values)
//                                           -->  BLECharacteristics (calls parsers)
//                                           -->  DeviceViewModel (displays values)
//
// ``BLEManager`` receives raw `Data` from CoreBluetooth and passes it here for decoding.
// ``BLECharacteristics`` also calls these parsers after performing typed reads.
// ======================================================================================

/// Stateless binary data parsers that decode raw BLE characteristic payloads into
/// typed Swift values.
///
/// All methods are `static` and pure (no side effects, no stored state). The enum
/// is caseless (cannot be instantiated) — it serves purely as a namespace.
///
/// ## Thread Safety
/// All methods are safe to call from any thread — they only read from the provided
/// `Data` buffer and return new values without mutating shared state.
enum BLEParsers {

    // MARK: - IEEE 754 Half-Precision Float

    /// Parse an IEEE 754 half-precision (binary16) floating-point number from two
    /// little-endian bytes.
    ///
    /// Half-precision floats use 16 bits to represent a floating-point number:
    /// ```
    /// Bit layout:  [15: sign] [14-10: exponent (5 bits)] [9-0: fraction (10 bits)]
    ///
    /// Example byte pair: 0x00 0x3C  (little-endian)
    ///   -> uint16 = 0x3C00
    ///   -> sign=0, exp=15, frac=0
    ///   -> value = +1.0 * 2^(15-15) = 1.0
    /// ```
    ///
    /// The ESS PM characteristics (PM1.0, PM2.5, PM10) use this compact format to
    /// transmit particulate matter concentrations in just 2 bytes instead of the
    /// 4 bytes that a standard `Float` would require.
    ///
    /// This implementation handles all three categories of half-precision values:
    /// - **Normal numbers** (exponent 1-30): `(-1)^sign * 2^(exp-15) * (1 + frac/1024)`
    /// - **Subnormal numbers** (exponent 0): Very small values near zero
    /// - **Special values** (exponent 31): Infinity and NaN
    ///
    /// - Parameters:
    ///   - b0: The low byte (least significant byte, read first in little-endian order).
    ///   - b1: The high byte (most significant byte, contains the sign bit).
    /// - Returns: The decoded value as a `Double`.
    ///
    /// Ported from `parsers.ts` -> `parseFloat16()`.
    static func parseFloat16(_ b0: UInt8, _ b1: UInt8) -> Double {
        // Reconstruct the 16-bit value from two little-endian bytes.
        // b0 is the low byte, b1 is the high byte.
        let val = UInt16(b0) | (UInt16(b1) << 8)

        // Extract the three fields from the 16-bit value:
        let sign = (val >> 15) & 1       // Bit 15: 0 = positive, 1 = negative
        let exp = (val >> 10) & 0x1F     // Bits 14-10: biased exponent (0-31)
        let frac = val & 0x3FF           // Bits 9-0: fraction/mantissa (0-1023)

        if exp == 0 {
            // Subnormal (denormalized) number: exponent field is zero.
            // These represent very small values close to zero.
            // Formula: (-1)^sign * (frac / 1024) * 2^(-14)
            return Double(sign != 0 ? -1 : 1) * (Double(frac) / 1024.0) * pow(2.0, -14.0)
        }
        if exp == 31 {
            // Special values: exponent field is all 1s (maximum).
            // If fraction is non-zero -> NaN (Not a Number).
            // If fraction is zero -> +/- Infinity.
            return frac != 0 ? .nan : (sign != 0 ? -.infinity : .infinity)
        }

        // Normal number.
        // Formula: (-1)^sign * (1 + frac/1024) * 2^(exp - 15)
        // The "1 +" is the implicit leading 1 bit in IEEE 754 normal numbers.
        // The exponent bias for half-precision is 15 (subtract to get actual exponent).
        return Double(sign != 0 ? -1 : 1) * (1.0 + Double(frac) / 1024.0) * pow(2.0, Double(exp) - 15.0)
    }

    // MARK: - ESS Characteristic Parsers
    // These parsers decode values from the standard Bluetooth Environmental Sensing
    // Service (ESS) characteristics. Each characteristic uses a format defined by the
    // Bluetooth SIG specification — the scaling factors are part of the standard.

    /// Parse an ESS Temperature characteristic value.
    ///
    /// The Bluetooth SIG defines ESS Temperature (UUID `0x2A6E`) as a signed 16-bit
    /// integer (`Int16`) in units of 0.01 degrees Celsius.
    ///
    /// - Parameter data: Raw 2-byte payload from the temperature characteristic.
    ///   Must contain at least 2 bytes.
    /// - Returns: Temperature in degrees Celsius as a `Double`.
    ///
    /// ## Example
    /// Raw bytes `[0x2E, 0x09]` -> `Int16` LE = 2350 -> 2350 / 100.0 = **23.50 degrees C**
    ///
    /// ## Why `Int16` (Signed)?
    /// Temperatures can be negative (e.g., -10.5 degrees C = raw value -1050).
    /// `UInt16` could not represent negative values.
    static func parseTemperature(_ data: Data) -> Double {
        Double(data.readInt16LE(at: 0)) / 100.0
    }

    /// Parse an ESS Humidity characteristic value.
    ///
    /// The Bluetooth SIG defines ESS Humidity (UUID `0x2A6F`) as an unsigned 16-bit
    /// integer (`UInt16`) in units of 0.01% relative humidity.
    ///
    /// - Parameter data: Raw 2-byte payload from the humidity characteristic.
    ///   Must contain at least 2 bytes.
    /// - Returns: Relative humidity as a percentage (0-100) as a `Double`.
    ///
    /// ## Example
    /// Raw bytes `[0xB3, 0x11]` -> `UInt16` LE = 4531 -> 4531 / 100.0 = **45.31% RH**
    ///
    /// ## Why `UInt16` (Unsigned)?
    /// Humidity is always non-negative (0-100%), so a signed type is unnecessary.
    static func parseHumidity(_ data: Data) -> Double {
        Double(data.readUInt16LE(at: 0)) / 100.0
    }

    /// Parse an ESS Pressure characteristic value.
    ///
    /// The Bluetooth SIG defines ESS Pressure (UUID `0x2A6D`) as an unsigned 32-bit
    /// integer (`UInt32`) in units of 0.1 Pascals. We convert to hectopascals (hPa),
    /// the standard meteorological unit (1 hPa = 100 Pa).
    ///
    /// - Parameter data: Raw 4-byte payload from the pressure characteristic.
    ///   Must contain at least 4 bytes.
    /// - Returns: Barometric pressure in hectopascals (hPa) as a `Double`.
    ///
    /// ## Example
    /// Raw value `1013250` (in 0.1 Pa) -> 1013250 / 1000.0 = **1013.250 hPa**
    ///
    /// ## Unit Conversion Chain
    /// `raw (0.1 Pa)` / 10 = `Pascals` / 100 = `hPa` ... so `raw / 1000 = hPa`.
    static func parsePressure(_ data: Data) -> Double {
        Double(data.readUInt32LE(at: 0)) / 1000.0
    }

    /// Parse an ESS CO2 Concentration characteristic value.
    ///
    /// The Bluetooth SIG defines CO2 Concentration (UUID `0x2B8C`) as an unsigned
    /// 16-bit integer in parts per million (ppm) with no scaling factor.
    ///
    /// - Parameter data: Raw 2-byte payload from the CO2 characteristic.
    ///   Must contain at least 2 bytes.
    /// - Returns: CO2 concentration in ppm as a `Double`.
    ///
    /// ## Example
    /// Raw bytes `[0x9C, 0x01]` -> `UInt16` LE = 412 -> **412 ppm CO2**
    ///
    /// ## Typical Values
    /// - Outdoor air: ~400 ppm
    /// - Well-ventilated indoor: 400-1000 ppm
    /// - Stuffy room: 1000-2000 ppm
    /// - Poor ventilation: >2000 ppm
    static func parseCO2(_ data: Data) -> Double {
        Double(data.readUInt16LE(at: 0))
    }

    /// Parse an ESS Particulate Matter (PM) characteristic value.
    ///
    /// PM characteristics (PM1.0, PM2.5, PM10) use IEEE 754 half-precision floats
    /// (2 bytes) to represent mass concentration in micrograms per cubic meter (ug/m3).
    ///
    /// - Parameter data: Raw 2-byte payload from a PM characteristic.
    ///   Must contain at least 2 bytes.
    /// - Returns: PM concentration in micrograms per cubic meter as a `Double`.
    ///
    /// ## What Is Particulate Matter?
    /// PM refers to tiny particles suspended in air. The number after "PM" is the
    /// maximum particle diameter in micrometers:
    /// - **PM1.0**: Particles <= 1.0 um (ultrafine, penetrate deep into lungs)
    /// - **PM2.5**: Particles <= 2.5 um ("fine" particles, primary health concern)
    /// - **PM10**:  Particles <= 10 um (includes dust and pollen)
    static func parsePM(_ data: Data) -> Double {
        parseFloat16(data.readUInt8(at: 0), data.readUInt8(at: 1))
    }

    // MARK: - Timestamp Conversion

    /// Convert an internal RTC (Real-Time Clock) timestamp to a standard Unix timestamp.
    ///
    /// The device firmware uses a non-standard epoch for its internal clock. This method
    /// subtracts the ``BLEConstants/rtcEpochOffset`` to convert to seconds since
    /// January 1, 1970 (the Unix epoch), which Swift's `Date(timeIntervalSince1970:)`
    /// and other standard APIs expect.
    ///
    /// - Parameter rtcTime: Timestamp in seconds since the device's internal epoch.
    /// - Returns: Timestamp in seconds since the Unix epoch (January 1, 1970).
    static func rtcToUnix(_ rtcTime: UInt64) -> Int {
        Int(rtcTime) - Int(BLEConstants.rtcEpochOffset)
    }

    // MARK: - Log Cell Parser

    /// Parse a complete log cell from a 57-byte BLE notification payload.
    ///
    /// Each log cell is a snapshot of all sensor readings at a point in time, stored in
    /// the device's flash memory. The 57-byte payload consists of:
    ///
    /// ```
    /// Bytes 0-3:   Cell number (uint32 LE) — sequential index on the device
    /// Bytes 4-56:  Sensor data (53 bytes) — see byte map below
    /// ```
    ///
    /// ## Sensor Data Byte Map (offsets relative to byte 4)
    ///
    /// | Offset | Size | Type      | Scale   | Field              | Unit         |
    /// |--------|------|-----------|---------|--------------------|--------------|
    /// | 0      | 1    | uint8     | —       | flags              | bitmask      |
    /// | 1-3    | 3    | —         | —       | (reserved/padding) | —            |
    /// | 4-11   | 8    | uint64 LE | —       | RTC timestamp      | seconds      |
    /// | 12-15  | 4    | int32 LE  | x0.001  | temperature        | degrees C    |
    /// | 16-17  | 2    | uint16 LE | x0.1    | pressure           | hPa          |
    /// | 18-19  | 2    | uint16 LE | x0.01   | humidity           | %RH          |
    /// | 20-21  | 2    | uint16 LE | —       | CO2                | ppm          |
    /// | 22-23  | 2    | uint16 LE | x0.01   | PM1.0              | ug/m3        |
    /// | 24-25  | 2    | uint16 LE | x0.01   | PM2.5              | ug/m3        |
    /// | 26-27  | 2    | uint16 LE | x0.01   | PM4.0              | ug/m3        |
    /// | 28-29  | 2    | uint16 LE | x0.01   | PM10.0             | ug/m3        |
    /// | 30-31  | 2    | uint16 LE | x0.01   | PN0.5              | #/cm3        |
    /// | 32-33  | 2    | uint16 LE | x0.01   | PN1.0              | #/cm3        |
    /// | 34-35  | 2    | uint16 LE | x0.01   | PN2.5              | #/cm3        |
    /// | 36-37  | 2    | uint16 LE | x0.01   | PN4.0              | #/cm3        |
    /// | 38-39  | 2    | uint16 LE | x0.01   | PN10.0             | #/cm3        |
    /// | 40     | 1    | uint8     | —       | VOC index          | 0-510        |
    /// | 41     | 1    | uint8     | —       | NOx index          | 0-255        |
    /// | 42-43  | 2    | uint16 LE | —       | CO2 uncompensated  | ppm          |
    /// | 44-47  | 4    | float32 LE| —       | Stroop mean (cong) | ms           |
    /// | 48-51  | 4    | float32 LE| —       | Stroop mean (inc)  | ms           |
    /// | 52     | 1    | uint8     | —       | Stroop throughput  | count        |
    ///
    /// **Note on PM vs PN:** PM (Particulate Matter) measures mass concentration (how much
    /// particulate weight per volume), while PN (Particle Number) measures count concentration
    /// (how many particles per volume). Both come from the same SPS30 particulate sensor.
    ///
    /// - Parameter data: Raw 57-byte notification payload. Must contain at least
    ///   ``BLEConstants/logCellNotificationSize`` (57) bytes.
    /// - Returns: A ``ParsedLogCell`` with all fields decoded and scaled to human-readable units.
    ///
    /// Ported from `parsers.ts` -> `parseLogCell()`. Byte offsets must match firmware exactly.
    static func parseLogCell(_ data: Data) -> ParsedLogCell {
        // Bytes 0-3: Cell number — a sequential index identifying this log entry on the device.
        let cellNumber = Int(data.readUInt32LE(at: 0))

        // All sensor data offsets are relative to byte 4 (start of the 53-byte cell payload).
        // Using `o` (origin) as the base offset keeps the field offset math readable
        // and matches the firmware's struct layout where cell data starts after the cell number.
        let o = 4

        // Byte o+0: Flags bitmask — indicates which sensor groups were active when recorded.
        // See `LogCellFlag` for bit definitions (e.g., bit 0 = temp/RH/PM, bit 1 = CO2).
        let flags = Int(data.readUInt8(at: o + 0))

        // Bytes o+1 to o+3: Reserved/padding (3 bytes) — skipped.
        // The firmware aligns the uint64 timestamp to a 4-byte boundary in the struct.

        // Bytes o+4 to o+11: RTC timestamp as uint64 LE — seconds since device's internal epoch.
        // Must be converted to Unix time using rtcToUnix() for display and persistence.
        let rtcTimestamp = data.readUInt64LE(at: o + 4)
        let timestamp = rtcToUnix(rtcTimestamp)

        // Bytes o+12 to o+15: Temperature as int32 LE, scaled by x0.001.
        // Note: This is higher precision (0.001 C) than the ESS characteristic (0.01 C)
        // because the log cell captures the raw sensor reading before rounding.
        let temperature = Double(data.readInt32LE(at: o + 12)) / 1000.0

        // Bytes o+16 to o+17: Pressure as uint16 LE, scaled by x0.1.
        // Note: Lower resolution than ESS pressure (uint32 x 0.1 Pa). Here it is already
        // in hPa * 10, so dividing by 10 gives hPa directly.
        let pressure = Double(data.readUInt16LE(at: o + 16)) / 10.0

        // Bytes o+18 to o+19: Humidity as uint16 LE, scaled by x0.01.
        let humidity = Double(data.readUInt16LE(at: o + 18)) / 100.0

        // Bytes o+20 to o+21: CO2 concentration as uint16 LE, in ppm (no scaling).
        let co2 = Int(data.readUInt16LE(at: o + 20))

        // Bytes o+22 to o+29: Particulate Matter mass concentrations (PM).
        // Four uint16 LE values, each scaled by x0.01 to get ug/m3.
        // Tuple order: (PM1.0, PM2.5, PM4.0, PM10.0)
        let pm = (
            Double(data.readUInt16LE(at: o + 22)) / 100.0,   // PM1.0:  particles <= 1.0 um
            Double(data.readUInt16LE(at: o + 24)) / 100.0,   // PM2.5:  particles <= 2.5 um
            Double(data.readUInt16LE(at: o + 26)) / 100.0,   // PM4.0:  particles <= 4.0 um
            Double(data.readUInt16LE(at: o + 28)) / 100.0    // PM10.0: particles <= 10 um
        )

        // Bytes o+30 to o+39: Particle Number concentrations (PN).
        // Five uint16 LE values, each scaled by x0.01 to get counts per cubic centimeter.
        // Tuple order: (PN0.5, PN1.0, PN2.5, PN4.0, PN10.0)
        let pn = (
            Double(data.readUInt16LE(at: o + 30)) / 100.0,   // PN0.5:  particles <= 0.5 um
            Double(data.readUInt16LE(at: o + 32)) / 100.0,   // PN1.0:  particles <= 1.0 um
            Double(data.readUInt16LE(at: o + 34)) / 100.0,   // PN2.5:  particles <= 2.5 um
            Double(data.readUInt16LE(at: o + 36)) / 100.0,   // PN4.0:  particles <= 4.0 um
            Double(data.readUInt16LE(at: o + 38)) / 100.0    // PN10.0: particles <= 10 um
        )

        // Byte o+40: VOC (Volatile Organic Compound) index as uint8.
        // Range 0-510 in the Sensirion SGP40 sensor index scale (but capped to uint8 = 0-255).
        // Higher values indicate more VOCs. Values 1-100 are typical for clean air.
        let voc = Int(data.readUInt8(at: o + 40))

        // Byte o+41: NOx (Nitrogen Oxide) index as uint8.
        // Range 0-255 in the Sensirion NOx index scale.
        // Higher values indicate more nitrogen oxides.
        let nox = Int(data.readUInt8(at: o + 41))

        // Bytes o+42 to o+43: Uncompensated CO2 as uint16 LE, in ppm.
        // This is the raw SCD41 sensor reading before temperature/humidity compensation
        // is applied. Useful for diagnostic purposes to compare against the compensated value.
        let co2Uncomp = Int(data.readUInt16LE(at: o + 42))

        // Bytes o+44 to o+52: Stroop cognitive test data.
        // The uCrit device includes a Stroop color-word test on its touchscreen.
        // These fields record the user's average reaction times and throughput.
        let stroop = StroopData(
            meanTimeCong: data.readFloat32LE(at: o + 44),     // float32: mean congruent time (ms)
            meanTimeIncong: data.readFloat32LE(at: o + 48),   // float32: mean incongruent time (ms)
            throughput: Int(data.readUInt8(at: o + 52))        // uint8: correct responses count
        )

        return ParsedLogCell(
            cellNumber: cellNumber,
            flags: flags,
            timestamp: timestamp,
            temperature: temperature,
            pressure: pressure,
            humidity: humidity,
            co2: co2,
            pm: pm,
            pn: pn,
            voc: voc,
            nox: nox,
            co2Uncomp: co2Uncomp,
            stroop: stroop
        )
    }

    // MARK: - Pet Stats Parser

    /// Parse virtual pet stats from a 6-byte BLE characteristic payload.
    ///
    /// The uCrit device includes a virtual pet game where air quality affects the pet's
    /// well-being. This parser decodes the pet's current stats from the 6-byte payload
    /// of characteristic `0x0010`.
    ///
    /// ## Byte Layout
    ///
    /// | Offset | Size | Type      | Field          | Range   |
    /// |--------|------|-----------|----------------|---------|
    /// | 0      | 1    | uint8     | vigour         | 0-255   |
    /// | 1      | 1    | uint8     | focus          | 0-255   |
    /// | 2      | 1    | uint8     | spirit         | 0-255   |
    /// | 3-4    | 2    | uint16 LE | age (days)     | 0-65535 |
    /// | 5      | 1    | uint8     | interventions  | 0-255   |
    ///
    /// - Parameter data: Raw 6-byte payload from the pet stats characteristic.
    ///   Must contain at least 6 bytes.
    /// - Returns: A ``PetStats`` struct with all fields decoded.
    ///
    /// Ported from `parsers.ts` -> `parseStats()`.
    static func parseStats(_ data: Data) -> PetStats {
        PetStats(
            vigour: data.readUInt8(at: 0),          // Byte 0: energy level (affected by air quality)
            focus: data.readUInt8(at: 1),            // Byte 1: concentration (affected by CO2)
            spirit: data.readUInt8(at: 2),           // Byte 2: mood (affected by comfort)
            age: data.readUInt16LE(at: 3),           // Bytes 3-4: age in days (little-endian)
            interventions: data.readUInt8(at: 5)     // Byte 5: user care actions count
        )
    }

    // MARK: - Bitmap Helpers

    /// Count the number of set (1) bits in a bitmap data buffer.
    ///
    /// The uCrit firmware stores item ownership and placement as bitmaps — 32 bytes
    /// (256 bits) where each bit represents one item. A bit value of 1 means the item
    /// is owned/placed; 0 means it is not. This method counts how many items are set.
    ///
    /// ## Algorithm: Bit-by-Bit Counting
    /// For each byte, the method repeatedly checks the least significant bit (`b & 1`),
    /// adds it to the count, then right-shifts the byte by one position (`b >>= 1`).
    /// This continues until all bits are zero. This is a simple but correct approach
    /// — for a 32-byte buffer (256 bits), the worst case is 256 iterations.
    ///
    /// - Parameter data: A bitmap data buffer (typically 32 bytes = 256 bits).
    /// - Returns: The total number of bits set to 1 across all bytes.
    ///
    /// ## Example
    /// ```swift
    /// let data = Data([0b10110001, 0b00000001])  // 4 bits set + 1 bit set
    /// BLEParsers.countBitmapItems(data)           // Returns 5
    /// ```
    ///
    /// Ported from `characteristics.ts` -> `countBitmapItems()`.
    static func countBitmapItems(_ data: Data) -> Int {
        var count = 0
        for byte in data {
            var b = byte
            while b != 0 {
                count += Int(b & 1)  // Add 1 if the lowest bit is set, 0 otherwise
                b >>= 1             // Shift right to examine the next bit
            }
        }
        return count
    }
}
