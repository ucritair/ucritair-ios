import Foundation
import Testing
@testable import uCritAir

@Suite("Models and Constants")
struct ModelAndConstantTests {

    @Test("vendor UUID formatting and characteristic sets")
    func bleConstants() {
        let custom = BLEConstants.vendorCharUUID(0x0015)
        #expect(custom.uuidString == BLEConstants.charDeviceConfig.uuidString)
        #expect(BLEConstants.logCellBLESize == 53)
        #expect(BLEConstants.logCellNotificationSize == 57)
        #expect(BLEConstants.logStreamEndMarker == 0xFFFF_FFFF)
        #expect(BLEConstants.allCustomCharacteristicUUIDs.count == 12)
        #expect(BLEConstants.allESSCharacteristicUUIDs.count == 7)
        #expect(BLEConstants.allESSCharacteristicUUIDs.contains(BLEConstants.essCO2))
        #expect(BLEConstants.allESSCharacteristicUUIDs.contains(BLEConstants.essPressure))
    }

    @Test("known characteristic catalogs merge correctly")
    func knownCharacteristics() {
        #expect(KnownCharacteristics.custom.count == 12)
        #expect(KnownCharacteristics.ess.count == 7)
        #expect(KnownCharacteristics.all.count == 19)
        #expect(KnownCharacteristics.all.contains { $0.uuid == BLEConstants.charDeviceName })
        #expect(KnownCharacteristics.all.contains { $0.uuid == BLEConstants.essTemperature })
    }

    @Test("characteristic def id mirrors UUID")
    func characteristicDefID() {
        let def = CharacteristicDef(
            label: "CO2",
            uuid: BLEConstants.essCO2,
            access: .read,
            format: "uint16 LE"
        )
        #expect(def.id == BLEConstants.essCO2.uuidString)
        #expect(def.access == .read)
    }

    @Test("device profile defaults and custom values")
    func deviceProfileInit() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let profile = DeviceProfile(
            deviceId: "dev-1",
            deviceName: "Bedroom",
            petName: "Mochi",
            roomLabel: "Upstairs",
            lastConnectedAt: now,
            lastKnownCellCount: 123,
            sortOrder: 2
        )
        #expect(profile.deviceId == "dev-1")
        #expect(profile.deviceName == "Bedroom")
        #expect(profile.petName == "Mochi")
        #expect(profile.roomLabel == "Upstairs")
        #expect(profile.lastConnectedAt == now)
        #expect(profile.lastKnownCellCount == 123)
        #expect(profile.sortOrder == 2)
    }

    @Test("sensor reading stores timestamp and values")
    func sensorReadingInit() {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_100)
        let values = SensorValues(
            temperature: 22.0,
            humidity: 45.0,
            co2: 420,
            pm1_0: 1,
            pm2_5: 2,
            pm4_0: 3,
            pm10: 4,
            pressure: 1013,
            voc: 10,
            nox: 20
        )

        let reading = SensorReading(timestamp: timestamp, values: values)
        #expect(reading.timestamp == timestamp)
        #expect(reading.values == values)
    }
}
