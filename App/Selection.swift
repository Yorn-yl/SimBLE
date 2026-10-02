import Foundation
import Observation

enum AppKey {
    static func make(udid: String, bundleID: String) -> String {
        "\(udid)|\(bundleID)"
    }
}

/// Thread-safe copy of the selection for bridge sessions, which answer loader requests off the main actor.
final class SelectionSnapshot: @unchecked Sendable {
    private let lock = NSLock()
    private var keys: Set<String> = []

    func contains(_ key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return keys.contains(key)
    }

    func replace(with keys: Set<String>) {
        lock.lock()
        defer { lock.unlock() }
        self.keys = keys
    }
}

/// Which simulator apps get the bridge, per simulator and bundle identifier.
@MainActor
@Observable
final class InjectionSettings {
    private(set) var selected: Set<String>
    @ObservationIgnored let snapshot = SelectionSnapshot()
    private static let defaultsKey = "selectedApps"

    init() {
        selected = Set(UserDefaults.standard.stringArray(forKey: Self.defaultsKey) ?? [])
        snapshot.replace(with: selected)
    }

    func isSelected(_ key: String) -> Bool {
        selected.contains(key)
    }

    func setSelected(_ key: String, _ isSelected: Bool) {
        if isSelected {
            selected.insert(key)
        } else {
            selected.remove(key)
        }
        UserDefaults.standard.set(Array(selected).sorted(), forKey: Self.defaultsKey)
        snapshot.replace(with: selected)
    }
}

/// Simulator and app display names for log labels, readable from any queue.
final class AppDirectory: @unchecked Sendable {
    private let lock = NSLock()
    private var deviceNames: [String: String] = [:]
    private var appNames: [String: String] = [:]

    func update(deviceNames: [String: String], appNames: [String: String]) {
        lock.lock()
        defer { lock.unlock() }
        self.deviceNames.merge(deviceNames) { _, new in new }
        self.appNames.merge(appNames) { _, new in new }
    }

    func label(bundleID: String, udid: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        let app = appNames[bundleID] ?? bundleID
        guard let device = deviceNames[udid] else { return app }
        return "\(app) · \(device)"
    }
}
