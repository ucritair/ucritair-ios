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
}
