//
//  UpdatePacing.swift
//  WikiViewerKit
//
//  How closely the open app follows the source. On a phone what costs power
//  is how often the radio wakes, not how many bytes move: after each request
//  the radio stays in a high-power state for seconds, and over Tailscale its
//  network extension wakes for every packet. Edits come in bursts, so the app
//  follows the source closely (long poll) only right after it opens or after
//  a publication arrived, and otherwise checks every few minutes. Low Power
//  Mode and Low Data Mode stretch that further. A request waiting for the
//  Mac keeps the app following, since its answer is expected soon.
//

import Foundation
import Network
import Synchronization

/// The device state that decides how closely to follow the source.
public struct UpdateConditions: Sendable, Equatable {
    public var lowPowerMode: Bool
    /// Low Data Mode.
    public var constrained: Bool
    /// Cellular, or a personal hotspot.
    public var expensive: Bool

    public init(lowPowerMode: Bool = false, constrained: Bool = false, expensive: Bool = false) {
        self.lowPowerMode = lowPowerMode
        self.constrained = constrained
        self.expensive = expensive
    }
}

public enum UpdatePacing: Sendable {
    /// Follows the source all the time (the Mac app).
    case continuous
    /// Follows closely only after activity; see `UpdateSchedule`.
    case adaptive(conditions: @Sendable () -> UpdateConditions)

    /// Adaptive, reading the device's power and network state.
    public static var adaptiveToDevice: UpdatePacing {
        .adaptive(conditions: { DeviceUpdateConditions.shared.current })
    }
}

/// What the watcher does next.
enum UpdateStep: Equatable {
    /// Wait for the source to announce a publication (long poll, or the
    /// short folder poll interval).
    case follow
    /// Fetch the manifest once this long after the previous check.
    case poll(every: Duration)
}

enum UpdateSchedule {
    /// How long after opening the app or the last publication it follows the source.
    static let activeWindow: Duration = .seconds(5 * 60)
    /// The same over cellular, where each request costs the most.
    static let expensiveActiveWindow: Duration = .seconds(2 * 60)
    /// Check interval while recently active.
    static let quietInterval: Duration = .seconds(2 * 60)
    /// After this long without a publication, `idleInterval` applies.
    static let idleAfter: Duration = .seconds(30 * 60)
    static let idleInterval: Duration = .seconds(5 * 60)
    /// Check interval in Low Power Mode or Low Data Mode.
    static let savingInterval: Duration = .seconds(15 * 60)
    /// The same while a request is waiting for the Mac.
    static let savingRequestInterval: Duration = .seconds(2 * 60)
    /// While waiting to poll, how often the step is worked out again (a
    /// request queued, Low Power Mode turned off). Wakes only the CPU.
    static let recheckInterval: Duration = .seconds(15)

    static func step(sinceActivity: Duration, waitingForMac: Bool, conditions: UpdateConditions) -> UpdateStep {
        if conditions.lowPowerMode || conditions.constrained {
            return .poll(every: waitingForMac ? savingRequestInterval : savingInterval)
        }
        if waitingForMac || sinceActivity < (conditions.expensive ? expensiveActiveWindow : activeWindow) {
            return .follow
        }
        return .poll(every: sinceActivity < idleAfter ? quietInterval : idleInterval)
    }
}

/// Low Power Mode from ProcessInfo, the network's cost from a path monitor
/// that runs for the life of the process.
final class DeviceUpdateConditions: Sendable {
    static let shared = DeviceUpdateConditions()

    private let path = Mutex((constrained: false, expensive: false))
    private let monitor = NWPathMonitor()

    private init() {
        monitor.pathUpdateHandler = { [unowned self] path in
            self.path.withLock { $0 = (path.isConstrained, path.isExpensive) }
        }
        monitor.start(queue: DispatchQueue(label: "WikiViewerKit.UpdateConditions", qos: .utility))
    }

    var current: UpdateConditions {
        let path = path.withLock { $0 }
        return UpdateConditions(lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
                                constrained: path.constrained, expensive: path.expensive)
    }
}
