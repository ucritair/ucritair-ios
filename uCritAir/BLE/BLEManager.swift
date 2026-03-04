import CoreBluetooth
import os.log

// MARK: - File Overview
// ======================================================================================
// BLEManager.swift — Core BLE Connection Manager for uCritAir
// ======================================================================================
//
// This is the most complex file in the BLE layer. It manages the entire lifecycle of
// a Bluetooth Low Energy connection to the uCrit air quality monitor, including:
//
//   1. Scanning for nearby uCrit devices
//   2. Connecting to a selected device
//   3. Discovering GATT services and characteristics
//   4. Reading and writing characteristic values (with async/await bridging)
//   5. Subscribing to ESS notifications for real-time sensor data
//   6. Polling the "live cell" for VOC/NOx/PM4.0 readings
//   7. Handling unexpected disconnects with automatic reconnection
//   8. Providing log stream notification forwarding for BLELogStream
//
// ## Background: CoreBluetooth's Delegate Pattern
//
// Apple's CoreBluetooth framework uses the **delegate pattern**, which is callback-based:
// you call a method (e.g., `peripheral.readValue(for:)`), and CoreBluetooth later calls
// a delegate method with the result (e.g., `peripheral(_:didUpdateValueFor:error:)`).
// This is fundamentally different from modern Swift async/await, where you write
// `let data = try await readCharacteristic(uuid)` and the result comes back inline.
//
// This file bridges the two patterns using **checked continuations** — a Swift
// concurrency primitive that lets you wrap callback-based APIs in async/await.
// See the `pendingReads` and `pendingWrites` dictionaries for how this works.
//
// ## Key Design Patterns
//
// ### Continuation Bridging (Callback -> Async/Await)
// The `readCharacteristic()` method stores a continuation in `pendingReads[uuid]`, then
// calls `peripheral.readValue(for:)`. When the delegate callback fires, it looks up the
// continuation by UUID, resumes it with the result, and removes it from the dictionary.
// This converts CoreBluetooth's callback pattern into a simple `try await` call.
//
// ### State Machine
// The connection lifecycle follows a state machine:
//   disconnected -> scanning -> connecting -> connected
//                                    |              |
//                                    v              v
//                              (timeout)    (unexpected disconnect)
//                                    |              |
//                                    v              v
//                              reconnecting --------+
//                                    |
//                                    v (max attempts exceeded)
//                              disconnected
//
// ### Service Discovery Flow
// After connecting, the app must discover which services and characteristics the
// device offers. This happens in two phases:
//   1. `discoverServices()` -> delegate: `didDiscoverServices` (finds services)
//   2. `discoverCharacteristics()` -> delegate: `didDiscoverCharacteristicsFor` (finds characteristics)
// Only after BOTH the custom service and ESS service have their characteristics
// discovered does the connection move to the `.connected` state.
//
// ## Architecture
//
//   ContentView / ViewModels
//         |
//         v
//   BLEManager (this file) — owns the CBCentralManager, handles all BLE events
//         |
//         +-- BLECharacteristics — typed read/write API (calls readCharacteristic/writeCharacteristic)
//         +-- BLELogStream — bulk download (uses onLogStreamNotification callback)
//         +-- BLEParsers — binary data decoding (called from delegate methods)
//         |
//         v
//   CoreBluetooth (Apple framework) — talks to the BLE radio hardware
//
// Ported from the web app's `src/ble/connection.ts` -> `BleConnection` class.
// ======================================================================================

/// The connection lifecycle states for the BLE manager.
///
/// These states form a finite state machine that the UI observes to show appropriate
/// feedback (scanning spinner, "connecting..." text, connected indicator, etc.).
/// The `String` raw value enables easy debugging and logging.
///
/// ## State Transitions
/// ```
/// disconnected  --scan()-->        scanning
/// scanning      --didDiscover-->   scanning (stays, accumulates peripherals)
/// scanning      --connect(to:)-->  connecting
/// connecting    --didConnect-->     connected (after service discovery)
/// connecting    --timeout-->       reconnecting (or disconnected)
/// connected     --didDisconnect--> reconnecting (or disconnected)
/// reconnecting  --didConnect-->    connected
/// reconnecting  --max attempts-->  disconnected
/// ```
///
/// Conforms to `Sendable` because it is shared across the main actor and SwiftUI views.
enum ConnectionState: String, Sendable {
    /// No device is connected and no scan or connection attempt is in progress.
    case disconnected

    /// Actively scanning for nearby uCrit devices advertising the custom service UUID.
    case scanning

    /// A connection attempt is in progress (waiting for CoreBluetooth to establish the link).
    case connecting

    /// Fully connected: services discovered, characteristics cached, ESS subscribed, polling active.
    case connected

    /// An unexpected disconnect occurred and the manager is attempting to automatically reconnect.
    case reconnecting
}

/// The central BLE connection manager for the uCrit air quality monitor.
///
/// This class owns the `CBCentralManager` (CoreBluetooth's entry point for BLE operations)
/// and implements both `CBCentralManagerDelegate` and `CBPeripheralDelegate` to handle all
/// BLE events: scanning, connecting, service discovery, characteristic reads/writes,
/// notifications, disconnects, and reconnection.
///
/// ## Observation
/// Marked with `@Observable` (Swift Observation framework) so that SwiftUI views
/// automatically re-render when ``connectionState``, ``discoveredPeripherals``, or
/// ``bluetoothState`` change. This replaces the older `@Published` + `ObservableObject`
/// pattern with a more efficient, compile-time mechanism.
///
/// ## Why `NSObject`?
/// CoreBluetooth's delegate protocols (`CBCentralManagerDelegate`, `CBPeripheralDelegate`)
/// are Objective-C protocols that require the delegate to be an `NSObject` subclass.
/// This is a historical requirement from CoreBluetooth's Objective-C origins.
///
/// ## Why `final`?
/// Marked `final` because this class is not designed to be subclassed. This also enables
/// the compiler to optimize method dispatch (static instead of dynamic dispatch).
///
/// ## Threading
/// All CoreBluetooth delegate callbacks are delivered on the main queue (specified via
/// `CBCentralManager(delegate:self, queue: .main)` in `init()`). All property mutations
/// and continuation resumes happen on the main queue to avoid data races.
///
/// Ported from the web app's `src/ble/connection.ts` -> `BleConnection` class.
@Observable
final class BLEManager: NSObject {

    // MARK: - Observable State (UI-Facing)
    // These properties are observed by SwiftUI views and ViewModels to update the UI.

    /// The current state of the BLE connection lifecycle.
    ///
    /// SwiftUI views observe this to show scanning spinners, connection status indicators,
    /// and disable/enable controls based on whether the device is connected.
    /// See ``ConnectionState`` for the full state machine documentation.
    var connectionState: ConnectionState = .disconnected

    /// Peripherals discovered during a BLE scan that advertise the uCrit custom service.
    ///
    /// Populated by ``centralManager(_:didDiscover:advertisementData:rssi:)`` during scanning.
    /// Cleared when a new scan begins. The UI displays these in a list for the user to
    /// select which device to connect to.
    ///
    /// `private(set)` means ViewModels can read this array but only BLEManager can modify it.
    private(set) var discoveredPeripherals: [CBPeripheral] = []

    /// The current state of the Bluetooth hardware and authorization.
    ///
    /// Reflects `CBCentralManager.state` — used by the UI to show appropriate messages:
    /// - `.poweredOn`: Bluetooth is on and ready
    /// - `.poweredOff`: User needs to enable Bluetooth in Settings
    /// - `.unauthorized`: App needs Bluetooth permission
    /// - `.unsupported`: Device does not have BLE hardware
    /// - `.unknown` / `.resetting`: Transient states during startup
    private(set) var bluetoothState: CBManagerState = .unknown

    // MARK: - Internal Connection State
    // These properties track the current connection and cached BLE objects.

    /// The currently connected (or connecting) CBPeripheral, or `nil` if disconnected.
    ///
    /// Set during ``connect(to:)`` and cleared during ``cleanupConnection()``.
    /// `private(set)` allows read access from other BLE layer files (e.g., BLELogStream)
    /// while restricting writes to this class.
    private(set) var connectedPeripheral: CBPeripheral?

