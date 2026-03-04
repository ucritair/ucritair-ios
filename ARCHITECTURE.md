# uCritAir iOS App — Architecture Guide

> A comprehensive guide to the uCritAir iOS app architecture, designed to be
> accessible to first-year computer science students while remaining useful as a
> reference for experienced developers.

---

## Table of Contents

1. [What Is This App?](#what-is-this-app)
2. [High-Level Architecture](#high-level-architecture)
3. [Layer-by-Layer Walkthrough](#layer-by-layer-walkthrough)
4. [Data Flow: From Sensor to Screen](#data-flow-from-sensor-to-screen)
5. [BLE (Bluetooth Low Energy) Protocol](#ble-bluetooth-low-energy-protocol)
6. [Persistence with SwiftData](#persistence-with-swiftdata)
7. [Key Design Patterns](#key-design-patterns)
8. [File Map](#file-map)
9. [Glossary](#glossary)

---

## What Is This App?

uCritAir is an iOS companion app for the **uCrit air quality monitor** — a
small hardware device built by Entropic Engineering. The device measures:

- **Temperature**, **humidity**, and **barometric pressure**
- **CO₂** (carbon dioxide) concentration
- **PM1.0, PM2.5, PM4.0, PM10** (particulate matter — tiny airborne particles)
- **VOC** (volatile organic compounds) and **NOx** (nitrogen oxides)

The device also has a built-in **virtual pet** whose health reflects your air
quality (good air = happy pet).

This iOS app connects to the device over **Bluetooth Low Energy (BLE)** and:

1. **Displays live sensor readings** on a dashboard with an air quality grade
2. **Downloads historical data** stored on the device's flash memory
3. **Charts sensor trends** over time (1h, 24h, 7d, 30d, all-time)
4. **Exports data** as CSV files for analysis in Excel/Google Sheets
5. **Manages device settings** like brightness, sleep timers, and pet names
6. **Supports multiple devices** via a persistent device registry

---

## High-Level Architecture

```
┌─────────────────────────────────────────────────┐
│                    SwiftUI Views                 │
│  (Dashboard, History, Devices, Developer)        │
├─────────────────────────────────────────────────┤
│                   ViewModels                     │
│  (DeviceVM, SensorVM, HistoryVM)                │
│  @Observable · @MainActor · async/await         │
├─────────────────────────────────────────────────┤
│                   BLE Layer                      │
│  (BLEManager · BLECharacteristics · BLEParsers) │
│  CoreBluetooth · CheckedContinuation            │
├─────────────────────────────────────────────────┤
│                  Persistence                     │
│  (SwiftData · LogCellEntity · DeviceProfile)    │
├─────────────────────────────────────────────────┤
│                   Services                       │
│  (AQIScoring · CSVExporter · TimelineFilter)    │
└─────────────────────────────────────────────────┘
```

The app follows **MVVM** (Model-View-ViewModel):

- **Views** display data and handle user interaction (SwiftUI)
- **ViewModels** hold state, process BLE data, and coordinate business logic
- **Models** define data structures (sensor values, device config, log cells)
- **Services** provide stateless utilities (scoring, export, filtering)
- **BLE Layer** manages the Bluetooth connection to the physical device

---

## Layer-by-Layer Walkthrough

### 1. App Entry Point (`uCritAirApp.swift`)

This is where the app starts. It:

1. Creates the **SwiftData ModelContainer** (the local database)
2. Creates the four shared objects that all views need:
   - `BLEManager` — the Bluetooth connection manager
   - `DeviceViewModel` — device info and multi-device registry
   - `SensorViewModel` — live sensor readings
   - `HistoryViewModel` — historical data and charts
3. Injects these into the SwiftUI **environment** so any view can access them

Think of the environment like a "shared backpack" that every view in the app
can reach into to grab what it needs.

### 2. Content View (`ContentView.swift`)

The root view with four tabs:

| Tab | View | Purpose |
|-----|------|---------|
| 0 — Dashboard | `DashboardView` | Live sensor readings + AQ grade |
| 1 — Data | `HistoryView` | Historical charts + CSV export |
| 2 — Devices | `DeviceListView` | Manage paired devices |
| 3 — Developer | `DeveloperToolsView` | Raw BLE debugging tools |

On first launch (no paired devices), it auto-switches to the Devices tab.

### 3. BLE Layer (`BLE/`)

This is the most complex part of the app. It's split into five files:

| File | Role |
|------|------|
| `BLEManager.swift` | **Central hub** — scanning, connecting, reading/writing characteristics |
| `BLECharacteristics.swift` | **Typed API** — high-level `readTemperature()`, `writeConfig()` etc. |
| `BLEParsers.swift` | **Binary decoder** — turns raw bytes into Swift types |
| `BLELogStream.swift` | **Bulk download** — streams hundreds of log cells from device flash |
| `BLEConstants.swift` | **Protocol spec** — service/characteristic UUIDs and constants |

**How a BLE read works (step by step):**

```
1. ViewModel calls:        BLECharacteristics.readStats(using: manager)
2. Characteristics calls:  manager.readCharacteristic(charStatsUUID)
3. BLEManager:             stores a "continuation" (promise) in pendingReads dictionary
4. BLEManager:             tells CoreBluetooth: peripheral.readValue(for: characteristic)
5. CoreBluetooth:          sends request to device over Bluetooth radio
6. Device:                 sends back 6 bytes of data
7. CoreBluetooth calls:    didUpdateValueFor(characteristic)
8. BLEManager:             looks up the continuation, resumes it with the data
9. Characteristics:        guards data.count >= 6, calls BLEParsers.parseStats(data)
10. BLEParsers:            reads bytes at specific offsets → PetStats struct
11. ViewModel:             receives PetStats, updates @Observable state
12. SwiftUI:               automatically re-renders any views showing pet stats
```

### 4. ViewModels (`ViewModels/`)

Each ViewModel is an `@Observable` class. The `@Observable` macro (new in
iOS 17) automatically tracks which properties each view reads, and re-renders
only the affected views when those properties change.

| ViewModel | Owns | Key Responsibilities |
|-----------|------|---------------------|
| `DeviceViewModel` | Device connection state, config, pet stats | Connect/disconnect, read/write device info, multi-device registry |
| `SensorViewModel` | Live sensor values, 30-min rolling history | Merge partial BLE updates, throttle history entries |
| `HistoryViewModel` | Downloaded log cells, charts, CSV export | Stream log data from device, filter by time range, compute stats |

### 5. Models (`Models/`)

Plain Swift structs and classes representing data:

| Model | Purpose | Persistence |
|-------|---------|-------------|
| `SensorValues` | Current live readings (temp, humidity, CO₂, PM, etc.) | In-memory only |
| `SensorReading` | Timestamped snapshot for rolling history | In-memory only |
| `ParsedLogCell` | One historical measurement from device flash | Transient (parsed from BLE) |
| `LogCellEntity` | SwiftData entity — persisted version of ParsedLogCell | SQLite database |
| `DeviceProfile` | SwiftData entity — known device with name, ID, room label | SQLite database |
| `DeviceConfig` | 16-byte device configuration (timers, brightness, flags) | On-device (BLE) |
| `PetStats` | Virtual pet health (vigour, focus, spirit, age) | On-device (BLE) |
| `AQScoreResult` | Computed air quality grade (A+ through F) | Computed on-the-fly |

### 6. Services (`Services/`)

Stateless utility types:

| Service | What It Does |
|---------|-------------|
| `AQIScoring` | Computes air quality grade from sensor values using piecewise-linear scoring |
| `CSVExporter` | Converts log cell arrays to CSV format and writes to temp file |
| `LogCellStore` | SwiftData CRUD operations for `LogCellEntity` |
| `TimelineFilter` | Reduces thousands of chart points to ~100 using the Ramer-Douglas-Peucker algorithm |
| `UnitFormatters` | Date/time formatting and unit conversions |

### 7. Views (`Views/`)

Every view is a SwiftUI struct. Views are **declarative** — they describe
*what* to show, and SwiftUI figures out *how* to render it.

**Dashboard group:**
- `DashboardView` — Grid of sensor cards with live values
- `AQGaugeView` — Animated circular gauge showing air quality grade
- `SensorCardView` — Individual sensor tile with sparkline

**History group:**
- `HistoryView` — Chart timeline with sensor picker, time range, day navigation
- `SensorChartView` — Swift Charts line chart with tooltip/crosshair

**Device group:**
- `DeviceListView` — List of known devices with connect/reconnect/delete
- `DeviceView` — Device settings editor (names, config, pet stats)
- `DeviceCardRow` — Rich device card with AQ score ring

**Shared group:**
- `ConnectButton` — BLE connect/disconnect button (used in navigation bar)
- `StatusBanner` — Dismissible error/reconnecting banner

---

## Data Flow: From Sensor to Screen

```
    Hardware Sensor (e.g., Senseair Sunrise CO₂ sensor)
           │
           ▼
    Device Firmware (Zephyr RTOS on nRF5340)
           │  writes value to BLE GATT characteristic
           ▼
    CoreBluetooth (Apple's BLE framework)
           │  delivers notification via didUpdateValueFor
           ▼
    BLEManager.swift
           │  routes to pending continuation or ESS handler
           │  applies data size guard (e.g., guard data.count >= 2)
           │  calls BLEParsers.parseCO2(data)
           ▼
    SensorViewModel.swift
           │  merges partial update into SensorValues.current
           │  throttles history to 1 entry per 4 seconds
           ▼
    DashboardView / SensorCardView
           │  @Observable triggers re-render
           ▼
    User sees "CO₂: 487 ppm" on screen
```

For **historical data**, the flow is different:

```
    Device Flash Memory (stores ~500 log cells)
           │
           ▼
    BLELogStream.streamLogCells()
           │  writes start cell + count to device
           │  device sends cells as BLE notifications
           │  BLEParsers.parseLogCell(data) for each
           ▼
    HistoryViewModel.swift
           │  saves each cell to SwiftData via LogCellStore
           │  loads all cells, computes chart points
           │  applies TimelineFilter to reduce point count
           ▼
    HistoryView / SensorChartView
           │  renders line chart with Swift Charts
           ▼
    User sees temperature trend over last 24 hours
```

---

## BLE (Bluetooth Low Energy) Protocol

### What Is BLE?

Bluetooth Low Energy is a wireless protocol designed for small, low-power
devices. Unlike "classic" Bluetooth (used for audio), BLE is designed for
sending small packets of data periodically.

### Key Concepts

- **Central**: The iPhone (our app). Scans for and connects to devices.
- **Peripheral**: The uCrit device. Advertises its presence and hosts data.
- **Service**: A collection of related data points. Like a "folder."
- **Characteristic**: A single data point within a service. Like a "file."
- **UUID**: A unique identifier for each service/characteristic.
- **Notification**: The device can "push" updates when a value changes.
- **GATT**: The protocol that defines how services and characteristics work.

### uCrit BLE Services

The device exposes two services:

**1. Custom Vendor Service** (`0xCAFE`):
| Characteristic | UUID | Type | Description |
|----------------|------|------|-------------|
| Device Name | `0x0011` | Read/Write | User-assigned device name (UTF-8 string) |
| Time | `0x0012` | Read/Write | Device RTC clock (Unix epoch, uint32) |
| Cell Count | `0x0013` | Read | Total log cells in flash (uint32) |
| Cell Selector | `0x0014` | Write | Select which cell to read (uint32) |
| Cell Data | `0x0016` | Read/Notify | 57-byte log cell payload |
| Stats | `0x0017` | Read | Pet stats (6 bytes) |
| Items Owned | `0x0018` | Read | Pet items bitmap (32 bytes) |
| Items Placed | `0x0019` | Read | Placed items bitmap (32 bytes) |
| Bonus | `0x001A` | Read/Write | Bonus coins (uint32) |
| Pet Name | `0x001B` | Read/Write | Pet name (UTF-8 string) |
| Device Config | `0x0015` | Read/Write | 16-byte config struct |
| Log Stream | `0x001C` | Read/Write/Notify | Bulk log cell download control |

**2. Environmental Sensing Service (ESS)** (`0x181A`):
| Characteristic | UUID | Type | Description |
|----------------|------|------|-------------|
| Temperature | `0x2A6E` | Read/Notify | sint16, 0.01°C resolution |
| Humidity | `0x2A6F` | Read/Notify | uint16, 0.01% resolution |
| Pressure | `0x2A6D` | Read | uint32, 0.1 Pa resolution |
| CO₂ | `0x2B8C` | Read/Notify | uint16, ppm |
| PM2.5 | `0x2BD6` | Read/Notify | float16, µg/m³ |
| PM1.0 | `0x2BD5` | Read/Notify | float16, µg/m³ |
| PM10 | `0x2BD7` | Read/Notify | float16, µg/m³ |

### Log Cell Format (57 bytes)

Each log cell contains a complete environmental snapshot:

```
Offset  Size   Type     Field
──────  ────   ────     ─────
0       4      uint32   Cell number (0-based index)
4       1      uint8    Flags
5-7     3      padding  (unused)
8       8      uint64   RTC timestamp
16      4      int32    Temperature (÷1000 → °C)
20      2      uint16   Pressure (÷10 → hPa)
22      2      uint16   Humidity (÷100 → %)
24      2      uint16   CO₂ (ppm)
26      2      uint16   PM1.0 (÷100 → µg/m³)
28      2      uint16   PM2.5 (÷100 → µg/m³)
30      2      uint16   PM4.0 (÷100 → µg/m³)
32      2      uint16   PM10 (÷100 → µg/m³)
34-42   10     uint16×5 Particle counts (PN0.5–PN10)
44      1      uint8    VOC index
45      1      uint8    NOx index
46      2      uint16   CO₂ uncompensated
48      4      float32  Stroop mean time (congruent)
52      4      float32  Stroop mean time (incongruent)
56      1      uint8    Stroop throughput
```

---

## Persistence with SwiftData

SwiftData is Apple's framework for storing data in a local SQLite database.
Think of it like a spreadsheet that lives on the phone.

### Models

**`LogCellEntity`** — One historical measurement:
- Has a `compositeKey` (`deviceId-cellNumber`) for uniqueness
- Prevents duplicates when re-downloading the same cells
- Stores all sensor values as native Swift types

**`DeviceProfile`** — A known device:
- Stores `deviceId` (the Bluetooth UUID), display names, room label
- Tracks `lastConnectedAt` for auto-reconnect ordering
- Has `sortOrder` for user-defined device list ordering

### Container Setup

The `ModelContainer` is created in `uCritAirApp.init()` with three-tier
fallback:

1. **Try normal creation** → success in most cases
2. **If migration fails** → delete old database, retry
3. **If that fails too** → use in-memory store (data won't persist)

---

## Key Design Patterns

### 1. `@Observable` (iOS 17+)

Instead of `@Published` + `ObservableObject` (the old way), we use the
`@Observable` macro. It automatically tracks property access:

```swift
@Observable
final class SensorViewModel {
    var current: SensorValues = .empty  // SwiftUI tracks reads automatically
}
```

Any view that reads `sensorVM.current` will re-render when it changes.
No manual `objectWillChange.send()` needed.

### 2. Async/Await with Continuations

CoreBluetooth uses old-style callbacks. We bridge them to modern
`async/await` using `CheckedContinuation`:

```swift
// Store a "promise" that will be fulfilled later
func readCharacteristic(_ uuid: CBUUID) async throws -> Data {
    return try await withCheckedThrowingContinuation { continuation in
        pendingReads[uuid] = continuation  // save for later
        peripheral.readValue(for: char)    // ask Bluetooth for data
    }
    // This function is SUSPENDED here until the continuation is resumed
}

// When Bluetooth delivers the data, fulfill the promise
func peripheral(didUpdateValueFor characteristic: ...) {
    if let continuation = pendingReads.removeValue(forKey: uuid) {
        continuation.resume(returning: data)  // wake up the suspended function
    }
}
```

### 3. Environment Injection

Instead of passing dependencies through init parameters, we use SwiftUI's
environment:

```swift
// In the app root:
ContentView()
    .environment(bleManager)
    .environment(deviceVM)

// In any child view:
@Environment(DeviceViewModel.self) private var deviceVM
```

### 4. Defensive BLE Parsing

BLE data can be truncated or corrupted. Every parsing path has size guards:

```swift
// In BLEManager (notification handler):
case BLEConstants.essTemperature:
    guard data.count >= 2 else { break }  // don't crash on short data
    let temp = BLEParsers.parseTemperature(data)

// In BLECharacteristics (explicit reads):
static func readStats(...) async throws -> PetStats {
    let data = try await manager.readCharacteristic(...)
    guard data.count >= 6 else { throw BLEError.noData }
    return BLEParsers.parseStats(data)
}
```

### 5. User-Friendly Error Messages

Raw CoreBluetooth errors are cryptic. The app maps them to actionable messages:

```swift
static func friendlyMessage(for error: Error, context: String) -> String {
    let nsError = error as NSError
    if nsError.domain == "CBErrorDomain" {
        switch nsError.code {
        case 6, 7: return "\(context): Connection lost. Try again."
        case 14:   return "\(context): Device rejected the request."
        default:   return "\(context): Bluetooth error. Try reconnecting."
        }
    }
    return "\(context): \(error.localizedDescription)"
}
```

---

## File Map

```
uCritAir/
├── App/
│   ├── uCritAirApp.swift          App entry point, DI container
│   ├── ContentView.swift          Root tab view
│   └── Info.plist                 App configuration
│
├── BLE/
│   ├── BLEManager.swift           CoreBluetooth central manager
│   ├── BLECharacteristics.swift   Typed read/write API
│   ├── BLEParsers.swift           Binary data parsers
│   ├── BLELogStream.swift         Bulk log cell download
│   └── BLEConstants.swift         UUIDs and protocol constants
│
├── Models/
│   ├── SensorValues.swift         Live sensor readings (in-memory)
│   ├── SensorReading.swift        Timestamped sensor snapshot
│   ├── ParsedLogCell.swift        Parsed log cell from BLE
│   ├── LogCellEntity.swift        SwiftData persisted log cell
│   ├── DeviceProfile.swift        SwiftData persisted device info
│   ├── DeviceConfig.swift         16-byte device config struct
│   ├── PetStats.swift             Virtual pet health stats
│   ├── AQScoreResult.swift        Air quality grade result
│   └── CharacteristicDef.swift    BLE characteristic definitions
│
├── ViewModels/
│   ├── DeviceViewModel.swift      Device connection & registry
│   ├── SensorViewModel.swift      Live sensor data
│   └── HistoryViewModel.swift     Historical data & charts
│
├── Views/
│   ├── Dashboard/
│   │   ├── DashboardView.swift    Live sensor grid
│   │   ├── AQGaugeView.swift      Air quality gauge
│   │   └── SensorCardView.swift   Individual sensor card
│   ├── History/
│   │   ├── HistoryView.swift      Chart timeline
│   │   └── SensorChartView.swift  Line chart component
│   ├── Device/
│   │   ├── DeviceListView.swift   Device management list
│   │   ├── DeviceView.swift       Device settings editor
│   │   └── DeviceCardRow.swift    Device card component
│   ├── Developer/
│   │   └── DeveloperView.swift    Raw BLE inspector
│   └── Shared/
│       ├── ConnectButton.swift    BLE connect/disconnect
│       └── StatusBanner.swift     Error/status banner
│
├── Services/
│   ├── AQIScoring.swift           Air quality grade computation
│   ├── CSVExporter.swift          CSV file generation
│   ├── LogCellStore.swift         SwiftData CRUD for log cells
│   ├── TimelineFilter.swift       Chart point reduction algorithm
│   └── UnitFormatters.swift       Date/unit formatting
│
├── Extensions/
│   ├── Data+Parsing.swift         Binary read/write helpers
│   └── Color+Hex.swift            Hex color parsing
│
└── Resources/
    ├── Assets.xcassets/           App icon and colors
    └── PrivacyInfo.xcprivacy     Apple privacy manifest
```

---

## Glossary

| Term | Definition |
|------|-----------|
| **BLE** | Bluetooth Low Energy — a low-power wireless protocol for IoT devices |
| **GATT** | Generic Attribute Profile — the BLE protocol for organizing data into services and characteristics |
| **Characteristic** | A single BLE data point (like "temperature" or "device name") identified by a UUID |
| **Service** | A group of related BLE characteristics (like "Environmental Sensing") |
| **UUID** | Universally Unique Identifier — a 128-bit ID (we use 16-bit short forms like `0x2A6E`) |
| **Notification** | A BLE push mechanism where the device automatically sends updates when a value changes |
| **Continuation** | A Swift concurrency primitive that bridges callback-based APIs to async/await |
| **SwiftData** | Apple's framework for persisting data to a local SQLite database |
| **@Observable** | A Swift macro that automatically tracks property access for reactive UI updates |
| **MVVM** | Model-View-ViewModel — an architecture where Views observe ViewModels which manage Models |
| **ESS** | Environmental Sensing Service — a Bluetooth SIG standard service for environmental sensors |
| **RTC** | Real-Time Clock — the device's internal clock (may drift from actual time) |
| **VOC** | Volatile Organic Compounds — gaseous chemicals from paints, furniture, cleaning products |
| **NOx** | Nitrogen Oxides — gases from combustion (cars, gas stoves) |
| **PM2.5** | Particulate Matter ≤2.5 micrometers — tiny particles that can enter your lungs |
| **AQI** | Air Quality Index — a numerical scale from "good" to "hazardous" |
| **Stroop** | A cognitive test measuring reaction time (built into the uCrit device) |
