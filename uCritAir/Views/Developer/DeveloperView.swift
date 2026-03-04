import SwiftUI
import CoreBluetooth
import os.log

/// Developer tools view providing Time Sync, Raw BLE Inspector, and Log Cell Inspector.
///
/// Ported from the web app's Developer.tsx page. Provides low-level device access
/// for debugging firmware behavior, inspecting BLE characteristics, and reading
/// individual log cells.
struct DeveloperToolsView: View {
    @Environment(DeviceViewModel.self) private var deviceVM

    var body: some View {
        List {
            timeSyncSection
            bleInspectorSection
            cellInspectorSection
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Developer")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                ConnectButton()
            }
            ToolbarItem(placement: .keyboard) {
                Button("Done") { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    // MARK: - Time Sync

    @State private var readTimeResult: String?
    @State private var customTimeText = ""
    @State private var timeStatus: String?

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

    // MARK: - Raw BLE Inspector

    @State private var selectedCharIndex: Int = 0
    @State private var useCustomUUID = false
    @State private var customUUIDText = ""
    @State private var readHexResult: String?
    @State private var readDecodedResult: String?
    @State private var writeHexText = ""
    @State private var inspectorStatus: String?

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

    /// The CBUUID resolved from either the picker selection or custom UUID input.
    /// Returns `nil` for empty or invalid custom UUID strings.
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

    /// Read the selected characteristic and display hex + decoded result.
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

    /// Write hex input to the selected characteristic.
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

    /// Auto-decode known characteristic data for display.
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

    // MARK: - Log Cell Inspector

    @State private var cellIndexText = ""
    @State private var cellResult: String?
    @State private var cellError: String?

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
