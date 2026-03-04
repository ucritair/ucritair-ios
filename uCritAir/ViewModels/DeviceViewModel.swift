// MARK: - DeviceViewModel.swift
// uCritAir iOS App
//
// ============================================================================
// FILE OVERVIEW
// ============================================================================
//
// This file defines `DeviceViewModel`, the central ViewModel responsible for
// managing the connection lifecycle, device metadata, and multi-device registry
// for the uCritAir iOS app.
//
// In the MVVM (Model-View-ViewModel) architecture used by this app, a ViewModel
// sits between the View layer (SwiftUI) and the Model/Service layer (BLE, SwiftData).
// Views observe the ViewModel's published properties and re-render automatically
// when those properties change. The ViewModel encapsulates all business logic so
// that Views remain simple and declarative.
//
// This ViewModel is the "hub" of the app. It:
//   1. Owns the connection to BLEManager and receives BLE state callbacks.
//   2. Reads/writes device characteristics (name, pet name, time, config, etc.)
//      via the BLECharacteristics helper, which wraps raw BLE byte operations.
//   3. Persists a registry of known devices using SwiftData (Apple's ORM for
//      on-device SQLite), so previously paired devices are remembered across
//      app launches.
//   4. Exposes user-facing error messages by translating cryptic CoreBluetooth
//      error codes into actionable, human-readable strings.
//
// Threading Model:
//   - The `@Observable` macro (introduced in iOS 17) makes every stored property
//     automatically observable by SwiftUI. When any property changes, any View
//     that reads it will re-render. This replaces the older `@Published` +
//     `ObservableObject` pattern.
//   - Most methods are annotated `@MainActor`, meaning they are guaranteed to
//     run on the main thread. This is critical because:
//       (a) SwiftUI can only update the UI from the main thread.
//       (b) SwiftData's ModelContext is not thread-safe.
//       (c) BLEManager dispatches its callbacks on the main queue.
//   - `async` methods use Swift's structured concurrency (`await`) to perform
//     sequential BLE reads/writes without blocking the main thread.
//
// Dependency Graph:
//   ContentView → DeviceViewModel → BLEManager (BLE hardware)
//                                 → ModelContext (SwiftData persistence)
//                                 → BLECharacteristics (read/write helpers)
//
// Ported from the web prototype's `src/stores/device.ts` (useDeviceStore),
// extended with native iOS multi-device SwiftData persistence.
// ============================================================================

import Foundation
import SwiftData
import os.log

/// The primary ViewModel for device connection management, BLE data access,
/// and the multi-device registry.
///
/// ## Responsibilities
///
/// - **Connection Lifecycle**: Manages scanning, connecting, reconnecting, and
///   disconnecting from uCritAir BLE peripherals via ``BLEManager``.
///
/// - **Device Info**: Reads and writes device characteristics such as the device
///   name, pet name, RTC clock, pet stats, configuration, item bitmaps, bonus
///   points, and log cell count. Each of these is exposed as an `@Observable`
///   property that SwiftUI views can bind to directly.
///
/// - **Multi-Device Registry**: Maintains a persistent list of ``DeviceProfile``
///   records in SwiftData. Each time a device connects, its profile is "upserted"
///   (created if new, updated if existing). The registry enables the device list
///   screen, auto-reconnect on launch, and offline display of last-known metadata.
///
/// - **Error Mapping**: Translates raw `CBErrorDomain` and `CBATTErrorDomain`
///   error codes into concise, user-friendly messages via ``friendlyMessage(for:context:)``.
///
/// ## Dependencies
///
/// - ``BLEManager``: Injected via ``configure(bleManager:)`` at app startup.
///   Provides the raw BLE transport (scan, connect, read, write, notify).
///
/// - ``ModelContext`` (SwiftData): Injected via ``configureStorage(modelContext:)``
///   from a SwiftUI view's `@Environment(\.modelContext)`. Used for persisting
///   ``DeviceProfile`` records.
///
/// ## Threading
///
/// This class is designed for main-thread use. The `@MainActor` annotation on
/// mutating methods ensures all property writes happen on the main thread, which
/// is required for both SwiftUI observation and SwiftData safety. BLE callbacks
/// arrive on the main queue (because ``BLEManager`` creates its `CBCentralManager`
/// with `queue: .main`), so the `MainActor.assumeIsolated` calls in the callback
/// closures are safe.
///
/// ## The @Observable Macro
///
/// The `@Observable` macro (Swift 5.9 / iOS 17) automatically synthesizes
/// change-tracking for all stored properties. When a SwiftUI view reads a
/// property of an `@Observable` object during its `body` evaluation, SwiftUI
/// records that dependency. If the property later changes, SwiftUI re-evaluates
/// only the views that depend on it. This is more efficient than the older
/// `ObservableObject` protocol, which triggered updates for *any* `@Published`
/// property change.
@Observable
final class DeviceViewModel {

