import CoreBluetooth

// MARK: - File Overview
// ======================================================================================
// BLEConstants.swift — BLE Protocol Constants for uCritAir
// ======================================================================================
//
// This file defines every UUID, magic number, and protocol constant needed to
// communicate with the uCrit air quality monitor over Bluetooth Low Energy (BLE).
//
// ## Background: How BLE Communication Works
//
// BLE devices expose data through a hierarchy:
//
//   Device  -->  Service(s)  -->  Characteristic(s)
//
// A **service** is a logical grouping of related data (like "Environmental Sensing").
// A **characteristic** is a single data endpoint within a service (like "Temperature").
// Each service and characteristic is identified by a UUID (Universally Unique Identifier).
//
// The Bluetooth SIG (Special Interest Group) defines standard 16-bit UUIDs for common
// services and characteristics (e.g., `0x181A` for Environmental Sensing, `0x2A6E` for
// Temperature). Device manufacturers can also define custom 128-bit UUIDs for
// proprietary data — that is what the uCrit vendor service uses.
//
// ## Services Exposed by the uCrit Device
//
// 1. **Custom Vendor Service** (`FC7D4395-1019-49C4-A91B-7491ECC40000`)
//    Proprietary characteristics for device configuration, log data, and the virtual
//    pet game. Each characteristic uses the same 128-bit base UUID with a different
//    16-bit suffix (e.g., `...ECC40001` for device name, `...ECC40002` for time).
//
// 2. **Environmental Sensing Service (ESS)** (`0x181A`)
//    Standard Bluetooth SIG service providing real-time sensor readings: temperature,
//    humidity, pressure, CO2, and particulate matter (PM1.0, PM2.5, PM10).
//
// ## How This File Is Used
//
// - ``BLEManager`` uses these UUIDs during scanning, service discovery, and
//   characteristic discovery to identify the correct endpoints.
// - ``BLECharacteristics`` references these UUIDs when performing typed reads/writes.
// - ``BLEParsers`` uses the log cell size constants to validate incoming data.
// - ``BLELogStream`` uses ``logStreamEndMarker`` to detect the end of a bulk download.
//
// Ported from the web app's `src/ble/constants.ts`.
// ======================================================================================

/// Central registry of all BLE service UUIDs, characteristic UUIDs, and protocol
/// constants used to communicate with the uCrit air quality monitor firmware.
///
/// This enum uses no cases (it is a "caseless enum"), which is a Swift convention for
/// types that act purely as namespaces — you cannot accidentally create an instance of
/// `BLEConstants`. All members are `static`, accessed as `BLEConstants.charDeviceName`.
///
/// ## Why an Enum Instead of a Struct?
/// In Swift, a caseless `enum` cannot be instantiated, making it the idiomatic way to
/// group related constants. A `struct` would allow `BLEConstants()` which is meaningless.
///
/// ## UUID Naming Conventions
/// - `customServiceUUID` / `essServiceUUID` — GATT service identifiers
/// - `char...` prefix — vendor-specific characteristics under the custom service
/// - `ess...` prefix — standard ESS characteristics under the Environmental Sensing Service
enum BLEConstants {

    // MARK: - Custom Vendor Service
    // These UUIDs identify the proprietary GATT service and characteristics defined
    // by the uCrit firmware. The base UUID is `FC7D4395-1019-49C4-A91B-7491ECC4xxxx`
    // where `xxxx` is a 16-bit identifier unique to each characteristic.

    /// Primary custom GATT service UUID for the uCrit device.
    ///
    /// The suffix `0x0000` designates the service itself. All vendor-specific
    /// characteristics live under this service and share the same 128-bit base
    /// UUID with different 16-bit suffixes (0x0001, 0x0002, etc.).
    ///
    /// During BLE scanning, the app filters for peripherals advertising this UUID
    /// to find uCrit devices among all nearby Bluetooth devices.
    static let customServiceUUID = CBUUID(string: "FC7D4395-1019-49C4-A91B-7491ECC40000")

