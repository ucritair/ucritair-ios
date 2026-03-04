import SwiftUI

// MARK: - File Overview
// ============================================================================
// AQIScoring.swift
// uCritAir
//
// PURPOSE:
//   Converts raw sensor readings (temperature, humidity, CO2, PM2.5, etc.)
//   into human-readable air quality grades (A+ through F) and color-coded
//   goodness percentages (0-100%).
//
// HOW IT WORKS:
//   Each sensor type has a "scoring curve" -- a set of control points that
//   maps raw values to a "badness" score from 0 (perfect) to 5 (hazardous).
//   The mapping uses *piecewise linear interpolation*, meaning we draw straight
//   lines between adjacent control points and read off the y-value.
//
//   Individual sensor scores are then combined into an aggregate score using
//   a worst-pollutant-wins strategy, with penalties for multiple bad pollutants
//   and multipliers for uncomfortable temperature/humidity.
//
// ORIGIN:
//   Direct port of the web app's `src/lib/aqi.ts` and firmware's `cat_air.c`.
//   All thresholds, curves, and grade tables are identical across platforms.
//
// KEY CONCEPTS FOR STUDENTS:
//
//   Piecewise Linear Interpolation:
//   ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
//   Imagine you have a few data points on a graph and you connect them with
//   straight line segments. Given any x-value, you find which two points it
//   falls between, then follow the straight line to get the y-value.
//
//   Example with points [(0, 0), (10, 5), (20, 2)]:
//
//       y
//     5 |       *
//     4 |      / \
//     3 |     /   \
//     2 |    /     *
//     1 |   /
//     0 |--*-----------
//       0  5  10  15  20  x
//
//   At x=5:  halfway between (0,0) and (10,5) => y = 2.5
//   At x=15: halfway between (10,5) and (20,2) => y = 3.5
//
//   The formula for any segment between (x0, y0) and (x1, y1) is:
//       y = y0 + (y1 - y0) * ((x - x0) / (x1 - x0))
//
//   This is the classic linear interpolation formula, sometimes called "lerp".
//   The term (x - x0) / (x1 - x0) computes how far along the segment we are
//   (0.0 at the left endpoint, 1.0 at the right endpoint).
//
//   Badness Score:
//   ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
//   Each sensor reading is converted to a "badness" score from 0 to 5:
//     0 = ideal / healthy
//     1 = acceptable
//     2 = moderate concern
//     3 = unhealthy for sensitive groups
//     4 = unhealthy
//     5 = hazardous
//
//   Goodness Percentage:
//   ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
//   The inverse of badness, scaled to 0-100%:
//     goodness = (5 - badness) / 5 * 100
//   So a badness of 0 gives 100% goodness (perfect air), and badness of 5
//   gives 0% goodness (hazardous air).
// ============================================================================

/// Air quality scoring algorithms matching the firmware (`cat_air.c`) and web app.
///
/// `AQIScoring` is a stateless utility (declared as an `enum` with no cases to prevent
/// instantiation). It provides:
/// - **Individual sensor scoring**: Convert a single sensor reading (e.g., CO2 in ppm)
///   to a 0-5 badness score via piecewise linear interpolation.
/// - **Aggregate scoring**: Combine all sensor scores into one overall badness score
///   with penalties for multiple bad pollutants and temperature/humidity discomfort.
/// - **Grade mapping**: Convert badness/goodness to letter grades (A+ through F),
///   semantic colors (green/yellow/orange/red), and labels ("Good"/"Fair"/"Poor"/"Bad").
///
/// Direct port of `src/lib/aqi.ts`.
///
/// ## Usage
/// ```swift
/// let sensors = SensorValues(co2: 800, pm2_5: 12, temperature: 22, humidity: 45, ...)
/// let result = AQIScoring.computeAQScore(sensors)
/// print(result.grade)    // "A-"
/// print(result.goodness) // 82
/// print(result.label)    // "Good"
/// ```
enum AQIScoring {

    // MARK: - Piecewise Linear Interpolation

