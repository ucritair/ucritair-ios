// ────────────────────────────────────────────────────────────────────────────
// DeviceView.swift
// uCritAir
// ────────────────────────────────────────────────────────────────────────────
//
// PURPOSE:
//   The device settings screen, accessed by tapping the gear icon on a
//   connected device in DeviceListView. It is pushed onto the NavigationStack
//   (not a separate tab).
//
//   This view provides a full device configuration interface organized into
//   three sections:
//
//   1. **Device Info** — Shows and allows inline editing of the device name,
//      pet name, device time (with sync), log cell count, bonus coins,
//      and item ownership counts.
//
//   2. **Pet Stats** — Displays the virtual pet's vital statistics (Vigour,
//      Focus, Spirit) as colored progress bars, plus age and intervention count.
//
//   3. **Configuration** — Editable numeric fields for hardware settings
//      (sensor wake period, sleep timeout, screen brightness, etc.) and
//      toggle switches for persist flags (battery alert, Fahrenheit, etc.).
//      A "Save Configuration" button writes changes to the device over BLE.
//
// SWIFTUI CONCEPTS USED:
//   - @Environment: Reads the shared DeviceViewModel.
//   - @State: Manages local UI state for inline editing (edit mode flags,
//     draft text, saving indicators) and the configuration draft copy.
//   - List / Section: Creates a grouped, scrollable settings form.
//   - LabeledContent: A convenience view that shows a label on the left
//     and a value on the right, like a Settings app row.
//   - TextField: A text input field for editing names and numbers.
//   - Toggle: A switch control for boolean flags.
//   - ProgressView: Shows a spinner during save operations.
//   - Binding: Custom Bindings are created with `Binding(get:set:)` to
//     connect the draft config fields to their input controls.
//   - Task { await ... }: Runs async BLE write operations from a SwiftUI
//     button action (which must be synchronous).
//   - .scrollDismissesKeyboard(.interactively): Lets the user dismiss the
//     keyboard by scrolling down.
//
// ────────────────────────────────────────────────────────────────────────────

import SwiftUI

/// The device settings editor — a drill-down view pushed from `DeviceListView`.
///
/// Displays device information, pet statistics, and hardware configuration
/// in a scrollable form layout. The user can edit the device name, pet name,
/// sync the device clock, and modify configuration parameters that are
/// written back to the device over BLE.
///
/// ## Dependencies
/// - `DeviceViewModel`: The primary data source and action handler. Provides
///   device info (name, time, cell count), pet stats, and config values.
///   Also provides methods for writing changes back to the device.
///
/// ## Edit Flow
/// Names use an inline edit pattern:
/// 1. User taps "Edit" next to the current value.
/// 2. A text field and Save/Cancel buttons appear.
/// 3. On "Save", the value is written to the device via BLE.
/// 4. The text field disappears and the display returns to read-only mode.
///
/// Configuration uses a draft-and-save pattern:
/// 1. A local `draft` copy of `DeviceConfig` is created on appear.
/// 2. The user edits fields, which modify the local draft.
/// 3. Pressing "Save Configuration" writes the entire draft to the device.
struct DeviceView: View {

    // MARK: - Environment

    /// The shared device view model providing device info, stats, config, and BLE write methods.
    @Environment(DeviceViewModel.self) private var deviceVM

    // MARK: - Inline Edit State

    /// Whether the device name field is currently in edit mode.
    @State private var isEditingDeviceName = false

    /// The working copy of the device name being edited by the user.
    @State private var editedDeviceName = ""

    /// Whether a BLE write for the device name is currently in progress.
    @State private var isSavingDeviceName = false

    /// Whether the pet name field is currently in edit mode.
    @State private var isEditingPetName = false

    /// The working copy of the pet name being edited by the user.
    @State private var editedPetName = ""

    /// Whether a BLE write for the pet name is currently in progress.
    @State private var isSavingPetName = false

    // MARK: - Config Draft State

    /// A local copy of the device configuration that the user can modify.
    ///
    /// This "draft" pattern prevents partial edits from being sent to the device.
    /// The draft is initialized from `deviceVM.config` on appear, and only
    /// written back when the user explicitly taps "Save Configuration".
    @State private var draft: DeviceConfig?

    /// Whether a BLE write for the full configuration is currently in progress.
    @State private var isSaving = false

    // MARK: - Body

    /// The main view body — a List-based form with three sections.
    ///
    /// **SwiftUI concept — .scrollDismissesKeyboard(.interactively):**
    /// This modifier lets the user dismiss the on-screen keyboard by scrolling
    /// the list. The keyboard slides away as the user scrolls down, providing
    /// a natural dismissal gesture.
    ///
    /// **SwiftUI concept — .onChange(of:):**
    /// When `deviceVM.config` changes (e.g., after a BLE read), the draft is
    /// updated to match — but only if a save is not currently in progress,
    /// to avoid overwriting the user's pending edits.
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

