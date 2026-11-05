import Foundation
import IOKit.ps

enum BatteryPauseReason: Equatable {
    case onBattery
    case lowPower
    case lowBattery(Int)

    var detail: String {
        switch self {
        case .onBattery: return "Running on battery"
        case .lowPower: return "Low Power Mode"
        case .lowBattery(let percentage): return "Battery at \(percentage)%"
        }
    }
}

struct BatteryPower: Equatable {
    let hasInternalBattery: Bool
    let onBattery: Bool
    let lowPower: Bool
    let percentage: Double?

    static var current: BatteryPower {
        let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue()
        let provider = snapshot.flatMap { IOPSGetProvidingPowerSourceType($0)?.takeUnretainedValue() }
        let sources = snapshot.flatMap { IOPSCopyPowerSourcesList($0)?.takeRetainedValue() } as? [CFTypeRef] ?? []
        let descriptions: [[String: Any]] = sources.compactMap { source in
            guard let snapshot else { return nil }
            return IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any]
        }
        return fromSources(descriptions, onBattery: provider == kIOPMBatteryPowerKey as CFString,
                           lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled)
    }

    static func fromSources(_ sources: [[String: Any]], onBattery: Bool, lowPower: Bool) -> BatteryPower {
        var found = false
        var invalid = false
        var currentTotal = 0.0
        var maximumTotal = 0.0
        for source in sources {
            guard source[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let present = source[kIOPSIsPresentKey] as? NSNumber,
                  CFGetTypeID(present) == CFBooleanGetTypeID(), present.boolValue else { continue }
            found = true
            guard let current = source[kIOPSCurrentCapacityKey] as? NSNumber,
                  let maximum = source[kIOPSMaxCapacityKey] as? NSNumber,
                  CFGetTypeID(current) == CFNumberGetTypeID(), CFGetTypeID(maximum) == CFNumberGetTypeID(),
                  current.doubleValue.isFinite, maximum.doubleValue.isFinite,
                  current.doubleValue >= 0, maximum.doubleValue > 0 else {
                invalid = true
                continue
            }
            currentTotal += current.doubleValue
            maximumTotal += maximum.doubleValue
        }
        let percentage = found && !invalid && maximumTotal > 0
            ? min(100, max(0, currentTotal * 100 / maximumTotal)) : nil
        return BatteryPower(hasInternalBattery: found, onBattery: onBattery, lowPower: lowPower, percentage: percentage)
    }

    func pauseReason(for policy: PlaybackPolicy) -> BatteryPauseReason? {
        if policy.pauseOnBattery && onBattery { return .onBattery }
        if policy.pauseOnLowPower && lowPower { return .lowPower }
        if policy.pauseOnLowBattery && onBattery, let percentage,
           percentage.isFinite, (0...100).contains(percentage),
           percentage <= Double(min(100, max(0, policy.lowPowerThreshold))) { return .lowBattery(Int(percentage.rounded())) }
        return nil
    }
}
