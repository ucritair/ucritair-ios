// MARK: - SensorViewModel.swift
// uCritAir iOS App
//
// ============================================================================
// FILE OVERVIEW
// ============================================================================
//
// This file defines `SensorViewModel`, the ViewModel responsible for managing
// **live sensor data** from the connected uCritAir device. It maintains:
//
//   1. The **current sensor values** — a single `SensorValues` struct containing
//      the most recent reading for each sensor (temperature, humidity, CO2, PM2.5,
//      pressure, VOC, NOx, etc.).
//
//   2. A **rolling history buffer** — an array of timestamped `SensorReading`
//      snapshots used for the live mini-chart on the device view. History is
//      throttled to one entry per 4 seconds and capped at 360 entries (~30 min).
//
// How Live Data Flows (the full pipeline):
//
//   [Device Hardware]
//       |
//       | BLE notifications (ESS service, every ~1-5 seconds)
//       v
//   [BLEManager] ──onSensorUpdate──> [SensorViewModel]
//       |                                  |
//       | (also: current cell polling      |-- merge into `current`
//       |  every 5s for VOC/NOx/PM4.0)    |-- throttle into `history`
//       v                                  v
//   [CoreBluetooth]                   [SwiftUI Views]
//
// The device sends sensor updates via two mechanisms:
//   a) **ESS notifications**: The BLE Environmental Sensing Service (UUID 0x181A)
//      sends automatic notifications for temperature, humidity, CO2, PM, and
//      pressure. Each notification contains a single sensor's value.
//   b) **Current cell polling**: BLEManager polls the "current cell" custom
//      characteristic every 5 seconds to get VOC, NOx, and PM4.0 values that
//      are NOT available via ESS.
//
// Both mechanisms produce `PartialSensorUpdate` values — structs where only the
// changed fields are non-nil. The "merge" pattern in this ViewModel combines
// these partial updates into a complete picture.
//
// Architecture Role:
//   This is a lightweight, focused ViewModel. Unlike DeviceViewModel (which manages
//   connection state and persistence) or HistoryViewModel (which handles stored
//   data and charts), SensorViewModel only deals with real-time data. It has no
//   persistence layer — when the device disconnects, all data is cleared.
//
// Threading Model:
//   - All properties are on `@MainActor` (required for SwiftUI observation).
//   - BLE callbacks arrive on the main queue, so `MainActor.assumeIsolated` is safe.
//   - The history throttle uses wall-clock time (`Date()`) for simplicity.
//
// Ported from the web prototype's `src/stores/sensors.ts` (useSensorStore).
// ============================================================================

import Foundation

/// ViewModel for live (real-time) sensor data from the connected uCritAir device.
///
/// ## Responsibilities
///
/// - **Merge partial updates**: BLE notifications arrive one sensor at a time.
///   This ViewModel merges each ``PartialSensorUpdate`` into a single ``SensorValues``
///   struct (``current``) so views always see the complete picture.
///
/// - **Maintain throttled history**: Appends a snapshot of ``current`` to the
///   ``history`` array at most once every 4 seconds, capped at 360 entries.
///   This provides ~30 minutes of data for the live mini-chart without consuming
///   excessive memory.
///
/// - **Reset on disconnect**: When the BLE connection drops, all live data is
///   cleared so the UI does not display stale readings from a previous session.
///
/// ## Dependencies
///
/// - ``BLEManager``: Provides the ``BLEManager/onSensorUpdate`` callback for
///   receiving partial sensor data, and ``BLEManager/onConnectionStateChanged``
///   for detecting disconnects.
///
/// ## Threading
///
/// This class runs entirely on `@MainActor`. BLE callbacks arrive on the main
/// queue (because ``BLEManager`` uses `queue: .main` for its `CBCentralManager`),
/// and all property mutations must happen on the main thread for SwiftUI safety.
///
/// ## The @Observable Macro
///
/// Like all ViewModels in this app, `SensorViewModel` uses Swift 5.9's `@Observable`
/// macro. This means every stored property (``current``, ``history``) is automatically
/// tracked by SwiftUI. When a View reads `sensorVM.current.co2` during its `body`
/// evaluation, SwiftUI records that dependency. When `current` changes (via a BLE
/// callback), only the Views that actually read that property will re-render.
/// This is more efficient than the older `ObservableObject` + `@Published` pattern,
/// which would re-render ALL observing views on ANY property change.
@Observable
final class SensorViewModel {