    // MARK: - State
    //
    // These properties form the "single source of truth" for the connected device.
    // SwiftUI views read them directly (e.g., `deviceVM.deviceName`) and
    // automatically re-render when they change, thanks to @Observable.
    //
    // All properties start as `nil` (no device connected) and are populated by
    // `refreshDeviceInfo()` after a successful BLE connection. They are reset
    // back to `nil` by `clearDeviceInfo()` on disconnect.

    /// Current BLE connection state (disconnected, scanning, connecting, connected, etc.).
    ///
    /// Drives the UI's connection indicator and determines which actions are available.
    /// Updated by the ``BLEManager/onConnectionStateChanged`` callback wired in
    /// ``configure(bleManager:)``.
    ///
    /// - Read by: `ConnectButton`, `DeviceView`, `DeviceListView`, `ContentView`
    /// - Written by: BLE connection state callback (see ``configure(bleManager:)``).
    var connectionState: ConnectionState = .disconnected

    /// The advertised device name read from the connected peripheral.
    ///
    /// This is the user-visible name stored on the device's BLE characteristic (e.g., "uCritAir-001").
    /// Not to be confused with ``DeviceProfile/deviceName``, which is the persisted copy.
    ///
    /// - Read by: `DeviceView` header, `DeviceCardRow`
    /// - Written by: ``refreshDeviceInfo()``, ``writeDeviceName(_:)``
    var deviceName: String?

    /// The user-assigned pet name stored on the device (e.g., "Pixel").
    ///
    /// The uCritAir device has a virtual pet whose name can be customized.
    /// This property holds the live value from the BLE characteristic.
    ///
    /// - Read by: `DeviceView`, `DeviceCardRow`
    /// - Written by: ``refreshDeviceInfo()``, ``writePetName(_:)``
    var petName: String?

    /// The device's RTC (Real-Time Clock) value as a Unix-epoch `UInt32`.
    ///
    /// The device stores time using a "local time as epoch" convention: the local
    /// wall-clock time is stored as if it were UTC. For example, 3:00 PM PST is
    /// stored as the epoch value for 3:00 PM UTC. This simplifies log cell
    /// timestamp interpretation but means the value does not represent true UTC.
    ///
    /// - Read by: `DeviceView` (time display and sync button)
    /// - Written by: ``refreshDeviceInfo()``, ``syncTime()``, ``writeTime(_:)``
    var deviceTime: UInt32?

    /// Virtual pet statistics (vigour, focus, spirit, age, interventions) read from the device.
    ///
    /// The ``PetStats`` struct contains the gameplay metrics for the virtual pet
    /// that lives on the uCritAir hardware. These are read-only from the iOS app's
    /// perspective.
    ///
    /// - Read by: `DeviceView` (pet stats display)
    /// - Written by: ``refreshDeviceInfo()``
    var petStats: PetStats?

    /// Device configuration parameters (sensor wake period, brightness, persist flags, etc.).
    ///
    /// The ``DeviceConfig`` struct holds tunable parameters that control the device's
    /// behavior: how often sensors wake, LCD brightness, whether data persists to flash, etc.
    /// Can be modified by the user through the settings UI and written back to the device.
    ///
    /// - Read by: `DeviceView` (settings section)
    /// - Written by: ``refreshDeviceInfo()``, ``writeConfig(_:)``
    var config: DeviceConfig?

    /// Raw bitmap of items owned by the virtual pet.
    ///
    /// Each bit in this `Data` blob represents whether the pet has acquired a
    /// particular in-game item. The item catalog is defined on the firmware side.
    ///
    /// - Read by: (future) Pet inventory UI
    /// - Written by: ``refreshDeviceInfo()``
    var itemsOwned: Data?

    /// Raw bitmap of items currently placed in the virtual pet's room.
    ///
    /// Similar to ``itemsOwned``, but tracks which items are actively placed
    /// (displayed) in the pet's virtual room on the device's LCD.
    ///
    /// - Read by: (future) Pet room UI
    /// - Written by: ``refreshDeviceInfo()``
    var itemsPlaced: Data?

    /// Accumulated bonus points on the device.
    ///
    /// Bonus points are earned through gameplay (e.g., the Stroop test) and can
    /// be spent on virtual pet items.
    ///
    /// - Read by: `DeviceView` (bonus display)
    /// - Written by: ``refreshDeviceInfo()``
    var bonus: UInt32?

    /// Total number of log cells stored on the device's flash memory.
    ///
    /// Each "log cell" is a 57-byte record containing a timestamped snapshot of
    /// all sensor readings. The device writes a new cell at a configurable interval
    /// (typically every 60 seconds). This count is used by ``HistoryViewModel`` to
    /// determine how many new cells need to be downloaded.
    ///
    /// - Read by: `DeviceView` (sync status), ``HistoryViewModel/downloadNewCells()``
    /// - Written by: ``refreshDeviceInfo()``
    var cellCount: UInt32?

    /// User-facing error message from the most recent failed operation, or `nil` if no error.
    ///
    /// When a BLE read, write, or SwiftData operation fails, this property is set to a
    /// human-readable string generated by ``friendlyMessage(for:context:)``. Views
    /// display this in an error banner. Setting a new error overwrites the previous one;
    /// successful operations should clear this to `nil` if appropriate.
    ///
    /// - Read by: `DeviceView` (error banner), `DeviceListView`
    /// - Written by: Various methods on error, or `nil` on scan start.
    var error: String?

