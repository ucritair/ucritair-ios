import Foundation
import os.log

/// Log streaming progress.
struct LogStreamProgress: Sendable {
    let received: Int
    let total: Int
}

/// Log cell streaming via BLE notifications.
/// Ported from src/ble/log-stream.ts → streamLogCells()
enum BLELogStream {

    private static let logger = Logger(subsystem: "com.ucritter.ucritair", category: "LogStream")
    private static let idleTimeout: TimeInterval = 10.0

    /// Stream log cells from the device.
    /// - Parameters:
    ///   - startCell: First cell number to request.
    ///   - count: Number of cells to request.
    ///   - manager: The connected BLEManager.
    ///   - onProgress: Called on each received cell with progress info.
    /// - Returns: Array of all received ParsedLogCell values.
    /// - Throws: BLEError if not connected or write fails.
    static func streamLogCells(
        startCell: Int,
        count: Int,
        using manager: BLEManager,
        onProgress: @escaping (LogStreamProgress) -> Void
    ) async throws -> [ParsedLogCell] {

        // Pause current cell polling to avoid BLE interleaving
        manager.pausePolling()

        defer {
            manager.onLogStreamNotification = nil
            manager.setLogStreamNotifications(enabled: false)
            manager.resumePolling()
        }

        return try await withCheckedThrowingContinuation { continuation in
            var cells: [ParsedLogCell] = []
            var resumed = false
            var timeoutTask: Task<Void, Never>?

            let finish: (Result<[ParsedLogCell], Error>) -> Void = { result in
                guard !resumed else { return }
                resumed = true
                timeoutTask?.cancel()
                continuation.resume(with: result)
            }

            let resetTimeout: () -> Void = {
                timeoutTask?.cancel()
                timeoutTask = Task {
                    try? await Task.sleep(for: .seconds(idleTimeout))
                    guard !Task.isCancelled else { return }
                    logger.info("Log stream idle timeout — resolving with \(cells.count) cells")
                    DispatchQueue.main.async {
                        finish(.success(cells))
                    }
                }
            }

            // Set up notification handler (runs on main queue via CB delegate)
            manager.onLogStreamNotification = { data in
                // Check for end marker: 4 bytes of 0xFFFFFFFF
                if data.count == 4 {
                    let marker = data.readUInt32LE(at: 0)
                    if marker == BLEConstants.logStreamEndMarker {
                        logger.info("Log stream end marker received — \(cells.count) cells")
                        finish(.success(cells))
                        return
                    }
                }

                // Parse the cell (57 bytes: 4-byte cellNumber + 53-byte data)
                guard data.count >= BLEConstants.logCellNotificationSize else {
                    logger.warning("Short log stream notification: \(data.count) bytes")
                    resetTimeout()
                    return
                }

                let cell = BLEParsers.parseLogCell(data)
                cells.append(cell)
                onProgress(LogStreamProgress(received: cells.count, total: count))
                resetTimeout()
            }

            // Enable notifications then write the stream request
            manager.setLogStreamNotifications(enabled: true)

            // Small delay to ensure notifications are enabled before writing
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                // Build 8-byte payload: startCell(u32 LE) + count(u32 LE)
                var payload = Data(count: 8)
                payload.writeUInt32LE(UInt32(startCell), at: 0)
                payload.writeUInt32LE(UInt32(count), at: 4)

                Task {
                    do {
                        try await manager.writeCharacteristic(
                            BLEConstants.charLogStream, data: payload
                        )
                        resetTimeout()
                    } catch {
                        logger.error("Failed to write stream request: \(error)")
                        finish(.failure(error))
                    }
                }
            }
        }
    }
}