    /// Evaluate a piecewise linear function defined by sorted control points.
    ///
    /// This is the core mathematical engine of the scoring system. Given a set of
    /// (x, y) control points that define a curve, it finds the y-value for any input x
    /// by interpolating between the two nearest control points.
    ///
    /// **How it works, step by step:**
    /// 1. If `x` is at or below the first control point's x-value, return that point's
    ///    y-value (clamp to left edge).
    /// 2. If `x` is at or above the last control point's x-value, return that point's
    ///    y-value (clamp to right edge).
    /// 3. Otherwise, scan the points left to right until we find the segment that
    ///    contains `x` (i.e., `points[i-1].x <= x <= points[i].x`).
    /// 4. Apply the linear interpolation formula:
    ///    ```
    ///    y = y0 + (y1 - y0) * ((x - x0) / (x1 - x0))
    ///    ```
    ///    where `(x0, y0)` and `(x1, y1)` are the endpoints of that segment.
    ///
    /// **Clamping behavior**: Values outside the domain are clamped to the first or
    /// last point's y-value. This means a CO2 reading of -10 ppm (nonsensical) would
    /// simply return the score for 0 ppm.
    ///
    /// - Parameters:
    ///   - points: Control points sorted ascending by x, each as `(x, y)`.
    ///   - x: The input value to interpolate.
    /// - Returns: The interpolated y-value.
    ///
    /// - Complexity: O(n) where n is the number of control points. Since our curves
    ///   have at most ~10 points, this is effectively O(1).
    private static func lerp(_ points: [(Double, Double)], _ x: Double) -> Double {
        // Clamp below: if x is at or below the leftmost control point, return its y
        if x <= points[0].0 { return points[0].1 }
        // Clamp above: if x is at or above the rightmost control point, return its y
        if x >= points[points.count - 1].0 { return points[points.count - 1].1 }
        // Scan segments to find which one contains x
        for i in 1..<points.count {
            if x <= points[i].0 {
                let (x0, y0) = points[i - 1]  // left endpoint of segment
                let (x1, y1) = points[i]      // right endpoint of segment
                // Linear interpolation: compute fractional position within segment,
                // then scale the y-range accordingly
                return y0 + (y1 - y0) * ((x - x0) / (x1 - x0))
            }
        }
        // Fallback (should never reach here if points are sorted correctly)
        return points[points.count - 1].1
    }

    // MARK: - Scoring Curves (0 = best, 5 = worst)
    //
    // Each curve is an array of (sensorValue, badnessScore) control points.
    // The `lerp` function interpolates between these points to produce a
    // continuous badness score for any sensor reading.
    //
    // The curves are designed so that:
    //   - "Ideal" sensor values map to 0 (no badness)
    //   - Progressively worse readings map to higher scores
    //   - Truly hazardous readings max out at 5
    //
    // Note: Temperature and humidity curves are U-shaped (both too low and
    // too high are bad), while pollutant curves are monotonically increasing
    // (more pollutant = worse).

    /// Temperature badness curve (degrees Celsius).
    ///
    /// The curve is U-shaped because both cold and hot temperatures are uncomfortable:
    /// - 0-8 C (freezing/cold): badness 5 (worst)
    /// - 16-18 C (cool): badness 3-4
    /// - 20-25 C (comfortable): badness 0-1 (best -- this is the "comfort band")
    /// - 27-29 C (warm): badness 1-3
    /// - 35+ C (hot): badness 5 (worst)
    private static let tempCurve: [(Double, Double)] = [
        (0, 5), (8, 5), (16, 4), (18, 3), (20, 1), (25, 0), (27, 1), (29, 3), (34, 4), (35, 5),
    ]

    /// Relative humidity badness curve (percent).
    ///
    /// Also U-shaped -- both dry air and humid air are bad:
    /// - 0-14% (very dry): badness 5
    /// - 40-50% (comfortable): badness 0-1 (best -- the comfort band)
    /// - 65-85% (humid/damp): badness 3-5
    private static let rhCurve: [(Double, Double)] = [
        (0, 5), (14, 5), (23, 4), (30, 3), (40, 1), (50, 0), (60, 1), (65, 3), (80, 4), (85, 5),
    ]