    /// Human-readable Bluetooth status message shown when BT is unavailable (off, denied, unsupported).
    /// `nil` when Bluetooth is powered on and available.
    ///
    /// This is a **computed property** that derives its value from ``BLEManager/bluetoothState``.
    /// Because `BLEManager` is also `@Observable`, SwiftUI will re-evaluate any view
    /// reading this property whenever the underlying Bluetooth state changes. This
    /// gives us reactive UI updates without manual notification logic.
    ///
    /// The messages are written to guide non-technical users toward the correct
    /// system setting to fix the problem.
    ///
    /// - Returns: A localized message string if Bluetooth is unavailable, or `nil`
    ///   if Bluetooth is powered on and ready to use.
    var bluetoothStatusMessage: String? {
        guard let state = bleManager?.bluetoothState else { return nil }
        switch state {
        case .poweredOff:
            return "Bluetooth is turned off. Enable it in Settings to connect."
        case .unauthorized:
            return "Bluetooth permission denied. Enable it in Settings > Privacy > Bluetooth."
        case .unsupported:
            return "This device does not support Bluetooth Low Energy."
        default:
            return nil
        }
    }

    /// All device profiles persisted in SwiftData, sorted by ``DeviceProfile/sortOrder``.
    ///
    /// This array is the data source for the device list screen. It is refreshed
    /// from SwiftData by ``loadKnownDevices()`` whenever profiles are created,
    /// updated, or deleted. The sort order can be customized by the user (drag-to-reorder).
    ///
    /// - Read by: `DeviceListView`, ``autoConnectToLastDevice()``
    /// - Written by: ``loadKnownDevices()``
    var knownDevices: [DeviceProfile] = []

    /// Reference to the shared BLE manager for connection and characteristic operations.
    ///
    /// Injected once at app startup via ``configure(bleManager:)``. Marked
    /// `private(set)` so that the `DeveloperView` (Raw BLE Inspector) can read
    /// the manager but external code cannot replace it.
    ///
    /// - Note: This is `nil` only before ``configure(bleManager:)`` is called.
    ///   All methods guard on this being non-nil before proceeding.
    private(set) var bleManager: BLEManager?

    /// SwiftData model context for persisting device profiles and log cells.
    ///
    /// Injected via ``configureStorage(modelContext:)`` from the SwiftUI view
    /// hierarchy, because `ModelContext` is provided by SwiftUI's
    /// `@Environment(\.modelContext)` and is not available at app-level init time.
    ///
    /// - Important: `ModelContext` is **not** thread-safe. All access must happen
    ///   on the `@MainActor`, which is enforced by the `@MainActor` annotation on
    ///   every method that touches this property.
    private var modelContext: ModelContext?

    /// Unified logger for this ViewModel. Messages appear in Console.app under
    /// the subsystem "com.ucritter.ucritair" with category "Device".
    private let logger = Logger(subsystem: "com.ucritter.ucritair", category: "Device")

    // MARK: - Computed Properties
    //
    // Computed properties derive values from other state without storing anything.
    // Because `@Observable` tracks access to the underlying stored properties,
    // SwiftUI views that read these computed properties will still update correctly
    // when the underlying data changes.

    /// The `deviceId` (CBPeripheral UUID string) of the currently connected peripheral.
    ///
    /// This is a pass-through to ``BLEManager/connectedDeviceId``. Returns `nil`
    /// when no device is connected. Used as the key for SwiftData lookups and
    /// to scope data operations to the correct device.
    var activeDeviceId: String? {
        bleManager?.connectedDeviceId
    }

    /// The ``DeviceProfile`` for the currently connected device, if one exists
    /// in the ``knownDevices`` registry.
    ///
    /// Performs a linear search through the known devices array. Returns `nil` if
    /// no device is connected or if the connected device has not yet been persisted
    /// (which happens shortly after connection in ``upsertDeviceProfile()``).
    ///
    /// - Complexity: O(n) where n is the number of known devices (typically < 10).
    var activeProfile: DeviceProfile? {
        guard let id = activeDeviceId else { return nil }
        return knownDevices.first { $0.deviceId == id }
    }

    // MARK: - Configuration
    //
    // The ViewModel has a two-phase initialization:
    //   1. `configure(bleManager:)` — called once from ContentView.init or .onAppear
    //      to wire up the BLE callback that drives the entire connection lifecycle.
    //   2. `configureStorage(modelContext:)` — called from a View's .onAppear where
    //      SwiftUI's @Environment(\.modelContext) is available. This provides the
    //      SwiftData persistence layer.
    //
    // This two-phase pattern exists because SwiftData's ModelContext is only
    // available inside the SwiftUI view hierarchy (injected by the .modelContainer
    // modifier), while BLEManager is created at the app level.

