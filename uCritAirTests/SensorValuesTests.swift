import Testing
@testable import uCritAir

@Suite("Sensor Values")
struct SensorValuesTests {

    @Test("empty has no values")
    func emptyHasNoValues() {
        let values = SensorValues.empty
        #expect(values.hasAnyValue == false)
    }

    @Test("merge updates only provided fields")
    func mergePartialUpdates() {
        var values = SensorValues.empty

        var first = PartialSensorUpdate()
        first.co2 = 500
        first.temperature = 24.5
        values.merge(first)

        #expect(values.co2 == 500)
        #expect(values.temperature == 24.5)
        #expect(values.humidity == nil)
        #expect(values.hasAnyValue)

        var second = PartialSensorUpdate()
        second.humidity = 55.0
        values.merge(second)

        #expect(values.co2 == 500)
        #expect(values.humidity == 55.0)
        #expect(values.temperature == 24.5)
    }
}