    /// Build a full 128-bit characteristic UUID from a 16-bit suffix.
    ///
    /// All vendor characteristics share the same 128-bit base UUID:
    /// `FC7D4395-1019-49C4-A91B-7491ECC4xxxx`. This helper substitutes the last
    /// 4 hex digits with the given suffix, avoiding repetition of the long base string.
    ///
    /// - Parameter suffix: The 16-bit identifier for the characteristic (e.g., `0x0001`
    ///   for device name, `0x0006` for log stream). Defined by the firmware.
    /// - Returns: A `CBUUID` with the full 128-bit UUID for that characteristic.
    ///
    /// ## Example
    /// ```swift
    /// vendorCharUUID(0x0001) // -> "FC7D4395-1019-49C4-A91B-7491ECC40001"
    /// ```
    static func vendorCharUUID(_ suffix: UInt16) -> CBUUID {
        CBUUID(string: String(format: "FC7D4395-1019-49C4-A91B-7491ECC4%04X", suffix))
    }

    // MARK: Vendor Characteristic UUIDs
    // Each constant below maps to a single BLE characteristic exposed by the firmware.
    // The hex suffix in the comment (e.g., `0x0001`) is the firmware's internal ID.

    /// User-configurable device name, stored as a UTF-8 string on the device.
    /// Firmware characteristic ID: `0x0001`. Read/write. Max ~20 bytes.
    static let charDeviceName   = vendorCharUUID(0x0001)

    /// Device real-time clock (RTC) time.
    /// Firmware characteristic ID: `0x0002`. Read/write.
    /// Value: `UInt32` little-endian representing seconds in the device's local epoch.
    /// The device uses a non-standard epoch — see ``rtcEpochOffset`` to convert to Unix time.
    static let charTime         = vendorCharUUID(0x0002)

    /// Total number of log cells stored on the device's flash memory.
    /// Firmware characteristic ID: `0x0003`. Read-only.
    /// Value: `UInt32` little-endian. Used to determine how many cells to download.
    static let charCellCount    = vendorCharUUID(0x0003)

    /// Cell selector index — write a cell number to select which log cell to read next.
    /// Firmware characteristic ID: `0x0004`. Write-only.
    /// Value: `UInt32` little-endian.
    /// - Writing a valid index (0 to cellCount-1) selects a historical log cell.
    /// - Writing `0xFFFFFFFF` (see ``logStreamEndMarker``) selects the **live** (current) cell,
    ///   which contains the most recent sensor readings not yet committed to flash.
    static let charCellSelector = vendorCharUUID(0x0004)

    /// Data payload of the currently selected log cell.
    /// Firmware characteristic ID: `0x0005`. Read-only.
    /// Value: 57 bytes — a 4-byte cell number (`UInt32` LE) followed by 53 bytes of
    /// sensor data. See ``BLEParsers/parseLogCell(_:)`` for the full byte layout.
    static let charCellData     = vendorCharUUID(0x0005)

    /// Notification-based bulk log cell streaming channel.
    /// Firmware characteristic ID: `0x0006`. Write (to start stream) + Notify (to receive cells).
    ///
    /// **How streaming works:**
    /// 1. The app writes an 8-byte payload: `startCell (UInt32 LE) + count (UInt32 LE)`.
    /// 2. The device sends each requested cell as a 57-byte notification.
    /// 3. After the last cell, the device sends a 4-byte end marker (`0xFFFFFFFF`).
    ///
    /// See ``BLELogStream`` for the full streaming protocol implementation.
    static let charLogStream    = vendorCharUUID(0x0006)

    /// Virtual pet game statistics: vigour, focus, spirit, age, and interventions.
    /// Firmware characteristic ID: `0x0010`. Read-only.
    /// Value: 6 bytes. See ``BLEParsers/parseStats(_:)`` for the byte layout.
    static let charStats        = vendorCharUUID(0x0010)

    /// Bitmask of shop items the user owns in the virtual pet game.
    /// Firmware characteristic ID: `0x0011`. Read-only.
    /// Value: 32 bytes = 256 bits, where each bit represents one item (1 = owned).
    static let charItemsOwned   = vendorCharUUID(0x0011)

    /// Bitmask of items currently placed/equipped in the virtual pet game.
    /// Firmware characteristic ID: `0x0012`. Read-only.
    /// Value: 32 bytes = 256 bits, where each bit represents one item (1 = placed).
    static let charItemsPlaced  = vendorCharUUID(0x0012)