    /// The CoreBluetooth central manager — the entry point for all BLE operations.
    ///
    /// Implicitly unwrapped (`!`) because `CBCentralManager(delegate:)` requires `self`
    /// as the delegate, but `self` is not fully initialized until after `super.init()`.
    /// So we declare it as `CBCentralManager!` and assign it immediately after `super.init()`.
    /// It is always non-nil after `init()` completes — the `!` is a technical necessity,
    /// not an indication that it could be nil during normal operation.
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var centralManager: CBCentralManager!

    /// Cached reference to the discovered custom vendor GATT service.
    ///
    /// Set during service discovery (`didDiscoverServices`), cleared on disconnect.
    /// Used to verify that service discovery completed before transitioning to `.connected`.
    private var customService: CBService?

    /// Cached reference to the discovered Environmental Sensing Service (ESS).
    ///
    /// Set during service discovery, cleared on disconnect. May be `nil` if the device
    /// does not expose ESS (though all uCrit devices should).
    private var essService: CBService?

    /// Cache of discovered CBCharacteristic objects, keyed by their UUID.
    ///
    /// Populated during characteristic discovery (`didDiscoverCharacteristicsFor`).
    /// Used by ``readCharacteristic(_:)`` and ``writeCharacteristic(_:data:)`` to look up
    /// the CBCharacteristic object needed for CoreBluetooth read/write calls.
    ///
    /// This cache avoids re-discovering characteristics on every read/write, which would
    /// be extremely slow. Once discovered, characteristics remain valid for the lifetime
    /// of the connection.
    private var characteristicCache: [CBUUID: CBCharacteristic] = [:]

    // MARK: - Reconnection Configuration
    // These constants and variables control automatic reconnection after unexpected disconnects.
    // Values match the web app: 2 attempts, 3-second delay between attempts, 5-second timeout.

    /// Number of reconnection attempts made so far for the current disconnect event.
    /// Reset to 0 on successful connection or when the user manually calls ``connect(to:)``.
    private var reconnectAttempts = 0

    /// Maximum number of automatic reconnection attempts before giving up.
    /// After this many failures, the state transitions to `.disconnected` and the user
    /// must manually reconnect via the Connect button.
    private let maxReconnectAttempts = 2

    /// Delay in seconds before each reconnection attempt.
    /// Gives the BLE radio time to reset and the device time to become discoverable again.
    private let reconnectDelay: TimeInterval = 3.0

    /// Maximum seconds to wait for a connection attempt to succeed.
    /// If CoreBluetooth does not call `didConnect` within this window, the attempt is
    /// considered failed and ``handleDisconnect()`` is invoked.
    private let connectTimeout: TimeInterval = 5.0

    /// Cancellable work item for the current connection timeout timer.
    /// Created by ``startConnectTimeout()`` and cancelled by ``cancelConnectTimeout()``.
    private var connectTimeoutWork: DispatchWorkItem?

    // MARK: - Current Cell Polling
    // The device has sensors (VOC, NOx, PM4.0) that are NOT exposed via ESS notifications.
    // To get live readings for these, we poll the "current cell" every 5 seconds.

    /// Repeating timer that polls the current (live) log cell for VOC/NOx/PM4.0 readings.
    ///
    /// Created by ``startCurrentCellPolling()``, invalidated by ``stopCurrentCellPolling()``.
    /// Paused during log streaming to avoid BLE operation conflicts.
    private var pollTimer: Timer?

    // MARK: - Async/Await Continuation Bridging
    // CoreBluetooth uses the delegate pattern (callbacks), but the rest of the app uses
    // Swift async/await. These dictionaries bridge the two worlds using CheckedContinuations.
    //
    // Flow:
    //   1. readCharacteristic() stores a continuation in pendingReads[uuid]
    //   2. It calls peripheral.readValue(for:) which is asynchronous
    //   3. CoreBluetooth eventually calls didUpdateValueFor (the delegate callback)
    //   4. The delegate looks up pendingReads[uuid], resumes the continuation with the result
    //   5. The original caller's `try await` returns with the data
    //
    // Only ONE read and ONE write per UUID can be pending at a time. Attempting a second
    // concurrent operation for the same UUID throws BLEError.operationInProgress.

    /// Pending async read continuations, keyed by characteristic UUID.
    ///
    /// When `readCharacteristic()` is called, a continuation is stored here. When the
    /// CoreBluetooth delegate `didUpdateValueFor` fires, the continuation is looked up
    /// by UUID, resumed with the result data (or error), and removed from this dictionary.
    private var pendingReads: [CBUUID: CheckedContinuation<Data, Error>] = [:]

    /// Pending async write continuations, keyed by characteristic UUID.
    ///
    /// Same pattern as `pendingReads` but for write operations. The continuation is
    /// resumed when `didWriteValueFor` fires, confirming the write succeeded or failed.
    private var pendingWrites: [CBUUID: CheckedContinuation<Void, Error>] = [:]

    // MARK: - Service Discovery Continuation
    // These are used when awaiting service/characteristic discovery completion.

    /// Continuation for awaiting the completion of service and characteristic discovery.
    /// Resumed when all expected services have their characteristics discovered.
    private var serviceDiscoveryContinuation: CheckedContinuation<Void, Error>?

    /// Number of services that have completed characteristic discovery so far.
    private var charDiscoveryCount = 0

    /// Number of services that need characteristic discovery (typically 2: custom + ESS).
    private var charDiscoveryTarget = 0

    // MARK: - ViewModel Callbacks
    // These closures allow ViewModels to receive BLE events without tight coupling.
    // The BLEManager does not import or reference any ViewModel directly.

    /// Callback invoked when new sensor data arrives (from ESS notifications or cell polling).
    ///
    /// The ``PartialSensorUpdate`` contains only the fields that changed — the ViewModel
    /// merges it into its full ``SensorValues`` using ``SensorValues/merge(_:)``.
    ///
    /// Set by `DeviceViewModel` during initialization. Called on the main queue.
    var onSensorUpdate: ((PartialSensorUpdate) -> Void)?

    /// Callback invoked whenever the ``connectionState`` changes.
    ///
    /// Used by ViewModels to trigger side effects on connection/disconnection
    /// (e.g., reading initial device data after connecting, clearing state on disconnect).
    var onConnectionStateChanged: ((ConnectionState) -> Void)?

    /// Callback for raw log stream notification payloads.
    ///
    /// Set by ``BLELogStream`` before starting a bulk download. When a notification arrives
    /// on the log stream characteristic (`0x0006`), the raw `Data` is forwarded here
    /// instead of being parsed as a sensor update. Cleared by BLELogStream on completion.
    var onLogStreamNotification: ((Data) -> Void)?

    /// One-shot callback for when the Bluetooth hardware becomes ready (`poweredOn`).
    ///
    /// Used during app launch to delay auto-reconnection until Bluetooth is available.
    /// Fires at most once, then is set to `nil`. If Bluetooth is already on when
    /// ``whenBluetoothReady(_:)`` is called, the callback fires immediately.
    private var onBluetoothReady: (() -> Void)?

    /// Logger instance for BLE-related events (connections, errors, state changes).
    /// Uses Apple's unified logging system (`os.log`) with the "BLE" category.
    private let logger = Logger(subsystem: "com.ucritter.ucritair", category: "BLE")

    // MARK: - Initialization

