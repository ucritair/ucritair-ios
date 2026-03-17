import SwiftUI

struct DashboardView: View {

    @Binding var selectedTab: Int

    @Environment(SensorViewModel.self) private var sensorVM

    @Environment(DeviceViewModel.self) private var deviceVM

    @Environment(BLEManager.self) private var bleManager

    @Environment(HistoryViewModel.self) private var historyVM

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @ScaledMetric(relativeTo: .body) private var sensorCardMinimumWidth = 150

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                StatusBanner()

                if dynamicTypeSize.usesAccessibilityLayout {
                    ConnectedDeviceHeader()
                }

                if bleManager.connectionState == .disconnected {
                    disconnectedView
                } else {
                    connectedView
                }
            }
            .padding()
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear
                .frame(height: AppChrome.customTabBarContentClearance)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .background(Color(.systemGroupedBackground))
        .accessibilityIdentifier("dashboardScreen")
    }

    private var disconnectedView: some View {
        VStack(spacing: 12) {
            Spacer(minLength: 60)
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            if let btMessage = deviceVM.bluetoothStatusMessage {
                Text(btMessage)
                    .font(.subheadline)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .buttonStyle(.bordered)
            } else {
                Text("No device connected")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Text("Tap Connect to pair with your uCrit device")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 60)
        }
        .frame(maxWidth: .infinity)
    }

    private var connectedView: some View {
        VStack(spacing: 16) {
            AQGaugeView()
                .padding()
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 16))

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
                    .accessibilityIdentifier("sensorCard_\(item.key)")
                }
            }
        }
    }

    private var columns: [GridItem] {
        if dynamicTypeSize.usesAccessibilityLayout {
            [GridItem(.flexible(), spacing: 12)]
        } else {
            [GridItem(.adaptive(minimum: sensorCardMinimumWidth), spacing: 12)]
        }
    }

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
                score: nil
            ),
        ]
    }
}

struct SensorItem: Identifiable {
    var id: String { key }
    let key: String
    let label: String
    let value: String
    let unit: String
    let score: Double?
}