    /// Bonus/reward state for the virtual pet game.
    /// Firmware characteristic ID: `0x0013`. Read/write.
    /// Value: `UInt32` little-endian.
    static let charBonus        = vendorCharUUID(0x0013)

    /// Pet display name, stored as a UTF-8 string on the device.
    /// Firmware characteristic ID: `0x0014`. Read/write.
    static let charPetName      = vendorCharUUID(0x0014)

    /// Device configuration flags and settings (screen brightness, sleep timers, etc.).
    /// Firmware characteristic ID: `0x0015`. Read/write.
    /// Value: 16 bytes. See ``DeviceConfig/parse(from:)`` for the byte layout.
    static let charDeviceConfig = vendorCharUUID(0x0015)

    // MARK: - Environmental Sensing Service (ESS)
    // The ESS is a standard Bluetooth SIG service (UUID 0x181A) that provides
    // real-time environmental sensor readings. Unlike vendor characteristics which use
    // custom 128-bit UUIDs, ESS characteristics use standard 16-bit UUIDs assigned
    // by the Bluetooth SIG. This means any generic BLE sensor app can read these values.
    //
    // The uCrit device supports two delivery modes for ESS characteristics:
    // - **Notify**: The device pushes updates automatically when values change.
    //   More efficient — no polling needed.
    // - **Read**: The app must explicitly request the value each time.
    //   Used for characteristics that the firmware does not support notifications on.

    /// Bluetooth SIG Environmental Sensing Service UUID (`0x181A`).
    ///
    /// This is a standard 16-bit UUID defined by the Bluetooth specification, not a
    /// custom vendor UUID. CoreBluetooth automatically expands it to the full 128-bit
    /// Bluetooth Base UUID: `0000181A-0000-1000-8000-00805F9B34FB`.
    static let essServiceUUID   = CBUUID(string: "181A")

    /// ESS Temperature characteristic (Bluetooth SIG UUID `0x2A6E`).
    /// Value: `Int16` little-endian in units of 0.01 degrees Celsius.
    /// Example: a raw value of `2350` means 23.50 degrees C.
    /// Delivery: notify (device pushes updates).
    static let essTemperature   = CBUUID(string: "2A6E")

    /// ESS Humidity characteristic (Bluetooth SIG UUID `0x2A6F`).
    /// Value: `UInt16` little-endian in units of 0.01% relative humidity.
    /// Example: a raw value of `4523` means 45.23% RH.
    /// Delivery: notify (device pushes updates).
    static let essHumidity      = CBUUID(string: "2A6F")

    /// ESS Pressure characteristic (Bluetooth SIG UUID `0x2A6D`).
    /// Value: `UInt32` little-endian in units of 0.1 Pascals.
    /// Example: a raw value of `1013250` means 1013.250 hPa (standard sea-level pressure).
    /// Delivery: read-only (app must poll; firmware does not send notifications).
    static let essPressure      = CBUUID(string: "2A6D")

    /// ESS CO2 Concentration characteristic (Bluetooth SIG UUID `0x2B8C`).
    /// Value: `UInt16` little-endian in parts per million (ppm). No scaling needed.
    /// Example: a raw value of `412` means 412 ppm CO2.
    /// Delivery: notify (device pushes updates).
    static let essCO2           = CBUUID(string: "2B8C")

    /// ESS PM2.5 Concentration characteristic (Bluetooth SIG UUID `0x2BD6`).
    /// Value: IEEE 754 half-precision float (2 bytes, little-endian) in micrograms per cubic meter.
    /// Delivery: notify (device pushes updates).
    static let essPM2_5         = CBUUID(string: "2BD6")

    /// ESS PM1.0 Concentration characteristic (Bluetooth SIG UUID `0x2BD5`).
    /// Value: IEEE 754 half-precision float (2 bytes, little-endian) in micrograms per cubic meter.
    /// Delivery: read-only (app must poll).
    static let essPM1_0         = CBUUID(string: "2BD5")

