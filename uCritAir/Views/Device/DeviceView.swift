import SwiftUI

struct DeviceView: View {

    @Environment(DeviceViewModel.self) private var deviceVM

    @State private var isEditingDeviceName = false

    @State private var editedDeviceName = ""

    @State private var isSavingDeviceName = false

    @State private var isEditingPetName = false

    @State private var editedPetName = ""

    @State private var isSavingPetName = false

    @State private var draft: DeviceConfig?

    @State private var isSaving = false

    var body: some View {
        List {
            deviceInfoSection
            petStatsSection
            configSection
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle(deviceVM.petName ?? "Device Settings")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                ConnectButton()
            }
            ToolbarItem(placement: .keyboard) {
                Button("Done") { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .onAppear {
            if draft == nil { draft = deviceVM.config }
        }
        .onChange(of: deviceVM.config) { _, newConfig in
            if !isSaving { draft = newConfig }
        }
    }

    private var deviceInfoSection: some View {
        Section("Device Info") {
            if isEditingDeviceName {
                HStack {
                    TextField("Device Name", text: $editedDeviceName)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .onChange(of: editedDeviceName) { _, newValue in
                            if newValue.count > 20 { editedDeviceName = String(newValue.prefix(20)) }
                        }
                    Button("Save") {
                        isSavingDeviceName = true
                        Task {
                            defer { isSavingDeviceName = false }
                            await deviceVM.writeDeviceName(editedDeviceName)
                            isEditingDeviceName = false
                        }
                    }
                    .disabled(isSavingDeviceName)
                    Button("Cancel", role: .cancel) {
                        isEditingDeviceName = false
                    }
                    .disabled(isSavingDeviceName)
                }
            } else {
                LabeledContent("Device Name") {
                    HStack {
                        Text(deviceVM.deviceName ?? "--")
                            .foregroundStyle(.secondary)
                        Button("Edit") {
                            editedDeviceName = deviceVM.deviceName ?? ""
                            isEditingDeviceName = true
                        }
                        .font(.caption)
                    }
                }
            }

            if isEditingPetName {
                HStack {
                    TextField("Pet Name", text: $editedPetName)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .onChange(of: editedPetName) { _, newValue in
                            if newValue.count > 20 { editedPetName = String(newValue.prefix(20)) }
                        }
                    Button("Save") {
                        isSavingPetName = true
                        Task {
                            defer { isSavingPetName = false }
                            await deviceVM.writePetName(editedPetName)
                            isEditingPetName = false
                        }
                    }
                    .disabled(isSavingPetName)
                    Button("Cancel", role: .cancel) {
                        isEditingPetName = false
                    }
                    .disabled(isSavingPetName)
                }
            } else {
                LabeledContent("Pet Name") {
                    HStack {
                        Text(deviceVM.petName ?? "--")
                            .foregroundStyle(.secondary)
                        Button("Edit") {
                            editedPetName = deviceVM.petName ?? ""
                            isEditingPetName = true
                        }
                        .font(.caption)
                    }
                }
            }

            LabeledContent("Device Time") {
                HStack {
                    if let t = deviceVM.deviceTime {
                        Text(UnitFormatters.fmtDateTime(t))
                            .foregroundStyle(.secondary)
                    } else {
                        Text("--").foregroundStyle(.secondary)
                    }
                    Button("Sync") {
                        Task { await deviceVM.syncTime() }
                    }
                    .font(.caption)
                }
            }

            LabeledContent("Log Cells", value: deviceVM.cellCount.map { "\($0)" } ?? "--")
            LabeledContent("Bonus", value: deviceVM.bonus.map { "\($0) coins" } ?? "--")
            LabeledContent("Items Owned", value: deviceVM.itemsOwned.map { "\(BLEParsers.countBitmapItems($0))" } ?? "--")
            LabeledContent("Items Placed", value: deviceVM.itemsPlaced.map { "\(BLEParsers.countBitmapItems($0))" } ?? "--")
        }
    }

    private var petStatsSection: some View {
        Section("Pet Stats") {
            if let stats = deviceVM.petStats {
                StatBarRow(label: "Vigour", value: stats.vigour, color: .green)
                StatBarRow(label: "Focus", value: stats.focus, color: .blue)
                StatBarRow(label: "Spirit", value: stats.spirit, color: .purple)
                LabeledContent("Age", value: "\(stats.age) days")
                LabeledContent("Interventions", value: "\(stats.interventions)")
            } else {
                Text("Connect to a device to view pet stats.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var configSection: some View {
        if var draft {
            Section("Configuration") {
                ConfigNumberField(label: "Sensor Period (s)", value: Binding(
                    get: { Int(draft.sensorWakeupPeriod) },
                    set: { draft.sensorWakeupPeriod = UInt16(clamping: $0); self.draft = draft }
                ))
                ConfigNumberField(label: "Sleep After (s)", value: Binding(
                    get: { Int(draft.sleepAfterSeconds) },
                    set: { draft.sleepAfterSeconds = UInt16(clamping: $0); self.draft = draft }
                ))
                ConfigNumberField(label: "Dim After (s)", value: Binding(
                    get: { Int(draft.dimAfterSeconds) },
                    set: { draft.dimAfterSeconds = UInt16(clamping: $0); self.draft = draft }
                ))
                ConfigNumberField(label: "NOx Period", value: Binding(
                    get: { Int(draft.noxSamplePeriod) },
                    set: { draft.noxSamplePeriod = UInt8(clamping: $0); self.draft = draft }
                ))
                ConfigNumberField(label: "Brightness (0-75)", value: Binding(
                    get: { Int(draft.screenBrightness) },
                    set: { draft.screenBrightness = UInt8(clamping: min($0, 75)); self.draft = draft }
                ))
            }

            Section("Persist Flags") {
                FlagToggle(label: "Battery Alert", flag: .batteryAlert, flags: Binding(
                    get: { draft.persistFlags },
                    set: { draft.persistFlags = $0; self.draft = draft }
                ))
                FlagToggle(label: "Manual Orient", flag: .manualOrient, flags: Binding(
                    get: { draft.persistFlags },
                    set: { draft.persistFlags = $0; self.draft = draft }
                ))
                FlagToggle(label: "Use Fahrenheit", flag: .useFahrenheit, flags: Binding(
                    get: { draft.persistFlags },
                    set: { draft.persistFlags = $0; self.draft = draft }
                ))
                FlagToggle(label: "AQ Dashboard First", flag: .aqFirst, flags: Binding(
                    get: { draft.persistFlags },
                    set: { draft.persistFlags = $0; self.draft = draft }
                ))
                FlagToggle(label: "Pause Care", flag: .pauseCare, flags: Binding(
                    get: { draft.persistFlags },
                    set: { draft.persistFlags = $0; self.draft = draft }
                ))
                FlagToggle(label: "Eternal Wake", flag: .eternalWake, flags: Binding(
                    get: { draft.persistFlags },
                    set: { draft.persistFlags = $0; self.draft = draft }
                ))
                FlagToggle(label: "Pause Logging", flag: .pauseLogging, flags: Binding(
                    get: { draft.persistFlags },
                    set: { draft.persistFlags = $0; self.draft = draft }
                ))
            }

            Section {
                Button {
                    guard let config = self.draft else { return }
                    isSaving = true
                    Task {
                        defer { isSaving = false }
                        await deviceVM.writeConfig(config)
                    }
                } label: {
                    HStack {
                        Spacer()
                        if isSaving {
                            ProgressView()
                                .padding(.trailing, 4)
                            Text("Saving...")
                        } else {
                            Text("Save Configuration")
                        }
                        Spacer()
                    }
                }
                .disabled(isSaving)
            }
        } else {
            Section("Configuration") {
                Text("Connect to a device to edit configuration.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Helper Views

private struct StatBarRow: View {
    let label: String
    let value: UInt8
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                Spacer()
                Text("\(value)")
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: Double(value), total: 255)
                .tint(color)
        }
        .padding(.vertical, 2)
    }
}

private struct ConfigNumberField: View {
    let label: String
    @Binding var value: Int
    @State private var text = ""

    var body: some View {
        LabeledContent(label) {
            TextField("", text: $text)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 80)
                .onAppear { text = "\(value)" }
                .onChange(of: text) { _, newText in
                    if let n = Int(newText) { value = n }
                }
                .onChange(of: value) { _, newValue in
                    let expected = "\(newValue)"
                    if text != expected { text = expected }
                }
        }
    }
}

private struct FlagToggle: View {
    let label: String
    let flag: PersistFlags
    @Binding var flags: PersistFlags

    var body: some View {
        Toggle(label, isOn: Binding(
            get: { flags.contains(flag) },
            set: { isOn in
                if isOn { flags.insert(flag) } else { flags.remove(flag) }
            }
        ))
    }
}