    /// CO2 badness curve (parts per million).
    ///
    /// Monotonically increasing -- more CO2 is always worse:
    /// - 0-420 ppm: badness 0 (outdoor baseline is ~420 ppm)
    /// - 800 ppm: badness 1 (stuffy room)
    /// - 1000 ppm: badness 2 (drowsiness threshold)
    /// - 1400 ppm: badness 3 (poor ventilation)
    /// - 4500+ ppm: badness 5 (hazardous)
    private static let co2Curve: [(Double, Double)] = [
        (0, 0), (420, 0), (800, 1), (1000, 2), (1400, 3), (4500, 5),
    ]

    /// PM2.5 badness curve (micrograms per cubic meter).
    ///
    /// Based on WHO and EPA breakpoints for fine particulate matter (particles
    /// smaller than 2.5 micrometers, which can penetrate deep into the lungs):
    /// - 0-5 ug/m3: badness 0-1 (clean air)
    /// - 12 ug/m3: badness 2 (EPA annual standard)
    /// - 35 ug/m3: badness 3 (EPA 24-hour standard)
    /// - 55 ug/m3: badness 4 (unhealthy)
    /// - 150+ ug/m3: badness 5 (hazardous)
    private static let pm25Curve: [(Double, Double)] = [
        (0, 0), (5, 1), (12, 2), (35, 3), (55, 4), (150, 5),
    ]

    /// PM10 badness curve (micrograms per cubic meter).
    ///
    /// Thresholds are roughly 3x the PM2.5 values, following WHO/EPA guidelines
    /// for coarse particulate matter (particles smaller than 10 micrometers):
    /// - 0-15 ug/m3: badness 0-1
    /// - 100 ug/m3: badness 3
    /// - 500+ ug/m3: badness 5
    private static let pm10Curve: [(Double, Double)] = [
        (0, 0), (15, 1), (45, 2), (100, 3), (200, 4), (500, 5),
    ]

    /// NOx (nitrogen oxides) index badness curve.
    ///
    /// Uses the Sensirion NOx Index, a proprietary scale from the SGP41 gas sensor.
    /// The index represents relative NOx levels compared to the sensor's baseline:
    /// - 0-1: badness 0-0.5 (clean)
    /// - 90: badness 2 (moderate)
    /// - 150: badness 3 (elevated)
    /// - 310+: badness 5 (hazardous)
    private static let noxCurve: [(Double, Double)] = [
        (0, 0), (1, 0.5), (90, 2), (150, 3), (300, 4), (310, 5),
    ]

    /// VOC (volatile organic compounds) index badness curve.
    ///
    /// Uses the Sensirion VOC Index from the SGP41 gas sensor. VOCs include
    /// chemicals like formaldehyde, benzene, and cleaning product fumes:
    /// - 0-100: badness 0-0.5 (baseline / clean)
    /// - 150: badness 2 (moderate off-gassing)
    /// - 250: badness 3 (poor air quality)
    /// - 410+: badness 5 (hazardous)
    private static let vocCurve: [(Double, Double)] = [
        (0, 0), (100, 0.5), (150, 2), (250, 3), (400, 4), (410, 5),
    ]

    // MARK: - Individual Sensor Scores
    //
    // Each function below is a thin wrapper that passes the appropriate scoring
    // curve to `lerp`. They accept a raw sensor reading and return a badness
    // score from 0.0 (ideal) to 5.0 (hazardous).
    //
    // Example:
    //   AQIScoring.scoreCO2(800)   // returns 1.0  (acceptable)
    //   AQIScoring.scoreCO2(1200)  // returns 2.5  (between moderate and poor)
    //   AQIScoring.scoreCO2(5000)  // returns 5.0  (clamped to worst)

