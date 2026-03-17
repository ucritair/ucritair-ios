import SwiftUI
import CoreBluetooth
import os.log

struct AdvancedView: View {

    @Environment(DeviceViewModel.self) private var deviceVM

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        List {
            if dynamicTypeSize.usesAccessibilityLayout && deviceVM.connectionState == .connected {
                Section {
                    ConnectedDeviceHeader()
                }
            }

            timeSyncSection
            bleInspectorSection
            cellInspectorSection
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Advanced")
        .accessibilityIdentifier("advancedScreen")
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

    @State private var readTimeResult: String?

    @State private var customTimeText = ""

    @State private var timeStatus: String?

    private var timeSyncSection: some View {
        Section("Time Sync") {
            ViewThatFits {
                HStack {
                    readTimeButton
                    syncToHostButton
                }

                VStack(alignment: .leading, spacing: 8) {
                    readTimeButton
                    syncToHostButton
                }
            }

            if let result = readTimeResult {
                keyValueRow(title: "Device Time", value: result)
            }

            ViewThatFits {
                HStack {
                    timeInputField
                    setTimeButton
                }

                VStack(alignment: .leading, spacing: 8) {
                    timeInputField
                    setTimeButton
                }
            }

            if let status = timeStatus {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var readTimeButton: some View {
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
        .minimumAccessibleTapTarget()
    }

    private var syncToHostButton: some View {
        Button("Sync to Host") {
            Task {
                await deviceVM.syncTime()
                if let t = deviceVM.deviceTime {
                    timeStatus = "Synced: \(UnitFormatters.fmtDateTime(t))"
                }
            }
        }
        .buttonStyle(.bordered)
        .minimumAccessibleTapTarget()
    }

    private var timeInputField: some View {
        TextField("Unix timestamp", text: $customTimeText)
            .keyboardType(.numberPad)
            .textFieldStyle(.roundedBorder)
    }

    private var setTimeButton: some View {
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
        .minimumAccessibleTapTarget()
    }

    @ViewBuilder
    private func keyValueRow(title: String, value: String) -> some View {
        if dynamicTypeSize.usesAccessibilityLayout {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(value)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            LabeledContent(title, value: value)
        }
    }

    @State private var selectedCharIndex: Int = 0

    @State private var useCustomUUID = false

    @State private var customUUIDText = ""

    @State private var readHexResult: String?

    @State private var readDecodedResult: String?

    @State private var writeHexText = ""

    @State private var inspectorStatus: String?

    private var bleInspectorSection: some View {
        Section("Raw BLE Inspector") {
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
                    keyValueRow(title: "Format", value: def.format)
                    keyValueRow(title: "UUID", value: def.uuid.uuidString)
                }
            }

            ViewThatFits {
                HStack {
                    readButton
                    writeButton
                }

                VStack(alignment: .leading, spacing: 8) {
                    readButton
                    writeButton
                }
            }

            if resolvedAccess != .read {
                TextField("Hex bytes (e.g. CA 7D F0)", text: $writeHexText)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.characters)
            }

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
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var readButton: some View {
        Button("Read") {
            Task { await performRead() }
        }
        .buttonStyle(.bordered)
        .disabled(resolvedAccess == .write)
        .minimumAccessibleTapTarget()
    }

    private var writeButton: some View {
        Button("Write") {
            Task { await performWrite() }
        }
        .buttonStyle(.bordered)
        .disabled(resolvedAccess == .read || writeHexText.isEmpty)
        .minimumAccessibleTapTarget()
    }

    private var resolvedUUID: CBUUID? {
        if useCustomUUID {
            let text = customUUIDText.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty, isValidUUIDString(text) else { return nil }
            return CBUUID(string: text)
        }
        guard selectedCharIndex < KnownCharacteristics.all.count else { return nil }
        return KnownCharacteristics.all[selectedCharIndex].uuid
    }

    private func isValidUUIDString(_ text: String) -> Bool {
        let hex = CharacterSet(charactersIn: "0123456789ABCDEFabcdef")
        let hexDash = CharacterSet(charactersIn: "0123456789ABCDEFabcdef-")
        if text.count == 4 {
            return text.unicodeScalars.allSatisfy { hex.contains($0) }
        }
        if text.count == 36 {
            return text.unicodeScalars.allSatisfy { hexDash.contains($0) }
        }
        if text.count == 8 {
            return text.unicodeScalars.allSatisfy { hex.contains($0) }
        }
        return false
    }

    private var resolvedAccess: CharAccess {
        if useCustomUUID { return .readWrite }
        guard selectedCharIndex < KnownCharacteristics.all.count else { return .readWrite }
        return KnownCharacteristics.all[selectedCharIndex].access
    }

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
            if resolvedAccess != .write {
                await performRead()
            }
        } catch {
            inspectorStatus = "Write failed: \(error.localizedDescription)"
        }
    }

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
            guard let s = try? BLEParsers.parseStats(data) else { return nil }
            return "V:\(s.vigour) F:\(s.focus) S:\(s.spirit) Age:\(s.age) Int:\(s.interventions)"

        case BLEConstants.charItemsOwned, BLEConstants.charItemsPlaced:
            return "\(BLEParsers.countBitmapItems(data)) items"

        case BLEConstants.charDeviceConfig:
            guard data.count >= 16, let c = DeviceConfig.parse(from: data) else { return nil }
            return "sensor:\(c.sensorWakeupPeriod)s sleep:\(c.sleepAfterSeconds)s dim:\(c.dimAfterSeconds)s nox:\(c.noxSamplePeriod) bright:\(c.screenBrightness) flags:0x\(String(c.persistFlags.rawValue, radix: 16))"

        case BLEConstants.essTemperature:
            guard data.count >= 2 else { return nil }
            guard let value = try? BLEParsers.parseTemperature(data) else { return nil }
            return "\(value) °C"

        case BLEConstants.essHumidity:
            guard data.count >= 2 else { return nil }
            guard let value = try? BLEParsers.parseHumidity(data) else { return nil }
            return "\(value) %"

        case BLEConstants.essPressure:
            guard data.count >= 4 else { return nil }
            guard let value = try? BLEParsers.parsePressure(data) else { return nil }
            return "\(value) hPa"

        case BLEConstants.essCO2:
            guard data.count >= 2 else { return nil }
            guard let value = try? BLEParsers.parseCO2(data) else { return nil }
            return "\(value) ppm"

        case BLEConstants.essPM2_5, BLEConstants.essPM1_0, BLEConstants.essPM10:
            guard data.count >= 2 else { return nil }
            guard let value = try? BLEParsers.parsePM(data) else { return nil }
            return "\(value) µg/m³"

        default:
            return nil
        }
    }

    @State private var cellIndexText = ""

    @State private var cellResult: String?

    @State private var cellError: String?

    private var cellInspectorSection: some View {
        Section("Log Cell Inspector") {
            if let count = deviceVM.cellCount {
                if count > 0 {
                    Text("Device has \(count) cells (0–\(count - 1))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Device has 0 cells")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            ViewThatFits {
                HStack {
                    cellIndexField
                    readCellButton
                }

                VStack(alignment: .leading, spacing: 8) {
                    cellIndexField
                    readCellButton
                }
            }

            if let error = cellError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let result = cellResult {
                Text(result)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
    }

    private var cellIndexField: some View {
        TextField("Cell #", text: $cellIndexText)
            .keyboardType(.numberPad)
            .textFieldStyle(.roundedBorder)
    }

    private var readCellButton: some View {
        Button("Read") {
            guard let index = UInt32(cellIndexText) else {
                cellError = "Invalid cell number"
                return
            }
            if let count = deviceVM.cellCount, count == 0 || index >= count {
                cellError = count == 0
                    ? "Device has no cells"
                    : "Cell index out of range (0–\(count - 1))"
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
        .minimumAccessibleTapTarget()
    }

    private func formatCell(_ cell: ParsedLogCell) -> String {
        """
        Cell #\(cell.cellNumber)
        Time: \(UnitFormatters.fmtDateTime(UInt32(clamping: cell.timestamp)))
        Flags: 0x\(String(cell.flags, radix: 16, uppercase: true))
        CO₂: \(cell.co2) ppm
        Temp: \(String(format: "%.2f", cell.temperature)) °C
        RH: \(String(format: "%.1f", cell.humidity)) %
        Pressure: \(String(format: "%.1f", cell.pressure)) hPa
        PM1.0: \(String(format: "%.1f", cell.pm.pm1_0)) µg/m³
        PM2.5: \(String(format: "%.1f", cell.pm.pm2_5)) µg/m³
        PM4.0: \(String(format: "%.1f", cell.pm.pm4_0)) µg/m³
        PM10: \(String(format: "%.1f", cell.pm.pm10)) µg/m³
        VOC: \(cell.voc)
        NOx: \(cell.nox)
        CO₂ uncomp: \(cell.co2Uncomp) ppm
        """
    }
}
