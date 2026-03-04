import Foundation
import SwiftData

@Model
final class DeviceProfile {

    @Attribute(.unique) var deviceId: String

    var deviceName: String

    var petName: String

    var roomLabel: String?

    var lastConnectedAt: Date

    var lastKnownCellCount: Int

    var sortOrder: Int

    init(
        deviceId: String,
        deviceName: String = "Unknown",
        petName: String = "",
        roomLabel: String? = nil,
        lastConnectedAt: Date = .now,
        lastKnownCellCount: Int = 0,
        sortOrder: Int = 0
    ) {
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.petName = petName
        self.roomLabel = roomLabel
        self.lastConnectedAt = lastConnectedAt
        self.lastKnownCellCount = lastKnownCellCount
        self.sortOrder = sortOrder
    }
}
