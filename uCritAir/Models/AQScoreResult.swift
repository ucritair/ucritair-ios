// MARK: - AQScoreResult.swift
// Part of the uCritAir iOS app — an air quality monitor companion.
//
// This file defines `AQScoreResult`, the output of the air quality scoring
// algorithm. It distills multiple sensor readings (CO2, PM2.5, VOC, etc.)
// into a single, easy-to-understand assessment.
//
// **Why a composite score?**
//
// Individual sensor values (e.g., "CO2 is 800 ppm, PM2.5 is 12 ug/m3")
// are hard for most people to interpret. The AQ score combines them into
// one number, one color, one letter grade, and one word — making it
// instantly clear whether the air is good or bad.
//
// **Scoring algorithm (high level):**
//
// The algorithm (implemented elsewhere in the scoring service) works by:
//
//   1. For each sensor (CO2, PM2.5, VOC, ...), compute a "badness" sub-score
//      on a 0-5 scale based on health thresholds.
//   2. Take the **worst** (highest) sub-score as the composite score.
//      (The air is only as good as its worst pollutant.)
//   3. Map the 0-5 badness score to a goodness percentage, color, label,
//      and letter grade.
//
// **Tier mapping:**
//
//   Score Range   Goodness   Color    Label   Grades
//   -----------   --------   -----    -----   ------
//   0.0 - 1.0    80 - 100   Green    Good    A+, A, A-
//   1.0 - 2.0    60 - 80    Yellow   Fair    B+, B, B-
//   2.0 - 3.5    30 - 60    Orange   Poor    C+, C, C-, D
//   3.5 - 5.0     0 - 30    Red      Bad     D-, F

import SwiftUI

/// The result of computing a composite air quality score from multiple
/// sensor inputs.
///
/// ## Overview
///
/// `AQScoreResult` is a **read-only value** produced by the air quality
/// scoring algorithm. It packages a raw numeric score together with
/// human-friendly representations (percentage, color, label, letter grade)
/// so the UI can display air quality status at different levels of detail:
///
/// - **Dashboard gauge:** uses ``goodness`` (0-100) and ``color``
/// - **Summary text:** uses ``label`` ("Good", "Fair", "Poor", "Bad")
/// - **Quick glance:** uses ``grade`` ("A+", "B-", "F", etc.)
/// - **Charts/analytics:** uses ``score`` (0.0-5.0) for numeric comparisons
///
/// ## Dual Scale (badness vs. goodness)
///
/// The scoring system uses two inverse scales:
///
/// - ``score`` is a **badness** scale: 0 = best, 5 = worst.
///   This is the algorithm's native output, where each pollutant contributes
///   "badness points."
///
/// - ``goodness`` is a **goodness** scale: 100 = best, 0 = worst.
///   This is the human-friendly inversion, because people intuitively
///   expect higher numbers to be better (like a test score).
///
/// ## Conformances
///
/// - `Equatable` — allows SwiftUI to detect when the score changes and
///   re-render only when needed.
/// - `Sendable` — safe to pass between concurrency contexts. Note that
///   `SwiftUI.Color` conforms to `Sendable`.
///
/// Ported from `src/lib/aqi.ts` -- `AQScoreResult`.
struct AQScoreResult: Equatable, Sendable {

    /// Composite "badness" score on a 0-to-5 scale.
    ///
    /// This is the algorithm's raw output. **Lower is better.**
    ///
    /// - **Range:** 0.0 (pristine air) to 5.0 (extremely polluted)
    /// - **Computation:** The worst (highest) sub-score among all individual
    ///   sensors (CO2, PM2.5, VOC, etc.) becomes the composite score.
    /// - **Usage:** Primarily for numeric comparisons and chart plotting.
    ///
    /// | Score Range | Air Quality Tier |
    /// |-------------|------------------|
    /// | 0.0 - 1.0  | Good             |
    /// | 1.0 - 2.0  | Fair             |
    /// | 2.0 - 3.5  | Poor             |
    /// | 3.5 - 5.0  | Bad              |
    let score: Double

    /// Human-friendly "goodness" percentage. **Higher is better.**
    ///
    /// This is the inverse mapping of ``score`` onto a 0-100 range, designed
    /// for intuitive display (like a school test grade percentage).
    ///
    /// - **Range:** 0 (terrible) to 100 (excellent)
    /// - **Derivation:** `goodness = 100 - (score / 5.0 * 100)` (approximately)
    /// - **Usage:** Dashboard gauges, progress bars, percentage displays
    let goodness: Int

    /// A `SwiftUI.Color` representing the air quality tier.
    ///
    /// The color provides an instant visual indicator of air quality status:
    ///
    /// | Tier | Color  | Custom Asset Name |
    /// |------|--------|-------------------|
    /// | Good | Green  | `Color.aqGood`    |
    /// | Fair | Yellow | `Color.aqFair`    |
    /// | Poor | Orange | `Color.aqPoor`    |
    /// | Bad  | Red    | `Color.aqBad`     |
    ///
    /// These are custom color assets defined in the app's asset catalog,
    /// not the system colors, to ensure consistent branding.
    let color: Color

    /// Human-readable air quality label.
    ///
    /// A single word summarizing the air quality tier. Used in UI text
    /// elements where a brief description is needed.
    ///
    /// - **Possible values:** `"Good"`, `"Fair"`, `"Poor"`, `"Bad"`
    let label: String

    /// Letter grade representing the air quality tier.
    ///
    /// Uses a familiar academic grading scale from `"A+"` (best) through
    /// `"F"` (worst). Provides a quick, universally understood quality
    /// indicator.
    ///
    /// - **Possible values (best to worst):**
    ///   `"A+"`, `"A"`, `"A-"`, `"B+"`, `"B"`, `"B-"`, `"C+"`, `"C"`,
    ///   `"C-"`, `"D"`, `"D-"`, `"F"`
    let grade: String
}
