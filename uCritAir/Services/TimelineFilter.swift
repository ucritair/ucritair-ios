import Foundation

// MARK: - File Overview
// ============================================================================
// TimelineFilter.swift
// uCritAir
//
// PURPOSE:
//   Cleans up log cell timelines that contain timestamp discontinuities caused
//   by device clock resets, timezone changes, or power cycles. Produces the
//   longest possible monotonically-increasing (always-going-forward-in-time)
//   sequence of cells for charting.
//
// THE PROBLEM:
//   The uCrit device stores log cells with local timestamps. Several events
//   can create discontinuities in the timestamp sequence:
//
//   1. **Clock reset**: The device loses power and its RTC resets to epoch 0.
//      When the phone reconnects and sets the time, new cells have much later
//      timestamps than the pre-reset cells.
//
//   2. **Timezone change**: The user travels across timezones. Since the device
//      stores "local time as UTC epoch," timestamps can jump forward or backward
//      by hours.
//
//   3. **Long power-off**: The device is off for days/weeks. When turned back
//      on, there's a huge forward gap that would create a misleading flat line
//      on the chart.
//
//   Example timeline with a clock reset:
//
//     Cell#:     0    1    2    3    4    5    6    7    8
//     Time:    100  280  460  640    0  180  360  540  720
//                                   ^
//                            clock reset here!
//
//   Cells 0-3 have timestamps 100-640 (old session).
//   Cells 4-8 have timestamps 0-720 (new session after reset).
//   If we plot all cells, the chart would zigzag backwards at cell 4.
//
// THE ALGORITHM (3 phases):
//   This uses a dynamic programming approach (not Ramer-Douglas-Peucker, which
//   is for point reduction). The algorithm finds the longest chain of
//   time-compatible segments:
//
//   Phase 1: SEGMENT DETECTION
//     Scan adjacent cells and split the timeline wherever timestamps jump
//     backward or have an unusually large forward gap. The threshold for
//     "unusually large" is adaptive: 10x the median normal gap, or at least
//     30 minutes.
//
//   Phase 2: DYNAMIC PROGRAMMING (Longest Compatible Chain)
//     Treat each segment as a node. Two segments are "compatible" if the
//     second one starts at or after the first one ends (time-wise). Find
//     the chain of compatible segments that maximizes total cell count.
//     This is a variant of the Longest Increasing Subsequence (LIS) problem.
//
//     Visual example with 4 segments:
//
//     Seg A: [t=100..640]  (4 cells)
//     Seg B: [t=0..720]    (5 cells)  <-- overlaps A, can't chain after A
//     Seg C: [t=800..1000] (3 cells)  <-- can chain after A or B
//     Seg D: [t=1100..1400] (2 cells) <-- can chain after A, B, or C
//
//     Possible chains:
//       A -> C -> D  = 4 + 3 + 2 = 9 cells
//       B -> C -> D  = 5 + 3 + 2 = 10 cells  <-- winner!
//       A -> D       = 4 + 2     = 6 cells
//
//   Phase 3: BACKTRACK AND MERGE
//     Starting from the best ending segment, follow the `prev` pointers
//     back to reconstruct the winning chain, then concatenate all cells
//     from those segments.
//
// COMPLEXITY:
//   - Time: O(n) for scanning + O(s^2) for DP where s = number of segments.
//     Since s is typically very small (1-5 segments), this is effectively O(n).
//   - Space: O(n) for the segment arrays.
//
// ORIGIN:
//   Ported from the web app's `History.tsx` -> `filterMonotonicTimeline()`.
// ============================================================================

/// Filters log cell arrays to produce the longest monotonically-increasing
/// (always-forward-in-time) timeline, handling device clock resets, timezone
/// changes, and power cycles.
///
/// Declared as a caseless `enum` to act as a pure namespace (cannot be instantiated).
///
/// Ported from `History.tsx` -> `filterMonotonicTimeline()`.
enum TimelineFilter {

