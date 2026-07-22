import Foundation
import Network
import UIKit
import Combine

/// Watches the two environmental gates the user can opt into: network type
/// (Wi-Fi vs cellular) and battery level. The engine consults `blockReason(for:)`
/// before each upload and parks the run loop while a gate is closed.
@MainActor
final class ConditionsMonitor: ObservableObject {
    @Published private(set) var isOnWiFi: Bool = true
    @Published private(set) var isConstrained: Bool = false      // Low Data Mode
    @Published private(set) var hasConnection: Bool = true
    @Published private(set) var batteryLevel: Double = 1.0
    @Published private(set) var isCharging: Bool = false

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.snapsiphon.conditions")

    init() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        updateBattery()
        NotificationCenter.default.addObserver(
            self, selector: #selector(batteryChanged),
            name: UIDevice.batteryLevelDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(batteryChanged),
            name: UIDevice.batteryStateDidChangeNotification, object: nil)

        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                self?.hasConnection = path.status == .satisfied
                self?.isOnWiFi = path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet)
                self?.isConstrained = path.isConstrained
            }
        }
        monitor.start(queue: queue)
    }

    deinit { monitor.cancel() }

    @objc private func batteryChanged() { updateBattery() }

    private func updateBattery() {
        let level = UIDevice.current.batteryLevel
        // Simulator / unknown reports -1; treat as "fine" so it never blocks there.
        batteryLevel = level < 0 ? 1.0 : Double(level)
        isCharging = UIDevice.current.batteryState == .charging || UIDevice.current.batteryState == .full
    }

    /// Returns a human reason the run loop must wait, or nil if clear to upload.
    func blockReason(for settings: BackupSettings) -> String? {
        if !hasConnection {
            return "Waiting for a network connection…"
        }
        if settings.wifiOnly && !isOnWiFi {
            return "Waiting for Wi-Fi (cellular uploads are off)…"
        }
        if settings.pauseOnLowBattery && !isCharging && batteryLevel < settings.lowBatteryThreshold {
            let pct = Int(settings.lowBatteryThreshold * 100)
            return "Paused — battery below \(pct)%. Charge to continue."
        }
        return nil
    }
}
