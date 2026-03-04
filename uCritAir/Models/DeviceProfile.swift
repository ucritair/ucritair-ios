// MARK: - DeviceProfile.swift
// Part of the uCritAir iOS app — an air quality monitor companion.
//
// This file defines `DeviceProfile`, a **SwiftData model** that persists
// metadata about each uCrit device the user has connected to. Think of it
// as the app's "address book" for devices.
//
// **Why persist device metadata?**
//
// When the app launches, it needs to know about previously-connected devices
// even before BLE scanning finds them. This allows the UI to show:
//   - A list of "known" devices with their names and room labels
//   - Sync status ("last connected 2 hours ago, 150 cells behind")
//   - A consistent display order chosen by the user
//
// **SwiftData basics (for first-year CS students):**
//
// SwiftData is Apple's framework for saving data to a local SQLite database.
// Key concepts used here:
//
//   - `@Model` — marks this class as a database table. SwiftData automatically
//     creates a SQLite table with columns matching the class's properties.
//   - `@Attribute(.unique)` — marks a property as the primary key. No two
//     rows can have the same value for this column.
//   - `final class` — SwiftData models must be classes (not structs) so
//     SwiftData can observe changes. `final` prevents subclassing.
//
// **Identity strategy:**
//
// Each `DeviceProfile` is identified by the `CBPeripheral.identifier` UUID
// string. This UUID is assigned by iOS and is **stable** for a given
// (device, iPhone) pair — meaning the same uCrit device will always have
// the same UUID on the same iPhone, even across app relaunches.

import Foundation
import SwiftData

/// A persistent record of a uCrit device the user has connected to.
///
/// ## Overview
///
/// `DeviceProfile` is a **SwiftData model** that stores metadata about each
/// physical uCrit device. One `DeviceProfile` row exists per device the user
/// has ever connected to. The data persists across app launches in a local
/// SQLite database managed by SwiftData.
///
/// ## What it stores
///
/// - **Identity:** The device's BLE peripheral UUID (primary key)
/// - **Names:** Device name and virtual pet name (read from BLE)
/// - **User metadata:** Room label (user-assigned) and display sort order
/// - **Sync status:** Last connection time and last known log cell count
///
/// ## Relationships to other types
///
/// - **``LogCellEntity``** — log cells reference back to a device via
///   `deviceId`, but there is no formal SwiftData relationship (they use
///   a string foreign key pattern instead).
/// - **``DeviceViewModel``** — the view model reads and writes `DeviceProfile`
///   to keep the database in sync with the live BLE connection state.
///
/// ## Lifecycle
///
/// 1. **Created** when the user connects to a new uCrit device for the first
///    time. The `init` populates defaults for most fields.
/// 2. **Updated** on every successful connection (refreshes `lastConnectedAt`,
///    `lastKnownCellCount`, and potentially `deviceName`/`petName`).
/// 3. **Queried** at app launch to populate the device list before BLE
///    scanning completes.
/// 4. **Never deleted** automatically — the user must explicitly remove a
///    device from the app.
@Model
final class DeviceProfile {

    // MARK: - Primary Key

    /// The unique identifier for this device, derived from Core Bluetooth.
    ///
    /// This is the string form of `CBPeripheral.identifier` (a `UUID`).
    /// iOS assigns this UUID and guarantees it is **stable per-device
    /// per-iPhone** — meaning the same physical uCrit device will always
    /// have the same UUID on the same iPhone, even after rebooting either
    /// device.
    ///
    /// > Important: This UUID is **not** the same across different iPhones.
    /// > If the user connects the same uCrit device from two iPhones, each
    /// > iPhone will assign a different UUID.
    ///
    /// - **SwiftData annotation:** `@Attribute(.unique)` makes this the
    ///   primary key. If you try to insert a second `DeviceProfile` with the
    ///   same `deviceId`, SwiftData will update the existing row instead.
    @Attribute(.unique) var deviceId: String

    // MARK: - Device Metadata (from BLE)

    /// Human-readable device name, read from BLE characteristic `0x0001`.
    ///
    /// This is the name the user set on the device itself (via the
    /// touchscreen). It defaults to `"Unknown"` until the app reads the
    /// characteristic for the first time.
    ///
    /// - **Example values:** "Living Room uCrit", "Office Monitor"
    var deviceName: String

    /// The virtual pet's name, read from BLE characteristic `0x0014`.
    ///
    /// The user names their pet on the device. This field caches that name
    /// so the app can display it even when the device is not connected.
    ///
    /// - **Example values:** "Dusty", "Breezy", ""
    /// - **Default:** Empty string (pet not yet named)
    var petName: String

    // MARK: - User Metadata

    /// Optional user-assigned location label for this device.
    ///
    /// The user can tag each device with a room or location name in the
    /// iOS app settings. This helps distinguish multiple devices in a
    /// household.
    ///
    /// - **Example values:** "Bedroom", "Office", "Kitchen", `nil`
    /// - **Default:** `nil` (no label assigned yet)
    var roomLabel: String?

    // MARK: - Sync Status

    /// The timestamp of the most recent successful BLE connection to this device.
    ///
    /// "Successful connection" means the app completed BLE service discovery
    /// and began receiving characteristic notifications. This is used to
    /// display "Last connected X minutes/hours ago" in the UI.
    ///
    /// - **Default:** The current time at profile creation (`Date.now`)
    var lastConnectedAt: Date

    /// The device's total log cell count at the time of the last connection.
    ///
    /// The device maintains a running count of how many log cells it has
    /// recorded. By comparing this cached value with the locally-synced cell
    /// count, the app can show how many cells are waiting to be downloaded
    /// — even when the device is offline.
    ///
    /// - **Example:** If `lastKnownCellCount` is 500 and the app has synced
    ///   480 cells, the UI shows "20 cells behind."
    /// - **Default:** 0 (no cells known yet)
    var lastKnownCellCount: Int

    // MARK: - Display Order

    /// Position in the user's device list (lower values appear first).
    ///
    /// The user can reorder their devices in the device list by dragging.
    /// This integer stores the resulting order so it persists across
    /// app launches.
    ///
    /// - **Default:** 0 (new devices appear at the top)
    var sortOrder: Int

    // MARK: - Initializer

    /// Creates a new device profile with the given peripheral identifier
    /// and optional metadata.
    ///
    /// This initializer is called when the user connects to a **new** uCrit
    /// device for the first time. Most parameters have sensible defaults so
    /// callers only need to provide the `deviceId`.
    ///
    /// - Parameters:
    ///   - deviceId: The `CBPeripheral.identifier.uuidString` that uniquely
    ///     identifies this device on this iPhone. **Required.**
    ///   - deviceName: Human-readable device name from BLE characteristic
    ///     `0x0001`. Defaults to `"Unknown"` until the real name is read.
    ///   - petName: Virtual pet name from BLE characteristic `0x0014`.
    ///     Defaults to an empty string.
    ///   - roomLabel: Optional user-assigned location label (e.g., "Living
    ///     Room"). Defaults to `nil`.
    ///   - lastConnectedAt: Timestamp of the most recent successful
    ///     connection. Defaults to `Date.now`.
    ///   - lastKnownCellCount: The device's log cell count at last
    ///     connection, for offline sync status. Defaults to `0`.
    ///   - sortOrder: Position in the user's device list. Lower values
    ///     appear first. Defaults to `0`.
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