    /// Score a temperature reading (in degrees Celsius) on the 0-5 badness scale.
    static func scoreTemperature(_ v: Double) -> Double { lerp(tempCurve, v) }
    /// Score a relative humidity reading (in percent) on the 0-5 badness scale.
    static func scoreHumidity(_ v: Double) -> Double { lerp(rhCurve, v) }
    /// Score a CO2 reading (in parts per million) on the 0-5 badness scale.
    static func scoreCO2(_ v: Double) -> Double { lerp(co2Curve, v) }
    /// Score a PM2.5 reading (in micrograms per cubic meter) on the 0-5 badness scale.
    static func scorePM25(_ v: Double) -> Double { lerp(pm25Curve, v) }
    /// Score a PM10 reading (in micrograms per cubic meter) on the 0-5 badness scale.
    static func scorePM10(_ v: Double) -> Double { lerp(pm10Curve, v) }
    /// Score a NOx index reading (Sensirion units) on the 0-5 badness scale.
    static func scoreNOx(_ v: Double) -> Double { lerp(noxCurve, v) }
    /// Score a VOC index reading (Sensirion units) on the 0-5 badness scale.
    static func scoreVOC(_ v: Double) -> Double { lerp(vocCurve, v) }

    // MARK: - Aggregate Score

    /// Compute the aggregate Indoor Air Quality (IAQ) score from a set of sensor readings.
    ///
    /// This is the main entry point for air quality assessment. It mirrors the firmware's
    /// scoring algorithm exactly so the iOS app, web app, and device all display the same grade.
    ///
    /// **Algorithm overview** (5 steps):
    ///
    /// 1. **Score each sensor independently** using its piecewise-linear curve.
    ///    Missing sensors (nil values) default to 0 (no contribution to badness).
    ///
    /// 2. **Base score = worst pollutant**. The overall air quality is driven by whichever
    ///    single pollutant (CO2, PM2.5, NOx, or VOC) is the worst. This follows the
    ///    standard AQI convention: one bad pollutant makes the air bad, even if others
    ///    are fine.
    ///
    /// 3. **Multiple-pollutant penalty**. If more than one pollutant scores above 3
    ///    ("poor"), add 0.5 for each additional bad pollutant. This captures the
    ///    compounding health effect of multiple pollutants being elevated simultaneously.
    ///
    /// 4. **Temperature and humidity multipliers**. Uncomfortable temperature or humidity
    ///    amplifies the perceived air quality problem. Each contributes a multiplier of
    ///    `1.0 + max(0, score - 1.0) * 0.1`. So a humidity score of 3 gives a 1.2x
    ///    multiplier; a score of 1 or below gives 1.0x (no penalty).
    ///
    /// 5. **Final score** is clamped to [0, 5], rounded to 2 decimal places, then
    ///    converted to a goodness percentage: `goodness = (5 - score) / 5 * 100`.
    ///
    /// - Parameter sensors: The current sensor readings (any may be nil if unavailable).
    /// - Returns: An `AQScoreResult` containing the numeric score, goodness percentage,
    ///   display color, human-readable label, and letter grade.
    ///
    /// Ported from `aqi.ts` -> `computeAQScore()`.
    static func computeAQScore(_ sensors: SensorValues) -> AQScoreResult {
        // Step 1: Score each sensor independently. The `?? 0` means missing sensors
        // contribute zero badness (they don't make the score worse).
        let scores = (
            co2: sensors.co2.map { scoreCO2($0) } ?? 0,
            pm25: sensors.pm2_5.map { scorePM25($0) } ?? 0,
            nox: sensors.nox.map { scoreNOx($0) } ?? 0,
            voc: sensors.voc.map { scoreVOC($0) } ?? 0,
            temp: sensors.temperature.map { scoreTemperature($0) } ?? 0,
            rh: sensors.humidity.map { scoreHumidity($0) } ?? 0
        )

        // Step 2: Base score = worst single pollutant (excluding temp/humidity,
        // which are comfort factors, not pollutants).
        var baseScore = max(scores.co2, scores.pm25, scores.nox, scores.voc)

        // Step 3: Penalty when multiple pollutants are simultaneously bad (score > 3).
        // Example: if CO2=4 and PM2.5=4, badCount=2, penalty = (2-1)*0.5 = +0.5
        let pollutantScores = [scores.co2, scores.pm25, scores.nox, scores.voc]
        let badCount = pollutantScores.filter { $0 > 3 }.count
        if badCount > 1 {
            baseScore += Double(badCount - 1) * 0.5
        }

        // Step 4: Temperature and humidity multipliers. These amplify the base score
        // when the room is uncomfortable. The multiplier only kicks in above a score
        // of 1.0 (i.e., slight discomfort is ignored).
        let tempMult = 1.0 + max(0, scores.temp - 1.0) * 0.1
        let rhMult = 1.0 + max(0, scores.rh - 1.0) * 0.1

        // Step 5: Combine, round to 2 decimal places, clamp to [0, 5], and convert
        // to goodness percentage (0-100 where 100 = perfect air).
        let finalScore = min(5.0, (baseScore * tempMult * rhMult * 100).rounded() / 100)
        let goodness = Int(((5.0 - finalScore) / 5.0 * 100).rounded())

        return AQScoreResult(
            score: finalScore,
            goodness: goodness,
            color: goodnessColor(goodness),
            label: goodnessLabel(goodness),
            grade: goodnessToGrade(goodness)
        )
    }

