import Foundation
@preconcurrency import CoreBluetooth
import os.log

struct LogStreamProgress: Sendable {
    let received: Int

    let total: Int
}

protocol BLELogStreamManaging: AnyObject, Sendable {
    var onLogStreamNotification: ((Data) -> Void)? { get set }
    func pausePolling()
    func setLogStreamNotifications(enabled: Bool)
    func resumePolling()
    func writeCharacteristic(_ uuid: CBUUID, data: Data, completion: @escaping (Error?) -> Void)
}

extension BLEManager: BLELogStreamManaging {}

enum BLELogStream {

    private static let logger = Logger(subsystem: "com.ucritter.ucritair", category: "LogStream")

    private static let idleTimeout: TimeInterval = 10.0

    static func streamLogCells(
        startCell: Int,
        count: Int,
        using manager: BLELogStreamManaging,
        onProgress: @escaping (LogStreamProgress) -> Void,
        idleTimeout: TimeInterval = BLELogStream.idleTimeout
    ) async throws -> [ParsedLogCell] {

        manager.pausePolling()

        defer {
            manager.onLogStreamNotification = nil

            manager.setLogStreamNotifications(enabled: false)

            manager.resumePolling()
        }

        return try await withCheckedThrowingContinuation { continuation in
            var cells: [ParsedLogCell] = []
            var resumed = false
            var timeoutWork: DispatchWorkItem?

            let finish: (Result<[ParsedLogCell], Error>) -> Void = { result in
                guard !resumed else { return }
                resumed = true
                timeoutWork?.cancel()
                continuation.resume(with: result)
            }

            let resetTimeout: () -> Void = {
                timeoutWork?.cancel()
                let work = DispatchWorkItem {
                    logger.warning("Log stream idle timeout — received \(cells.count)/\(count) cells")
                    finish(.failure(BLEError.logStreamIncomplete(expected: count, received: cells.count)))
                }
                timeoutWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + idleTimeout, execute: work)
            }

            manager.onLogStreamNotification = { data in

                if data.count == 4, let marker = try? data.tryReadUInt32LE(at: 0) {
                    if marker == BLEConstants.logStreamEndMarker {
                        if cells.count == count {
                            logger.info("Log stream end marker received — \(cells.count) cells")
                            finish(.success(cells))
                        } else {
                            logger.warning("End marker arrived before expected count (\(cells.count)/\(count))")
                            finish(.failure(BLEError.logStreamIncomplete(expected: count, received: cells.count)))
                        }
                        return
                    }
                }

                guard data.count >= BLEConstants.logCellNotificationSize else {
                    logger.warning("Short log stream notification: \(data.count) bytes")
                    resetTimeout()
                    return
                }

                do {
                    let cell = try BLEParsers.parseLogCell(data)
                    cells.append(cell)
                } catch {
                    logger.warning("Malformed log stream payload (\(data.count) bytes): \(error.localizedDescription)")
                    resetTimeout()
                    return
                }

                onProgress(LogStreamProgress(received: cells.count, total: count))

                if cells.count == count {
                    logger.info("Log stream reached expected count (\(count) cells)")
                    finish(.success(cells))
                    return
                }

                resetTimeout()
            }

            manager.setLogStreamNotifications(enabled: true)

            var payload = Data(count: 8)
            payload.writeUInt32LE(UInt32(startCell), at: 0)
            payload.writeUInt32LE(UInt32(count), at: 4)

            manager.writeCharacteristic(BLEConstants.charLogStream, data: payload) { error in
                if let error {
                    logger.error("Failed to write stream request: \(error)")
                    finish(.failure(error))
                } else {
                    resetTimeout()
                }
            }
        }
    }
}
