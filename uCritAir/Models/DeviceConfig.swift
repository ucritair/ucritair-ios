import Foundation

// MARK: - DeviceConfig

struct DeviceConfig: Equatable, Sendable {

    var sensorWakeupPeriod: UInt16

    var sleepAfterSeconds: UInt16

    var dimAfterSeconds: UInt16

    var noxSamplePeriod: UInt8

    var screenBrightness: UInt8

    var persistFlags: PersistFlags

    func serialize() -> Data {
        var data = Data(count: 16)

        data.writeUInt16LE(sensorWakeupPeriod, at: 0)
        data.writeUInt16LE(sleepAfterSeconds, at: 2)
        data.writeUInt16LE(dimAfterSeconds, at: 4)
        data.writeUInt8(noxSamplePeriod, at: 6)
        data.writeUInt8(screenBrightness, at: 7)

        data.writeUInt32LE(UInt32(persistFlags.rawValue & 0xFFFF_FFFF), at: 8)
        data.writeUInt32LE(UInt32((persistFlags.rawValue >> 32) & 0xFFFF_FFFF), at: 12)

        return data
    }

    static func parse(from data: Data) -> DeviceConfig? {
        guard data.count >= 16 else { return nil }
        let flagsLow = UInt64(data.readUInt32LE(at: 8))
        let flagsHigh = UInt64(data.readUInt32LE(at: 12))

        return DeviceConfig(
            sensorWakeupPeriod: data.readUInt16LE(at: 0),
            sleepAfterSeconds: data.readUInt16LE(at: 2),
            dimAfterSeconds: data.readUInt16LE(at: 4),
            noxSamplePeriod: data.readUInt8(at: 6),
            screenBrightness: data.readUInt8(at: 7),
            persistFlags: PersistFlags(rawValue: (flagsHigh << 32) | flagsLow)
        )
    }
}

// MARK: - PersistFlags

struct PersistFlags: OptionSet, Equatable, Sendable {

    let rawValue: UInt64

    static let batteryAlert  = PersistFlags(rawValue: 1 << 0)

    static let manualOrient  = PersistFlags(rawValue: 1 << 1)

    static let useFahrenheit = PersistFlags(rawValue: 1 << 2)

    static let aqFirst       = PersistFlags(rawValue: 1 << 3)

    static let pauseCare     = PersistFlags(rawValue: 1 << 4)

    static let eternalWake   = PersistFlags(rawValue: 1 << 5)

    static let pauseLogging  = PersistFlags(rawValue: 1 << 6)
}