    /// Wire up BLE manager callbacks. **Call exactly once at app startup.**
    ///
    /// This method stores a reference to the shared ``BLEManager`` and installs a
    /// connection-state callback that drives the entire post-connection flow:
    ///
    /// 1. When state becomes `.connected`:
    ///    - Spawns an async `Task` to call ``refreshDeviceInfo()`` (reads all
    ///      characteristics sequentially from the device).
    ///    - Then calls ``upsertDeviceProfile()`` to persist the device in SwiftData.
    ///
    /// 2. When state becomes `.disconnected`:
    ///    - Calls ``clearDeviceInfo()`` to reset all cached properties to `nil`.
    ///
    /// The callback closure captures `self` weakly (`[weak self]`) to avoid a
    /// retain cycle (BLEManager -> closure -> DeviceViewModel -> BLEManager).
    ///
    /// - Parameter bleManager: The shared BLE manager instance created at app launch.
    ///
    /// - Important: `MainActor.assumeIsolated` is used inside the callback because
    ///   BLEManager's `CBCentralManager` is initialized with `queue: .main`, so all
    ///   its delegate callbacks are guaranteed to arrive on the main thread. This is
    ///   safe and avoids an unnecessary async hop.
    @MainActor
    func configure(bleManager: BLEManager) {
        self.bleManager = bleManager

        // Install the connection state callback.
        // This closure is called by BLEManager every time the connection state changes.
        bleManager.onConnectionStateChanged = { [weak self] state in
            guard let self else { return }
            // BLE callbacks are dispatched on the main queue (CBCentralManager queue: .main).
            // `MainActor.assumeIsolated` asserts we are on the main thread and lets us
            // access @MainActor-isolated properties without an `await`.
            MainActor.assumeIsolated {
                self.connectionState = state

                // --- On successful connection ---
                // Kick off the characteristic read sequence and persist the device profile.
                // This runs in a Task so the async reads don't block the callback.
                if state == .connected {
                    Task { @MainActor in
                        await self.refreshDeviceInfo()
                        self.upsertDeviceProfile()
                    }
                }

                // --- On disconnect ---
                // Clear all cached device data so the UI shows a clean "no device" state.
                if state == .disconnected {
                    self.clearDeviceInfo()
                }
            }
        }
    }

    /// Provide the SwiftData ``ModelContext`` for persistence operations.
    ///
    /// Called from a SwiftUI view's `.onAppear` where `@Environment(\.modelContext)`
    /// is available. After storing the context, immediately loads all known device
    /// profiles from the database so the device list is populated.
    ///
    /// - Parameter modelContext: The SwiftData model context from the SwiftUI environment.
    ///
    /// - Note: This is separate from ``configure(bleManager:)`` because the
    ///   `ModelContext` is not available at app-level init time -- it is injected
    ///   by SwiftUI's `.modelContainer()` view modifier and only accessible inside
    ///   the view hierarchy.
    @MainActor
    func configureStorage(modelContext: ModelContext) {
        self.modelContext = modelContext
        logger.info("configureStorage: modelContext set")
        loadKnownDevices()
    }

    // MARK: - Multi-Device Registry
    //
    // The multi-device registry lets users manage multiple uCritAir devices from
    // a single iPhone. Each physical device is represented by a `DeviceProfile`
    // persisted in SwiftData. The "upsert" pattern (update-or-insert) ensures that
    // connecting to a device always records/updates its profile without creating
    // duplicates.
    //
    // SwiftData is Apple's modern ORM (Object-Relational Mapper) built on top of
    // Core Data / SQLite. It provides:
    //   - Automatic schema migration
    //   - Type-safe queries via `FetchDescriptor` and `#Predicate`
    //   - Integration with SwiftUI via `@Query` and `@Environment(\.modelContext)`
    //
    // The `ModelContext` acts like a "scratch pad" for changes. You fetch, insert,
    // and modify model objects on the context, then call `ctx.save()` to persist
    // changes to disk. If you don't save, changes are lost.

    /// Fetch all known device profiles from SwiftData, sorted by the user's
    /// preferred display order.
    ///
    /// This method queries the SwiftData store for all ``DeviceProfile`` records
    /// and assigns them to ``knownDevices``. It is called:
    ///   - Once during ``configureStorage(modelContext:)`` (initial load)
    ///   - After every create, update, or delete to keep the array in sync
    ///
    /// The `FetchDescriptor` is SwiftData's equivalent of an SQL query. Here it
    /// specifies: "SELECT * FROM DeviceProfile ORDER BY sortOrder ASC".
    ///
    /// - Side Effects: Updates ``knownDevices``. On failure, sets ``error`` to a
    ///   user-facing message.
    @MainActor
    func loadKnownDevices() {
        guard let ctx = modelContext else {
            logger.warning("loadKnownDevices: no modelContext")
            return
        }
        do {
            // Build a type-safe fetch request: all DeviceProfile records, sorted ascending.
            let descriptor = FetchDescriptor<DeviceProfile>(
                sortBy: [SortDescriptor(\.sortOrder, order: .forward)]
            )
            knownDevices = try ctx.fetch(descriptor)
            logger.info("loadKnownDevices: found \(self.knownDevices.count) devices")
        } catch {
            self.error = "Failed to load devices. Try restarting the app."
            logger.error("loadKnownDevices failed: \(error)")
        }
    }

