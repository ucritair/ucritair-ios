import CoreBluetooth
import Foundation
import Testing
@testable import uCritAir

@Suite("BLE Log Stream")
struct BLELogStreamTests {

    @Test("stream completes when expected cells are received")
    func streamCompletesAtExpectedCount() async throws {
        let manager = FakeBLELogStreamManager()
        var progressUpdates: [LogStreamProgress] = []

        manager.writeHandler = { _, _ in
            manager.emit(makeLogCellPayload(cellNumber: 10, timestamp: 1_700_000_010))
            manager.emit(makeLogCellPayload(cellNumber: 11, timestamp: 1_700_000_011))
        }

        let cells = try await BLELogStream.streamLogCells(
            startCell: 10,
            count: 2,
            using: manager,
            onProgress: { progressUpdates.append($0) },
            idleTimeout: 0.05
        )

        #expect(cells.map(\.cellNumber) == [10, 11])
        #expect(progressUpdates.map(\.received) == [1, 2])
        #expect(manager.pausePollingCount == 1)
        #expect(manager.resumePollingCount == 1)
        #expect(manager.notificationToggleHistory == [true, false])
    }

    @Test("stream fails when end marker arrives before expected count")
    func streamFailsWhenEndMarkerArrivesEarly() async {
        let manager = FakeBLELogStreamManager()

        manager.writeHandler = { _, _ in
            manager.emit(makeLogCellPayload(cellNumber: 20, timestamp: 1_700_000_020))
            manager.emit(endMarkerPayload())
        }

        do {
            _ = try await BLELogStream.streamLogCells(
                startCell: 20,
                count: 2,
                using: manager,
                onProgress: { _ in },
                idleTimeout: 0.05
            )
            #expect(Bool(false))
        } catch let error as BLEError {
            switch error {
            case .logStreamIncomplete(let expected, let received):
                #expect(expected == 2)
                #expect(received == 1)
            default:
                #expect(Bool(false))
            }
        } catch {
            #expect(Bool(false))
        }

        #expect(manager.pausePollingCount == 1)
        #expect(manager.resumePollingCount == 1)
        #expect(manager.notificationToggleHistory == [true, false])
    }

    @Test("stream fails on idle timeout with partial data")
    func streamFailsOnIdleTimeout() async {
        let manager = FakeBLELogStreamManager()

        manager.writeHandler = { _, _ in
            manager.emit(makeLogCellPayload(cellNumber: 30, timestamp: 1_700_000_030))
        }

        do {
            _ = try await BLELogStream.streamLogCells(
                startCell: 30,
                count: 2,
                using: manager,
                onProgress: { _ in },
                idleTimeout: 0.02
            )
            #expect(Bool(false))
        } catch let error as BLEError {
            switch error {
            case .logStreamIncomplete(let expected, let received):
                #expect(expected == 2)
                #expect(received == 1)
            default:
                #expect(Bool(false))
            }
        } catch {
            #expect(Bool(false))
        }

        #expect(manager.pausePollingCount == 1)
        #expect(manager.resumePollingCount == 1)
        #expect(manager.notificationToggleHistory == [true, false])
    }

    private func makeLogCellPayload(cellNumber: Int, timestamp: Int) -> Data {
        var data = Data(count: BLEConstants.logCellNotificationSize)
        data.writeUInt32LE(UInt32(clamping: cellNumber), at: 0)
        data[4] = 0x03

        let rtc = UInt64(BLEConstants.rtcEpochOffset) + UInt64(clamping: timestamp)
        data.writeUInt64LE(rtc, at: 8)
        data.writeUInt32LE(UInt32(bitPattern: Int32(21_500)), at: 16)
        data.writeUInt16LE(10_132, at: 20)
        data.writeUInt16LE(4_550, at: 22)
        data.writeUInt16LE(501, at: 24)

        data.writeUInt16LE(100, at: 26)
        data.writeUInt16LE(250, at: 28)
        data.writeUInt16LE(400, at: 30)
        data.writeUInt16LE(1_000, at: 32)

        data.writeUInt16LE(11, at: 34)
        data.writeUInt16LE(22, at: 36)
        data.writeUInt16LE(33, at: 38)
        data.writeUInt16LE(44, at: 40)
        data.writeUInt16LE(55, at: 42)

        data[44] = 17
        data[45] = 23
        data.writeUInt16LE(520, at: 46)
        data.writeUInt32LE(Float(123.5).bitPattern, at: 48)
        data.writeUInt32LE(Float(234.5).bitPattern, at: 52)
        data[56] = 9
        return data
    }

    private func endMarkerPayload() -> Data {
        var data = Data(count: 4)
        data.writeUInt32LE(BLEConstants.logStreamEndMarker, at: 0)
        return data
    }
}

private final class FakeBLELogStreamManager: BLELogStreamManaging, @unchecked Sendable {
    var onLogStreamNotification: ((Data) -> Void)?
    var writeHandler: ((_ uuid: CBUUID, _ data: Data) -> Void)?

    private(set) var pausePollingCount = 0
    private(set) var resumePollingCount = 0
    private(set) var notificationToggleHistory: [Bool] = []

    func pausePolling() {
        pausePollingCount += 1
    }

    func setLogStreamNotifications(enabled: Bool) {
        notificationToggleHistory.append(enabled)
    }

    func resumePolling() {
        resumePollingCount += 1
    }

    func writeCharacteristic(_ uuid: CBUUID, data: Data, completion: @escaping (Error?) -> Void) {
        writeHandler?(uuid, data)
        completion(nil)
    }

    func emit(_ data: Data) {
        onLogStreamNotification?(data)
    }
}
