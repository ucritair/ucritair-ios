import CoreBluetooth
import Testing
@testable import uCritAir

@Suite("BLEManager Observers")
struct BLEManagerObserverTests {

    @MainActor
    @Test("Connection-state observers can coexist and be removed")
    func testConnectionObservers() {
        let manager = BLEManager()
        var firstCount = 0
        var secondCount = 0

        let firstToken = manager.addConnectionStateObserver { _ in firstCount += 1 }
        _ = manager.addConnectionStateObserver { _ in secondCount += 1 }

        manager._testEmitConnectionState(.connected)
        #expect(firstCount == 1)
        #expect(secondCount == 1)

        manager.removeConnectionStateObserver(firstToken)
        manager._testEmitConnectionState(.disconnected)
        #expect(firstCount == 1)
        #expect(secondCount == 2)
    }

    @MainActor
    @Test("Sensor observers can coexist and be removed")
    func testSensorObservers() {
        let manager = BLEManager()
        var firstCount = 0
        var secondCount = 0

        let firstToken = manager.addSensorUpdateObserver { _ in firstCount += 1 }
        _ = manager.addSensorUpdateObserver { _ in secondCount += 1 }

        var update = PartialSensorUpdate()
        update.co2 = 500
        manager._testEmitSensorUpdate(update)
        #expect(firstCount == 1)
        #expect(secondCount == 1)

        manager.removeSensorUpdateObserver(firstToken)
        manager._testEmitSensorUpdate(update)
        #expect(firstCount == 1)
        #expect(secondCount == 2)
    }

    @MainActor
    @Test("Pending read operations time out and release the characteristic slot")
    func testPendingReadTimeoutClearsSlot() async {
        let manager = BLEManager()
        let uuid = CBUUID(string: "1234")

        let firstError = await captureError {
            try await manager._testAwaitReadTimeout(for: uuid)
        }
        expectTimeout(firstError)
        #expect(!manager._testHasPendingRead(for: uuid))

        let secondError = await captureError {
            try await manager._testAwaitReadTimeout(for: uuid)
        }
        expectTimeout(secondError)
        #expect(!manager._testHasPendingRead(for: uuid))
    }

    @MainActor
    @Test("Pending write operations time out and release the characteristic slot")
    func testPendingWriteTimeoutClearsSlot() async {
        let manager = BLEManager()
        let uuid = CBUUID(string: "5678")

        let firstError = await captureError {
            try await manager._testAwaitWriteTimeout(for: uuid)
        }
        expectTimeout(firstError)
        #expect(!manager._testHasPendingWrite(for: uuid))

        let secondError = await captureError {
            try await manager._testAwaitWriteTimeout(for: uuid)
        }
        expectTimeout(secondError)
        #expect(!manager._testHasPendingWrite(for: uuid))
    }

    private func captureError(_ operation: () async throws -> Void) async -> Error? {
        do {
            try await operation()
            return nil
        } catch {
            return error
        }
    }

    private func expectTimeout(_ error: Error?) {
        if case .timeout? = error as? BLEError {
            return
        }
        #expect(Bool(false))
    }
}