    /// Create or update the ``DeviceProfile`` for the currently connected device.
    ///
    /// This implements the **upsert pattern** (update-or-insert):
    ///   1. Query SwiftData for an existing profile with the same `deviceId`.
    ///   2. If found: update its `deviceName`, `petName`, `lastConnectedAt`, and `lastKnownCellCount`.
    ///   3. If not found: create a new ``DeviceProfile`` and insert it into the context.
    ///   4. Save the context to persist changes to disk.
    ///   5. Reload ``knownDevices`` so the UI reflects the change.
    ///
    /// Called automatically by the connection callback in ``configure(bleManager:)``
    /// after ``refreshDeviceInfo()`` completes, so the profile always has the latest
    /// device metadata.
    ///
    /// The `#Predicate` macro creates a type-safe, compile-time-checked filter
    /// expression (similar to SQL WHERE). It is translated by SwiftData into an
    /// efficient SQLite query.
    ///
    /// - Side Effects: Inserts or modifies a ``DeviceProfile`` in SwiftData, saves
    ///   the context, and reloads ``knownDevices``. On failure, sets ``error``.
    @MainActor
    func upsertDeviceProfile() {
        logger.info("upsertDeviceProfile: hasContext=\(self.modelContext != nil) activeDeviceId=\(self.activeDeviceId ?? "nil")")
        guard let ctx = modelContext,
              let deviceId = activeDeviceId else {
            logger.warning("upsertDeviceProfile: skipping — missing context or deviceId")
            return
        }

        do {
            // Step 1: Look up an existing profile by deviceId.
            let descriptor = FetchDescriptor<DeviceProfile>(
                predicate: #Predicate { $0.deviceId == deviceId }
            )
            let existing = try ctx.fetch(descriptor).first

            if let profile = existing {
                // Step 2a: UPDATE — merge new values into existing profile.
                // Use nil-coalescing (`??`) to keep the old value if the new one is nil
                // (e.g., if a characteristic read failed during refreshDeviceInfo).
                profile.deviceName = deviceName ?? profile.deviceName
                profile.petName = petName ?? profile.petName
                profile.lastConnectedAt = .now
                if let cc = cellCount { profile.lastKnownCellCount = Int(cc) }
                logger.info("upsertDeviceProfile: updated existing profile for \(deviceId)")
            } else {
                // Step 2b: INSERT — create a brand-new profile.
                // sortOrder is set to the current count so new devices appear at the end.
                let nextOrder = knownDevices.count
                let profile = DeviceProfile(
                    deviceId: deviceId,
                    deviceName: deviceName ?? "Unknown",
                    petName: petName ?? "",
                    lastConnectedAt: .now,
                    lastKnownCellCount: Int(cellCount ?? 0),
                    sortOrder: nextOrder
                )
                ctx.insert(profile)
                logger.info("upsertDeviceProfile: created new profile for \(deviceId)")
            }

            // Step 3: Persist to disk and refresh the in-memory array.
            try ctx.save()
            loadKnownDevices()
            logger.info("upsertDeviceProfile: saved. knownDevices count = \(self.knownDevices.count)")
        } catch {
            self.error = "Failed to save device profile. Try restarting the app."
            logger.error("upsertDeviceProfile failed: \(error)")
        }
    }

    /// Remove a device profile from the registry, optionally deleting its cached log data.
    ///
    /// This is a destructive operation. If `deleteCachedData` is `true`, all
    /// ``LogCellEntity`` records for this device are also deleted from SwiftData,
    /// freeing disk space. If `false`, the log data is retained (useful if the user
    /// wants to re-pair the same device later without re-downloading history).
    ///
    /// - Parameters:
    ///   - profile: The ``DeviceProfile`` to remove.
    ///   - deleteCachedData: If `true`, also deletes all persisted log cells for this device.
    ///
    /// - Side Effects: Deletes from SwiftData, saves, and reloads ``knownDevices``.
    ///   On failure, sets ``error``.
    @MainActor
    func removeDevice(_ profile: DeviceProfile, deleteCachedData: Bool) {
        guard let ctx = modelContext else { return }
        do {
            if deleteCachedData {
                // Delete all LogCellEntity records scoped to this device.
                try LogCellStore.clearAllCells(deviceId: profile.deviceId, context: ctx)
            }
            // Delete the profile itself.
            ctx.delete(profile)
            try ctx.save()
            loadKnownDevices()
        } catch {
            self.error = "Failed to remove device. Try again."
        }
    }