    // MARK: - Color / Label / Grade Mapping
    //
    // These functions convert numeric scores into user-facing display values.
    // The color palette is defined in Color+Hex.swift and matches the web app's
    // Tailwind CSS colors (green-500, yellow-500, orange-500, red-500).
    //
    // Goodness thresholds:
    //   >= 80%  ->  Good  (green)   -- healthy air
    //   >= 60%  ->  Fair  (yellow)  -- acceptable but could be better
    //   >= 40%  ->  Poor  (orange)  -- should take action
    //   <  40%  ->  Bad   (red)     -- unhealthy, ventilate immediately

    /// Map a goodness percentage (0-100) to a semantic color for UI display.
    ///
    /// The four-tier color system provides an instant visual indicator of air quality:
    /// - **Green** (`.aqGood`): goodness >= 80% -- healthy, no action needed
    /// - **Yellow** (`.aqFair`): goodness >= 60% -- acceptable
    /// - **Orange** (`.aqPoor`): goodness >= 40% -- concerning
    /// - **Red** (`.aqBad`): goodness < 40% -- unhealthy
    ///
    /// - Parameter goodness: Aggregate goodness value where 100 is best and 0 is worst.
    /// - Returns: A themed `Color` from the air quality palette defined in `Color+Hex.swift`.
    static func goodnessColor(_ goodness: Int) -> Color {
        if goodness >= 80 { return .aqGood }
        if goodness >= 60 { return .aqFair }
        if goodness >= 40 { return .aqPoor }
        return .aqBad
    }

    /// Map a goodness percentage (0-100) to a human-readable label string.
    ///
    /// Uses the same threshold breakpoints as `goodnessColor(_:)`:
    /// - >= 80% -> `"Good"`
    /// - >= 60% -> `"Fair"`
    /// - >= 40% -> `"Poor"`
    /// - <  40% -> `"Bad"`
    ///
    /// - Parameter goodness: Aggregate goodness value where 100 is best.
    /// - Returns: One of four descriptive strings: `"Good"`, `"Fair"`, `"Poor"`, or `"Bad"`.
    static func goodnessLabel(_ goodness: Int) -> String {
        if goodness >= 80 { return "Good" }
        if goodness >= 60 { return "Fair" }
        if goodness >= 40 { return "Poor" }
        return "Bad"
    }

