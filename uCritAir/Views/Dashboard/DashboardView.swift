// ────────────────────────────────────────────────────────────────────────────
// DashboardView.swift
// uCritAir
// ────────────────────────────────────────────────────────────────────────────
//
// PURPOSE:
//   The Dashboard is the app's home screen and the first thing the user sees.
//   It lives in the "Dashboard" tab (tab index 0) inside the root TabView
//   defined in ContentView.swift.
//
//   When a BLE device is connected, the dashboard displays:
//     - A large circular air-quality gauge (AQGaugeView) at the top
//     - An 8-card grid of individual sensor readings (SensorCardView)
//
//   When no device is connected, it shows a friendly placeholder that
//   prompts the user to pair a device, or directs them to iOS Settings
//   if Bluetooth is disabled.
//
//   Tapping any sensor card navigates the user to the History tab (tab 1)
//   with that sensor pre-selected for charting.
//
// SWIFTUI CONCEPTS USED:
//   - @Binding: A two-way connection to state owned by a parent view.
//     Here, `selectedTab` lets this view switch the active tab.
//   - @Environment: Reads shared objects from the SwiftUI environment.
//     The four environment objects are created in uCritAirApp.swift and
//     injected via `.environment()` modifiers.
//   - ScrollView / VStack / LazyVGrid: Layout containers. LazyVGrid only
//     creates child views as they scroll into view, improving performance.
//   - .accessibilityLabel: Provides VoiceOver descriptions for users
//     who rely on screen readers.
//
// ────────────────────────────────────────────────────────────────────────────

import SwiftUI

/// The main dashboard view that serves as the app's home screen.
///
/// This view is the first tab in the app's TabView and provides an at-a-glance
/// overview of indoor air quality. It has two visual states:
///
/// 1. **Connected** — Shows a hero AQ gauge and an 8-card sensor grid.
/// 2. **Disconnected** — Shows a placeholder prompting the user to pair a device.
///
/// ## Dependencies
/// - `SensorViewModel`: Supplies the latest sensor readings to display.
/// - `DeviceViewModel`: Provides Bluetooth availability status messages.
/// - `BLEManager`: Supplies the current BLE connection state.
/// - `HistoryViewModel`: Receives the selected sensor key when the user taps a card.
///
/// ## Navigation
/// Tapping a sensor card sets `historyVM.selectedSensor` and switches to the
/// History tab, letting users drill into that sensor's chart.
struct DashboardView: View {

    // MARK: - Properties

    /// A two-way binding to the selected tab index in the parent TabView.
    ///
    /// **SwiftUI concept — @Binding:**
    /// A `@Binding` does not own the data; it borrows it from a parent view.
    /// When this view writes to `selectedTab`, the parent's `@State` updates,
    /// causing the TabView to switch tabs. This is how tapping a sensor card
    /// navigates the user to the History tab (index 1).
    @Binding var selectedTab: Int

    /// The sensor view model that provides the latest readings for all 8 sensors.
    ///
    /// **SwiftUI concept — @Environment:**
    /// `@Environment` reads a shared object that was injected higher in the
    /// view hierarchy using `.environment()`. Here, `SensorViewModel` is created
    /// once in `uCritAirApp` and shared across the entire app. Any view that
    /// reads it will automatically re-render when its published properties change.
    @Environment(SensorViewModel.self) private var sensorVM

    /// The device view model that provides Bluetooth status messages and device info.
    @Environment(DeviceViewModel.self) private var deviceVM

    /// The BLE manager that provides the current connection state (connected/disconnected/etc.).
    @Environment(BLEManager.self) private var bleManager

    /// The history view model — used to pre-select a sensor when navigating to the History tab.
    @Environment(HistoryViewModel.self) private var historyVM

    /// Grid layout definition for the sensor cards.
    ///
    /// `GridItem(.adaptive(minimum: 150))` tells `LazyVGrid` to fit as many
    /// columns as possible, with each column at least 150 points wide. On an
    /// iPhone this typically produces 2 columns; on an iPad it may produce 3–4.
    private let columns = [
        GridItem(.adaptive(minimum: 150), spacing: 12),
    ]

    // MARK: - Body

    /// The main view body — a scrollable container that conditionally shows either
    /// the connected dashboard or the disconnected placeholder.
    ///
    /// **SwiftUI concept — conditional rendering:**
    /// The `if/else` inside the `VStack` causes SwiftUI to build a completely
    /// different view tree depending on the connection state. When the state
    /// changes, SwiftUI animates the transition automatically.
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // StatusBanner shows reconnecting/error banners at the top of the dashboard.
                StatusBanner()

