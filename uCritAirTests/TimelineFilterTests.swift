import Foundation
import Testing
@testable import uCritAir

@Suite("Timeline Filter")
struct TimelineFilterTests {

    @Test("empty and single-element arrays pass through")
    func passthroughCases() {
        #expect(TimelineFilter.filterMonotonic([]).isEmpty)

        let one = makeCell(cellNumber: 1, timestamp: 100)
        let result = TimelineFilter.filterMonotonic([one])
        #expect(result.count == 1)
        #expect(result[0].cellNumber == 1)
    }

    @Test("clock reset keeps the longest monotonic segment")
    func keepsLongestSegmentAfterBackwardJump() {
        let cells = [
            makeCell(cellNumber: 0, timestamp: 100),
            makeCell(cellNumber: 1, timestamp: 200),
            makeCell(cellNumber: 2, timestamp: 300),
            makeCell(cellNumber: 3, timestamp: 150),
            makeCell(cellNumber: 4, timestamp: 250),
            makeCell(cellNumber: 5, timestamp: 350),
            makeCell(cellNumber: 6, timestamp: 450),
        ]

        let filtered = TimelineFilter.filterMonotonic(cells)
        #expect(filtered.map(\.timestamp) == [150, 250, 350, 450])
        #expect(filtered.map(\.cellNumber) == [3, 4, 5, 6])
    }

    @Test("large forward gaps split segments but preserve monotonic chain")
    func preservesForwardMonotonicChainAcrossGap() {
        let cells = [
            makeCell(cellNumber: 0, timestamp: 0),
            makeCell(cellNumber: 1, timestamp: 60),
            makeCell(cellNumber: 2, timestamp: 120),
            makeCell(cellNumber: 3, timestamp: 5_000),
            makeCell(cellNumber: 4, timestamp: 5_060),
        ]

        let filtered = TimelineFilter.filterMonotonic(cells)
        #expect(filtered.map(\.cellNumber) == [0, 1, 2, 3, 4])
    }

    private func makeCell(cellNumber: Int, timestamp: Int) -> LogCellEntity {
        let parsed = ParsedLogCell(
            cellNumber: cellNumber,
            flags: 0,
            timestamp: timestamp,
            temperature: 20.0,
            pressure: 1013.0,
            humidity: 45.0,
            co2: 420,
            pm: (1, 2, 3, 4),
            pn: (1, 2, 3, 4, 5),
            voc: 10,
            nox: 20,
            co2Uncomp: 425,
            stroop: StroopData(meanTimeCong: 100, meanTimeIncong: 150, throughput: 7)
        )
        return LogCellEntity(from: parsed, deviceId: "T1")
    }
}
