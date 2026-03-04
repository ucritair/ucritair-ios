import Foundation

/// A timestamped sensor reading for the history ring buffer.
///
/// Used to maintain a rolling window of recent sensor data for charting
/// and trend display. Each reading captures a snapshot of all sensor values
/// at a specific point in time.
///
/// Ported from `src/types/index.ts` -- `SensorReading`.
struct SensorReading: Identifiable, Sendable {
    /// Unique identifier for SwiftUI list diffing.
    let id = UUID()

    /// The wall-clock time when this reading was captured.
    let timestamp: Date

    /// The full set of sensor values at the time of this reading.
    let values: SensorValues
}
