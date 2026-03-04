import Foundation

/// View model for live sensor readings and history.
/// Ported from src/stores/sensors.ts → useSensorStore
@Observable
final class SensorViewModel {

    /// Maximum history entries (~30 minutes at 5s intervals).
    private let maxHistory = 360

    /// Minimum time between history entries (seconds).
    private let historyThrottleSeconds: TimeInterval = 4.0

    // MARK: - State

    /// The most recent merged sensor values from all BLE characteristic updates.
    var current: SensorValues = .empty

    /// Rolling history of sensor snapshots, throttled to one entry per 4 seconds (up to ~30 minutes).
    var history: [SensorReading] = []

    private var bleManager: BLEManager?

    // MARK: - Configuration

    /// Wire up BLE sensor update callbacks. Call once at app startup.
    func configure(bleManager: BLEManager) {
        self.bleManager = bleManager

        bleManager.onSensorUpdate = { [weak self] partial in
            self?.handleSensorUpdate(partial)
        }

        // Also listen for connection state to reset on disconnect
        let existingCallback = bleManager.onConnectionStateChanged
        bleManager.onConnectionStateChanged = { [weak self] state in
            existingCallback?(state)
            if state == .disconnected {
                self?.reset()
            }
        }
    }

    // MARK: - Private

    /// Handle a partial sensor update from BLE.
    /// Matches sensors.ts: merge current, throttle history to >= 4s.
    private func handleSensorUpdate(_ partial: PartialSensorUpdate) {
        current.merge(partial)

        guard current.hasAnyValue else { return }

        let now = Date()

        // Throttle: only add to history if >= 4s since last entry
        if let lastTimestamp = history.last?.timestamp,
           now.timeIntervalSince(lastTimestamp) < historyThrottleSeconds {
            return
        }

        let reading = SensorReading(timestamp: now, values: current)
        history.append(reading)

        // Trim to max size
        if history.count > maxHistory {
            history.removeFirst(history.count - maxHistory)
        }
    }

    /// Reset sensor data (on disconnect).
    private func reset() {
        current = .empty
        history = []
    }
}