    /// Create a new BLEManager and initialize the CoreBluetooth central manager.
    ///
    /// The `CBCentralManager` is created with `queue: .main`, meaning all delegate
    /// callbacks will be delivered on the main queue. This simplifies thread safety
    /// since all UI updates and state mutations also happen on the main queue.
    ///
    /// ## Why Two-Phase Init?
    /// `CBCentralManager(delegate: self, queue:)` requires `self` as the delegate,
    /// but `self` is not available until after `super.init()`. So we first call
    /// `super.init()`, then create the central manager. The `centralManager` property
    /// is implicitly unwrapped (`!`) to accommodate this pattern.
    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: .main)
    }

    // MARK: - Computed Properties

    /// The stable BLE identifier (UUID string) of the currently connected device, or `nil`.
    ///
    /// This identifier persists across app launches and can be used to reconnect to
    /// a previously known device without scanning. It is stored in the device's SwiftData
    /// record so the app can auto-reconnect on next launch.
    ///
    /// Note: This is NOT the device's MAC address (which iOS hides for privacy). It is
    /// a stable identifier assigned by CoreBluetooth that uniquely identifies the device
    /// on THIS specific iPhone.
    var connectedDeviceId: String? {
        connectedPeripheral?.identifier.uuidString
    }

    /// Register a one-shot callback for when Bluetooth hardware becomes ready.
    ///
    /// If Bluetooth is already powered on, the callback fires immediately (synchronously).
    /// Otherwise, it is stored and fired when ``centralManagerDidUpdateState(_:)``
    /// receives `.poweredOn`. The callback fires at most once and is then discarded.
    ///
    /// This is used during app launch: the app wants to auto-reconnect to the last device,
    /// but cannot issue BLE commands until the radio is powered on. Instead of polling
    /// `centralManager.state`, it registers a callback that triggers reconnection.
    ///
    /// - Parameter callback: Closure to execute when Bluetooth is ready. Called on the main queue.
    func whenBluetoothReady(_ callback: @escaping () -> Void) {
        if centralManager.state == .poweredOn {
            callback()
        } else {
            onBluetoothReady = callback
        }
    }

    // MARK: - Public API (Connection Management)
    // These methods are called by ViewModels and the app's UI layer to control the
    // BLE connection lifecycle: scan, connect, reconnect, disconnect.

    /// Attempt to reconnect to a previously paired device without scanning.
    ///
    /// CoreBluetooth maintains a cache of known peripherals. `retrievePeripherals(withIdentifiers:)`
    /// returns a `CBPeripheral` object for a device the system has seen before, even if
    /// the device is not currently advertising. This is much faster than a full scan.
    ///
    /// If the device is not found in CoreBluetooth's cache (e.g., Bluetooth was reset,
    /// or the device has never been seen by this iPhone), falls back to a full scan.
    ///
    /// Called during app launch when a previously connected device ID is stored in SwiftData.
    ///
    /// - Parameter identifier: The `UUID` of the peripheral to reconnect to. This is the
    ///   value previously obtained from ``connectedDeviceId`` and persisted.
    func reconnectToKnownDevice(identifier: UUID) {
        // Ask CoreBluetooth for a peripheral with this identifier from its internal cache.
        // This does NOT require the device to be advertising — it returns a CBPeripheral
        // object that can be used for connection even if the device is sleeping.
        let peripherals = centralManager.retrievePeripherals(withIdentifiers: [identifier])
        if let peripheral = peripherals.first {
            connect(to: peripheral)
        } else {
            // Device not in CoreBluetooth's cache — fall back to a full scan.
            // This can happen if Bluetooth was reset or the device was never seen by this phone.
            logger.info("Known device not found nearby, starting scan")
            scan()
        }
    }

    /// Start scanning for nearby uCrit devices.
    ///
    /// Scans for peripherals advertising the uCrit custom service UUID. Only devices
    /// that include ``BLEConstants/customServiceUUID`` in their advertisement packets
    /// will be reported — all other BLE devices are filtered out by CoreBluetooth.
    ///
    /// Discovered peripherals are accumulated in ``discoveredPeripherals`` via the
    /// ``centralManager(_:didDiscover:advertisementData:rssi:)`` delegate callback.
    ///
    /// The scan runs indefinitely until either:
    /// - ``connect(to:)`` is called (which stops the scan automatically)
    /// - ``disconnect()`` is called
    /// - Bluetooth is turned off
    ///
    /// ## Note on `CBCentralManagerScanOptionAllowDuplicatesKey`
    /// Setting this to `false` means CoreBluetooth will only report each peripheral once,
    /// even if it sends multiple advertisement packets. This reduces noise and battery usage.
    func scan() {
        guard centralManager.state == .poweredOn else {
            logger.warning("Cannot scan: Bluetooth not powered on")
            return
        }

        // Clear any previously discovered peripherals from a prior scan.
        discoveredPeripherals = []
        setState(.scanning)

        // Begin scanning with a service UUID filter.
        // Only peripherals advertising the uCrit custom service UUID will be reported.
        centralManager.scanForPeripherals(
            withServices: [BLEConstants.customServiceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }

    /// Connect to a discovered peripheral.
    ///
    /// Stops any active scan, sets this peripheral as the connection target, and begins
    /// the CoreBluetooth connection process. A timeout is started — if the connection
    /// does not succeed within ``connectTimeout`` seconds, the attempt is cancelled and
    /// reconnection logic is triggered.
    ///
    /// After a successful connection (reported via ``centralManager(_:didConnect:)``),
    /// the manager automatically discovers services and characteristics, subscribes to
    /// ESS notifications, and starts current-cell polling.
    ///
    /// - Parameter peripheral: The `CBPeripheral` to connect to. Typically selected from
    ///   ``discoveredPeripherals`` or retrieved via ``reconnectToKnownDevice(identifier:)``.
    func connect(to peripheral: CBPeripheral) {
        centralManager.stopScan()              // Stop scanning — we found our device
        connectedPeripheral = peripheral       // Store reference (needed for all future operations)
        peripheral.delegate = self             // Set ourselves as the peripheral's delegate
        setState(.connecting)
        reconnectAttempts = 0                  // Reset reconnection counter for fresh connections

        // Start a timeout timer. If CoreBluetooth does not call didConnect within
        // `connectTimeout` seconds, we cancel the attempt and try reconnecting.
        startConnectTimeout()
        centralManager.connect(peripheral, options: nil)
    }

    /// Intentionally disconnect from the current device and stop all BLE activity.
    ///
    /// This is a **user-initiated** disconnect (via the Disconnect button), as opposed
    /// to an unexpected disconnect (which triggers automatic reconnection).
    ///
    /// Key difference from unexpected disconnect: we set `reconnectAttempts` to the
    /// maximum to prevent ``handleDisconnect()`` from attempting auto-reconnection
    /// when CoreBluetooth delivers the `didDisconnectPeripheral` callback.
    func disconnect() {
        centralManager.stopScan()
        stopCurrentCellPolling()
        cancelConnectTimeout()

        // Set reconnect attempts to max to suppress auto-reconnection.
        // When CoreBluetooth delivers `didDisconnectPeripheral`, the guard in that
        // delegate method sees `.disconnected` state and skips handleDisconnect().
        reconnectAttempts = maxReconnectAttempts

        if let peripheral = connectedPeripheral {
            centralManager.cancelPeripheralConnection(peripheral)
        }

        cleanupConnection()
        setState(.disconnected)
    }

    // MARK: - Characteristic Read/Write API
    // These methods bridge CoreBluetooth's callback-based read/write into async/await.
    // They are called by BLECharacteristics (typed layer) and BLELogStream (streaming).

    /// Read the current value of a characteristic from the connected device.
    ///
    /// This method bridges CoreBluetooth's callback-based read into Swift async/await
    /// using a `CheckedContinuation`. The flow is:
    ///
    /// 1. Look up the cached `CBCharacteristic` object by UUID
    /// 2. Store a continuation in ``pendingReads`` keyed by UUID
    /// 3. Call `peripheral.readValue(for:)` to initiate the BLE read
    /// 4. CoreBluetooth asynchronously calls ``peripheral(_:didUpdateValueFor:error:)``
    /// 5. The delegate looks up the continuation in ``pendingReads``, resumes it, and removes it
    /// 6. This method returns the `Data` to the caller
    ///
    /// ## Concurrency Guard
    /// Only one read per UUID can be pending at a time. If a second read for the same
    /// UUID is attempted while one is already in flight, ``BLEError/operationInProgress``
    /// is thrown. This prevents continuation leaks (where two callers store continuations
    /// for the same UUID, but only one can be resumed by the single delegate callback).
    ///
    /// ## Thread Safety
    /// The continuation storage and `peripheral.readValue(for:)` call are dispatched to
    /// `DispatchQueue.main` to prevent data races when multiple concurrent reads are
    /// issued (e.g., via `async let` in the ViewModel).
    ///
    /// - Parameter uuid: The `CBUUID` of the characteristic to read.
    /// - Returns: The raw `Data` payload returned by the device.
    /// - Throws: ``BLEError/characteristicNotFound(_:)`` if the UUID is not in the cache,
    ///           ``BLEError/notConnected`` if no peripheral is connected,
    ///           ``BLEError/operationInProgress`` if a read for this UUID is already pending,
    ///           or any `Error` from CoreBluetooth if the read fails.
    func readCharacteristic(_ uuid: CBUUID) async throws -> Data {
        guard let char = characteristicCache[uuid] else {
            throw BLEError.characteristicNotFound(uuid)
        }
        guard let peripheral = connectedPeripheral else {
            throw BLEError.notConnected
        }

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.main.async {
                // Guard: only one pending read per UUID at a time.
                if self.pendingReads[uuid] != nil {
                    continuation.resume(throwing: BLEError.operationInProgress)
                    return
                }
                // Store the continuation — it will be resumed by didUpdateValueFor.
                self.pendingReads[uuid] = continuation
                // Initiate the BLE read. CoreBluetooth will call didUpdateValueFor when done.
                peripheral.readValue(for: char)
            }
        }
    }

    /// Write data to a characteristic on the connected device, waiting for confirmation.
    ///
    /// Uses the `.withResponse` write type, meaning the device acknowledges the write.
    /// The method does not return until the device confirms the write succeeded (via
    /// the ``peripheral(_:didWriteValueFor:error:)`` delegate callback).
    ///
    /// The continuation bridging pattern is the same as ``readCharacteristic(_:)`` —
    /// see that method's documentation for a detailed explanation.
    ///
    /// ## Write Types in BLE
    /// BLE defines two write types:
    /// - `.withResponse`: The device sends an acknowledgment. Slower but reliable.
    /// - `.withoutResponse`: Fire-and-forget. Faster but no delivery guarantee.
    /// We always use `.withResponse` for data integrity.
    ///
    /// - Parameters:
    ///   - uuid: The `CBUUID` of the characteristic to write.
    ///   - data: The raw bytes to write to the characteristic.
    /// - Throws: ``BLEError/characteristicNotFound(_:)`` if the UUID is not in the cache,
    ///           ``BLEError/notConnected`` if no peripheral is connected,
    ///           ``BLEError/operationInProgress`` if a write for this UUID is already pending,
    ///           or any `Error` from CoreBluetooth if the write fails.
    func writeCharacteristic(_ uuid: CBUUID, data: Data) async throws {
        guard let char = characteristicCache[uuid] else {
            throw BLEError.characteristicNotFound(uuid)
        }
        guard let peripheral = connectedPeripheral else {
            throw BLEError.notConnected
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.main.async {
                // Guard: only one pending write per UUID at a time.
                if self.pendingWrites[uuid] != nil {
                    continuation.resume(throwing: BLEError.operationInProgress)
                    return
                }
                // Store the continuation — it will be resumed by didWriteValueFor.
                self.pendingWrites[uuid] = continuation
                // Initiate the BLE write with response. CoreBluetooth will call
                // didWriteValueFor when the device acknowledges.
                peripheral.writeValue(data, for: char, type: .withResponse)
            }
        }
    }

    /// Read the current value of an ESS (Environmental Sensing Service) characteristic.
    ///
    /// Functionally identical to ``readCharacteristic(_:)`` — the same continuation
    /// bridging and concurrency guard apply. This separate method exists for clarity
    /// in the call site, distinguishing ESS reads from custom vendor characteristic reads.
    ///
    /// - Parameter uuid: The `CBUUID` of the ESS characteristic to read (e.g., ``BLEConstants/essPressure``).
    /// - Returns: The raw `Data` payload returned by the device.
    /// - Throws: Same errors as ``readCharacteristic(_:)``.
    func readESSCharacteristic(_ uuid: CBUUID) async throws -> Data {
        guard let char = characteristicCache[uuid] else {
            throw BLEError.characteristicNotFound(uuid)
        }
        guard let peripheral = connectedPeripheral else {
            throw BLEError.notConnected
        }

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.main.async {
                if self.pendingReads[uuid] != nil {
                    continuation.resume(throwing: BLEError.operationInProgress)
                    return
                }
                self.pendingReads[uuid] = continuation
                peripheral.readValue(for: char)
            }
        }
    }

    // MARK: - Private Helpers (State Management)
    // Internal methods for managing connection state, cleaning up resources, and
    // handling the lifecycle of pending continuations.

    /// Update the connection state and notify all observers.
    ///
    /// This is the single point through which all state transitions flow. It updates
    /// the ``connectionState`` property (which triggers SwiftUI re-renders via `@Observable`)
    /// and calls the ``onConnectionStateChanged`` callback (which triggers ViewModel logic).
    ///
    /// - Parameter state: The new ``ConnectionState`` to transition to.
    private func setState(_ state: ConnectionState) {
        connectionState = state
        onConnectionStateChanged?(state)
    }

    /// Resume all pending async continuations with a disconnection error, then clear them.
    ///
    /// When the device disconnects unexpectedly, any in-flight `readCharacteristic()` or
    /// `writeCharacteristic()` calls are still awaiting their continuations. If we do not
    /// resume these continuations, the callers would hang forever (a "continuation leak").
    ///
    /// This method resumes every pending continuation with ``BLEError/notConnected``,
    /// causing the caller's `try await` to throw that error. Then it clears all dictionaries
    /// so no stale continuations remain.
    ///
    /// **Must be called BEFORE clearing `pendingReads`/`pendingWrites`** — if the
    /// dictionaries were cleared first, the continuations would leak without being resumed.
    private func failPendingContinuations() {
        // Resume all pending read continuations with a disconnection error.
        for (_, continuation) in pendingReads {
            continuation.resume(throwing: BLEError.notConnected)
        }
        pendingReads = [:]

        // Resume all pending write continuations with a disconnection error.
        for (_, continuation) in pendingWrites {
            continuation.resume(throwing: BLEError.notConnected)
        }
        pendingWrites = [:]

        // Resume the service discovery continuation if one is pending.
        if let sc = serviceDiscoveryContinuation {
            sc.resume(throwing: BLEError.notConnected)
            serviceDiscoveryContinuation = nil
        }
    }

    /// Reset all connection-related state to a clean baseline.
    ///
    /// Called after an intentional disconnect or after reconnection attempts are exhausted.
    /// Performs the following cleanup in order:
    /// 1. Clears the peripheral reference (so ``connectedDeviceId`` returns `nil`)
    /// 2. Clears cached service and characteristic objects (they are invalid after disconnect)
    /// 3. Resumes and clears all pending continuations (prevents continuation leaks)
    /// 4. Clears the log stream notification callback (prevents stale callbacks)
    private func cleanupConnection() {
        connectedPeripheral = nil
        customService = nil
        essService = nil
        characteristicCache = [:]
        failPendingContinuations()
        onLogStreamNotification = nil
    }

    /// Schedule a timeout that fires if the connection is not established in time.
    ///
    /// Creates a `DispatchWorkItem` that fires after ``connectTimeout`` seconds. If the
    /// connection state is still `.connecting` or `.reconnecting` when it fires, the
    /// connection attempt is cancelled and ``handleDisconnect()`` is invoked to trigger
    /// reconnection logic.
    ///
    /// The previous timeout (if any) is cancelled first to prevent overlapping timeouts.
    ///
    /// ## Why `DispatchWorkItem` Instead of `Timer`?
    /// `DispatchWorkItem` can be cleanly cancelled without invalidation, and integrates
    /// naturally with `DispatchQueue.main.asyncAfter`. It is also lighter weight than
    /// `Timer` for one-shot timeouts.
    private func startConnectTimeout() {
        cancelConnectTimeout()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.connectionState == .connecting || self.connectionState == .reconnecting else { return }
            self.logger.warning("Connect timeout")
            // Cancel the in-progress connection attempt with CoreBluetooth.
            if let peripheral = self.connectedPeripheral {
                self.centralManager.cancelPeripheralConnection(peripheral)
            }
            // Trigger reconnection logic (or give up if max attempts reached).
            self.handleDisconnect()
        }
        connectTimeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + connectTimeout, execute: work)
    }

    /// Cancel the pending connection timeout, if any.
    ///
    /// Called when a connection succeeds (no longer need the timeout) or when
    /// disconnecting intentionally (no longer care about the timeout).
    private func cancelConnectTimeout() {
        connectTimeoutWork?.cancel()
        connectTimeoutWork = nil
    }

    // MARK: - ESS Subscriptions
    // After connecting and discovering characteristics, we need to start receiving
    // environmental sensor data. Some characteristics support BLE notifications
    // (push from device), while others must be explicitly read (pull from app).

    /// Subscribe to ESS notifications and perform initial reads for non-notify characteristics.
    ///
    /// Called once after service/characteristic discovery completes. Sets up two data flows:
    ///
    /// 1. **Notify characteristics** (temperature, humidity, CO2, PM2.5):
    ///    Calls `setNotifyValue(true, for:)` to tell the device "push me updates."
    ///    The device will then automatically send new values whenever readings change,
    ///    which arrive via ``peripheral(_:didUpdateValueFor:error:)``.
    ///
    /// 2. **Read-only characteristics** (pressure, PM1.0, PM10):
    ///    These do not support notifications in the firmware, so we read them once here.
    ///    Their values change slowly enough that a single read at connection time is sufficient.
    ///
    /// Matches the web app's `subscribeToESS()`.
    private func subscribeToESS() {
        guard let peripheral = connectedPeripheral else { return }

        // Subscribe to characteristics that support BLE notifications.
        // After this, the device will push updates automatically.
        for uuid in BLEConstants.essNotifyCharacteristicUUIDs {
            if let char = characteristicCache[uuid] {
                peripheral.setNotifyValue(true, for: char)
            } else {
                logger.warning("ESS characteristic not found for notification: \(uuid)")
            }
        }

        // Read characteristics that do NOT support notifications (one-time read).
        // These values (pressure, PM1.0, PM10) change slowly and are read once here.
        // The results arrive via didUpdateValueFor and are routed to onSensorUpdate.
        for uuid in BLEConstants.essReadCharacteristicUUIDs {
            if let char = characteristicCache[uuid] {
                peripheral.readValue(for: char)
            }
        }
    }

    // MARK: - Log Stream Notifications
    // These methods are called by BLELogStream to manage the bulk download lifecycle.
    // During a log stream, normal polling must be paused to avoid BLE operation conflicts.

    /// Enable or disable BLE notifications for the log stream characteristic (`0x0006`).
    ///
    /// Called by ``BLELogStream`` to subscribe before starting a bulk download and
    /// unsubscribe after it completes. When enabled, the device sends log cell data
    /// as notification payloads, which arrive via ``peripheral(_:didUpdateValueFor:error:)``
    /// and are forwarded to ``onLogStreamNotification``.
    ///
    /// - Parameter enabled: `true` to subscribe to notifications, `false` to unsubscribe.
    func setLogStreamNotifications(enabled: Bool) {
        guard let peripheral = connectedPeripheral,
              let char = characteristicCache[BLEConstants.charLogStream] else { return }
        peripheral.setNotifyValue(enabled, for: char)
    }

    /// Pause the current-cell polling timer.
    ///
    /// Called by ``BLELogStream`` before starting a bulk download. BLE is a serial
    /// protocol — only one operation can be in flight at a time. If the poll timer
    /// fires during a log stream, the polling read/write would conflict with the
    /// stream's write, causing errors. Pausing prevents this interference.
    func pausePolling() {
        stopCurrentCellPolling()
    }

    /// Resume the current-cell polling timer after a pause.
    ///
    /// Called by ``BLELogStream`` after a bulk download completes (or fails).
    /// Only resumes if the device is still connected — if the connection was lost
    /// during the stream, there is nothing to poll.
    func resumePolling() {
        guard connectionState == .connected else { return }
        startCurrentCellPolling()
    }

    // MARK: - Current Cell Polling
    // The uCrit device has sensors (VOC, NOx, PM4.0) that are NOT exposed via the
    // standard ESS service. The only way to get live readings for these is to read
    // the "current cell" — the device's in-progress log entry that has not yet been
    // committed to flash. This section implements a 5-second polling loop for that data.

    /// Start polling the "current cell" every 5 seconds for live VOC/NOx/PM4.0 readings.
    ///
    /// The uCrit device's SPS30 particulate matter sensor and SGP40 gas sensors expose
    /// their readings through the log cell data structure, but NOT through the standard
    /// ESS service. To get live values for these sensors, the app must:
    ///
    /// 1. Write `0xFFFFFFFF` to the cell selector (selects the live/in-progress cell)
    /// 2. Read the cell data (57 bytes, same format as historical log cells)
    /// 3. Extract VOC, NOx, and PM4.0 values from the parsed cell
    ///
    /// This polling runs every 5 seconds (matching the web app) and starts immediately
    /// after connection. It is paused during log streaming to avoid BLE conflicts.
    private func startCurrentCellPolling() {
        // Stop any existing timer first to prevent duplicates.
        stopCurrentCellPolling()

        // Poll immediately (do not wait 5 seconds for the first reading),
        // then schedule repeating polls every 5 seconds.
        pollCurrentCell()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.pollCurrentCell()
        }
    }

    /// Stop the repeating current-cell poll timer and release it.
    ///
    /// Called when disconnecting, entering reconnection, or when ``BLELogStream``
    /// pauses polling during a bulk download.
    private func stopCurrentCellPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    /// Perform a single current-cell poll: write the live-cell selector, read cell data, extract sensor values.
    ///
    /// This method intentionally uses the same `writeCharacteristic`/`readCharacteristic`
    /// async API that ``BLECharacteristics`` uses. This ensures it participates in the
    /// concurrency guard (``pendingReads``/``pendingWrites`` dictionaries) and will not
    /// interfere with concurrent operations from other callers.
    ///
    /// ## Error Handling
    /// Poll failures are **silently ignored**. Errors are expected during:
    /// - Reconnection (device temporarily unreachable)
    /// - Concurrent operations (``BLEError/operationInProgress``)
    /// - Brief signal loss
    ///
    /// The next timer tick (5 seconds later) will retry automatically.
    ///
    /// ## Why `@MainActor`?
    /// The `Task { @MainActor ... }` ensures the entire poll runs on the main queue,
    /// which is required because BLEManager's state and CoreBluetooth are main-queue-only.
    private func pollCurrentCell() {
        guard connectionState == .connected else { return }

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                // Step 1: Write the "live cell" selector value (0xFFFFFFFF) to the cell selector characteristic.
                // This tells the firmware "I want to read the current in-progress cell, not a historical one."
                var selectorData = Data(count: 4)
                selectorData.writeUInt32LE(BLEConstants.logStreamEndMarker, at: 0)
                try await self.writeCharacteristic(BLEConstants.charCellSelector, data: selectorData)

                // Step 2: Read the cell data. The firmware returns the 57-byte payload for
                // whichever cell was last selected (in this case, the live cell).
                let data = try await self.readCharacteristic(BLEConstants.charCellData)
                guard data.count >= BLEConstants.logCellNotificationSize else { return }

                // Step 3: Parse the raw bytes into a typed ParsedLogCell struct.
                let cell = BLEParsers.parseLogCell(data)

                // Step 4: Extract only the sensors not available via ESS and emit an update.
                // VOC and NOx are only sent if > 0 (a value of 0 means the sensor has not
                // produced a reading yet, e.g., during its warm-up period).
                var update = PartialSensorUpdate()
                if cell.voc > 0 { update.voc = Double(cell.voc) }
                if cell.nox > 0 { update.nox = Double(cell.nox) }
                update.pm4_0 = cell.pm.2 // PM4.0 is the third element of the PM tuple
                self.onSensorUpdate?(update)
            } catch {
                // Polling errors are expected during reconnection or concurrent operations.
                // Silently ignore — the next poll (5 seconds later) will retry.
            }
        }
    }

    // MARK: - Reconnection
    // When the device disconnects unexpectedly (e.g., goes out of range, firmware crash,
    // BLE interference), we attempt to automatically reconnect. This provides a smooth
    // user experience — brief connection drops are recovered without user intervention.

    /// Handle an unexpected disconnection by attempting automatic reconnection.
    ///
    /// This method is called when:
    /// - ``centralManager(_:didDisconnectPeripheral:error:)`` fires unexpectedly
    /// - ``centralManager(_:didFailToConnect:error:)`` reports a connection failure
    /// - A connection timeout fires (see ``startConnectTimeout()``)
    ///
    /// ## Reconnection Strategy
    /// 1. Clean up stale state (cached services, pending continuations)
    /// 2. If attempts remain (< ``maxReconnectAttempts``):
    ///    - Transition to `.reconnecting` state
    ///    - Wait ``reconnectDelay`` seconds (gives BLE radio time to reset)
    ///    - Attempt a new connection with a fresh timeout
    /// 3. If all attempts exhausted:
    ///    - Fully clean up (including clearing the peripheral reference)
    ///    - Transition to `.disconnected` — user must manually reconnect
    ///
    /// ## Why Keep the Peripheral Reference?
    /// During reconnection, we keep ``connectedPeripheral`` set so we can attempt
    /// `centralManager.connect(peripheral)` again. Only after all attempts are exhausted
    /// do we clear it via ``cleanupConnection()``.
    ///
    /// Matches the web app's `handleDisconnect()`.
    private func handleDisconnect() {
        // Stop polling and cancel any pending timeout — we are handling the disconnect now.
        stopCurrentCellPolling()
        cancelConnectTimeout()

        // Clear cached services and characteristics — they are invalid after disconnect.
        // But do NOT clear connectedPeripheral yet — we need it for reconnection attempts.
        customService = nil
        essService = nil
        characteristicCache = [:]

        // Resume all pending continuations with errors so callers do not hang forever.
        failPendingContinuations()

        if reconnectAttempts < maxReconnectAttempts, let peripheral = connectedPeripheral {
            // Still have attempts remaining — try to reconnect.
            setState(.reconnecting)
            reconnectAttempts += 1
            logger.info("Reconnect attempt \(self.reconnectAttempts)/\(self.maxReconnectAttempts)...")

            // Wait `reconnectDelay` seconds before retrying. This delay:
            // 1. Gives the BLE radio time to reset after the disconnect
            // 2. Gives the device time to become connectable again
            // 3. Avoids hammering the radio with immediate retry attempts
            DispatchQueue.main.asyncAfter(deadline: .now() + reconnectDelay) { [weak self] in
                guard let self, self.connectionState == .reconnecting else { return }
                // Start a fresh timeout for this reconnection attempt.
                self.startConnectTimeout()
                self.centralManager.connect(peripheral, options: nil)
            }
        } else {
            // All reconnection attempts exhausted — give up.
            logger.info("Reconnection gave up — use Connect button to re-pair")
            cleanupConnection()  // Now we clear the peripheral reference too
            setState(.disconnected)
        }
    }

    // MARK: - Service/Characteristic Discovery Flow
    // After connecting to a BLE device, the app must "discover" which services and
    // characteristics the device offers. This is a multi-step process:
    //
    //   1. discoverServices() — ask the device "what services do you have?"
    //   2. didDiscoverServices (delegate) — for each service, ask "what characteristics?"
    //   3. didDiscoverCharacteristicsFor (delegate) — cache each characteristic
    //   4. When all services are done, transition to .connected state

    /// Kick off GATT service discovery for the custom vendor service and ESS.
    ///
    /// Called immediately after a successful BLE connection is established. We request
    /// discovery of exactly two services:
    /// - ``BLEConstants/customServiceUUID``: Proprietary service with device config, log data, pet game
    /// - ``BLEConstants/essServiceUUID``: Standard Environmental Sensing Service with sensor readings
    ///
    /// Specifying the exact service UUIDs (instead of `nil` for "discover all") is faster
    /// because CoreBluetooth can skip services the app does not need. On a typical uCrit
    /// device, this saves ~200ms compared to discovering all services.
    ///
    /// The results arrive asynchronously via ``peripheral(_:didDiscoverServices:)``,
    /// which then triggers characteristic discovery for each found service.
    private func discoverServices() {
        guard let peripheral = connectedPeripheral else { return }
        peripheral.discoverServices([BLEConstants.customServiceUUID, BLEConstants.essServiceUUID])
    }
}