    // MARK: - Device Info Section

    /// The "Device Info" section showing the device name, pet name, time, and read-only stats.
    ///
    /// The device name and pet name fields support inline editing: tapping "Edit"
    /// reveals a `TextField` with Save/Cancel buttons. Other fields (time, log cells,
    /// bonus, items) are read-only with some having action buttons (Sync, Edit).
    ///
    /// **SwiftUI concept — LabeledContent:**
    /// `LabeledContent("Label", value: "Value")` renders a row with the label on
    /// the left and the value on the right, similar to rows in the iOS Settings app.
    private var deviceInfoSection: some View {
        Section("Device Info") {
            // Device Name — inline editable with a 20-character limit.
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

            // Pet Name (inline editable)
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

            // Device Time
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

            // Read-only fields
            LabeledContent("Log Cells", value: deviceVM.cellCount.map { "\($0)" } ?? "--")
            LabeledContent("Bonus", value: deviceVM.bonus.map { "\($0) coins" } ?? "--")
            LabeledContent("Items Owned", value: deviceVM.itemsOwned.map { "\(BLEParsers.countBitmapItems($0))" } ?? "--")
            LabeledContent("Items Placed", value: deviceVM.itemsPlaced.map { "\(BLEParsers.countBitmapItems($0))" } ?? "--")
        }
    }

    // MARK: - Pet Stats Section

    /// The "Pet Stats" section showing the virtual pet's vital statistics.
    ///
    /// Displays three stat bars (Vigour, Focus, Spirit) as colored progress
    /// indicators (0–255), plus the pet's age in days and intervention count.
    /// If no device is connected, shows a placeholder message.
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

    // MARK: - Config Section

    /// The device configuration editing sections.
    ///
    /// When a draft config is available (device connected), renders two List sections:
    ///
    /// 1. **Configuration** — Numeric input fields for hardware parameters like
    ///    sensor wake-up period, sleep timeout, screen brightness, etc.
    ///
    /// 2. **Persist Flags** — Toggle switches for boolean device settings like
    ///    battery alert, Fahrenheit mode, pause logging, etc.
    ///
    /// Plus a "Save Configuration" button section that writes the draft to the device.
    ///
    /// **SwiftUI concept — Binding(get:set:):**
    /// The `Binding` initializer with `get` and `set` closures creates a custom
    /// two-way binding. This is used here because the draft is a `@State` struct,
    /// and SwiftUI cannot automatically create key-path bindings into it.
    /// The `get` closure reads the current value; the `set` closure writes the
    /// new value and reassigns `self.draft` to trigger a view update.
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

/// A horizontal row showing a pet stat as a label, numeric value, and colored progress bar.
///
/// Used in the "Pet Stats" section of `DeviceView`. The progress bar fills
/// proportionally to the stat value (0–255).
///
/// **SwiftUI concept — ProgressView(value:total:):**
/// `ProgressView` can display a determinate progress bar when given a `value`
/// and `total`. Here, the value is the stat (0–255) and the total is 255.
/// The `.tint()` modifier colors the filled portion.
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

/// A numeric input field for device configuration values.
///
/// Wraps a `TextField` with number pad keyboard and two-way synchronization
/// between the text representation and the integer `@Binding`.
///
/// **SwiftUI concept — @Binding:**
/// `@Binding` creates a two-way connection to state owned by a parent view.
/// When the user types a number, the `set` direction updates the parent's value.
/// When the parent's value changes (e.g., from a BLE read), the `get` direction
/// updates the displayed text.
///
/// **Internal @State:**
/// The `text` property is a `@State` String that holds the raw text field input.
/// This allows intermediate states (like an empty field while typing) without
/// immediately updating the integer binding.
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

/// A toggle switch for a single boolean flag within a `PersistFlags` option set.
///
/// `PersistFlags` is an `OptionSet` where each flag is a single bit. This view
/// creates a custom `Binding<Bool>` that reads and writes a specific bit within
/// the option set, allowing a standard SwiftUI `Toggle` to control it.
///
/// **SwiftUI concept — Toggle with custom Binding:**
/// `Toggle` expects a `Binding<Bool>`, but our data model uses an `OptionSet`.
/// The `Binding(get:set:)` initializer bridges between these two types:
/// - `get`: Returns `true` if the flag bit is set in the option set.
/// - `set`: Inserts or removes the flag bit based on the toggle state.
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
