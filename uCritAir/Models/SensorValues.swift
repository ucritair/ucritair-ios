import Foundation

struct SensorValues: Equatable, Sendable {

    var temperature: Double?

    var humidity: Double?

    var co2: Double?

    var pm1_0: Double?

    var pm2_5: Double?

    var pm4_0: Double?

    var pm10: Double?

    var pressure: Double?

    var voc: Double?

    var nox: Double?

    static let empty = SensorValues()

    mutating func merge(_ update: PartialSensorUpdate) {
        if let v = update.temperature { temperature = v }
        if let v = update.humidity { humidity = v }
        if let v = update.co2 { co2 = v }
        if let v = update.pm1_0 { pm1_0 = v }
        if let v = update.pm2_5 { pm2_5 = v }
        if let v = update.pm4_0 { pm4_0 = v }
        if let v = update.pm10 { pm10 = v }
        if let v = update.pressure { pressure = v }
        if let v = update.voc { voc = v }
        if let v = update.nox { nox = v }
    }

    var hasAnyValue: Bool {
        temperature != nil || humidity != nil || co2 != nil ||
        pm1_0 != nil || pm2_5 != nil || pm4_0 != nil || pm10 != nil ||
        pressure != nil || voc != nil || nox != nil
    }
}

// MARK: - PartialSensorUpdate

struct PartialSensorUpdate: Sendable {
    var temperature: Double?

    var humidity: Double?

    var co2: Double?

    var pm1_0: Double?

    var pm2_5: Double?

    var pm4_0: Double?

    var pm10: Double?

    var pressure: Double?

    var voc: Double?

    var nox: Double?
}