    /// Update the user-editable room/location label for a device profile.
    ///
    /// The room label is a free-text field that lets users annotate where each
    /// device is physically located (e.g., "Bedroom", "Office", "Kitchen").
    /// This is purely a UI convenience -- the label is not sent to the device.
    ///
    /// - Parameters:
    ///   - label: The new room label string, or `nil` to clear it.
    ///   - profile: The ``DeviceProfile`` to update.
    ///
    /// - Side Effects: Saves the context and reloads ``knownDevices``.
    @MainActor
    func setRoomLabel(_ label: String?, for profile: DeviceProfile) {
        guard let ctx = modelContext else { return }
        profile.roomLabel = label
        do {
            try ctx.save()
            loadKnownDevices()
        } catch {
            self.error = "Failed to update room label. Try again."
        }
    }

    /// Attempt to auto-reconnect to the most recently connected known device.
    ///
    /// Called once at app launch after Bluetooth becomes ready (via
    /// ``BLEManager/whenBluetoothReady(_:)``). The algorithm:
    ///   1. Skip if already connected/scanning/connecting.
    ///   2. Ensure ``knownDevices`` is loaded from SwiftData.
    ///   3. Find the profile with the most recent ``DeviceProfile/lastConnectedAt``.
    ///   4. Call ``connectToKnownDevice(_:)`` to initiate a BLE reconnection.
    ///
    /// This provides a seamless "resume" experience: the user opens the app and
    /// it automatically reconnects to the device they were using last time.
    ///
    /// - Note: If the device is not nearby, ``BLEManager/reconnectToKnownDevice(identifier:)``
    ///   will fall back to a full BLE scan.
    @MainActor
    func autoConnectToLastDevice() {
        guard connectionState == .disconnected else {
            logger.info("autoConnectToLastDevice: skipping — already \(self.connectionState.rawValue)")
            return
        }
        // Ensure devices loaded (may not be if called before ContentView.onAppear)
        if knownDevices.isEmpty && modelContext != nil {
            loadKnownDevices()
        }
        // Find the device with the most recent connection timestamp.
        guard let mostRecent = knownDevices.max(by: { $0.lastConnectedAt < $1.lastConnectedAt }) else {
            logger.info("autoConnectToLastDevice: no known devices")
            return
        }
        logger.info("autoConnectToLastDevice: reconnecting to \(mostRecent.deviceName) (\(mostRecent.deviceId))")
        connectToKnownDevice(mostRecent)
    }

    /// Attempt to reconnect to a previously known device using its stored BLE UUID.
    ///
    /// Converts the profile's `deviceId` string back into a `UUID` and delegates
    /// to ``BLEManager/reconnectToKnownDevice(identifier:)``, which uses
    /// CoreBluetooth's `retrievePeripherals(withIdentifiers:)` to find the device
    /// without a full scan (much faster when the device is nearby).
    ///
    /// - Parameter profile: The ``DeviceProfile`` of the device to reconnect to.
    func connectToKnownDevice(_ profile: DeviceProfile) {
        guard let manager = bleManager,
              let uuid = UUID(uuidString: profile.deviceId) else { return }
        manager.reconnectToKnownDevice(identifier: uuid)
    }

    // MARK: - Actions
    //
    // Public methods that Views call to trigger BLE operations.
    // All mutating methods are `@MainActor` to ensure property writes happen on
    // the main thread. Async methods (`async`) suspend the caller while waiting
    // for BLE responses, but do NOT block the main thread -- other UI updates
    // and animations continue while the BLE operation is in flight.
    //
    // Error handling pattern:
    //   - Each method wraps its BLE calls in a do/catch block.
    //   - On success: update the relevant property.
    //   - On failure: set `self.error` to a user-friendly message via
    //     `friendlyMessage(for:context:)`.
    //   - The caller (View) does not need to handle errors -- it simply
    //     observes the `error` property and displays a banner when non-nil.

    /// Start scanning for nearby uCritAir BLE devices.
    ///
    /// Clears any previous error message and delegates to ``BLEManager/scan()``,
    /// which starts a CoreBluetooth scan filtered to the uCritAir custom service UUID.
    /// Discovered devices will appear in ``BLEManager/discoveredPeripherals``.
    func scan() {
        error = nil
        bleManager?.scan()
    }

    /// Disconnect from the currently connected device.
    ///
    /// Delegates to ``BLEManager/disconnect()`` (which cancels the CoreBluetooth
    /// connection) and immediately clears all cached device info properties.
    /// The BLE callback will also fire and set ``connectionState`` to `.disconnected`.
    func disconnect() {
        bleManager?.disconnect()
        clearDeviceInfo()
    }

