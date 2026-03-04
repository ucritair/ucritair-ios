@preconcurrency import CoreBluetooth

/// Access mode for a BLE characteristic (read-only, write-only, or read-write).
enum CharAccess: String, Sendable {
    case read = "r"
    case write = "w"
    case readWrite = "r/w"
}

/// Definition of a known BLE characteristic for the Raw BLE Inspector picker.
struct CharacteristicDef: Identifiable, Sendable {
    /// Display label shown in the picker (e.g. "Device Name").
    let label: String

    /// The CBUUID of this characteristic.
    let uuid: CBUUID

    /// Whether the characteristic supports read, write, or both.
    let access: CharAccess

    /// Human-readable data format description (e.g. "UTF-8 string", "uint32 LE").
    let format: String

    var id: String { uuid.uuidString }
}

/// Catalog of all known BLE characteristics for the Raw BLE Inspector.
///
/// Groups characteristics by service: Custom Vendor Service (0x0000) and
/// Environmental Sensing Service (0x181A). UUIDs reference ``BLEConstants``.
enum KnownCharacteristics {

    /// Custom vendor service characteristics (char IDs 0x0001–0x0015).
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

    /// Environmental Sensing Service (ESS) characteristics.
    static let ess: [CharacteristicDef] = [
        CharacteristicDef(label: "Temperature", uuid: BLEConstants.essTemperature, access: .read, format: "int16 LE (x0.01 °C)"),
        CharacteristicDef(label: "Humidity",    uuid: BLEConstants.essHumidity,    access: .read, format: "uint16 LE (x0.01 %)"),
        CharacteristicDef(label: "Pressure",    uuid: BLEConstants.essPressure,    access: .read, format: "uint32 LE (x0.1 Pa)"),
        CharacteristicDef(label: "CO₂",         uuid: BLEConstants.essCO2,         access: .read, format: "uint16 LE (ppm)"),
        CharacteristicDef(label: "PM2.5",       uuid: BLEConstants.essPM2_5,       access: .read, format: "binary16 float"),
        CharacteristicDef(label: "PM1.0",       uuid: BLEConstants.essPM1_0,       access: .read, format: "binary16 float"),
        CharacteristicDef(label: "PM10",        uuid: BLEConstants.essPM10,        access: .read, format: "binary16 float"),
    ]

    /// All known characteristics (custom + ESS).
    static let all: [CharacteristicDef] = custom + ess
}
