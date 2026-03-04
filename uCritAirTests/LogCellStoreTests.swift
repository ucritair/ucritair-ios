import SwiftData
import Testing
@testable import uCritAir

@Suite("LogCellStore")
struct LogCellStoreTests {

    @MainActor
    @Test("save/fetch/count/max are scoped per device")
    func saveFetchCountMax() throws {
        let context = try makeContext()

        let deviceACells = [
            makeParsedCell(cellNumber: 3, timestamp: 1_700_000_003),
            makeParsedCell(cellNumber: 1, timestamp: 1_700_000_001),
        ]
        let deviceBCells = [
            makeParsedCell(cellNumber: 2, timestamp: 1_700_000_002),
        ]

        try LogCellStore.saveCells(deviceACells, deviceId: "A", context: context)
        try LogCellStore.saveCells(deviceBCells, deviceId: "B", context: context)

        let fetchedA = try LogCellStore.fetchAllCells(deviceId: "A", context: context)
        #expect(fetchedA.map(\.cellNumber) == [1, 3])
        #expect(try LogCellStore.cachedCellCount(deviceId: "A", context: context) == 2)
        #expect(try LogCellStore.cachedCellCount(deviceId: "B", context: context) == 1)
        #expect(try LogCellStore.maxCachedCellNumber(deviceId: "A", context: context) == 3)
        #expect(try LogCellStore.maxCachedCellNumber(deviceId: "MISSING", context: context) == -1)
    }

    @MainActor
    @Test("clearAllCells removes only target device")
    func clearAllCells() throws {
        let context = try makeContext()

        try LogCellStore.saveCells([makeParsedCell(cellNumber: 0, timestamp: 1_700_000_000)], deviceId: "A", context: context)
        try LogCellStore.saveCells([makeParsedCell(cellNumber: 1, timestamp: 1_700_000_001)], deviceId: "B", context: context)

        try LogCellStore.clearAllCells(deviceId: "A", context: context)

        #expect(try LogCellStore.fetchAllCells(deviceId: "A", context: context).isEmpty)
        #expect(try LogCellStore.fetchAllCells(deviceId: "B", context: context).count == 1)
    }

    @MainActor
    private func makeContext() throws -> ModelContext {
        let schema = Schema([LogCellEntity.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        return ModelContext(container)
    }

    private func makeParsedCell(cellNumber: Int, timestamp: Int) -> ParsedLogCell {
        ParsedLogCell(
            cellNumber: cellNumber,
            flags: 0x03,
            timestamp: timestamp,
            temperature: 22.5,
            pressure: 1013.2,
            humidity: 45.5,
            co2: 420,
            pm: (1.0, 2.0, 3.0, 4.0),
            pn: (5.0, 6.0, 7.0, 8.0, 9.0),
            voc: 10,
            nox: 20,
            co2Uncomp: 430,
            stroop: StroopData(meanTimeCong: 120.0, meanTimeIncong: 180.0, throughput: 8)
        )
    }
}
