// MARK: - SensorReading.swift
// Part of the uCritAir iOS app — an air quality monitor companion.
//
// This file defines `SensorReading`, a timestamped snapshot of sensor data
// used to build a **history ring buffer** for charting and trend analysis.
//
// **Data flow:**
//
//   BLE notification
//     --> PartialSensorUpdate
//       --> SensorValues.merge(_:)           (live state)
//         --> SensorReading(timestamp, values) (history entry)
//           --> DeviceViewModel.sensorHistory  (ring buffer array)
//             --> Chart views read from the array
//
// The ring buffer is kept in memory (not persisted to SwiftData). It stores
// the most recent N readings so the UI can render real-time sparkline charts
// without querying the full log database.

import Foundation

/// A single timestamped snapshot of all sensor values, used for in-memory
/// charting and trend display.
///
/// ## Overview
///
/// Each time the app receives a BLE sensor update, it captures the current
/// ``SensorValues`` together with the wall-clock time into a `SensorReading`.
/// These readings accumulate in a **ring buffer** (a fixed-capacity array
/// where the oldest entry is dropped when the buffer is full) managed by
/// ``DeviceViewModel``.
///
/// The chart views iterate over the array of `SensorReading` objects and
/// plot each sensor's value against its `timestamp` on the x-axis.
///
/// ## Conformances
///
/// - `Identifiable` — each reading has a unique `id` so SwiftUI `ForEach`
///   and `Chart` can efficiently diff and animate list/chart changes.
/// - `Sendable` — safe to pass between concurrency contexts. Both `Date`
///   and ``SensorValues`` are value types that conform to `Sendable`.
///
/// ## Lifecycle
///
/// 1. **Created** in `DeviceViewModel` when new BLE data arrives.
/// 2. **Stored** in `DeviceViewModel.sensorHistory` (an in-memory array).
/// 3. **Consumed** by chart/trend SwiftUI views.
/// 4. **Discarded** when the ring buffer capacity is exceeded (oldest first)
///    or when the device disconnects.
///
/// > Note: `SensorReading` is a *transient, in-memory* structure. For
/// > *persistent* historical data, see ``LogCellEntity``, which stores
/// > full log cells in SwiftData.
///
/// Ported from `src/types/index.ts` -- `SensorReading`.
struct SensorReading: Identifiable, Sendable {

    /// A universally unique identifier generated at creation time.
    ///
    /// SwiftUI uses this to track each reading in lists and charts. Because
    /// `UUID()` generates a new random value each time, every `SensorReading`
    /// is guaranteed to have a distinct identity — even if two readings share
    /// the same timestamp and values.
    let id = UUID()

    /// The wall-clock time when this reading was captured by the iOS app.
    ///
    /// This is the iPhone's local `Date` at the moment the BLE notification
    /// was processed — **not** the device's internal RTC timestamp. For
    /// device-side timestamps, see ``ParsedLogCell/timestamp``.
    let timestamp: Date

    /// The full set of sensor values at the time of this reading.
    ///
    /// This is a copy of the ``SensorValues`` snapshot taken at `timestamp`.
    /// Because `SensorValues` is a value type (struct), this copy is
    /// independent of any future mutations to the live sensor state.
    let values: SensorValues
}
