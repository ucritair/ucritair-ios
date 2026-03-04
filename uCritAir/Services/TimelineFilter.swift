import Foundation

enum TimelineFilter {

    static func filterMonotonic(_ cells: [LogCellEntity]) -> [LogCellEntity] {
        guard cells.count > 1 else { return cells }

        var forwardDeltas: [Int] = []
        for i in 1..<cells.count {
            let delta = cells[i].timestamp - cells[i - 1].timestamp
            if delta > 0 && delta < 7200 {
                forwardDeltas.append(delta)
            }
        }
        forwardDeltas.sort()
        let medianDelta = forwardDeltas.isEmpty
            ? 180
            : forwardDeltas[forwardDeltas.count / 2]

        let splitThreshold = max(medianDelta * 10, 1800)

        var segments: [[LogCellEntity]] = [[cells[0]]]
        for i in 1..<cells.count {
            let delta = cells[i].timestamp - cells[i - 1].timestamp
            if delta < 0 || delta > splitThreshold {
                segments.append([])
            }
            segments[segments.count - 1].append(cells[i])
        }

        if segments.count == 1 { return cells }

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

        var bestIdx = 0
        for i in 1..<n {
            if dp[i] > dp[bestIdx] {
                bestIdx = i
            }
        }

        var chain: [Int] = []
        var idx = bestIdx
        while idx != -1 {
            chain.append(idx)
            idx = prev[idx]
        }
        chain.reverse()

        var result: [LogCellEntity] = []
        for segIdx in chain {
            result.append(contentsOf: segments[segIdx])
        }
        return result
    }
}