// MARK: - CBCentralManagerDelegate
// This extension implements the delegate methods for CBCentralManager — the "central"
// side of a BLE connection. These methods are called by CoreBluetooth to notify the app
// about system-level BLE events: Bluetooth state changes, peripheral discovery,
// connection success/failure, and disconnection.
//
// ## What is a CBCentralManagerDelegate?
// In BLE, there are two roles:
// - **Central** (this app): Scans for, connects to, and reads data from peripherals.
// - **Peripheral** (the uCrit device): Advertises its presence and provides data.
//
// The CBCentralManagerDelegate receives callbacks about the central's operations
// (scanning, connecting). The CBPeripheralDelegate (next extension) receives callbacks
// about operations on a specific connected peripheral (service discovery, reads, writes).

extension BLEManager: CBCentralManagerDelegate {

    /// Called by CoreBluetooth when the Bluetooth hardware state changes.
    ///
    /// This is always the FIRST delegate method called after creating a `CBCentralManager`.
    /// It fires immediately with the current state, and again whenever the state changes
    /// (e.g., user toggles Bluetooth in Settings, airplane mode, etc.).
    ///
    /// ## Key States
    /// - `.poweredOn`: Bluetooth is ready — safe to scan and connect.
    /// - `.poweredOff`: User turned off Bluetooth. Active scans/connections are cancelled.
    /// - `.unauthorized`: App does not have Bluetooth permission (user denied in Settings).
    /// - `.unsupported`: This device does not have BLE hardware (rare on modern iPhones).
    /// - `.unknown` / `.resetting`: Transient states during startup. Wait for a final state.
    ///
    /// - Parameter central: The `CBCentralManager` whose state changed.
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        logger.info("Central manager state: \(central.state.rawValue)")
        bluetoothState = central.state

