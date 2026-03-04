import Foundation
import os.log

// MARK: - File Overview
// ======================================================================================
// BLELogStream.swift — Bulk Log Cell Download via BLE Notifications
// ======================================================================================
//
// This file implements the protocol for downloading historical sensor data from the
// uCrit device's flash memory. Instead of reading cells one-by-one (which would be
// extremely slow over BLE), this uses a **notification streaming** approach where the
// device pushes cells to the phone as fast as BLE allows.
//
// ## Background: BLE Read vs. Notify
//
// In BLE, there are two ways to get data from a device:
//
// 1. **Read**: The app explicitly requests a value. The device responds with one payload.
//    This is a request-response pattern — slow for bulk transfers because each read
//    requires a full round-trip (request -> response -> request -> response...).
//
// 2. **Notify**: The app subscribes to a characteristic, and the device sends data
//    whenever it has something new — without the app asking. This is a push pattern,
//    much faster for bulk transfers because the device can send many payloads back-to-back
//    without waiting for the app to request each one.
//
// ## Streaming Protocol
//
// The log stream uses characteristic `0x0006` (``BLEConstants/charLogStream``):
//
//   1. App enables notifications on the characteristic
//   2. App writes an 8-byte request:
//      ```
//      Bytes 0-3: startCell (UInt32 LE) — first cell index to send
//      Bytes 4-7: count    (UInt32 LE) — number of cells to send
//      ```
//   3. Device sends each cell as a 57-byte notification (same format as cell data reads)
//   4. Device sends a 4-byte end marker (`0xFFFFFFFF`) when done
//   5. App disables notifications and resumes normal polling
//
// ## Idle Timeout Safety Net
//
// If the device stops sending notifications without an end marker (e.g., due to
// connection instability), the app waits ``idleTimeout`` seconds (10s) after the last
// received notification before resolving with whatever cells were received. This
// prevents the app from hanging indefinitely.
//
// ## Architecture
//
//   DeviceViewModel -> BLELogStream.streamLogCells() -> BLEManager (notifications)
//                   <- [ParsedLogCell] array          <- BLEParsers.parseLogCell()
//
// Ported from the web app's `src/ble/log-stream.ts` -> `streamLogCells()`.
// ======================================================================================

/// Progress information for an in-flight log stream download.
///
/// Passed to the `onProgress` callback during ``BLELogStream/streamLogCells(startCell:count:using:onProgress:)``
/// so the UI can display a progress bar or percentage.
struct LogStreamProgress: Sendable {
    /// Number of log cells received so far in this stream.
    let received: Int

    /// Total number of log cells requested. Note: the actual number received may be less
    /// if the device has fewer cells than requested, or if the stream is interrupted.
    let total: Int
}

/// Bulk log cell download engine using BLE notification streaming.
///
/// This caseless enum provides a single static method, ``streamLogCells(startCell:count:using:onProgress:)``,
/// that orchestrates the entire download: pausing normal polling, enabling notifications,
/// writing the stream request, collecting cells as they arrive, detecting the end marker,
/// and cleaning up.
///
/// ## Thread Safety
/// The notification handler runs on the main queue (via CoreBluetooth's delegate
/// callbacks in ``BLEManager``). All state mutations (`cells` array, `resumed` flag,
/// timeout task) happen on the main queue to avoid data races.
///
/// ## Error Handling
/// - If the write request fails, the stream resolves with the error immediately.
/// - If notifications stop arriving, the idle timeout resolves with partial results.
/// - The `defer` block always cleans up (disables notifications, resumes polling).
///
/// Ported from `src/ble/log-stream.ts` -> `streamLogCells()`.
enum BLELogStream {

    /// Logger for stream events (start, end marker, timeouts, errors).
    private static let logger = Logger(subsystem: "com.ucritter.ucritair", category: "LogStream")

    /// Maximum seconds to wait between received notifications before assuming the
    /// stream has stalled and resolving with whatever cells were collected.
    ///
    /// This safety net prevents the app from hanging indefinitely if the device
    /// loses connectivity or encounters a firmware error mid-stream. The 10-second
    /// value allows for temporary BLE congestion while still failing reasonably quickly.
    private static let idleTimeout: TimeInterval = 10.0

