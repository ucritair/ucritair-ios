import Foundation
import SwiftData

@Model
final class LogCellEntity {

    @Attribute(.unique) var compositeKey: String

    var deviceId: String

    var cellNumber: Int

    var flags: Int

    var timestamp: Int

    var temperature: Double

    var pressure: Double

    var humidity: Double

    var co2: Int

    var pm1_0: Double

    var pm2_5: Double

    var pm4_0: Double

    var pm10: Double

    var pn0_5: Double

    var pn1_0: Double

    var pn2_5: Double

    var pn4_0: Double

    var pn10: Double

    var voc: Int

    var nox: Int

    var co2Uncomp: Int

    var stroopMeanCong: Float

    var stroopMeanIncong: Float

    var stroopThroughput: Int

    init(from cell: ParsedLogCell, deviceId: String) {
        self.compositeKey = "\(deviceId)|\(cell.cellNumber)"
        self.deviceId = deviceId
        self.cellNumber = cell.cellNumber
        self.flags = cell.flags
        self.timestamp = cell.timestamp
        self.temperature = cell.temperature
        self.pressure = cell.pressure
        self.humidity = cell.humidity
        self.co2 = cell.co2

        self.pm1_0 = cell.pm.pm1_0
        self.pm2_5 = cell.pm.pm2_5
        self.pm4_0 = cell.pm.pm4_0
        self.pm10 = cell.pm.pm10

        self.pn0_5 = cell.pn.pn0_5
        self.pn1_0 = cell.pn.pn1_0
        self.pn2_5 = cell.pn.pn2_5
        self.pn4_0 = cell.pn.pn4_0
        self.pn10 = cell.pn.pn10

        self.voc = cell.voc
        self.nox = cell.nox
        self.co2Uncomp = cell.co2Uncomp

        self.stroopMeanCong = cell.stroop.meanTimeCong
        self.stroopMeanIncong = cell.stroop.meanTimeIncong
        self.stroopThroughput = cell.stroop.throughput
    }
}