        switch central.state {
        case .poweredOn:
            // Bluetooth is ready. Fire the one-shot callback (used for auto-reconnect on launch).
            onBluetoothReady?()
            onBluetoothReady = nil  // Fire only once — prevent stale callbacks on future state changes

        case .poweredOff, .unauthorized, .unsupported:
            // Bluetooth became unavailable. If we were in the middle of scanning or connecting,
            // CoreBluetooth has already cancelled those operations — update our state to match.
            if connectionState == .scanning || connectionState == .connecting {
                setState(.disconnected)
            }

        default:
            // Transient states (.unknown, .resetting). If we were scanning, the scan has been
            // implicitly cancelled — transition to disconnected.
            if connectionState == .scanning {
                setState(.disconnected)
            }
        }
    }

    /// Called by CoreBluetooth when a peripheral advertising the target service UUID is discovered.
    ///
    /// This callback fires for each advertisement packet received from a peripheral that
    /// matches the service UUID filter we passed to `scanForPeripherals(withServices:)`.
    ///
    /// We check for duplicates (by identifier) before adding to the list because
    /// CoreBluetooth may deliver the same peripheral multiple times if it re-advertises,
    /// despite our `allowDuplicates: false` option (which reduces but does not eliminate
    /// duplicates in practice).
    ///
    /// - Parameters:
    ///   - central: The `CBCentralManager` performing the scan.
    ///   - peripheral: The discovered `CBPeripheral`. Must be retained (we add it to our array)
    ///     to keep it alive — CoreBluetooth does not retain discovered peripherals.
    ///   - advertisementData: Dictionary of advertisement data (e.g., local name, service UUIDs).
    ///   - RSSI: The signal strength in dBm. Could be used for proximity sorting.
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                         advertisementData: [String: Any], rssi RSSI: NSNumber) {
        // Deduplicate: only add if we have not seen this peripheral's UUID before.
        if !discoveredPeripherals.contains(where: { $0.identifier == peripheral.identifier }) {
            discoveredPeripherals.append(peripheral)
            logger.info("Discovered: \(peripheral.name ?? "Unknown") (\(peripheral.identifier))")
        }
    }

    /// Called by CoreBluetooth when a connection to a peripheral succeeds.
    ///
    /// At this point, the BLE link is established but we do not yet know what services
    /// or characteristics the device offers. We must perform GATT service discovery
    /// before we can read or write any data.
    ///
    /// This method:
    /// 1. Cancels the connection timeout (we connected in time)
    /// 2. Clears any stale characteristic cache from a previous connection
    /// 3. Begins service discovery
    ///
    /// The state does NOT transition to `.connected` here — that happens later, after
    /// service and characteristic discovery completes in ``peripheral(_:didDiscoverCharacteristicsFor:error:)``.
    ///
    /// - Parameters:
    ///   - central: The `CBCentralManager`.
    ///   - peripheral: The peripheral that was successfully connected.
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        logger.info("Connected to \(peripheral.name ?? "Unknown")")
        cancelConnectTimeout()
        characteristicCache = [:]  // Clear any stale cache from a previous connection
        discoverServices()         // Begin GATT service discovery
    }

    /// Called by CoreBluetooth when a connection attempt fails.
    ///
    /// This can happen if:
    /// - The device went out of range during the connection attempt
    /// - The device rejected the connection
    /// - A system-level error occurred
    ///
    /// We cancel the timeout (this callback handles the failure) and trigger reconnection.
    ///
    /// - Parameters:
    ///   - central: The `CBCentralManager`.
    ///   - peripheral: The peripheral that failed to connect.
    ///   - error: The reason for the failure, or `nil` if unknown.
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        logger.error("Failed to connect: \(error?.localizedDescription ?? "Unknown")")
        cancelConnectTimeout()
        handleDisconnect()  // Trigger reconnection logic
    }

    /// Called by CoreBluetooth when a connected peripheral disconnects.
    ///
    /// This fires for BOTH unexpected disconnects (device went out of range, firmware crash)
    /// and intentional disconnects (user pressed Disconnect). We distinguish between them:
    ///
    /// - **Intentional**: ``disconnect()`` already set state to `.disconnected` before
    ///   CoreBluetooth delivers this callback. The `guard` catches this and returns early.
    /// - **Unexpected**: State is still `.connected` (or `.reconnecting`), so we proceed
    ///   to ``handleDisconnect()`` for automatic reconnection.
    ///
    /// This guard prevents double-handling: without it, an intentional disconnect would
    /// trigger reconnection logic (because CoreBluetooth always fires this callback).
    ///
    /// - Parameters:
    ///   - central: The `CBCentralManager`.
    ///   - peripheral: The peripheral that disconnected.
    ///   - error: The disconnect reason, or `nil` for a clean (intentional) disconnect.
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        // Guard: if we already moved to .disconnected (intentional disconnect), skip.
        guard connectionState != .disconnected else { return }
        logger.info("Disconnected: \(error?.localizedDescription ?? "clean")")
        handleDisconnect()  // Trigger automatic reconnection
    }
}

