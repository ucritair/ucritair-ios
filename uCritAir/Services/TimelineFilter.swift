import Foundation

/// Filters log cell arrays to the longest monotonically-increasing timeline.
/// Handles device clock resets and timezone changes.
/// Ported from History.tsx → filterMonotonicTimeline()
enum TimelineFilter {

    /// Filter cells to the longest chain of time-compatible segments.
    /// - Parameter cells: LogCellEntity array sorted by cellNumber.
    /// - Returns: Filtered array with discontinuities removed.
    static func filterMonotonic(_ cells: [LogCellEntity]) -> [LogCellEntity] {
        guard cells.count > 1 else { return cells }

        // 1. Compute median forward delta for gap detection
        var forwardDeltas: [Int] = []
        for i in 1..<cells.count {
            let delta = cells[i].timestamp - cells[i - 1].timestamp
            if delta > 0 && delta < 7200 { // exclude outliers > 2h
                forwardDeltas.append(delta)
            }
        }
        forwardDeltas.sort()
        let medianDelta = forwardDeltas.isEmpty
            ? 180
            : forwardDeltas[forwardDeltas.count / 2]

        // Split threshold: max(medianDelta * 10, 1800 seconds = 30 min)
        let splitThreshold = max(medianDelta * 10, 1800)

        // 2. Split into segments at backward jumps or huge forward gaps
        var segments: [[LogCellEntity]] = [[cells[0]]]
        for i in 1..<cells.count {
            let delta = cells[i].timestamp - cells[i - 1].timestamp
            if delta < 0 || delta > splitThreshold {
                segments.append([])
            }
            segments[segments.count - 1].append(cells[i])
        }

        // No discontinuities found
        if segments.count == 1 { return cells }

        // 3. DP: find longest chain of compatible segments (by total cell count)
        let n = segments.count
        var dp = Array(repeating: 0, count: n)
        var prev = Array(repeating: -1, count: n)

        for i in 0..<n {
            dp[i] = segments[i].count
            for j in 0..<i {
                guard let jEnd = segments[j].last, let iStart = segments[i].first else { continue }
                if iStart.timestamp >= jEnd.timestamp && dp[j] + segments[i].count > dp[i] {
                    dp[i] = dp[j] + segments[i].count
                    prev[i] = j
                }
            }
        }

        // 4. Find the best ending segment (highest total count)
        var bestIdx = 0
        for i in 1..<n {
            if dp[i] > dp[bestIdx] {
                bestIdx = i
            }
        }

        // 5. Backtrack from best segment to reconstruct chain
        var chain: [Int] = []
        var idx = bestIdx
        while idx != -1 {
            chain.append(idx)
            idx = prev[idx]
        }
        chain.reverse()

        // 6. Merge cells from winning chain
        var result: [LogCellEntity] = []
        for segIdx in chain {
            result.append(contentsOf: segments[segIdx])
        }
        return result
    }
}
