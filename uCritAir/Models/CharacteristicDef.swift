// MARK: - CharacteristicDef.swift
// Part of the uCritAir iOS app — an air quality monitor companion.
//
// This file defines the **catalog of known BLE characteristics** used by
// the Raw BLE Inspector developer tool. It provides human-readable metadata
// (labels, access modes, data formats) for every characteristic the app
// knows about.
//
// **What is a BLE characteristic?**
//
// In Bluetooth Low Energy (BLE), data is organized into a hierarchy:
//
//   Device
//     --> Service (a group of related data, identified by a UUID)
//       --> Characteristic (a single data value, identified by a UUID)
//
// Think of a BLE service as a "folder" and a characteristic as a "file"
// inside that folder. Each characteristic has:
//   - A UUID (unique identifier)
//   - A value (the actual data bytes)
//   - Properties (read, write, notify, etc.)
//
// **The uCrit device exposes two BLE services:**
//
// 1. **Custom Vendor Service** (UUID `0x0000`) — proprietary characteristics
//    for device-specific data (device name, pet stats, log cells, config, etc.)
//
// 2. **Environmental Sensing Service (ESS)** (UUID `0x181A`) — standard
//    Bluetooth SIG characteristics for environmental data (temperature,
//    humidity, pressure, CO2, particulate matter).
//
// **Why this catalog exists:**
//
// The Raw BLE Inspector is a developer/debug tool that lets you read and
// write any BLE characteristic directly. This catalog provides the picker
// list with human-readable labels, so developers don't have to memorize
// UUIDs or look up data formats.

// The `@preconcurrency` attribute suppresses Swift 6 concurrency warnings
// for CoreBluetooth types (like CBUUID) that haven't been fully annotated
// for Sendable yet.
@preconcurrency import CoreBluetooth

// MARK: - CharAccess

/// The access mode (permissions) of a BLE characteristic.
///
/// BLE characteristics can support different combinations of read and write
/// operations. This enum captures the three modes relevant to the uCrit
/// device's characteristics.
///
/// ## How this maps to BLE
///
/// In Core Bluetooth, characteristics have a `properties` bitmask that can
/// include `.read`, `.write`, `.notify`, etc. This simplified enum captures
/// the user-facing access mode for the BLE Inspector picker UI.
///
/// ## Raw Values
///
/// The raw `String` values (`"r"`, `"w"`, `"r/w"`) are used for display
/// in the BLE Inspector UI next to each characteristic.
enum CharAccess: String, Sendable {
    /// The characteristic can be read but not written.
    ///
    /// Reading returns the current value. Attempting to write will fail.
    /// Example: sensor readings, pet stats.
    case read = "r"

    /// The characteristic can be written but not read.
    ///
    /// Writing sets a value on the device. Attempting to read may return
    /// stale or empty data. Example: cell selector (tells the device which
    /// log cell to prepare for reading).
    case write = "w"

    /// The characteristic supports both reading and writing.
    ///
    /// The app can read the current value and write a new one.
    /// Example: device name, device config, pet name.
    case readWrite = "r/w"
}

// MARK: - CharacteristicDef

/// Metadata definition for a single known BLE characteristic.
///
/// ## Overview
///
/// Each `CharacteristicDef` describes one BLE characteristic that the app
/// knows about. It bundles together the information needed to display the
/// characteristic in the Raw BLE Inspector picker and to guide the
/// developer in reading/writing its data.
///
/// ## What each field provides
///
/// | Field    | Purpose                                          | Example               |
/// |----------|--------------------------------------------------|-----------------------|
/// | `label`  | Human-readable name for the picker UI            | "Temperature"         |
/// | `uuid`   | The BLE UUID used to find this characteristic    | `CBUUID(string: "2A6E")` |
/// | `access` | Whether you can read, write, or both             | `.read`               |
/// | `format` | Description of the raw byte format               | "int16 LE (x0.01 C)" |
///
/// ## Conformances
///
/// - `Identifiable` — uses the UUID string as the stable identity for
///   SwiftUI `ForEach` / `Picker` views.
/// - `Sendable` — safe to pass across concurrency boundaries.
struct CharacteristicDef: Identifiable, Sendable {

    /// Human-readable display label shown in the BLE Inspector picker.
    ///
    /// This is the name the developer sees when selecting which characteristic
    /// to inspect. It should be concise and descriptive.
    ///
    /// - **Examples:** "Device Name", "Temperature", "Pet Stats", "CO2"
    let label: String

    /// The Core Bluetooth UUID (`CBUUID`) of this characteristic.
    ///
    /// This UUID is used to locate the characteristic on the device during
    /// BLE service discovery. Standard characteristics use 16-bit UUIDs
    /// (e.g., `0x2A6E` for temperature). Custom characteristics use the
    /// vendor's base UUID with a 16-bit characteristic ID.
    ///
    /// The actual UUID values are defined in ``BLEConstants``.
    let uuid: CBUUID

    /// The access mode (read, write, or read/write) for this characteristic.
    ///
    /// Determines which operations the BLE Inspector allows. A read-only
    /// characteristic will only show a "Read" button; a writable one will
    /// also show a text field for entering data to write.
    let access: CharAccess

