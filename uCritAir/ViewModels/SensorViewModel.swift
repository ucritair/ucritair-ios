import Foundation

@Observable
final class SensorViewModel {

    private let maxHistory = 360

    private let historyThrottleSeconds: TimeInterval = 4.0

    var current: SensorValues = .empty

    var history: [SensorReading] = []

    private var bleManager: BLEManager?

    private var sensorObserverToken: UUID?

    private var connectionObserverToken: UUID?

    private var configuredBLEManagerID: ObjectIdentifier?

    deinit {
        if let manager = bleManager {
            if let token = sensorObserverToken { manager.removeSensorUpdateObserver(token) }
            if let token = connectionObserverToken { manager.removeConnectionStateObserver(token) }
        }
    }

    @MainActor
    func configure(bleManager: BLEManager) {
        let managerID = ObjectIdentifier(bleManager)
        if configuredBLEManagerID == managerID,
           sensorObserverToken != nil,
           connectionObserverToken != nil {
            return
        }

        if let oldManager = self.bleManager {
            if let sensorObserverToken {
                oldManager.removeSensorUpdateObserver(sensorObserverToken)
            }
            if let connectionObserverToken {
                oldManager.removeConnectionStateObserver(connectionObserverToken)
            }
        }

        self.bleManager = bleManager
        configuredBLEManagerID = managerID

        sensorObserverToken = bleManager.addSensorUpdateObserver { [weak self] partial in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.handleSensorUpdate(partial)
            }
        }

        connectionObserverToken = bleManager.addConnectionStateObserver { [weak self] state in
            guard let self else { return }
            if state == .disconnected {
                MainActor.assumeIsolated {
                    self.reset()
                }
            }
        }
    }

    private func handleSensorUpdate(_ partial: PartialSensorUpdate) {
        current.merge(partial)

        guard current.hasAnyValue else { return }

        let now = Date()

        if let lastTimestamp = history.last?.timestamp,
           now.timeIntervalSince(lastTimestamp) < historyThrottleSeconds {
            return
        }

        let reading = SensorReading(timestamp: now, values: current)
        history.append(reading)

        if history.count > maxHistory {
            history.removeFirst(history.count - maxHistory)
        }
    }

    private func reset() {
        current = .empty
        history = []
    }
}