                // Conditionally render based on BLE connection state.
                if bleManager.connectionState == .disconnected {
                    disconnectedView
                } else {
                    connectedView
                }
            }
            .padding()
        }
        // Use the system grouped background color for visual consistency with List views.
        .background(Color(.systemGroupedBackground))
    }

    // MARK: - Disconnected

    /// Placeholder shown when no BLE device is connected, prompting the user to pair.
    ///
    /// This view handles two sub-cases:
    /// 1. **Bluetooth is off or unauthorized** — Shows a warning message (from
    ///    `deviceVM.bluetoothStatusMessage`) and an "Open Settings" button that
    ///    deep-links to the iOS Settings app so the user can enable Bluetooth.
    /// 2. **Bluetooth is available but no device paired** — Shows a generic
    ///    "No device connected" message prompting the user to tap Connect.
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

    // MARK: - Connected

    /// Main dashboard content shown when a BLE device is connected.
    ///
    /// Displays two main sections:
    /// 1. **Hero AQ Gauge** — A large circular gauge (`AQGaugeView`) showing the
    ///    overall air quality score and letter grade.
    /// 2. **Sensor Grid** — A responsive 2-column grid of 8 sensor cards, each
    ///    showing the current reading, unit, quality grade, and a mini sparkline.
    ///
    /// **Interaction:** Tapping any sensor card writes the sensor key to
    /// `historyVM.selectedSensor` and sets `selectedTab = 1` (History tab).
    /// This cross-tab navigation pattern uses the `@Binding` on `selectedTab`.
    ///
    /// **SwiftUI concept — LazyVGrid:**
    /// `LazyVGrid` is a layout container that arranges its children in a grid.
    /// Unlike a regular `VStack`, it only instantiates views that are currently
    /// visible on screen, which improves performance for large collections.
    /// The `columns` array defines how many columns to use and their sizing.
    private var connectedView: some View {
        VStack(spacing: 16) {
            // Hero AQ Score — the large circular gauge at the top of the dashboard.
            AQGaugeView()
                .padding()
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 16))

            // Sensor grid — 8 tappable cards arranged in an adaptive grid.
            // Each card is wrapped in a Button so the user can tap to navigate
            // to the History tab with that sensor pre-selected for charting.
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(sensorItems, id: \.key) { item in
                    Button {
                        // Set the selected sensor in HistoryViewModel so the
                        // chart view knows which sensor to display.
                        historyVM.selectedSensor = item.key
                        // Switch to the History tab (index 1) via the @Binding.
                        selectedTab = 1
                    } label: {
                        SensorCardView(item: item)
                    }
                    // .plain button style removes the default highlight effect,
                    // letting SensorCardView control its own visual appearance.
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(item.label): \(item.value) \(item.unit)")
                }
            }
        }
    }

    // MARK: - Sensor Items

    /// Builds the array of 8 sensor display items from the current sensor readings.
    ///
    /// Each `SensorItem` bundles together everything a `SensorCardView` needs:
    /// - `key`: A string identifier (e.g., "co2", "pm2_5") used to look up
    ///   history data and navigate to the correct chart.
    /// - `label`: A human-readable name shown on the card header.
    /// - `value`: The formatted current reading (e.g., "423", "22.5").
    /// - `unit`: The measurement unit (e.g., "ppm", "°C").
    /// - `score`: An optional "badness" score from 0 (excellent) to 5 (hazardous),
    ///   computed by `AQIScoring`. Pressure has no scoring curve, so it is `nil`.
    ///
    /// The 8 sensors are: CO2, PM2.5, PM10, Temperature, Humidity, VOC, NOx, Pressure.
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

/// A lightweight data model for a single sensor card displayed on the Dashboard.
///
/// `SensorItem` is a plain value type (struct) that holds everything the
/// `SensorCardView` needs to render one card. It conforms to `Identifiable`
/// so that `ForEach` can efficiently diff the list when sensor data updates.
///
/// ## Properties
/// - `key`: A machine-readable identifier (e.g., "co2", "pm2_5") used to
///   look up historical data and navigate to the correct chart.
/// - `label`: A short human-readable name displayed in the card header
///   (e.g., "CO₂", "PM2.5", "Temp").
/// - `value`: The formatted sensor reading as a string (e.g., "423", "22.5").
/// - `unit`: The measurement unit (e.g., "ppm", "µg/m³", "°C").
/// - `score`: An optional "badness" value from 0.0 (excellent) to 5.0
///   (hazardous), used to determine the letter grade and status color.
///   Sensors without a scoring curve (like pressure) have `nil`.
struct SensorItem: Identifiable {
    /// Conformance to `Identifiable` — uses the sensor key as a stable ID.
    var id: String { key }
    let key: String
    let label: String
    let value: String
    let unit: String
    let score: Double?  // badness 0-5, nil if no scoring curve
}