    /// Human-readable description of the characteristic's binary data format.
    ///
    /// This helps developers understand how to interpret the raw bytes
    /// returned by a read operation, or how to format bytes for a write.
    ///
    /// - **Examples:**
    ///   - `"UTF-8 string"` — the bytes are a text string
    ///   - `"uint32 LE"` — a 4-byte unsigned integer in little-endian order
    ///   - `"int16 LE (x0.01 °C)"` — a signed 16-bit integer that must be
    ///     multiplied by 0.01 to get degrees Celsius
    ///   - `"57-byte struct"` — a complex binary structure (see ``ParsedLogCell``)
    ///   - `"16-byte struct"` — the device config (see ``DeviceConfig``)
    let format: String

    /// The stable identity for SwiftUI, derived from the characteristic's UUID.
    ///
    /// Since each characteristic has a unique UUID, its string form makes
    /// a natural and stable identifier for `Identifiable` conformance.
    var id: String { uuid.uuidString }
}

// MARK: - KnownCharacteristics

/// A static catalog of all known BLE characteristics on the uCrit device.
///
/// ## Overview
///
/// `KnownCharacteristics` is a **caseless enum** (it has no instances —
/// it exists purely as a namespace for static properties). It groups the
/// known characteristics into two categories:
///
/// - ``custom`` — proprietary characteristics in the vendor's Custom Service
/// - ``ess`` — standard characteristics in the Environmental Sensing Service
/// - ``all`` — the combined list of both
///
/// ## Why a caseless enum?
///
/// In Swift, a caseless `enum` (an enum with no cases) cannot be
/// instantiated. This makes it a clean namespace for grouping related
/// static constants — similar to a `static class` in other languages.
///
/// ## Where UUIDs come from
///
/// The UUID constants (like `BLEConstants.charDeviceName`) are defined in
/// the `BLEConstants` enum in the BLE layer. This catalog simply references
/// them and adds human-readable metadata.
enum KnownCharacteristics {

    /// Characteristics in the **Custom Vendor Service** (service UUID `0x0000`).
    ///
    /// These are proprietary to the uCrit device and not defined by the
    /// Bluetooth SIG standard. They carry device-specific data like the
    /// pet's stats, log cells, device configuration, and game items.
    ///
    /// Characteristic IDs range from `0x0001` to `0x0015`.
    static let custom: [CharacteristicDef] = [
        CharacteristicDef(label: "Device Name",   uuid: BLEConstants.charDeviceName,   access: .readWrite, format: "UTF-8 string"),
        CharacteristicDef(label: "Time",           uuid: BLEConstants.charTime,         access: .readWrite, format: "uint32 LE"),
        CharacteristicDef(label: "Cell Count",     uuid: BLEConstants.charCellCount,    access: .read,      format: "uint32 LE"),
        CharacteristicDef(label: "Cell Selector",  uuid: BLEConstants.charCellSelector, access: .write,     format: "uint32 LE"),
        CharacteristicDef(label: "Cell Data",      uuid: BLEConstants.charCellData,     access: .read,      format: "57-byte struct"),
        CharacteristicDef(label: "Log Stream",    uuid: BLEConstants.charLogStream,    access: .readWrite, format: "notify stream"),
        CharacteristicDef(label: "Pet Stats",      uuid: BLEConstants.charStats,        access: .read,      format: "6-byte struct"),
        CharacteristicDef(label: "Items Owned",    uuid: BLEConstants.charItemsOwned,   access: .read,      format: "32-byte bitmap"),
        CharacteristicDef(label: "Items Placed",   uuid: BLEConstants.charItemsPlaced,  access: .read,      format: "32-byte bitmap"),
        CharacteristicDef(label: "Bonus",          uuid: BLEConstants.charBonus,        access: .readWrite, format: "uint32 LE"),
        CharacteristicDef(label: "Pet Name",       uuid: BLEConstants.charPetName,      access: .readWrite, format: "UTF-8 string"),
        CharacteristicDef(label: "Device Config",  uuid: BLEConstants.charDeviceConfig, access: .readWrite, format: "16-byte struct"),
    ]

    /// Characteristics in the **Environmental Sensing Service (ESS)**
    /// (service UUID `0x181A`).
    ///
    /// These are **standard** Bluetooth SIG characteristics defined in the
    /// GATT Specification. Any BLE client that understands ESS can read
    /// these values. They provide live sensor readings with notifications.
    ///
    /// Each characteristic carries a single sensor value in a compact binary
    /// format (see the `format` field for encoding details).
    static let ess: [CharacteristicDef] = [
        CharacteristicDef(label: "Temperature", uuid: BLEConstants.essTemperature, access: .read, format: "int16 LE (x0.01 °C)"),
        CharacteristicDef(label: "Humidity",    uuid: BLEConstants.essHumidity,    access: .read, format: "uint16 LE (x0.01 %)"),
        CharacteristicDef(label: "Pressure",    uuid: BLEConstants.essPressure,    access: .read, format: "uint32 LE (x0.1 Pa)"),
        CharacteristicDef(label: "CO₂",         uuid: BLEConstants.essCO2,         access: .read, format: "uint16 LE (ppm)"),
        CharacteristicDef(label: "PM2.5",       uuid: BLEConstants.essPM2_5,       access: .read, format: "binary16 float"),
        CharacteristicDef(label: "PM1.0",       uuid: BLEConstants.essPM1_0,       access: .read, format: "binary16 float"),
        CharacteristicDef(label: "PM10",        uuid: BLEConstants.essPM10,        access: .read, format: "binary16 float"),
    ]

    /// All known characteristics: the union of ``custom`` and ``ess``.
    ///
    /// Use this when you need a flat list of every characteristic the app
    /// knows about — for example, to populate the BLE Inspector's full
    /// picker list.
    static let all: [CharacteristicDef] = custom + ess
}