    /// Filter an array of log cells to the longest chain of time-compatible segments.
    ///
    /// Call this before charting to ensure the x-axis (time) always increases from
    /// left to right, even if the raw data contains clock resets or timezone jumps.
    ///
    /// - Parameter cells: `LogCellEntity` array sorted by `cellNumber` ascending.
    ///   The sort-by-cellNumber order is important because cell numbers are always
    ///   monotonically increasing regardless of timestamp issues.
    /// - Returns: A filtered array containing only cells from the longest compatible
    ///   chain of segments. If no discontinuities are found, returns the input unchanged.
    ///
    /// ## Algorithm Overview
    /// 1. **Compute adaptive split threshold** from median timestamp delta.
    /// 2. **Split** into segments at backward jumps or huge forward gaps.
    /// 3. **Dynamic programming** to find the longest chain of compatible segments.
    /// 4. **Backtrack** to reconstruct the winning chain.
    /// 5. **Merge** cells from winning segments into the output array.
    static func filterMonotonic(_ cells: [LogCellEntity]) -> [LogCellEntity] {
        // Trivial case: 0 or 1 cells can't have discontinuities
        guard cells.count > 1 else { return cells }

        // =====================================================================
        // PHASE 1a: Compute the adaptive split threshold
        // =====================================================================
        // The "normal" time gap between consecutive cells depends on the device's
        // sampling interval (typically 3 minutes = 180 seconds). We compute the
        // median of all forward deltas to adapt to whatever interval was used.
        //
        // We exclude deltas > 2 hours (7200 seconds) as outliers, since those
        // are likely the very discontinuities we're trying to detect.
        var forwardDeltas: [Int] = []
        for i in 1..<cells.count {
            let delta = cells[i].timestamp - cells[i - 1].timestamp
            if delta > 0 && delta < 7200 { // Only include "normal" positive gaps
                forwardDeltas.append(delta)
            }
        }
        forwardDeltas.sort()
        // Use the median delta, or default to 180 seconds (3 min) if no valid deltas
        let medianDelta = forwardDeltas.isEmpty
            ? 180
            : forwardDeltas[forwardDeltas.count / 2]

        // The split threshold is 10x the normal gap, but at least 30 minutes (1800s).
        // This means: if normal gaps are 180s, threshold = max(1800, 1800) = 1800s.
        // If normal gaps are 300s (5 min), threshold = max(3000, 1800) = 3000s.
        let splitThreshold = max(medianDelta * 10, 1800)

        // =====================================================================
        // PHASE 1b: Split into segments at discontinuities
        // =====================================================================
        // Walk through the cells and start a new segment whenever we see:
        //   - A backward timestamp jump (delta < 0) -- indicates clock reset
        //   - A huge forward gap (delta > splitThreshold) -- indicates long power-off
        var segments: [[LogCellEntity]] = [[cells[0]]]
        for i in 1..<cells.count {
            let delta = cells[i].timestamp - cells[i - 1].timestamp
            if delta < 0 || delta > splitThreshold {
                // Start a new segment
                segments.append([])
            }
            // Append this cell to the current (last) segment
            segments[segments.count - 1].append(cells[i])
        }

        // If there's only one segment, the timeline is already clean
        if segments.count == 1 { return cells }

        // =====================================================================
        // PHASE 2: Dynamic programming -- longest chain of compatible segments
        // =====================================================================
        // This is a variant of the Longest Increasing Subsequence (LIS) problem.
        //
        // dp[i] = maximum total cell count achievable ending at segment i
        // prev[i] = index of the previous segment in the optimal chain (-1 if none)
        //
        // Two segments are "compatible" (can be chained) if the later segment's
        // first timestamp >= the earlier segment's last timestamp. This ensures
        // the merged timeline is monotonically increasing.
        let n = segments.count
        var dp = Array(repeating: 0, count: n)    // Best total count ending at segment i
        var prev = Array(repeating: -1, count: n)  // Previous segment in the chain

        for i in 0..<n {
            // Base case: just this segment alone
            dp[i] = segments[i].count
            // Try chaining segment i after each earlier segment j
            for j in 0..<i {
                guard let jEnd = segments[j].last, let iStart = segments[i].first else { continue }
                // Check compatibility: segment i must start at or after segment j ends
                if iStart.timestamp >= jEnd.timestamp && dp[j] + segments[i].count > dp[i] {
                    dp[i] = dp[j] + segments[i].count
                    prev[i] = j  // Remember that segment i chains after segment j
                }
            }
        }

        // =====================================================================
        // PHASE 3: Find best ending segment and backtrack
        // =====================================================================
        // The optimal chain ends at whichever segment has the highest dp value
        var bestIdx = 0
        for i in 1..<n {
            if dp[i] > dp[bestIdx] {
                bestIdx = i
            }
        }

        // Backtrack through `prev` pointers to reconstruct the full chain
        // (from end to beginning, then reverse)
        var chain: [Int] = []
        var idx = bestIdx
        while idx != -1 {
            chain.append(idx)
            idx = prev[idx]
        }
        chain.reverse()  // Now chain is in chronological order

        // =====================================================================
        // PHASE 4: Merge cells from the winning chain of segments
        // =====================================================================
        var result: [LogCellEntity] = []
        for segIdx in chain {
            result.append(contentsOf: segments[segIdx])
        }
        return result
    }
}
