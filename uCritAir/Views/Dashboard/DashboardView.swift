import SwiftUI

/// Main dashboard showing hero AQ score and sensor grid.
/// Ported from src/pages/Dashboard.tsx
struct DashboardView: View {
    @Binding var selectedTab: Int
    @Environment(SensorViewModel.self) private var sensorVM
    @Environment(DeviceViewModel.self) private var deviceVM
    @Environment(BLEManager.self) private var bleManager
    @Environment(HistoryViewModel.self) private var historyVM

    private let columns = [
        GridItem(.adaptive(minimum: 150), spacing: 12),
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                StatusBanner()

                if bleManager.connectionState == .disconnected {
                    disconnectedView
                } else {
                    connectedView
                }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
    }

    // MARK: - Disconnected

    /// Placeholder shown when no BLE device is connected, prompting the user to pair.
    private var disconnectedView: some View {
        VStack(spacing: 12) {
            Spacer(minLength: 60)
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("No device connected")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Tap Connect to pair with your uCrit device")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
            Spacer(minLength: 60)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Connected

    /// Main dashboard content shown when a device is connected: hero AQ gauge and sensor card grid.
    private var connectedView: some View {
        VStack(spacing: 16) {
            // Hero AQ Score
            AQGaugeView()
                .padding()
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 16))

            // Sensor grid (matching web app's 8 cards)
            // Tap navigates to History tab with that sensor pre-selected.
            // Matches Dashboard.tsx → goToSensor(key)
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(sensorItems, id: \.key) { item in
                    Button {
                        historyVM.selectedSensor = item.key
                        selectedTab = 1
                    } label: {
                        SensorCardView(item: item)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(item.label): \(item.value) \(item.unit)")
                }
            }
        }
    }

    // MARK: - Sensor Items

    /// Build the 8 sensor items matching Dashboard.tsx.
    private var sensorItems: [SensorItem] {
        let c = sensorVM.current
        return [
            SensorItem(
                key: "co2", label: "CO\u{2082}",
                value: UnitFormatters.fmtCO2Value(c.co2), unit: "ppm",
                score: c.co2.map { AQIScoring.scoreCO2($0) }
            ),
            SensorItem(
                key: "pm2_5", label: "PM2.5",
                value: UnitFormatters.fmtPMValue(c.pm2_5), unit: "µg/m³",
                score: c.pm2_5.map { AQIScoring.scorePM25($0) }
            ),
            SensorItem(
                key: "pm10", label: "PM10",
                value: UnitFormatters.fmtPMValue(c.pm10), unit: "µg/m³",
                score: c.pm10.map { AQIScoring.scorePM10($0) }
            ),
            SensorItem(
                key: "temperature", label: "Temp",
                value: UnitFormatters.fmtTempValue(c.temperature), unit: "°C",
                score: c.temperature.map { AQIScoring.scoreTemperature($0) }
            ),
            SensorItem(
                key: "humidity", label: "Humidity",
                value: UnitFormatters.fmtHumidityValue(c.humidity), unit: "%",
                score: c.humidity.map { AQIScoring.scoreHumidity($0) }
            ),
            SensorItem(
                key: "voc", label: "VOC",
                value: UnitFormatters.fmtIndex(c.voc), unit: "index",
                score: c.voc.map { AQIScoring.scoreVOC($0) }
            ),
            SensorItem(
                key: "nox", label: "NOx",
                value: UnitFormatters.fmtIndex(c.nox), unit: "index",
                score: c.nox.map { AQIScoring.scoreNOx($0) }
            ),
            SensorItem(
                key: "pressure", label: "Pressure",
                value: UnitFormatters.fmtPressureValue(c.pressure), unit: "hPa",
                score: nil  // No scoring curve for pressure
            ),
        ]
    }
}

/// Data for a single sensor card.
struct SensorItem: Identifiable {
    var id: String { key }
    let key: String
    let label: String
    let value: String
    let unit: String
    let score: Double?  // badness 0-5, nil if no scoring curve
}
