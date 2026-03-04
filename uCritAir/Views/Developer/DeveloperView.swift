// ────────────────────────────────────────────────────────────────────────────
// DeveloperView.swift
// uCritAir
// ────────────────────────────────────────────────────────────────────────────
//
// PURPOSE:
//   **This is a debugging and development tool, NOT intended for end users.**
//
//   The Developer tab (tab index 3 in the root TabView) provides low-level
//   access to the BLE device for firmware developers and hardware engineers.
//   It is used to:
//
//   - Diagnose firmware issues by reading/writing raw BLE characteristics.
//   - Inspect the device's internal clock and synchronize it.
//   - Read individual log cells to verify data integrity.
//
//   The view is organized into three sections:
//
//   1. **Time Sync** — Read the device's current time, sync it to the host
//      (phone) time, or write an arbitrary Unix timestamp for testing.
//
//   2. **Raw BLE Inspector** — Select any known BLE characteristic from a
//      picker (or enter a custom UUID), read its raw hex bytes, see a decoded
//      human-readable value, and write raw hex data. This is essential for
//      debugging the BLE protocol between the iOS app and the firmware.
//
//   3. **Log Cell Inspector** — Read a single log cell by index number and
//      display all its fields (timestamp, CO2, temperature, humidity, PM, etc.)
//      in a monospaced text view. Useful for verifying that the firmware is
//      writing correct data to the log.
//
//   In a production release, this tab could be hidden behind a developer
//   settings toggle. It currently ships visible for development convenience.
//
// SWIFTUI CONCEPTS USED:
//   - @Environment: Reads the shared DeviceViewModel.
//   - @State: Manages many independent pieces of local UI state (text fields,
//     results, status messages, picker selections, toggle states).
//   - List / Section: Groups related controls into a scrollable form layout.
//   - Picker: A selection control for choosing a BLE characteristic.
//   - Toggle: Switches between the known-characteristic picker and custom UUID input.
//   - TextField: Text input for UUIDs, hex data, timestamps, and cell numbers.
//   - Task { await ... }: Runs async BLE operations from button actions.
//   - .textSelection(.enabled): Allows the user to long-press and copy text
//     from result displays (useful for sharing debug output).
//
// ────────────────────────────────────────────────────────────────────────────

import SwiftUI
import CoreBluetooth
import os.log

/// A developer-only debugging tool providing raw BLE access, time sync, and log cell inspection.
///
/// **Important:** This view is intended for firmware developers and hardware engineers,
/// not for end users. It exposes low-level BLE operations that can modify device state.
///
/// The view has three sections:
/// - **Time Sync**: Read, sync, or manually set the device's internal clock.
/// - **Raw BLE Inspector**: Read/write arbitrary BLE characteristics by UUID.
/// - **Log Cell Inspector**: Read individual log cells by index for data verification.
///
/// ## Dependencies
/// - `DeviceViewModel`: Provides access to the BLE manager, device info (cell count),
///   and methods for reading/writing device characteristics.
struct DeveloperToolsView: View {

    // MARK: - Environment

    /// The shared device view model providing BLE access and device state.
    @Environment(DeviceViewModel.self) private var deviceVM

    // MARK: - Body