// MARK: - CBPeripheralDelegate
// This extension implements the delegate methods for a specific connected CBPeripheral.
// These methods are called by CoreBluetooth to report the results of operations on
// the peripheral: service discovery, characteristic discovery, read results, write
// confirmations, and notification state changes.
//
// ## Important: didUpdateValueFor Is Multi-Purpose
// The `didUpdateValueFor` callback fires for BOTH:
// - Explicit reads (app called `peripheral.readValue(for:)`)
// - Notifications (device pushed an update after `setNotifyValue(true, for:)`)
//
// We must distinguish these cases to route data correctly. The routing logic checks:
// 1. Is there a pending read continuation for this UUID? -> Resume it (explicit read)
// 2. Is this the log stream characteristic? -> Forward to BLELogStream callback
// 3. Is this an ESS characteristic? -> Parse and emit as sensor update
// 4. Is this cell data? -> Parse and extract VOC/NOx/PM4.0

extension BLEManager: CBPeripheralDelegate {

    /// Called after GATT service discovery completes on the connected peripheral.
    ///
    /// This is the first phase of the discovery flow. For each discovered service that
    /// we recognize (custom vendor or ESS), we cache the service reference and initiate
    /// characteristic discovery. Services we do not recognize are silently ignored.
    ///
    /// ## GATT Discovery Model
    /// In BLE, you cannot read or write characteristics directly after connecting. You must:
    /// 1. Discover services (this callback)
    /// 2. Discover characteristics within each service (next callback)
    /// 3. Only then can you read/write the characteristics
    ///
    /// - Parameters:
    ///   - peripheral: The peripheral whose services were discovered.
    ///   - error: An error if service discovery failed, or `nil` on success.
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            logger.error("Service discovery error: \(error.localizedDescription)")
            return
        }

        guard let services = peripheral.services else { return }

        // For each discovered service, kick off characteristic discovery.
        // We specify exactly which characteristics to discover (not nil/"discover all")
        // for performance — avoids discovering characteristics we do not need.
        for service in services {
            if service.uuid == BLEConstants.customServiceUUID {
                customService = service
                peripheral.discoverCharacteristics(BLEConstants.allCustomCharacteristicUUIDs, for: service)
            } else if service.uuid == BLEConstants.essServiceUUID {
                essService = service
                peripheral.discoverCharacteristics(BLEConstants.allESSCharacteristicUUIDs, for: service)
            }
        }
    }

    /// Called after characteristic discovery completes for a single service.
    ///
    /// This is the second phase of the discovery flow. Each discovered characteristic is
    /// cached in ``characteristicCache`` for later use by read/write operations.
    ///
    /// When characteristics for ALL expected services have been discovered, the connection
    /// is finalized: state transitions to `.connected`, ESS subscriptions begin, and
    /// current-cell polling starts.
    ///
    /// ## Connection Finalization Logic
    /// The check `hasCustomChars && hasESSChars` ensures we wait for BOTH services before
    /// declaring the connection ready. `essService == nil` in the `hasESSChars` check
    /// handles the edge case where the device does not advertise ESS at all (unlikely
    /// but defensive).
    ///
    /// - Parameters:
    ///   - peripheral: The peripheral whose characteristics were discovered.
    ///   - service: The specific service whose characteristics were discovered.
    ///   - error: An error if characteristic discovery failed, or `nil` on success.
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error {
            logger.error("Characteristic discovery error: \(error.localizedDescription)")
            return
        }

        guard let characteristics = service.characteristics else { return }

        // Cache every discovered characteristic by its UUID for fast lookup during reads/writes.
        for char in characteristics {
            characteristicCache[char.uuid] = char
        }

        // Check if we have discovered characteristics for ALL expected services.
        // The connection is not ready until both the custom and ESS services are fully discovered.
        let hasCustomChars = customService?.characteristics != nil
        let hasESSChars = essService?.characteristics != nil || essService == nil

        if hasCustomChars && hasESSChars {
            // All services and characteristics discovered — the connection is fully ready.
            reconnectAttempts = 0      // Reset reconnect counter on successful connection
            setState(.connected)       // Transition to the connected state (triggers UI updates)
            subscribeToESS()           // Subscribe to ESS notifications for real-time sensor data
            startCurrentCellPolling()  // Start 5-second polling for VOC/NOx/PM4.0
        }
    }

    /// Called when a characteristic's value is updated — either from an explicit read or a notification.
    ///
    /// This is the **most complex delegate method** because it serves as the central routing
    /// hub for all incoming BLE data. It handles three distinct data flows:
    ///
    /// 1. **Pending async reads**: If `readCharacteristic()` is awaiting a response, the
    ///    continuation is resumed with the data (or error) and the method returns early.
    ///
    /// 2. **Log stream notifications**: If data arrives on the log stream characteristic
    ///    (`0x0006`), it is forwarded to ``onLogStreamNotification`` for ``BLELogStream``
    ///    to process.
    ///
    /// 3. **ESS notifications and sensor data**: ESS characteristic updates are parsed
    ///    using ``BLEParsers`` and emitted as ``PartialSensorUpdate`` via ``onSensorUpdate``.
    ///    Cell data reads are parsed similarly to extract VOC/NOx/PM4.0.
    ///
    /// ## Priority Order
    /// Pending reads are checked FIRST. This is critical because when `readCharacteristic()`
    /// is used to read an ESS characteristic, the response must go to the awaiting
    /// continuation, NOT be handled as a notification/sensor update.
    ///
    /// ## Minimum Byte Guards
    /// Each parser requires a minimum number of bytes. The `guard data.count >= N` checks
    /// prevent crashes from truncated BLE data (which can occur due to signal issues or
    /// firmware bugs).
    ///
    /// - Parameters:
    ///   - peripheral: The peripheral that sent the data.
    ///   - characteristic: The characteristic whose value was updated.
    ///   - error: An error if the read/notify failed, or `nil` on success.
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        let uuid = characteristic.uuid

        // --- Priority 1: Pending Async Reads ---
        // Check if there is a continuation waiting for this characteristic's value.
        // If so, resume it and return immediately — do not process as a notification.
        if let continuation = pendingReads.removeValue(forKey: uuid) {
            if let error {
                continuation.resume(throwing: error)
            } else if let data = characteristic.value {
                continuation.resume(returning: data)
            } else {
                continuation.resume(throwing: BLEError.noData)
            }
            return
        }

        // --- Priority 2: Log Stream Notifications ---
        // If a log stream download is active, forward raw data to the BLELogStream handler.
        // The handler will parse cells and detect the end marker.
        if uuid == BLEConstants.charLogStream {
            if let data = characteristic.value {
                onLogStreamNotification?(data)
            }
            return
        }

        // --- Priority 3: ESS Notifications and Sensor Data ---
        // Parse each ESS characteristic value using the appropriate parser and emit
        // a PartialSensorUpdate containing only the changed field.
        guard let data = characteristic.value else { return }

        switch uuid {
        case BLEConstants.essTemperature:
            // ESS Temperature: sint16 x 0.01 C -> degrees Celsius
            guard data.count >= 2 else { break }
            let temp = BLEParsers.parseTemperature(data)
            onSensorUpdate?(PartialSensorUpdate(temperature: temp))

        case BLEConstants.essHumidity:
            // ESS Humidity: uint16 x 0.01% -> percentage
            guard data.count >= 2 else { break }
            let hum = BLEParsers.parseHumidity(data)
            onSensorUpdate?(PartialSensorUpdate(humidity: hum))

        case BLEConstants.essCO2:
            // ESS CO2: uint16 ppm -> parts per million
            guard data.count >= 2 else { break }
            let co2 = BLEParsers.parseCO2(data)
            onSensorUpdate?(PartialSensorUpdate(co2: co2))

        case BLEConstants.essPM2_5:
            // ESS PM2.5: fp16 -> micrograms per cubic meter
            guard data.count >= 2 else { break }
            let pm = BLEParsers.parsePM(data)
            onSensorUpdate?(PartialSensorUpdate(pm2_5: pm))

        case BLEConstants.essPressure:
            // ESS Pressure: uint32 x 0.1 Pa -> hectopascals
            guard data.count >= 4 else { break }
            let pres = BLEParsers.parsePressure(data)
            onSensorUpdate?(PartialSensorUpdate(pressure: pres))

        case BLEConstants.essPM1_0:
            // ESS PM1.0: fp16 -> micrograms per cubic meter
            guard data.count >= 2 else { break }
            let pm = BLEParsers.parsePM(data)
            onSensorUpdate?(PartialSensorUpdate(pm1_0: pm))

        case BLEConstants.essPM10:
            // ESS PM10: fp16 -> micrograms per cubic meter
            guard data.count >= 2 else { break }
            let pm = BLEParsers.parsePM(data)
            onSensorUpdate?(PartialSensorUpdate(pm10: pm))

        case BLEConstants.charCellData:
            // Current cell poll result or direct cell data read.
            // Parse the full 57-byte log cell and extract VOC, NOx, PM4.0 — the sensors
            // not available via ESS. VOC/NOx of 0 means the sensor has not warmed up yet.
            if data.count >= BLEConstants.logCellNotificationSize {
                let cell = BLEParsers.parseLogCell(data)
                var update = PartialSensorUpdate()
                if cell.voc > 0 { update.voc = Double(cell.voc) }
                if cell.nox > 0 { update.nox = Double(cell.nox) }
                update.pm4_0 = cell.pm.2 // PM4.0 is the third element (index 2) of the PM tuple
                onSensorUpdate?(update)
            }

        default:
            break  // Unknown characteristic — ignore silently
        }
    }

    /// Called after a write-with-response operation completes on a characteristic.
    ///
    /// Resumes the pending write continuation stored in ``pendingWrites``. The continuation
    /// is resumed with either success (write confirmed by device) or the error from CoreBluetooth.
    ///
    /// If no continuation is pending for this UUID (e.g., if the write was cancelled or
    /// timed out), this callback is silently ignored.
    ///
    /// - Parameters:
    ///   - peripheral: The peripheral that confirmed the write.
    ///   - characteristic: The characteristic that was written.
    ///   - error: An error if the write failed, or `nil` on success.
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        let uuid = characteristic.uuid

        // Look up and remove the pending write continuation for this characteristic.
        if let continuation = pendingWrites.removeValue(forKey: uuid) {
            if let error {
                continuation.resume(throwing: error)
            } else {
                continuation.resume()  // Void return — write succeeded
            }
        }
    }

    /// Called when a notification subscription state changes for a characteristic.
    ///
    /// This fires after `setNotifyValue(_:for:)` succeeds or fails. Used for logging
    /// to help diagnose issues where notifications are not being received.
    ///
    /// ## What Is a BLE Notification Subscription?
    /// Calling `peripheral.setNotifyValue(true, for: char)` tells the device "send me
    /// updates whenever this characteristic's value changes." This callback confirms
    /// whether the subscription was accepted (some characteristics may not support it).
    ///
    /// - Parameters:
    ///   - peripheral: The peripheral whose notification state changed.
    ///   - characteristic: The characteristic whose notification state changed.
    ///   - error: An error if the subscription failed, or `nil` on success.
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            logger.warning("Notification state error for \(characteristic.uuid): \(error.localizedDescription)")
        } else {
            logger.info("Notifications \(characteristic.isNotifying ? "enabled" : "disabled") for \(characteristic.uuid)")
        }
    }
}