    /// Maximum number of entries in the ``history`` array.
    ///
    /// At one entry per ~5 seconds (due to the 4-second throttle and BLE timing),
    /// 360 entries covers approximately 30 minutes of live data. When the array
    /// exceeds this limit, the oldest entries are removed from the front (FIFO).
    private let maxHistory = 360

    /// Minimum time interval (in seconds) between consecutive ``history`` entries.
    ///
    /// BLE notifications can arrive multiple times per second (especially when
    /// multiple sensors report simultaneously). Without throttling, the history
    /// array would fill up too quickly and consume unnecessary memory. This
    /// threshold ensures at most one snapshot every 4 seconds.
    private let historyThrottleSeconds: TimeInterval = 4.0

    // MARK: - State

    /// The most recent merged sensor values from all BLE characteristic updates.
    ///
    /// This struct contains one optional `Double?` field per sensor (temperature,
    /// humidity, CO2, PM2.5, etc.). Fields start as `nil` and become non-nil as
    /// BLE notifications arrive. Once a field is set, subsequent updates overwrite
    /// it with the newest value.
    ///
    /// The merge pattern works like this:
    /// ```
    /// // BLE notification 1: temperature = 22.5
    /// current = { temperature: 22.5, humidity: nil, co2: nil, ... }
    ///
    /// // BLE notification 2: humidity = 45.2
    /// current = { temperature: 22.5, humidity: 45.2, co2: nil, ... }
    ///
    /// // BLE notification 3: co2 = 450
    /// current = { temperature: 22.5, humidity: 45.2, co2: 450, ... }
    /// ```
    ///
    /// - Read by: `DeviceView` (live sensor cards), `DeviceCardRow` (list summary)
    /// - Written by: ``handleSensorUpdate(_:)``
    var current: SensorValues = .empty

    /// Rolling history of timestamped sensor snapshots, used for the live mini-chart.
    ///
    /// Each ``SensorReading`` contains a timestamp and a full copy of ``SensorValues``
    /// at that moment. The array acts as a **ring buffer** (FIFO): new entries are
    /// appended to the end, and when ``maxHistory`` is exceeded, the oldest entries
    /// are removed from the front.
    ///
    /// Throttling: A new entry is only added if at least ``historyThrottleSeconds``
    /// (4 seconds) have elapsed since the last entry. This prevents the buffer from
    /// filling up too quickly when BLE notifications arrive in rapid bursts.
    ///
    /// - Read by: `DeviceView` (live trend chart)
    /// - Written by: ``handleSensorUpdate(_:)``
    var history: [SensorReading] = []

    /// Reference to the shared BLE manager. Used only for callback registration.
    /// Set once during ``configure(bleManager:)`` and never changed.
    private var bleManager: BLEManager?

    // MARK: - Configuration

