import SwiftUI

/// Result of the aggregate air quality score computation.
///
/// Produced by the AQ scoring algorithm that combines multiple sensor inputs
/// (CO2, PM2.5, VOC, etc.) into a single composite assessment. The score uses
/// an inverted scale where lower values are better.
///
/// Ported from `src/lib/aqi.ts` -- `AQScoreResult`.
struct AQScoreResult: Equatable, Sendable {
    /// Composite badness score on a 0-5 scale (0 = best air quality, 5 = worst).
    let score: Double

    /// Human-friendly goodness percentage (0-100, where 100 = best air quality).
    /// Derived as the inverse of ``score`` mapped to a 0-100 range.
    let goodness: Int

    /// SwiftUI color representing the air quality tier (green/yellow/orange/red).
    /// Corresponds to ``Color/aqGood``, ``Color/aqFair``, ``Color/aqPoor``, or ``Color/aqBad``.
    let color: Color

    /// Human-readable air quality label: "Good", "Fair", "Poor", or "Bad".
    let label: String

    /// Letter grade from "A+" (best) through "F" (worst) representing the air quality tier.
    let grade: String
}
