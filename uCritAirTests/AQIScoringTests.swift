import Testing
import SwiftUI
@testable import uCritAir

/// Unit tests for the ``AQIScoring`` engine, covering individual sensor scoring curves
/// (CO2, temperature, humidity, PM2.5), letter-grade mapping, aggregate score computation,
/// and sensor status label/color assignment.
@Suite("AQI Scoring")
struct AQIScoringTests {

    // MARK: - Individual Sensor Scores

    @Test("CO2 scoring — 420 ppm is 0 (best)")
    func testCO2Good() {
        let score = AQIScoring.scoreCO2(420)
        #expect(abs(score) < 0.01)
    }

    @Test("CO2 scoring — 1000 ppm is 2")
    func testCO2Medium() {
        let score = AQIScoring.scoreCO2(1000)
        #expect(abs(score - 2.0) < 0.01)
    }

    @Test("CO2 scoring — 4500 ppm is 5 (worst)")
    func testCO2Bad() {
        let score = AQIScoring.scoreCO2(4500)
        #expect(abs(score - 5.0) < 0.01)
    }

    @Test("Temperature scoring — 25°C is 0 (optimal)")
    func testTempOptimal() {
        let score = AQIScoring.scoreTemperature(25)
        #expect(abs(score) < 0.01)
    }

    @Test("Temperature scoring — 0°C is 5 (worst)")
    func testTempCold() {
        let score = AQIScoring.scoreTemperature(0)
        #expect(abs(score - 5.0) < 0.01)
    }

    @Test("Humidity scoring — 50% is 0 (optimal)")
    func testHumidityOptimal() {
        let score = AQIScoring.scoreHumidity(50)
        #expect(abs(score) < 0.01)
    }

    @Test("PM2.5 scoring — 0 is 0 (best)")
    func testPM25Clean() {
        let score = AQIScoring.scorePM25(0)
        #expect(abs(score) < 0.01)
    }

    @Test("PM2.5 scoring — 35 is 3")
    func testPM25Moderate() {
        let score = AQIScoring.scorePM25(35)
        #expect(abs(score - 3.0) < 0.01)
    }

    @Test("PM10 scoring — 0 is 0 (best)")
    func testPM10Clean() {
        let score = AQIScoring.scorePM10(0)
        #expect(abs(score) < 0.01)
    }

    @Test("PM10 scoring — 100 is 3")
    func testPM10Moderate() {
        let score = AQIScoring.scorePM10(100)
        #expect(abs(score - 3.0) < 0.01)
    }

    @Test("PM10 scoring — 500+ is 5 (worst)")
    func testPM10Bad() {
        let score = AQIScoring.scorePM10(500)
        #expect(abs(score - 5.0) < 0.01)
    }

    // MARK: - Letter Grades

    @Test("goodnessToGrade — 100 is A+")
    func testGradeMax() {
        #expect(AQIScoring.goodnessToGrade(100) == "A+")
    }

    @Test("goodnessToGrade — 0 is F")
    func testGradeMin() {
        #expect(AQIScoring.goodnessToGrade(0) == "F")
    }

    @Test("goodnessToGrade — 50 is C")
    func testGradeMid() {
        let grade = AQIScoring.goodnessToGrade(50)
        #expect(grade == "C" || grade == "C+" || grade == "C-")
    }

    // MARK: - Aggregate Score

    @Test("Aggregate — all clean sensors")
    func testAggregateClean() {
        let sensors = SensorValues(
            temperature: 23, humidity: 50, co2: 400,
            pm1_0: 1, pm2_5: 2, pm4_0: 3, pm10: 4,
            pressure: 1013, voc: 50, nox: 0
        )
        let result = AQIScoring.computeAQScore(sensors)
        #expect(result.goodness >= 80)
        #expect(result.label == "Good")
    }

    @Test("Aggregate — high CO2 pollutant")
    func testAggregateHighCO2() {
        let sensors = SensorValues(
            temperature: 23, humidity: 50, co2: 4500,
            pm1_0: 0, pm2_5: 0, pm4_0: 0, pm10: 0,
            pressure: 1013, voc: 0, nox: 0
        )
        let result = AQIScoring.computeAQScore(sensors)
        #expect(result.goodness <= 20)
        #expect(result.label == "Bad")
    }

    @Test("Aggregate — empty sensors")
    func testAggregateEmpty() {
        let sensors = SensorValues.empty
        let result = AQIScoring.computeAQScore(sensors)
        #expect(result.goodness == 100)
        #expect(result.grade == "A+")
    }

    // MARK: - Sensor Status

    @Test("sensorStatus — good")
    func testSensorStatusGood() {
        let status = AQIScoring.sensorStatus(0.5)
        #expect(status.label == "Good")
    }

    @Test("sensorStatus — bad")
    func testSensorStatusBad() {
        let status = AQIScoring.sensorStatus(4.0)
        #expect(status.label == "Bad")
    }
}
