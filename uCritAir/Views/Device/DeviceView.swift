import SwiftUI

struct DeviceView: View {

    @Environment(DeviceViewModel.self) private var deviceVM

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

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
            if dynamicTypeSize.usesAccessibilityLayout && deviceVM.connectionState == .connected {
                Section {
                    ConnectedDeviceHeader()
                }
            }

            deviceInfoSection
            petStatsSection
            configSection
        }
        .appTabBarScrollContentClearance()
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle(deviceVM.petName ?? "Device Settings")
        .accessibilityIdentifier("deviceSettingsScreen")
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
                editableTextRow(
                    title: "Device Name",
                    text: $editedDeviceName,
                    isSaving: isSavingDeviceName,
                    saveAction: {
                        isSavingDeviceName = true
                        Task {
                            defer { isSavingDeviceName = false }
                            await deviceVM.writeDeviceName(editedDeviceName)
                            isEditingDeviceName = false
                        }
                    },
                    cancelAction: { isEditingDeviceName = false }
                )
                .onChange(of: editedDeviceName) { _, newValue in
                    if newValue.count > 20 { editedDeviceName = String(newValue.prefix(20)) }
                }
            } else {
                valueActionRow(
                    title: "Device Name",
                    value: deviceVM.deviceName ?? "--",
                    actionTitle: "Edit"
                ) {
                    editedDeviceName = deviceVM.deviceName ?? ""
                    isEditingDeviceName = true
                }
            }

            if isEditingPetName {
                editableTextRow(
                    title: "Pet Name",
                    text: $editedPetName,
                    isSaving: isSavingPetName,
                    saveAction: {
                        isSavingPetName = true
                        Task {
                            defer { isSavingPetName = false }
                            await deviceVM.writePetName(editedPetName)
                            isEditingPetName = false
                        }
                    },
                    cancelAction: { isEditingPetName = false }
                )
                .onChange(of: editedPetName) { _, newValue in
                    if newValue.count > 20 { editedPetName = String(newValue.prefix(20)) }
                }
            } else {
                valueActionRow(
                    title: "Pet Name",
                    value: deviceVM.petName ?? "--",
                    actionTitle: "Edit"
                ) {
                    editedPetName = deviceVM.petName ?? ""
                    isEditingPetName = true
                }
            }

            valueActionRow(
                title: "Device Time",
                value: deviceVM.deviceTime.map(UnitFormatters.fmtDateTime) ?? "--",
                actionTitle: "Sync"
            ) {
                Task { await deviceVM.syncTime() }
            }

            keyValueRow(title: "Log Cells", value: deviceVM.cellCount.map { "\($0)" } ?? "--")
            keyValueRow(title: "Bonus", value: deviceVM.bonus.map { "\($0) coins" } ?? "--")
            keyValueRow(title: "Items Owned", value: deviceVM.itemsOwned.map { "\(BLEParsers.countBitmapItems($0))" } ?? "--")
            keyValueRow(title: "Items Placed", value: deviceVM.itemsPlaced.map { "\(BLEParsers.countBitmapItems($0))" } ?? "--")
        }
    }

    @ViewBuilder
    private func keyValueRow(title: String, value: String) -> some View {
        if dynamicTypeSize.usesAccessibilityLayout {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(value)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 2)
        } else {
            LabeledContent(title, value: value)
        }
    }

    @ViewBuilder
    private func valueActionRow(
        title: String,
        value: String,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        if dynamicTypeSize.usesAccessibilityLayout {
            VStack(alignment: .leading, spacing: 10) {
                Text(title)
                    .font(.subheadline.weight(.semibold))

                Text(value)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button(actionTitle, action: action)
                    .buttonStyle(.bordered)
                    .minimumAccessibleTapTarget()
            }
            .padding(.vertical, 2)
        } else {
            LabeledContent(title) {
                HStack {
                    Text(value)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(actionTitle, action: action)
                        .font(.caption)
                }
            }
        }
    }

    private func editableTextRow(
        title: String,
        text: Binding<String>,
        isSaving: Bool,
        saveAction: @escaping () -> Void,
        cancelAction: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.subheadline.weight(.semibold))

            TextField(title, text: text)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()

            ViewThatFits {
                HStack {
                    Button("Save", action: saveAction)
                        .buttonStyle(.borderedProminent)
                    Button("Cancel", role: .cancel, action: cancelAction)
                        .buttonStyle(.bordered)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Button("Save", action: saveAction)
                        .buttonStyle(.borderedProminent)
                    Button("Cancel", role: .cancel, action: cancelAction)
                        .buttonStyle(.bordered)
                }
            }
            .disabled(isSaving)
        }
    }

    private var petStatsSection: some View {
        Section("Pet Stats") {
            if let stats = deviceVM.petStats {
                StatBarRow(label: "Vigour", value: stats.vigour, color: .green)
                StatBarRow(label: "Focus", value: stats.focus, color: .blue)
                StatBarRow(label: "Spirit", value: stats.spirit, color: .purple)
                keyValueRow(title: "Age", value: "\(stats.age) days")
                keyValueRow(title: "Interventions", value: "\(stats.interventions)")
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

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if dynamicTypeSize.usesAccessibilityLayout {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                    Text("\(value)")
                        .foregroundStyle(.secondary)
                }
            } else {
                HStack {
                    Text(label)
                    Spacer()
                    Text("\(value)")
                        .foregroundStyle(.secondary)
                }
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

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if dynamicTypeSize.usesAccessibilityLayout {
                VStack(alignment: .leading, spacing: 8) {
                    Text(label)
                        .font(.subheadline.weight(.semibold))
                    field
                }
            } else {
                LabeledContent(label) {
                    field
                }
            }
        }
        .onAppear { text = "\(value)" }
        .onChange(of: text) { _, newText in
            if let n = Int(newText) { value = n }
        }
        .onChange(of: value) { _, newValue in
            let expected = "\(newValue)"
            if text != expected { text = expected }
        }
    }

    private var field: some View {
        TextField("", text: $text)
            .keyboardType(.numberPad)
            .multilineTextAlignment(dynamicTypeSize.usesAccessibilityLayout ? .leading : .trailing)
            .textFieldStyle(.roundedBorder)
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
