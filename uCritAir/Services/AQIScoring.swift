import SwiftUI

/// Air quality scoring algorithms matching the firmware (cat_air.c) and web app.
/// Direct port of src/lib/aqi.ts
enum AQIScoring {

    // MARK: - Piecewise Linear Interpolation

    /// Evaluate a piecewise linear function defined by sorted control points.
    ///
    /// Values outside the domain are clamped to the first or last point's y-value.
    ///
    /// - Parameters:
    ///   - points: Control points sorted ascending by x, each as `(x, y)`.
    ///   - x: The input value to interpolate.
    /// - Returns: The interpolated y-value.
    private static func lerp(_ points: [(Double, Double)], _ x: Double) -> Double {
        if x <= points[0].0 { return points[0].1 }
        if x >= points[points.count - 1].0 { return points[points.count - 1].1 }
        for i in 1..<points.count {
            if x <= points[i].0 {
                let (x0, y0) = points[i - 1]
                let (x1, y1) = points[i]
                return y0 + (y1 - y0) * ((x - x0) / (x1 - x0))
            }
        }
        return points[points.count - 1].1
    }

    // MARK: - Scoring Curves (0 = best, 5 = worst)

    /// Temperature badness curve (C). Comfort band ~20-25 C scores 0; extremes score 5.
    private static let tempCurve: [(Double, Double)] = [
        (0, 5), (8, 5), (16, 4), (18, 3), (20, 1), (25, 0), (27, 1), (29, 3), (34, 4), (35, 5),
    ]
    /// Relative humidity badness curve (%). Comfort band ~40-50% scores 0; extremes score 5.
    private static let rhCurve: [(Double, Double)] = [
        (0, 5), (14, 5), (23, 4), (30, 3), (40, 1), (50, 0), (60, 1), (65, 3), (80, 4), (85, 5),
    ]
    /// CO2 badness curve (ppm). Outdoor baseline ~420 ppm scores 0; 4500+ scores 5.
    private static let co2Curve: [(Double, Double)] = [
        (0, 0), (420, 0), (800, 1), (1000, 2), (1400, 3), (4500, 5),
    ]
    /// PM2.5 badness curve (ug/m3). Based on WHO/EPA breakpoints; 150+ scores 5.
    private static let pm25Curve: [(Double, Double)] = [
        (0, 0), (5, 1), (12, 2), (35, 3), (55, 4), (150, 5),
    ]
    /// PM10 badness curve (ug/m3). Thresholds ~3x PM2.5 per WHO/EPA guidelines; 500+ scores 5.
    private static let pm10Curve: [(Double, Double)] = [
        (0, 0), (15, 1), (45, 2), (100, 3), (200, 4), (500, 5),
    ]
    /// NOx index badness curve. Sensirion NOx index units; 310+ scores 5.
    private static let noxCurve: [(Double, Double)] = [
        (0, 0), (1, 0.5), (90, 2), (150, 3), (300, 4), (310, 5),
    ]
    /// VOC index badness curve. Sensirion VOC index units; 410+ scores 5.
    private static let vocCurve: [(Double, Double)] = [
        (0, 0), (100, 0.5), (150, 2), (250, 3), (400, 4), (410, 5),
    ]

    // MARK: - Individual Sensor Scores

    static func scoreTemperature(_ v: Double) -> Double { lerp(tempCurve, v) }
    static func scoreHumidity(_ v: Double) -> Double { lerp(rhCurve, v) }
    static func scoreCO2(_ v: Double) -> Double { lerp(co2Curve, v) }
    static func scorePM25(_ v: Double) -> Double { lerp(pm25Curve, v) }
    static func scorePM10(_ v: Double) -> Double { lerp(pm10Curve, v) }
    static func scoreNOx(_ v: Double) -> Double { lerp(noxCurve, v) }
    static func scoreVOC(_ v: Double) -> Double { lerp(vocCurve, v) }

    // MARK: - Aggregate Score

    /// Compute aggregate IAQ score matching firmware algorithm.
    /// Returns badness (0-5) and goodness (0-100%).
    /// Ported from aqi.ts → computeAQScore()
    static func computeAQScore(_ sensors: SensorValues) -> AQScoreResult {
        let scores = (
            co2: sensors.co2.map { scoreCO2($0) } ?? 0,
            pm25: sensors.pm2_5.map { scorePM25($0) } ?? 0,
            nox: sensors.nox.map { scoreNOx($0) } ?? 0,
            voc: sensors.voc.map { scoreVOC($0) } ?? 0,
            temp: sensors.temperature.map { scoreTemperature($0) } ?? 0,
            rh: sensors.humidity.map { scoreHumidity($0) } ?? 0
        )

        // Base score = worst pollutant
        var baseScore = max(scores.co2, scores.pm25, scores.nox, scores.voc)

        // Multiple pollutants penalty
        let pollutantScores = [scores.co2, scores.pm25, scores.nox, scores.voc]
        let badCount = pollutantScores.filter { $0 > 3 }.count
        if badCount > 1 {
            baseScore += Double(badCount - 1) * 0.5
        }

        // Temperature & humidity multipliers
        let tempMult = 1.0 + max(0, scores.temp - 1.0) * 0.1
        let rhMult = 1.0 + max(0, scores.rh - 1.0) * 0.1

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

    /// Map a goodness percentage (0-100) to a semantic color.
    ///
    /// - Parameter goodness: Aggregate goodness value where 100 is best.
    /// - Returns: A themed color from `.aqGood` (>=80) to `.aqBad` (<40).
    static func goodnessColor(_ goodness: Int) -> Color {
        if goodness >= 80 { return .aqGood }
        if goodness >= 60 { return .aqFair }
        if goodness >= 40 { return .aqPoor }
        return .aqBad
    }

    /// Map a goodness percentage (0-100) to a human-readable label.
    ///
    /// - Parameter goodness: Aggregate goodness value where 100 is best.
    /// - Returns: `"Good"`, `"Fair"`, `"Poor"`, or `"Bad"`.
    static func goodnessLabel(_ goodness: Int) -> String {
        if goodness >= 80 { return "Good" }
        if goodness >= 60 { return "Fair" }
        if goodness >= 40 { return "Poor" }
        return "Bad"
    }

    /// Individual sensor score → color and label.
    /// Ported from aqi.ts → sensorStatus()
    static func sensorStatus(_ score: Double) -> (color: Color, label: String) {
        if score <= 1 { return (.aqGood, "Good") }
        if score <= 2 { return (.aqFair, "Fair") }
        if score <= 3 { return (.aqPoor, "Poor") }
        return (.aqBad, "Bad")
    }

    // MARK: - Letter Grades

    /// 13 letter grades from `F` to `A+`, matching the firmware's `cat_air.c` grade table.
    private static let grades = ["F", "D-", "D", "D+", "C-", "C", "C+", "B-", "B", "B+", "A-", "A", "A+"]

    /// Map goodness (0-100) to a letter grade (F through A+).
    /// Ported from aqi.ts → goodnessToGrade()
    static func goodnessToGrade(_ goodness: Int) -> String {
        let normalized = Double(max(0, min(100, goodness))) / 100.0
        let index = Int((normalized * 12).rounded())
        return grades[max(0, min(12, index))]
    }

    /// Map individual sensor badness (0-5) to a letter grade.
    /// Ported from aqi.ts → sensorBadnessToGrade()
    static func sensorBadnessToGrade(_ badness: Double) -> String {
        let goodness = Int(((5 - min(5, max(0, badness))) / 5.0 * 100).rounded())
        return goodnessToGrade(goodness)
    }
}