    /// Download a range of historical log cells from the device via notification streaming.
    ///
    /// This is the primary entry point for bulk log downloads. It handles the full
    /// lifecycle: pause polling -> enable notifications -> write request -> collect cells
    /// -> detect end marker -> disable notifications -> resume polling.
    ///
    /// ## Concurrency Note
    /// This method pauses the ``BLEManager``'s current-cell polling during the stream
    /// to prevent BLE operations from interleaving. BLE is a serial protocol — only one
    /// read/write can be in flight at a time. If polling and streaming happened
    /// simultaneously, they would interfere with each other and cause errors.
    ///
    /// ## Continuation Bridging Pattern
    /// This method uses `withCheckedThrowingContinuation` to bridge between the
    /// callback-based BLE notification API and Swift's async/await. The continuation
    /// is resumed exactly once — either when the end marker arrives, the idle timeout
    /// fires, or the write request fails. The `resumed` flag prevents double-resumption,
    /// which would be a runtime crash in Swift concurrency.
    ///
    /// - Parameters:
    ///   - startCell: The zero-based index of the first cell to download. Typically
    ///     the number of cells already synced (i.e., "give me everything new").
    ///   - count: The number of cells to request. Typically `totalCells - startCell`.
    ///   - manager: A connected ``BLEManager`` instance.
    ///   - onProgress: Called on the main queue after each cell is received, with
    ///     a ``LogStreamProgress`` indicating how many cells have arrived out of the total requested.
    /// - Returns: An array of ``ParsedLogCell`` values, in the order received from the device.
    ///   May contain fewer cells than `count` if the stream was interrupted or the device
    ///   has fewer cells than requested.
    /// - Throws: ``BLEError`` if the device is not connected or the stream request write fails.
    static func streamLogCells(
        startCell: Int,
        count: Int,
        using manager: BLEManager,
        onProgress: @escaping (LogStreamProgress) -> Void
    ) async throws -> [ParsedLogCell] {

        // Pause the BLEManager's 5-second current-cell polling timer.
        // BLE is a serial protocol — concurrent reads/writes would conflict.
        manager.pausePolling()

        // The `defer` block runs when this method returns (success or error),
        // guaranteeing cleanup even if an exception is thrown.
        defer {
            // Remove the notification callback so stray notifications after cleanup
            // do not attempt to resume an already-completed continuation.
            manager.onLogStreamNotification = nil

            // Tell the device to stop sending log stream notifications.
            manager.setLogStreamNotifications(enabled: false)

            // Restart the current-cell polling that we paused above.
            manager.resumePolling()
        }

        // Bridge from callback-based notifications to async/await using a continuation.
        // The continuation will be resumed exactly once when the stream completes.
        return try await withCheckedThrowingContinuation { continuation in
            // Mutable state captured by the notification closure.
            // All mutations happen on the main queue (CoreBluetooth delivers notifications there).
            var cells: [ParsedLogCell] = []
            var resumed = false                 // Guard against resuming the continuation twice
            var timeoutTask: Task<Void, Never>? // Currently scheduled idle timeout

            // Helper: resolve the continuation exactly once with the given result.
            // The `resumed` flag prevents a fatal "continuation resumed more than once" crash
            // that would occur if, for example, the end marker and idle timeout fire simultaneously.
            let finish: (Result<[ParsedLogCell], Error>) -> Void = { result in
                guard !resumed else { return }
                resumed = true
                timeoutTask?.cancel()
                continuation.resume(with: result)
            }

            // Helper: reset the idle timeout.
            // Called after each received notification. If no notification arrives within
            // `idleTimeout` seconds, the stream resolves with whatever cells were collected.
            let resetTimeout: () -> Void = {
                timeoutTask?.cancel()
                timeoutTask = Task {
                    try? await Task.sleep(for: .seconds(idleTimeout))
                    guard !Task.isCancelled else { return }
                    // Timed out waiting for the next notification.
                    // Resolve with partial results rather than hanging forever.
                    logger.info("Log stream idle timeout — resolving with \(cells.count) cells")
                    DispatchQueue.main.async {
                        finish(.success(cells))
                    }
                }
            }

            // Install a notification handler on the BLEManager.
            // CoreBluetooth calls `peripheral(_:didUpdateValueFor:error:)` on the main queue,
            // which checks for the charLogStream UUID and forwards the raw Data here.
            manager.onLogStreamNotification = { data in

                // Check for the 4-byte end marker (0xFFFFFFFF) that signals stream completion.
                // The firmware sends this as the final notification after all requested cells.
                if data.count == 4 {
                    let marker = data.readUInt32LE(at: 0)
                    if marker == BLEConstants.logStreamEndMarker {
                        logger.info("Log stream end marker received — \(cells.count) cells")
                        finish(.success(cells))
                        return
                    }
                }

                // Validate that the notification is a full 57-byte log cell.
                // Short notifications could occur due to BLE fragmentation issues or firmware bugs.
                guard data.count >= BLEConstants.logCellNotificationSize else {
                    logger.warning("Short log stream notification: \(data.count) bytes")
                    resetTimeout()  // Still reset timeout — the device is alive, just sent bad data
                    return
                }

                // Parse the 57-byte payload into a typed ParsedLogCell struct.
                let cell = BLEParsers.parseLogCell(data)
                cells.append(cell)

                // Notify the UI of progress (e.g., "Received 42 of 100 cells").
                onProgress(LogStreamProgress(received: cells.count, total: count))

                // Reset the idle timeout since we just received a valid notification.
                resetTimeout()
            }

            // Step 1: Enable BLE notifications on the log stream characteristic.
            // This tells the device "I want to receive push updates on this characteristic."
            manager.setLogStreamNotifications(enabled: true)

            // Step 2: Write the stream request after a short delay.
            // The 100ms delay ensures CoreBluetooth has finished the notification subscription
            // round-trip before we write the request. Without this delay, the device might
            // start sending cells before the subscription is confirmed, causing missed cells.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {

                // Build the 8-byte stream request payload:
                //   Bytes 0-3: startCell (UInt32 LE) — first cell index to send
                //   Bytes 4-7: count    (UInt32 LE) — number of cells to send
                var payload = Data(count: 8)
                payload.writeUInt32LE(UInt32(startCell), at: 0)
                payload.writeUInt32LE(UInt32(count), at: 4)

                Task {
                    do {
                        // Write the request to the device. The device will start sending
                        // notifications as soon as it processes this write.
                        try await manager.writeCharacteristic(
                            BLEConstants.charLogStream, data: payload
                        )
                        // Start the idle timeout now that the request has been sent.
                        resetTimeout()
                    } catch {
                        // If the write fails (e.g., disconnected), resolve with the error.
                        logger.error("Failed to write stream request: \(error)")
                        finish(.failure(error))
                    }
                }
            }
        }
    }
}