    /// Read all device information characteristics from the connected device.
    ///
    /// This is the main "refresh" operation that populates the ViewModel's state
    /// after a successful connection. It reads **9 characteristics sequentially**:
    ///
    /// 1. Device name (string)
    /// 2. Pet name (string)
    /// 3. Device time (UInt32 epoch)
    /// 4. Pet stats (vigour, focus, spirit, age, interventions)
    /// 5. Device config (wake period, brightness, persist flags)
    /// 6. Items owned (bitmap)
    /// 7. Items placed (bitmap)
    /// 8. Bonus points (UInt32)
    /// 9. Cell count (UInt32)
    ///
    /// **Why sequential, not parallel?** BLE (Bluetooth Low Energy) has limited
    /// bandwidth and the nRF5340 firmware processes requests one at a time.
    /// Issuing multiple concurrent reads can overwhelm the BLE stack, cause
    /// timeouts, or trigger data races in ``BLEManager``'s internal continuation
    /// dictionaries. Sequential reads are slower but reliable.
    ///
    /// Each `try await` suspends until the BLE read completes (typically 20-100ms).
    /// If any read fails, the entire sequence aborts and the error is displayed.
    ///
    /// - Side Effects: Populates ``deviceName``, ``petName``, ``deviceTime``,
    ///   ``petStats``, ``config``, ``itemsOwned``, ``itemsPlaced``, ``bonus``,
    ///   and ``cellCount``. On failure, sets ``error``.
    @MainActor
    func refreshDeviceInfo() async {
        guard let manager = bleManager else { return }

        do {
            // Each `try await` suspends the current task until the BLE characteristic
            // read completes. The main thread is NOT blocked during the suspension --
            // other UI work continues normally.
            deviceName = try await BLECharacteristics.readDeviceName(using: manager)
            petName = try await BLECharacteristics.readPetName(using: manager)
            deviceTime = try await BLECharacteristics.readTime(using: manager)
            petStats = try await BLECharacteristics.readStats(using: manager)
            config = try await BLECharacteristics.readDeviceConfig(using: manager)
            itemsOwned = try await BLECharacteristics.readItemsOwned(using: manager)
            itemsPlaced = try await BLECharacteristics.readItemsPlaced(using: manager)
            bonus = try await BLECharacteristics.readBonus(using: manager)
            cellCount = try await BLECharacteristics.readCellCount(using: manager)
        } catch {
            // Convert the raw error into a user-friendly message and store it.
            self.error = Self.friendlyMessage(for: error, context: "Failed to read device info")
            logger.error("Failed to read device info: \(error)")
        }
    }

    /// Sync the device's RTC clock to the iPhone's current local time.
    ///
    /// The device uses a "local time as epoch" convention (see ``deviceTime``).
    /// ``UnitFormatters/getLocalTimeAsEpoch()`` generates the correct epoch value
    /// by treating the local wall-clock time as if it were UTC.
    ///
    /// After a successful write, the local ``deviceTime`` property is updated to
    /// match, so the UI immediately reflects the new time without a re-read.
    ///
    /// - Side Effects: Writes to the device's time characteristic. Updates ``deviceTime``.
    ///   On failure, sets ``error``.
    @MainActor
    func syncTime() async {
        guard let manager = bleManager else { return }
        let epoch = UnitFormatters.getLocalTimeAsEpoch()
        do {
            try await BLECharacteristics.writeTime(epoch, using: manager)
            // Optimistic update: set local state without re-reading from device.
            deviceTime = epoch
        } catch {
            self.error = Self.friendlyMessage(for: error, context: "Failed to sync time")
        }
    }

    /// Write a new device name to the connected device and update the persisted profile.
    ///
    /// The device name is stored in a BLE characteristic on the device and is also
    /// persisted in the local ``DeviceProfile`` via ``upsertDeviceProfile()``.
    ///
    /// - Parameter name: The new device name string (e.g., "uCritAir-Kitchen").
    ///
    /// - Side Effects: Writes to BLE, updates ``deviceName``, persists to SwiftData.
    ///   On failure, sets ``error``.
    @MainActor
    func writeDeviceName(_ name: String) async {
        guard let manager = bleManager else { return }
        do {
            try await BLECharacteristics.writeDeviceName(name, using: manager)
            deviceName = name
            // Persist the new name in the device registry so it survives app restarts.
            upsertDeviceProfile()
        } catch {
            self.error = Self.friendlyMessage(for: error, context: "Failed to save device name")
            logger.error("writeDeviceName failed: \(error)")
        }
    }

    /// Write a new pet name to the connected device and update the persisted profile.
    ///
    /// Similar to ``writeDeviceName(_:)`` but for the virtual pet's name.
    ///
    /// - Parameter name: The new pet name string (e.g., "Pixel").
    ///
    /// - Side Effects: Writes to BLE, updates ``petName``, persists to SwiftData.
    ///   On failure, sets ``error``.
    @MainActor
    func writePetName(_ name: String) async {
        guard let manager = bleManager else { return }
        do {
            try await BLECharacteristics.writePetName(name, using: manager)
            petName = name
            upsertDeviceProfile()
        } catch {
            self.error = Self.friendlyMessage(for: error, context: "Failed to save pet name")
            logger.error("writePetName failed: \(error)")
        }
    }