    /// Wire up BLE sensor update callbacks. **Call exactly once at app startup.**
    ///
    /// This method installs two callbacks on the ``BLEManager``:
    ///
    /// 1. **`onSensorUpdate`**: Called every time a BLE sensor notification arrives
    ///    (from ESS notifications or current-cell polling). The callback receives a
    ///    ``PartialSensorUpdate`` containing only the fields that changed, and passes
    ///    it to ``handleSensorUpdate(_:)`` for merging and history management.
    ///
    /// 2. **`onConnectionStateChanged`** (chained): When the connection state becomes
    ///    `.disconnected`, calls ``reset()`` to clear all live data. This callback is
    ///    **chained** with the existing callback (which ``DeviceViewModel`` already
    ///    installed) using a closure composition pattern:
    ///    ```
    ///    let existingCallback = bleManager.onConnectionStateChanged
    ///    bleManager.onConnectionStateChanged = { state in
    ///        existingCallback?(state)  // Call DeviceViewModel's handler first
    ///        // Then handle our own logic
    ///    }
    ///    ```
    ///    This pattern allows multiple ViewModels to observe the same event without
    ///    overwriting each other's callbacks. It is a simple alternative to the
    ///    delegate or Combine publisher patterns.
    ///
    /// - Parameter bleManager: The shared ``BLEManager`` instance.
    ///
    /// - Important: The closures capture `self` weakly (`[weak self]`) to avoid
    ///   retain cycles. `MainActor.assumeIsolated` is used because BLE callbacks
    ///   are guaranteed to arrive on the main queue.
    @MainActor
    func configure(bleManager: BLEManager) {
        self.bleManager = bleManager

        // Callback 1: Handle incoming sensor data from BLE notifications.
        bleManager.onSensorUpdate = { [weak self] partial in
            guard let self else { return }
            // BLE callbacks are dispatched on the main queue (CBCentralManager queue: .main).
            // MainActor.assumeIsolated asserts we are on the main thread and lets us
            // safely mutate @Observable properties without an async context.
            MainActor.assumeIsolated {
                self.handleSensorUpdate(partial)
            }
        }

        // Callback 2: Reset live data on disconnect.
        // Chain with the existing callback so DeviceViewModel's handler still fires.
        let existingCallback = bleManager.onConnectionStateChanged
        bleManager.onConnectionStateChanged = { [weak self] state in
            // Forward to DeviceViewModel's handler first.
            existingCallback?(state)
            guard let self else { return }
            if state == .disconnected {
                MainActor.assumeIsolated {
                    self.reset()
                }
            }
        }
    }

    // MARK: - Private

    /// Process an incoming partial sensor update from BLE.
    ///
    /// This method implements the **merge-and-throttle** pattern:
    ///
    /// **Step 1 — Merge**: The partial update is merged into ``current`` via
    /// ``SensorValues/merge(_:)``. Only non-nil fields in the partial update
    /// overwrite the corresponding fields in `current`. This means that a
    /// temperature-only notification does not erase the existing humidity value.
    ///
    /// **Step 2 — Throttle**: Check if at least ``historyThrottleSeconds`` have
    /// elapsed since the last history entry. If not, return early (the merge
    /// still happened, so ``current`` is up-to-date, but no history entry is added).
    ///
    /// **Step 3 — Append**: Create a ``SensorReading`` snapshot of ``current`` and
    /// append it to ``history``.
    ///
    /// **Step 4 — Trim**: If ``history`` exceeds ``maxHistory`` entries, remove the
    /// oldest entries from the front to maintain the fixed-size window.
    ///
    /// - Parameter partial: A ``PartialSensorUpdate`` containing only the sensor
    ///   fields that changed in this BLE notification.
    private func handleSensorUpdate(_ partial: PartialSensorUpdate) {
        // Step 1: Merge the partial update into the current values.
        current.merge(partial)

        // Don't start recording history until we have at least one real value.
        guard current.hasAnyValue else { return }

        let now = Date()

        // Step 2: Throttle — skip if less than 4 seconds since the last entry.
        if let lastTimestamp = history.last?.timestamp,
           now.timeIntervalSince(lastTimestamp) < historyThrottleSeconds {
            return
        }

        // Step 3: Append a timestamped snapshot to the history buffer.
        let reading = SensorReading(timestamp: now, values: current)
        history.append(reading)

        // Step 4: Trim to max size (FIFO eviction from the front).
        if history.count > maxHistory {
            history.removeFirst(history.count - maxHistory)
        }
    }

    /// Clear all live sensor data.
    ///
    /// Called when the BLE connection drops. Resets ``current`` to an empty state
    /// (all fields `nil`) and clears the ``history`` array. This ensures that
    /// when the user reconnects (possibly to a different device), they do not
    /// see stale data from the previous session.
    private func reset() {
        current = .empty
        history = []
    }
}