// MARK: - BLE Errors
// Custom error type for BLE operations. These errors are thrown by the async read/write
// methods and caught by ViewModels to display appropriate error messages to the user.

/// Error conditions that can occur during BLE operations.
///
/// Conforms to `LocalizedError` so that `error.localizedDescription` returns a
/// human-readable message suitable for display in the UI.
///
/// These errors cover the main failure modes in the BLE layer:
/// - Connection issues (not connected, timed out)
/// - Discovery issues (characteristic not found)
/// - Data issues (no data returned, truncated payload)
/// - Concurrency issues (operation already in flight)
enum BLEError: LocalizedError {
    /// No peripheral is currently connected.
    ///
    /// Thrown when ``BLEManager/readCharacteristic(_:)`` or ``BLEManager/writeCharacteristic(_:data:)``
    /// is called while ``BLEManager/connectedPeripheral`` is `nil`. Also used to fail
    /// pending continuations during unexpected disconnection.
    case notConnected

    /// The requested characteristic UUID was not found in the ``BLEManager/characteristicCache``.
    ///
    /// This can happen if:
    /// - The characteristic was not discovered during service discovery (firmware version mismatch)
    /// - The UUID is incorrect (typo in ``BLEConstants``)
    /// - Service discovery has not completed yet
    case characteristicNotFound(CBUUID)

    /// The characteristic read returned no data, or the data was too short to parse.
    ///
    /// BLE characteristics can return empty payloads in edge cases (e.g., the device
    /// has not yet initialized the value). Parsers also throw this when the byte count
    /// is less than the expected minimum for the data format.
    case noData

    /// A connection attempt exceeded the configured timeout.
    ///
    /// The timeout is ``BLEManager/connectTimeout`` seconds (default: 5).
    /// Triggers automatic reconnection via ``BLEManager/handleDisconnect()``.
    case timeout

    /// A read or write for this characteristic UUID is already in progress.
    ///
    /// Only one async read and one async write per UUID can be pending simultaneously.
    /// This error is thrown when a second concurrent operation is attempted on the same
    /// UUID. Callers should either await the first operation or serialize their calls.
    case operationInProgress

    /// Human-readable description for each error case, displayed in the UI.
    var errorDescription: String? {
        switch self {
        case .notConnected: return "Not connected to device"
        case .characteristicNotFound(let uuid): return "Characteristic not found: \(uuid)"
        case .noData: return "No data received"
        case .timeout: return "Connection timed out"
        case .operationInProgress: return "Another operation is already in progress for this characteristic"
        }
    }
}