    /// Write updated device configuration and read it back to confirm.
    ///
    /// Uses a **write-then-read** pattern: after writing the new config, it reads
    /// the characteristic back from the device to ensure the firmware accepted the
    /// values. The device may clamp or adjust certain fields (e.g., minimum wake
    /// period), so the read-back value is the "truth" that gets stored in ``config``.
    ///
    /// - Parameter newConfig: The ``DeviceConfig`` struct with updated values.
    ///
    /// - Side Effects: Writes to BLE, re-reads and updates ``config``.
    ///   On failure, sets ``error``.
    @MainActor
    func writeConfig(_ newConfig: DeviceConfig) async {
        guard let manager = bleManager else { return }
        do {
            try await BLECharacteristics.writeDeviceConfig(newConfig, using: manager)
            // Read back to get the firmware's actual accepted values.
            config = try await BLECharacteristics.readDeviceConfig(using: manager)
        } catch {
            self.error = Self.friendlyMessage(for: error, context: "Failed to save config")
            logger.error("writeConfig failed: \(error)")
        }
    }

    /// Write an arbitrary Unix timestamp to the device's RTC clock.
    ///
    /// Unlike ``syncTime()`` which always writes the current local time, this
    /// method accepts any timestamp value. Primarily used by the Developer Tools
    /// view for testing and debugging time-related functionality.
    ///
    /// - Parameter unixSeconds: The Unix epoch timestamp to set on the device.
    ///
    /// - Side Effects: Writes to BLE, updates ``deviceTime``. On failure, sets ``error``.
    @MainActor
    func writeTime(_ unixSeconds: UInt32) async {
        guard let manager = bleManager else { return }
        do {
            try await BLECharacteristics.writeTime(unixSeconds, using: manager)
            deviceTime = unixSeconds
        } catch {
            self.error = Self.friendlyMessage(for: error, context: "Failed to set time")
            logger.error("writeTime failed: \(error)")
        }
    }

    /// Read a single log cell from the device by its index number.
    ///
    /// This is a **two-step BLE operation**:
    ///   1. Write the cell index to the "cell selector" characteristic. This tells
    ///      the firmware which log cell to load into the "cell data" characteristic.
    ///   2. Read the "cell data" characteristic, which now contains the 57-byte
    ///      payload for the requested cell.
    ///
    /// This method is used by ``HistoryViewModel`` for streaming bulk downloads and
    /// by the Developer Tools view for single-cell inspection.
    ///
    /// - Parameter index: The zero-based log cell index to read.
    /// - Returns: A ``ParsedLogCell`` with all decoded sensor values and metadata.
    /// - Throws: ``BLEError/notConnected`` if no device is connected, or any
    ///   CoreBluetooth error from the read/write operations.
    @MainActor
    func readLogCell(at index: UInt32) async throws -> ParsedLogCell {
        guard let manager = bleManager else { throw BLEError.notConnected }
        try await BLECharacteristics.writeCellSelector(index, using: manager)
        return try await BLECharacteristics.readCellData(using: manager)
    }

    /// Reset all device info properties to `nil`.
    ///
    /// Called when the device disconnects to return the ViewModel to a clean
    /// "no device" state. This ensures the UI does not display stale data from
    /// a previous connection.
    private func clearDeviceInfo() {
        deviceName = nil
        petName = nil
        deviceTime = nil
        petStats = nil
        config = nil
        itemsOwned = nil
        itemsPlaced = nil
        bonus = nil
        cellCount = nil
    }

    // MARK: - Error Mapping

    /// Translate a raw BLE error into a concise, user-friendly message.
    ///
    /// CoreBluetooth errors arrive as `NSError` objects with numeric codes and
    /// technical domain strings (e.g., "CBErrorDomain", code 6). These are
    /// meaningless to end users. This method maps common error codes to
    /// actionable guidance like "Connection lost. Make sure the device is nearby."
    ///
    /// The mapping covers two error domains:
    ///   - **CBErrorDomain**: Connection-level errors (timeout, disconnect during I/O).
    ///   - **CBATTErrorDomain**: GATT protocol errors (the device rejected a request).
    ///
    /// For errors from our own ``BLEError`` enum (e.g., `.notConnected`, `.noData`),
    /// the `localizedDescription` is already user-friendly.
    ///
    /// - Parameters:
    ///   - error: The raw `Error` from CoreBluetooth or ``BLEError``.
    ///   - context: A prefix string describing what operation failed (e.g.,
    ///     "Failed to read device info"). Prepended to the friendly message.
    ///
    /// - Returns: A formatted string like "Failed to read device info: Connection lost.
    ///   Make sure the device is nearby and try again."
    private static func friendlyMessage(for error: Error, context: String) -> String {
        let nsError = error as NSError
        // Check if this is a CoreBluetooth error domain.
        if nsError.domain == "CBErrorDomain" || nsError.domain == "CBATTErrorDomain" {
            switch nsError.code {
            case 6, 7: // disconnectedDuringRead/Write, connectionTimeout
                return "\(context): Connection lost. Make sure the device is nearby and try again."
            case 14: // CBATTError.unlikelyError — the firmware rejected the GATT request
                return "\(context): The device rejected the request. Try reconnecting."
            default:
                return "\(context): Bluetooth error. Try reconnecting to the device."
            }
        }
        // BLEError from our own code — already has a good localizedDescription.
        if error is BLEError {
            return "\(context): \(error.localizedDescription)"
        }
        // Fallback for unexpected errors.
        return "\(context): \(error.localizedDescription)"
    }
}