    /// The main view body — a List-based form with three debugging sections.
    var body: some View {
        List {
            timeSyncSection
            bleInspectorSection
            cellInspectorSection
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Developer")
        .toolbar {
            // Leading: BLE connect/disconnect button.
            ToolbarItem(placement: .topBarLeading) {
                ConnectButton()
            }
            // Keyboard: "Done" button to dismiss the keyboard.
            ToolbarItem(placement: .keyboard) {
                Button("Done") { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Time Sync Section
    // ═══════════════════════════════════════════════════════════════════════
    //
    // Allows developers to read the device's internal clock, sync it to the
    // phone's current time, or write an arbitrary Unix timestamp for testing.
    // The device stores time as a 32-bit Unix timestamp (seconds since 1970).

    /// The result of the last "Read Time" operation (e.g., "1709123456 — Feb 28, 2024 12:30:56").
    @State private var readTimeResult: String?

    /// The custom Unix timestamp text entered by the user for the "Set" button.
    @State private var customTimeText = ""

    /// A status message displayed after time operations (success or error).
    @State private var timeStatus: String?

    /// The Time Sync section UI — buttons for reading, syncing, and setting the device clock.
    private var timeSyncSection: some View {
        Section("Time Sync") {
            HStack {
                Button("Read Time") {
                    Task {
                        do {
                            guard let manager = deviceVM.bleManager else { return }
                            let t = try await BLECharacteristics.readTime(using: manager)
                            readTimeResult = "\(t) — \(UnitFormatters.fmtDateTime(t))"
                            timeStatus = nil
                        } catch {
                            timeStatus = "Read failed: \(error.localizedDescription)"
                        }
                    }
                }
                .buttonStyle(.bordered)

                Button("Sync to Host") {
                    Task {
                        await deviceVM.syncTime()
                        if let t = deviceVM.deviceTime {
                            timeStatus = "Synced: \(UnitFormatters.fmtDateTime(t))"
                        }
                    }
                }
                .buttonStyle(.bordered)
            }

            if let result = readTimeResult {
                LabeledContent("Device Time", value: result)
            }

            HStack {
                TextField("Unix timestamp", text: $customTimeText)
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)
                Button("Set") {
                    guard let value = UInt32(customTimeText) else {
                        timeStatus = "Invalid timestamp"
                        return
                    }
                    Task {
                        await deviceVM.writeTime(value)
                        timeStatus = "Set to: \(UnitFormatters.fmtDateTime(value))"
                    }
                }
                .buttonStyle(.bordered)
            }

            if let status = timeStatus {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Raw BLE Inspector Section
    // ═══════════════════════════════════════════════════════════════════════
    //
    // The BLE Inspector lets developers read and write raw BLE characteristic
    // data. It operates in two modes:
    //
    // 1. **Known Characteristic mode** (default): A Picker lists all
    //    characteristics defined in `KnownCharacteristics.all`, showing
    //    their label, access mode (read/write/readWrite), format, and UUID.
    //
    // 2. **Custom UUID mode**: A text field accepts a 4-character short UUID
    //    (e.g., "2A6E") or a full 36-character UUID string.
    //
    // After reading, the raw hex bytes are displayed, plus a "Decoded" line
    // that uses type-specific parsers (e.g., temperature from 2 bytes,
    // device name from UTF-8 string, config struct from 16 bytes).

    /// The index of the currently selected characteristic in `KnownCharacteristics.all`.
    @State private var selectedCharIndex: Int = 0

    /// Whether the inspector is in custom UUID mode (true) vs. known characteristic mode (false).
    @State private var useCustomUUID = false

    /// The custom UUID string entered by the user (e.g., "2A6E" or a full UUID).
    @State private var customUUIDText = ""

    /// The raw hex bytes result from the last read operation (e.g., "CA 7D F0 01").
    @State private var readHexResult: String?

    /// The human-readable decoded result from the last read operation (e.g., "423 ppm").
    @State private var readDecodedResult: String?

    /// The hex bytes to write, entered by the user (e.g., "CA 7D F0").
    @State private var writeHexText = ""

    /// An error or status message from the last inspector operation.
    @State private var inspectorStatus: String?

    /// The Raw BLE Inspector section UI.
    private var bleInspectorSection: some View {
        Section("Raw BLE Inspector") {
            // Characteristic picker
            Toggle("Custom UUID", isOn: $useCustomUUID)

            if useCustomUUID {
                TextField("UUID (e.g. 2A6E)", text: $customUUIDText)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.characters)
            } else {
                Picker("Characteristic", selection: $selectedCharIndex) {
                    ForEach(Array(KnownCharacteristics.all.enumerated()), id: \.offset) { idx, def in
                        Text("\(def.label) (\(def.access.rawValue))")
                            .tag(idx)
                    }
                }

                if selectedCharIndex < KnownCharacteristics.all.count {
                    let def = KnownCharacteristics.all[selectedCharIndex]
                    LabeledContent("Format", value: def.format)
                    LabeledContent("UUID", value: def.uuid.uuidString)
                        .font(.caption2)
                }
            }

            // Read button
            HStack {
                Button("Read") {
                    Task { await performRead() }
                }
                .buttonStyle(.bordered)
                .disabled(resolvedAccess == .write)

                Button("Write") {
                    Task { await performWrite() }
                }
                .buttonStyle(.bordered)
                .disabled(resolvedAccess == .read || writeHexText.isEmpty)
            }

            // Write input
            if resolvedAccess != .read {
                TextField("Hex bytes (e.g. CA 7D F0)", text: $writeHexText)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.characters)
            }

            // Results
            if let hex = readHexResult {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Raw:").font(.caption.bold())
                    Text(hex)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
            }

            if let decoded = readDecodedResult {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Decoded:").font(.caption.bold())
                    Text(decoded)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
            }

            if let status = inspectorStatus {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    /// Resolves the currently selected BLE characteristic UUID.
    ///
    /// In custom UUID mode, parses the user's text input into a `CBUUID`.
    /// In known characteristic mode, returns the UUID from the picker selection.
    /// Returns `nil` if the input is invalid or the picker index is out of bounds.
    private var resolvedUUID: CBUUID? {
        if useCustomUUID {
            let text = customUUIDText.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty, isValidUUIDString(text) else { return nil }
            return CBUUID(string: text)
        }
        guard selectedCharIndex < KnownCharacteristics.all.count else { return nil }
        return KnownCharacteristics.all[selectedCharIndex].uuid
    }

    /// Validate that a string is acceptable for `CBUUID(string:)`.
    /// Accepts 4-char short UUIDs (e.g. "2A6E") and full 36-char UUIDs with dashes.
    private func isValidUUIDString(_ text: String) -> Bool {
        let hex = CharacterSet(charactersIn: "0123456789ABCDEFabcdef")
        let hexDash = CharacterSet(charactersIn: "0123456789ABCDEFabcdef-")
        if text.count == 4 {
            return text.unicodeScalars.allSatisfy { hex.contains($0) }
        }
        if text.count == 36 {
            return text.unicodeScalars.allSatisfy { hexDash.contains($0) }
        }
        // Also allow 8-char (32-bit) short UUIDs
        if text.count == 8 {
            return text.unicodeScalars.allSatisfy { hex.contains($0) }
        }
        return false
    }

    /// The access mode for the currently selected characteristic.
    private var resolvedAccess: CharAccess {
        if useCustomUUID { return .readWrite }
        guard selectedCharIndex < KnownCharacteristics.all.count else { return .readWrite }
        return KnownCharacteristics.all[selectedCharIndex].access
    }

    /// Reads the selected BLE characteristic and displays the raw hex bytes and decoded value.
    ///
    /// This is the core "Read" action in the BLE Inspector. It:
    /// 1. Resolves the UUID (from picker or custom input).
    /// 2. Calls `manager.readCharacteristic()` to perform the BLE read.
    /// 3. Displays the raw hex bytes (e.g., "CA 7D F0 01").
    /// 4. Attempts to decode the bytes into a human-readable string using
    ///    `decodeCharacteristic()` (e.g., "423 ppm" for CO2).
    ///
    /// `@MainActor` ensures this runs on the main thread (required for UI updates).
    @MainActor
    private func performRead() async {
        guard let uuid = resolvedUUID, let manager = deviceVM.bleManager else {
            inspectorStatus = "No UUID or not connected"
            return
        }
        inspectorStatus = nil
        readDecodedResult = nil
        do {
            let data = try await manager.readCharacteristic(uuid)
            readHexResult = data.hexString
            readDecodedResult = decodeCharacteristic(uuid: uuid, data: data)
        } catch {
            inspectorStatus = "Read failed: \(error.localizedDescription)"
            readHexResult = nil
        }
    }

    /// Writes raw hex bytes to the selected BLE characteristic.
    ///
    /// Parses the user's hex string input (e.g., "CA 7D F0") into `Data`,
    /// writes it to the device, and then auto-reads the characteristic to
    /// show the result (useful for verifying the write succeeded).
    @MainActor
    private func performWrite() async {
        guard let uuid = resolvedUUID, let manager = deviceVM.bleManager else {
            inspectorStatus = "No UUID or not connected"
            return
        }
        guard let data = Data.fromHexString(writeHexText) else {
            inspectorStatus = "Invalid hex string"
            return
        }
        inspectorStatus = nil
        do {
            try await manager.writeCharacteristic(uuid, data: data)
            inspectorStatus = nil
            // Auto-read after write to show result
            if resolvedAccess != .write {
                await performRead()
            }
        } catch {
            inspectorStatus = "Write failed: \(error.localizedDescription)"
        }
    }

    /// Attempts to decode raw BLE characteristic data into a human-readable string.
    ///
    /// Uses the characteristic's UUID to determine how to interpret the bytes.
    /// For example:
    /// - Device name / pet name: decoded as UTF-8 string.
    /// - Temperature: 2 bytes decoded as a signed 16-bit integer / 100.
    /// - Config: 16 bytes decoded into all configuration fields.
    ///
    /// Returns `nil` for unknown UUIDs or if the data is too short.
    private func decodeCharacteristic(uuid: CBUUID, data: Data) -> String? {
        switch uuid {
        case BLEConstants.charDeviceName, BLEConstants.charPetName:
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: CharacterSet(charactersIn: "\0"))

        case BLEConstants.charTime:
            guard data.count >= 4 else { return nil }
            let t = data.readUInt32LE(at: 0)
            return "\(t) — \(UnitFormatters.fmtDateTime(t))"

        case BLEConstants.charCellCount, BLEConstants.charBonus:
            guard data.count >= 4 else { return nil }
            return "\(data.readUInt32LE(at: 0))"

        case BLEConstants.charStats:
            guard data.count >= 6 else { return nil }
            let s = BLEParsers.parseStats(data)
            return "V:\(s.vigour) F:\(s.focus) S:\(s.spirit) Age:\(s.age) Int:\(s.interventions)"

        case BLEConstants.charItemsOwned, BLEConstants.charItemsPlaced:
            return "\(BLEParsers.countBitmapItems(data)) items"

        case BLEConstants.charDeviceConfig:
            guard data.count >= 16 else { return nil }
            let c = DeviceConfig.parse(from: data)
            return "sensor:\(c.sensorWakeupPeriod)s sleep:\(c.sleepAfterSeconds)s dim:\(c.dimAfterSeconds)s nox:\(c.noxSamplePeriod) bright:\(c.screenBrightness) flags:0x\(String(c.persistFlags.rawValue, radix: 16))"

        case BLEConstants.essTemperature:
            guard data.count >= 2 else { return nil }
            return "\(BLEParsers.parseTemperature(data)) °C"

        case BLEConstants.essHumidity:
            guard data.count >= 2 else { return nil }
            return "\(BLEParsers.parseHumidity(data)) %"

        case BLEConstants.essPressure:
            guard data.count >= 4 else { return nil }
            return "\(BLEParsers.parsePressure(data)) hPa"

        case BLEConstants.essCO2:
            guard data.count >= 2 else { return nil }
            return "\(BLEParsers.parseCO2(data)) ppm"

        case BLEConstants.essPM2_5, BLEConstants.essPM1_0, BLEConstants.essPM10:
            guard data.count >= 2 else { return nil }
            return "\(BLEParsers.parsePM(data)) µg/m³"

        default:
            return nil
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Log Cell Inspector Section
    // ═══════════════════════════════════════════════════════════════════════
    //
    // The Log Cell Inspector reads a single log cell from the device by its
    // index number and displays all parsed fields. This is useful for:
    // - Verifying that firmware is writing correct sensor data to the log.
    // - Debugging timestamp issues.
    // - Inspecting individual data points without downloading the entire log.
    //
    // A log cell contains: cell number, timestamp, flags, CO2, temperature,
    // humidity, pressure, PM1.0/2.5/4.0/10, VOC, NOx, and uncompensated CO2.

    /// The cell index number entered by the user.
    @State private var cellIndexText = ""

    /// The formatted result of the last cell read operation.
    @State private var cellResult: String?

    /// An error message from the last cell read operation.
    @State private var cellError: String?

    /// The Log Cell Inspector section UI — input field, read button, and results display.
    private var cellInspectorSection: some View {
        Section("Log Cell Inspector") {
            if let count = deviceVM.cellCount {
                Text("Device has \(count) cells (0–\(count > 0 ? count - 1 : 0))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                TextField("Cell #", text: $cellIndexText)
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)

                Button("Read") {
                    guard let index = UInt32(cellIndexText) else {
                        cellError = "Invalid cell number"
                        return
                    }
                    if let count = deviceVM.cellCount, index >= count {
                        cellError = "Cell index out of range (0–\(count - 1))"
                        return
                    }
                    cellError = nil
                    cellResult = nil
                    Task {
                        do {
                            let cell = try await deviceVM.readLogCell(at: index)
                            cellResult = formatCell(cell)
                        } catch {
                            cellError = "Read failed: \(error.localizedDescription)"
                        }
                    }
                }
                .buttonStyle(.bordered)
            }

            if let error = cellError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if let result = cellResult {
                Text(result)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
    }

    /// Format a parsed log cell into a human-readable key-value string.
    private func formatCell(_ cell: ParsedLogCell) -> String {
        """
        Cell #\(cell.cellNumber)
        Time: \(UnitFormatters.fmtDateTime(UInt32(clamping: cell.timestamp)))
        Flags: 0x\(String(cell.flags, radix: 16, uppercase: true))
        CO₂: \(cell.co2) ppm
        Temp: \(String(format: "%.2f", cell.temperature)) °C
        RH: \(String(format: "%.1f", cell.humidity)) %
        Pressure: \(String(format: "%.1f", cell.pressure)) hPa
        PM1.0: \(String(format: "%.1f", cell.pm.0)) µg/m³
        PM2.5: \(String(format: "%.1f", cell.pm.1)) µg/m³
        PM4.0: \(String(format: "%.1f", cell.pm.2)) µg/m³
        PM10: \(String(format: "%.1f", cell.pm.3)) µg/m³
        VOC: \(cell.voc)
        NOx: \(cell.nox)
        CO₂ uncomp: \(cell.co2Uncomp) ppm
        """
    }
}