    /// ESS PM10 Concentration characteristic (Bluetooth SIG UUID `0x2BD7`).
    /// Value: IEEE 754 half-precision float (2 bytes, little-endian) in micrograms per cubic meter.
    /// Delivery: read-only (app must poll).
    static let essPM10          = CBUUID(string: "2BD7")

    // MARK: - Log Cell Constants
    // These constants define the binary layout and protocol details of log cells
    // — the time-series data records stored on the device's flash memory.

    /// Offset between the device's internal RTC epoch and standard Unix epoch (Jan 1, 1970).
    ///
    /// The device firmware stores timestamps as seconds since a non-standard epoch.
    /// To convert a device timestamp to Unix time:
    /// ```
    /// unixTimestamp = deviceTimestamp - rtcEpochOffset
    /// ```
    /// This offset (59,958,144,000 seconds) corresponds to approximately 1,900 years,
    /// reflecting the firmware's internal RTC counter origin.
    static let rtcEpochOffset: UInt64 = 59_958_144_000

    /// Size of the sensor data portion of a log cell, in bytes.
    ///
    /// The firmware stores each log cell as a 64-byte struct in flash, but 11 bytes are
    /// internal padding. Only 53 bytes of meaningful sensor data are transmitted over BLE.
    /// This is the payload size *without* the 4-byte cell number prefix.
    static let logCellBLESize = 53

    /// Total size of a log cell BLE notification, in bytes.
    ///
    /// Each notification contains: 4-byte cell number (`UInt32` LE) + 53 bytes of sensor data
    /// = 57 bytes total. Both ``charCellData`` reads and ``charLogStream`` notifications
    /// use this same 57-byte format.
    static let logCellNotificationSize = 57

    /// Sentinel value used as the end-of-stream marker during bulk log downloads.
    ///
    /// When the device finishes sending all requested log cells via ``charLogStream``,
    /// it sends a final 4-byte notification containing `0xFFFFFFFF`. The app checks for
    /// this marker to know the stream is complete.
    ///
    /// This same value is also written to ``charCellSelector`` to select the **live**
    /// (current, not-yet-committed) cell for real-time polling.
    static let logStreamEndMarker: UInt32 = 0xFFFF_FFFF

    // MARK: - Characteristic Discovery Lists
    // During BLE connection setup, the app must discover which characteristics are
    // available under each service. These arrays tell CoreBluetooth exactly which
    // characteristics to look for, avoiding a slow "discover all" operation.

    /// All vendor-specific characteristic UUIDs to discover under the custom service.
    ///
    /// Passed to `CBPeripheral.discoverCharacteristics(_:for:)` during connection setup.
    /// Listing specific UUIDs (instead of `nil` for "discover all") is faster because
    /// CoreBluetooth can skip characteristics the app does not need.
    static let allCustomCharacteristicUUIDs: [CBUUID] = [
        charDeviceName, charTime, charCellCount, charCellSelector,
        charCellData, charLogStream, charStats, charItemsOwned,
        charItemsPlaced, charBonus, charPetName, charDeviceConfig,
    ]

    /// ESS characteristics that support BLE notifications (device pushes updates).
    ///
    /// After connection, the app subscribes to these characteristics using
    /// `CBPeripheral.setNotifyValue(true, for:)`. The device then automatically sends
    /// new values whenever the sensor readings change, without the app needing to poll.
    static let essNotifyCharacteristicUUIDs: [CBUUID] = [
        essTemperature, essHumidity, essCO2, essPM2_5,
    ]

    /// ESS characteristics that must be explicitly read (no notification support).
    ///
    /// These characteristics do not support BLE notifications in the firmware, so the
    /// app reads them once during connection setup. Their values change slowly enough
    /// that a single read is sufficient (pressure, PM1.0, PM10 update infrequently).
    static let essReadCharacteristicUUIDs: [CBUUID] = [
        essPressure, essPM1_0, essPM10,
    ]

    /// Combined list of all ESS characteristic UUIDs to discover under the ESS service.
    ///
    /// Union of ``essNotifyCharacteristicUUIDs`` and ``essReadCharacteristicUUIDs``.
    /// Used during service discovery to find all ESS characteristics in one call.
    static let allESSCharacteristicUUIDs: [CBUUID] = essNotifyCharacteristicUUIDs + essReadCharacteristicUUIDs
}