    /// Convert an individual sensor's badness score (0-5) to a color and label tuple.
    ///
    /// This is used for per-sensor status indicators (e.g., showing the CO2 reading
    /// with its own color badge). The thresholds differ slightly from the aggregate
    /// goodness thresholds because this operates on the 0-5 badness scale directly:
    /// - <= 1: Good (green)
    /// - <= 2: Fair (yellow)
    /// - <= 3: Poor (orange)
    /// - >  3: Bad (red)
    ///
    /// - Parameter score: A sensor's badness score from 0.0 (ideal) to 5.0 (hazardous).
    /// - Returns: A tuple of `(color: Color, label: String)` for UI display.
    ///
    /// Ported from `aqi.ts` -> `sensorStatus()`.
    static func sensorStatus(_ score: Double) -> (color: Color, label: String) {
        if score <= 1 { return (.aqGood, "Good") }
        if score <= 2 { return (.aqFair, "Fair") }
        if score <= 3 { return (.aqPoor, "Poor") }
        return (.aqBad, "Bad")
    }

    // MARK: - Letter Grades
    //
    // The grading system uses 13 letter grades familiar from academic grading:
    //   Index:  0    1    2    3    4    5    6    7    8    9   10   11   12
    //   Grade:  F   D-    D   D+   C-    C   C+   B-    B   B+   A-    A   A+
    //
    // The mapping works by normalizing goodness (0-100) to [0.0, 1.0], multiplying
    // by 12 (the number of grade intervals), and rounding to get an array index.
    //
    // Examples:
    //   goodness = 100  ->  normalized = 1.0  ->  index = 12  ->  "A+"
    //   goodness = 50   ->  normalized = 0.5  ->  index = 6   ->  "C+"
    //   goodness = 0    ->  normalized = 0.0  ->  index = 0   ->  "F"

    /// The 13 letter grades from worst (`"F"`, index 0) to best (`"A+"`, index 12).
    ///
    /// This array matches the firmware's `cat_air.c` grade table exactly, ensuring
    /// the grade shown on the device's e-ink display matches what the app displays.
    private static let grades = ["F", "D-", "D", "D+", "C-", "C", "C+", "B-", "B", "B+", "A-", "A", "A+"]

    /// Convert a goodness percentage (0-100) to a letter grade (`"F"` through `"A+"`).
    ///
    /// **Algorithm:**
    /// 1. Clamp goodness to [0, 100] to handle any edge cases.
    /// 2. Normalize to [0.0, 1.0] by dividing by 100.
    /// 3. Multiply by 12 (there are 13 grades, so 12 intervals) and round to the
    ///    nearest integer to get an index into the `grades` array.
    /// 4. Clamp the index to [0, 12] as a safety measure.
    ///
    /// - Parameter goodness: Air quality goodness from 0 (worst) to 100 (best).
    /// - Returns: A letter grade string like `"A+"`, `"B-"`, `"C"`, `"D+"`, or `"F"`.
    ///
    /// Ported from `aqi.ts` -> `goodnessToGrade()`.
    static func goodnessToGrade(_ goodness: Int) -> String {
        let normalized = Double(max(0, min(100, goodness))) / 100.0
        let index = Int((normalized * 12).rounded())
        return grades[max(0, min(12, index))]
    }

    /// Convert an individual sensor's badness score (0-5) to a letter grade.
    ///
    /// This is a convenience wrapper that first converts badness to goodness
    /// (`goodness = (5 - badness) / 5 * 100`), then delegates to `goodnessToGrade(_:)`.
    ///
    /// - Parameter badness: Sensor badness from 0.0 (ideal) to 5.0 (hazardous).
    /// - Returns: A letter grade string (e.g., badness 0.0 -> `"A+"`, badness 5.0 -> `"F"`).
    ///
    /// Ported from `aqi.ts` -> `sensorBadnessToGrade()`.
    static func sensorBadnessToGrade(_ badness: Double) -> String {
        // Convert badness (0-5) to goodness (0-100), clamping to valid range
        let goodness = Int(((5 - min(5, max(0, badness))) / 5.0 * 100).rounded())
        return goodnessToGrade(goodness)
    }
}
