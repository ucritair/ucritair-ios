import Foundation

struct SensorReading: Identifiable, Sendable {

    let id = UUID()

    let timestamp: Date

    let values: SensorValues
}
