import Testing
@testable import uCritAir

@Suite("Sensor ViewModel")
struct SensorViewModelTests {

    @MainActor
    @Test("sensor updates merge into current values and add history")
    func updatesMergeAndAppendHistory() {
        let manager = BLEManager()
        let vm = SensorViewModel()
        vm.configure(bleManager: manager)

        var update = PartialSensorUpdate()
        update.co2 = 500
        update.temperature = 24.0
        manager._testEmitSensorUpdate(update)

        #expect(vm.current.co2 == 500)
        #expect(vm.current.temperature == 24.0)
        #expect(vm.history.count == 1)
    }

    @MainActor
    @Test("history throttles frequent updates")
    func historyThrottle() {
        let manager = BLEManager()
        let vm = SensorViewModel()
        vm.configure(bleManager: manager)

        var first = PartialSensorUpdate()
        first.co2 = 450
        manager._testEmitSensorUpdate(first)
        #expect(vm.history.count == 1)

        var second = PartialSensorUpdate()
        second.humidity = 55
        manager._testEmitSensorUpdate(second)
        #expect(vm.current.humidity == 55)
        #expect(vm.history.count == 1)
    }

    @MainActor
    @Test("disconnect resets current values and history")
    func disconnectResetsState() {
        let manager = BLEManager()
        let vm = SensorViewModel()
        vm.configure(bleManager: manager)

        var update = PartialSensorUpdate()
        update.co2 = 501
        manager._testEmitSensorUpdate(update)
        #expect(vm.history.count == 1)

        manager._testEmitConnectionState(.disconnected)
        #expect(vm.current == .empty)
        #expect(vm.history.isEmpty)
    }

    @MainActor
    @Test("reconfigure detaches observers from old manager")
    func reconfigureDetachesOldManager() {
        let firstManager = BLEManager()
        let secondManager = BLEManager()
        let vm = SensorViewModel()

        vm.configure(bleManager: firstManager)
        vm.configure(bleManager: secondManager)

        var oldUpdate = PartialSensorUpdate()
        oldUpdate.co2 = 400
        firstManager._testEmitSensorUpdate(oldUpdate)
        #expect(vm.current.co2 == nil)

        var newUpdate = PartialSensorUpdate()
        newUpdate.co2 = 620
        secondManager._testEmitSensorUpdate(newUpdate)
        #expect(vm.current.co2 == 620)
    }
}
