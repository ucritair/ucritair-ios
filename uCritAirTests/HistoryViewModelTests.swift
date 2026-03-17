import Foundation
import Testing
@testable import uCritAir

@Suite("History ViewModel")
struct HistoryViewModelTests {

    @Test("csvFileURL invalidates cache when data changes at same row count")
    func testCSVCacheInvalidatesForContentChange() throws {
        let vm = HistoryViewModel()

        vm.allCells = [makeCell(cellNumber: 1, temperature: 22.0)]
        let firstURL = try #require(vm.csvFileURL())
        let firstCSV = try String(contentsOf: firstURL, encoding: .utf8)

        vm.allCells = [makeCell(cellNumber: 1, temperature: 23.0)]
        let secondURL = try #require(vm.csvFileURL())
        let secondCSV = try String(contentsOf: secondURL, encoding: .utf8)

        #expect(firstURL != secondURL)
        #expect(firstCSV != secondCSV)
        #expect(secondCSV.contains("23.000"))
    }

    @Test("csvFileURL regenerates when cached temp file is missing")
    func testCSVCacheRegeneratesWhenFileDeleted() throws {
        let vm = HistoryViewModel()
        vm.allCells = [makeCell(cellNumber: 1, temperature: 21.5)]

        let url = try #require(vm.csvFileURL())
        #expect(FileManager.default.fileExists(atPath: url.path))

        try FileManager.default.removeItem(at: url)
        #expect(!FileManager.default.fileExists(atPath: url.path))

        let regeneratedURL = try #require(vm.csvFileURL())
        #expect(regeneratedURL != url)
        #expect(FileManager.default.fileExists(atPath: regeneratedURL.path))
    }

    @Test("csvFileURL invalidates cache when a middle row changes")
    func testCSVCacheInvalidatesForMiddleRowChange() throws {
        let vm = HistoryViewModel()

        vm.allCells = [
            makeCell(cellNumber: 1, temperature: 21.0),
            makeCell(cellNumber: 2, temperature: 22.0),
            makeCell(cellNumber: 3, temperature: 23.0),
        ]
        let firstURL = try #require(vm.csvFileURL())
        let firstCSV = try String(contentsOf: firstURL, encoding: .utf8)

        vm.allCells = [
            makeCell(cellNumber: 1, temperature: 21.0),
            makeCell(cellNumber: 2, temperature: 42.0),
            makeCell(cellNumber: 3, temperature: 23.0),
        ]
        let secondURL = try #require(vm.csvFileURL())
        let secondCSV = try String(contentsOf: secondURL, encoding: .utf8)

        #expect(firstURL != secondURL)
        #expect(firstCSV != secondCSV)
        #expect(secondCSV.contains("42.000"))
    }

    @Test("filteredCells applies rolling one-hour window")
    func testFilteredCellsOneHour() {
        let vm = HistoryViewModel()
        let now = Int(Date().timeIntervalSince1970)
        vm.allCells = [
            makeCell(cellNumber: 1, timestamp: now - 7_200, co2: 390),
            makeCell(cellNumber: 2, timestamp: now - 1_800, co2: 420),
            makeCell(cellNumber: 3, timestamp: now, co2: 450),
        ]

        vm.timeRange = .oneHour
        #expect(vm.filteredCells.map(\.cellNumber) == [2, 3])
    }

    @Test("chartPoints inserts a nil gap marker")
    func testChartPointsGapInsertion() throws {
        let vm = HistoryViewModel()
        vm.timeRange = .all
        vm.allCells = [
            makeCell(cellNumber: 1, timestamp: 1_000, co2: 400),
            makeCell(cellNumber: 2, timestamp: 2_000, co2: 500),
        ]

        let sensor = try #require(HistoryViewModel.sensorDefs.first { $0.id == "co2" })
        let points = vm.chartPoints(for: sensor)
        #expect(points.count == 3)
        #expect(points[0].value == 400)
        #expect(points[1].value == nil)
        #expect(points[2].value == 500)
    }

    @Test("stats computes latest/avg/min/max")
    func testStats() throws {
        let vm = HistoryViewModel()
        vm.timeRange = .all
        vm.allCells = [
            makeCell(cellNumber: 1, timestamp: 10, co2: 400),
            makeCell(cellNumber: 2, timestamp: 20, co2: 500),
            makeCell(cellNumber: 3, timestamp: 30, co2: 600),
        ]

        let sensor = try #require(HistoryViewModel.sensorDefs.first { $0.id == "co2" })
        let stats = try #require(vm.stats(for: sensor))
        #expect(stats.latest == 600)
        #expect(stats.avg == 500)
        #expect(stats.min == 400)
        #expect(stats.max == 600)
    }

    @Test("time-range navigation mutates state")
    func testNavigation() {
        let vm = HistoryViewModel()

        vm.goBack()
        #expect(vm.dayOffset == -1)
        #expect(vm.canGoForward)

        vm.goForward()
        vm.goForward()
        #expect(vm.dayOffset == 0)

        vm.dayOffset = -3
        vm.setTimeRange(.sevenDays)
        #expect(vm.dayOffset == 0)
    }

    @Test("day label and back navigation availability")
    func testDayLabelAndCanGoBack() {
        let vm = HistoryViewModel()
        let now = Int(Date().timeIntervalSince1970)
        vm.allCells = [makeCell(cellNumber: 1, timestamp: now - (3 * 86_400), co2: 410)]
        vm.timeRange = .oneDay

        #expect(vm.dayLabel == "Today")
        #expect(vm.canGoBack)
        vm.goBack()
        #expect(vm.dayLabel == "Yesterday")
    }

    @Test("incremental download plan uses normal forward sync")
    func testIncrementalDownloadPlanNormal() {
        let plan = HistoryViewModel.computeIncrementalDownloadPlan(
            deviceCellCount: 120,
            maxCachedCell: 99
        )
        #expect(!plan.requiresCacheReset)
        #expect(plan.startCell == 100)
        #expect(plan.count == 20)
    }

    @Test("incremental download plan forces full resync after counter regression")
    func testIncrementalDownloadPlanCounterRegression() {
        let plan = HistoryViewModel.computeIncrementalDownloadPlan(
            deviceCellCount: 12,
            maxCachedCell: 40
        )
        #expect(plan.requiresCacheReset)
        #expect(plan.startCell == 0)
        #expect(plan.count == 12)
    }

    @Test("incremental download plan handles empty device log")
    func testIncrementalDownloadPlanEmptyDevice() {
        let plan = HistoryViewModel.computeIncrementalDownloadPlan(
            deviceCellCount: 0,
            maxCachedCell: 0
        )
        #expect(plan.requiresCacheReset)
        #expect(plan.startCell == 0)
        #expect(plan.count == 0)
    }

    private func makeCell(
        cellNumber: Int,
        temperature: Double = 22.0,
        timestamp: Int = 1_700_000_000,
        co2: Int = 420
    ) -> LogCellEntity {
        let parsed = ParsedLogCell(
            cellNumber: cellNumber,
            flags: 0x03,
            timestamp: timestamp,
            temperature: temperature,
            pressure: 1013.2,
            humidity: 45.0,
            co2: co2,
            pm: (1.0, 2.0, 3.0, 4.0),
            pn: (1.0, 2.0, 3.0, 4.0, 5.0),
            voc: 10,
            nox: 20,
            co2Uncomp: 430,
            stroop: StroopData(meanTimeCong: 120.0, meanTimeIncong: 180.0, throughput: 8)
        )
        return LogCellEntity(from: parsed, deviceId: "TEST-DEVICE")
    }
}
