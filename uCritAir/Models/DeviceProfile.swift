import Foundation
import SwiftData

/// Persistent device registry entry -- one per physical uCrit device the user has connected to.
///
/// The device identity is tied to the `CBPeripheral` UUID, which is stable per-device
/// per-iPhone. Stored in SwiftData so the app remembers previously-paired devices
/// and their metadata across launches.
@Model
final class DeviceProfile {
    /// Primary key: `CBPeripheral.identifier.uuidString`.
    @Attribute(.unique) var deviceId: String

    /// Device name read from the BLE characteristic.
    var deviceName: String

    /// Pet name read from the BLE characteristic.
    var petName: String

    /// User-editable room/location label (e.g. "Bedroom", "Office").
    var roomLabel: String?

    /// Last time the app successfully connected to this device.
    var lastConnectedAt: Date

    /// Last known cell count on the device (for showing sync status when offline).
    var lastKnownCellCount: Int

    /// Display order for the device list (user can reorder).
    var sortOrder: Int

    /// Creates a new device profile with the given peripheral identifier and optional metadata.
    ///
    /// - Parameters:
    ///   - deviceId: The `CBPeripheral.identifier.uuidString` that uniquely identifies this device on this iPhone.
    ///   - deviceName: Human-readable device name from BLE characteristic 0x0001. Defaults to `"Unknown"`.
    ///   - petName: Virtual pet name from BLE characteristic 0x0014. Defaults to an empty string.
    ///   - roomLabel: Optional user-assigned location label (e.g. "Living Room").
    ///   - lastConnectedAt: Timestamp of the most recent successful connection. Defaults to now.
    ///   - lastKnownCellCount: The device's log cell count at last connection, for offline sync status. Defaults to `0`.
    ///   - sortOrder: Position in the user's device list. Defaults to `0`.
    init(
        deviceId: String,
        deviceName: String = "Unknown",
        petName: String = "",
        roomLabel: String? = nil,
        lastConnectedAt: Date = .now,
        lastKnownCellCount: Int = 0,
        sortOrder: Int = 0
    ) {
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.petName = petName
        self.roomLabel = roomLabel
        self.lastConnectedAt = lastConnectedAt
        self.lastKnownCellCount = lastKnownCellCount
        self.sortOrder = sortOrder
    }
}
