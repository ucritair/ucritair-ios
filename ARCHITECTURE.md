# uCritAir iOS Architecture

## Purpose
uCritAir is an iOS companion app for the uCrit air-quality monitor. It connects over BLE, shows live readings, downloads device history, persists data locally, and exports CSV.

## Stack
- UI: SwiftUI + Observation (`@Observable`)
- BLE: CoreBluetooth
- Persistence: SwiftData
- Charts: Swift Charts
- Concurrency: Swift async/await + continuations for BLE callbacks

## Module Layout
- `uCritAir/App`
- `uCritAir/BLE`
- `uCritAir/ViewModels`
- `uCritAir/Models`
- `uCritAir/Services`
- `uCritAir/Views`
- `uCritAir/Extensions`

## Responsibilities
### App
- `uCritAirApp.swift`: Creates the shared `ModelContainer`, `BLEManager`, and view models.
- `ContentView.swift`: Root tab structure and app-level lifecycle wiring.

### BLE Layer
- `BLEManager.swift`: Connection lifecycle, service/characteristic discovery, notification routing, read/write bridging.
- `BLECharacteristics.swift`: Typed BLE operations used by view models.
- `BLEParsers.swift`: Binary decoding for sensor packets, log cells, and pet stats.
- `BLELogStream.swift`: Bulk log-cell streaming with timeout and progress handling.
- `BLEConstants.swift`: UUIDs and protocol constants.

### ViewModels
- `DeviceViewModel.swift`: Device identity/config/pet metadata and known-device management.
- `SensorViewModel.swift`: Live sensor state and short-window trend data.
- `HistoryViewModel.swift`: Cached history, time filtering, chart points, statistics, CSV export.

### Models
- Runtime and persistence types: `SensorValues`, `ParsedLogCell`, `LogCellEntity`, `DeviceProfile`, `DeviceConfig`, `PetStats`, `AQScoreResult`, related supporting types.

### Services
- `AQIScoring.swift`: Air-quality scoring and grading.
- `LogCellStore.swift`: SwiftData persistence helpers for history cells.
- `CSVExporter.swift`: CSV generation and temp-file output.
- `TimelineFilter.swift`: Monotonic timeline filtering for chart correctness.
- `UnitFormatters.swift`: Shared numeric/date/unit formatting helpers.

## Data Flows
### Live readings
1. `BLEManager` subscribes to ESS and custom characteristics.
2. Notification payloads are parsed in `BLEParsers`.
3. Parsed partial updates are emitted to observers.
4. `SensorViewModel` merges updates into `SensorValues`.
5. SwiftUI re-renders bound views.

### Historical sync
1. `HistoryViewModel` asks for latest device cell count.
2. `BLELogStream` requests and receives log-cell notifications.
3. `BLEParsers` decodes cells into `ParsedLogCell`.
4. `LogCellStore` upserts `LogCellEntity` in SwiftData.
5. `HistoryViewModel` computes filtered/chart-ready datasets and export payloads.

## State and Concurrency
- BLE callbacks run on the main queue (`CBCentralManager(..., queue: .main)`).
- Async BLE reads/writes are bridged with checked continuations keyed by characteristic UUID.
- View models are main-actor oriented and update UI-observed state synchronously on main.

## Persistence Rules
- Data is device-scoped by `deviceId`.
- `LogCellEntity.compositeKey` prevents duplicate cell inserts.
- History views query from local cache first; BLE sync is incremental.

## Reliability Constraints
- Unknown/short BLE payloads are treated as recoverable failures.
- Connect/disconnect paths clean up timers, caches, and pending operations.
- History/chart pipeline is resilient to time discontinuities via `TimelineFilter`.

## Release-Critical Artifacts
- `uCritAir/App/Info.plist`
- `uCritAir/Resources/PrivacyInfo.xcprivacy`
- `project.yml` and `uCritAir.xcodeproj`
- `uCritAirTests/*`

## Not in Scope
- External backend services (none used by the app).
- Telemetry/analytics pipeline (none present).
