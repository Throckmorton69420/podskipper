import Foundation
import UIKit

/// Pass 35: what this iPhone reports about itself right now, for the top of
/// Diagnostics, beside model tests, and in exports. Every value says where
/// it came from; nothing is estimated where iOS gives a figure, and nothing
/// iOS doesn't expose to apps (CPU or GPU load) is shown at all.
struct DeviceResources: Sendable {
    struct Line: Sendable, Identifiable {
        enum Source: String, Sendable { case measured = "measured", fromSignature = "from the app's signature", unavailable = "not available" }
        var id: String { title }
        var title: String
        var value: String
        var source: Source
    }

    var lines: [Line]

    var dictionary: [String: String] {
        Dictionary(lines.map { ($0.title, $0.value) }, uniquingKeysWith: { a, _ in a })
    }

    @MainActor
    static func measure() -> DeviceResources {
        let info = Bundle.main.infoDictionary ?? [:]
        let device = UIDevice.current
        device.isBatteryMonitoringEnabled = true
        defer { device.isBatteryMonitoringEnabled = false }
        let f = { (n: Int64) in ByteCountFormatter.string(fromByteCount: n, countStyle: .memory) }
        var lines: [Line] = [
            Line(title: "Device", value: Diagnostics.deviceModel, source: .measured),
            Line(title: "iOS", value: device.systemVersion, source: .measured),
            Line(title: "App", value: "\(info["CFBundleShortVersionString"] ?? "?") · build \(BuildInfo.commit)", source: .measured),
            // 0 means iOS gave no figure (the simulator, or no memory limit applies).
            os_proc_available_memory() > 0
                ? Line(title: "Memory this app may still use", value: f(Int64(os_proc_available_memory())), source: .measured)
                : Line(title: "Memory this app may still use", value: "—", source: .unavailable),
            Line(title: "Memory in this iPhone", value: f(Int64(ProcessInfo.processInfo.physicalMemory)), source: .measured),
            Line(title: "Heat", value: Diagnostics.thermalName.capitalized, source: .measured),
            Line(title: "Low Power Mode", value: ProcessInfo.processInfo.isLowPowerModeEnabled ? "On" : "Off", source: .measured),
        ]
        let level = device.batteryLevel
        let state: String = switch device.batteryState {
        case .charging: "charging"; case .full: "full"; case .unplugged: "on battery"; default: "unknown"
        }
        lines.append(level >= 0
            ? Line(title: "Battery", value: "\(Int(level * 100)) %, \(state)", source: .measured)
            : Line(title: "Battery", value: "—", source: .unavailable))
        if let free = ModelStorage.freeBytes() {
            lines.append(Line(title: "Free storage", value: ByteCountFormatter.string(fromByteCount: free, countStyle: .file)
                              + (free < StorageGuard.lowThreshold ? " (nearly full)" : ""), source: .measured))
        } else {
            lines.append(Line(title: "Free storage", value: "—", source: .unavailable))
        }
        let uptime = ProcessInfo.processInfo.systemUptime
        lines.append(Line(title: "Since iPhone restarted", value: Duration.seconds(uptime).formatted(.units(allowed: [.days, .hours, .minutes], width: .abbreviated)), source: .measured))
        let present = SignedEntitlements.present
        func signed(_ title: String, _ key: String) {
            lines.append(Line(title: title, value: present.contains(key) ? "Yes" : (present.isEmpty ? "Unsigned build" : "No"), source: .fromSignature))
        }
        signed("Increased memory limit", "com.apple.developer.kernel.increased-memory-limit")
        signed("Extended virtual addressing", "com.apple.developer.kernel.extended-virtual-addressing")
        signed("Background GPU", SignedEntitlements.backgroundGPUKey)
        signed("iCloud key-value storage", "com.apple.developer.ubiquity-kvstore-identifier")
        // Pass 53: both devices must name the same store, and each writes
        // its own presence there (`CloudSync.notePresence`).
        if let store = SignedEntitlements.describe("com.apple.developer.ubiquity-kvstore-identifier") {
            lines.append(Line(title: "iCloud store", value: store, source: .fromSignature))
            let others = CloudSync.otherDevices(in: NSUbiquitousKeyValueStore.default.dictionaryRepresentation, me: CloudSync.deviceID)
            lines.append(Line(title: "Other devices on this iCloud store",
                              value: others.isEmpty ? "None has written here yet"
                                : others.map { "\($0.kind), iOS \($0.system), build \($0.build), \($0.at.formatted(date: .abbreviated, time: .shortened))" }
                                    .joined(separator: "; "),
                              source: .measured))
        }
        // Pass 54: copies signed by different teams sync through R2 instead.
        lines.append(Line(title: "Sync through your Cloudflare storage",
                          value: SyncRelaySetup.load() == nil ? "Off" : "On", source: .measured))
        signed("CarPlay audio", "com.apple.developer.carplay-audio")
        lines.append(Line(title: "App Group", value: WidgetSnapshot.resolvedGroup ?? "None", source: .fromSignature))
        return DeviceResources(lines: lines)
    }
}
