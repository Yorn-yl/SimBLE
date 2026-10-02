import Foundation
import Observation

struct SimulatorApp: Identifiable, Hashable {
    let udid: String
    let bundleID: String
    let name: String

    /// Unique across simulators: the sidebar selects rows by this identity, and logs are keyed the same way.
    var id: String { AppKey.make(udid: udid, bundleID: bundleID) }
}

struct SimulatorDevice: Identifiable, Hashable {
    let udid: String
    let name: String
    let runtime: String
    var apps: [SimulatorApp]

    var id: String { udid }
}

/// Tracks booted iOS simulators and their user apps, and sets the simulator-wide DYLD_INSERT_LIBRARIES
/// so apps launched outside Xcode load the loader. Removed again when SimBLE quits.
@MainActor
@Observable
final class SimulatorService {
    private(set) var devices: [SimulatorDevice] = []
    private(set) var lastError: String?

    @ObservationIgnored private let loaderPath: String
    @ObservationIgnored private let directory: AppDirectory
    @ObservationIgnored private let logs: LogStore
    @ObservationIgnored private var injectedDevices: Set<String> = []
    @ObservationIgnored private var pollTask: Task<Void, Never>?

    init(loaderPath: String, directory: AppDirectory, logs: LogStore) {
        self.loaderPath = loaderPath
        self.directory = directory
        self.logs = logs
    }

    func start() {
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh(reloadApps: false)
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    func refresh(reloadApps: Bool) async {
        guard let booted = await Self.bootedDevices() else {
            lastError = "xcrun simctl is not available"
            return
        }
        lastError = nil
        var updated: [SimulatorDevice] = []
        for device in booted {
            if !reloadApps, let known = devices.first(where: { $0.udid == device.udid }) {
                updated.append(known)
                continue
            }
            var device = device
            device.apps = await Self.userApps(on: device.udid)
            updated.append(device)
        }
        // Names first: apps connect as soon as the variable is set, and their log labels read the directory.
        directory.update(
            deviceNames: Dictionary(updated.map { ($0.udid, $0.name) }, uniquingKeysWith: { first, _ in first }),
            appNames: Dictionary(updated.flatMap(\.apps).map { ($0.bundleID, $0.name) }, uniquingKeysWith: { first, _ in first })
        )
        for device in updated where !injectedDevices.contains(device.udid) {
            let result = await Shell.xcrun(["simctl", "spawn", device.udid, "launchctl", "setenv", "DYLD_INSERT_LIBRARIES", loaderPath])
            if result.status == 0 {
                injectedDevices.insert(device.udid)
                logs.append(appKey: nil, source: "Bridge", .bridge, .app, "Simulator ready", detail: "\(device.name) (\(device.runtime))")
            }
        }
        injectedDevices.formIntersection(updated.map(\.udid))
        if updated != devices {
            devices = updated
        }
    }

    /// Runs synchronously from applicationWillTerminate so the variable is gone before the process exits.
    func removeInjection() {
        for udid in injectedDevices {
            Shell.xcrunSync(["simctl", "spawn", udid, "launchctl", "unsetenv", "DYLD_INSERT_LIBRARIES"])
        }
        injectedDevices.removeAll()
    }

    func relaunch(_ app: SimulatorApp, on device: SimulatorDevice) async {
        // terminate blocks while a debugger holds the app, so it gets a short timeout.
        _ = await Shell.xcrun(["simctl", "terminate", device.udid, app.bundleID], timeout: 5)
        let result = await Shell.xcrun(["simctl", "launch", device.udid, app.bundleID], timeout: 20)
        let source = directory.label(bundleID: app.bundleID, udid: device.udid)
        let key = app.id
        if result.status == 0 {
            logs.append(appKey: key, source: source, .bridge, .app, "Relaunched")
        } else {
            logs.append(appKey: key, source: source, .bridge, .app, "Relaunch failed", error: result.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private static func bootedDevices() async -> [SimulatorDevice]? {
        let result = await Shell.xcrun(["simctl", "list", "devices", "booted", "-j"])
        guard result.status == 0,
              let json = try? JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: Any],
              let runtimes = json["devices"] as? [String: [[String: Any]]] else { return nil }
        var devices: [SimulatorDevice] = []
        for (runtime, entries) in runtimes where runtime.contains("iOS") {
            // "com.apple.CoreSimulator.SimRuntime.iOS-27-2" -> "iOS 27.2"
            let parts = (runtime.components(separatedBy: ".").last ?? runtime).components(separatedBy: "-")
            let runtimeName = "\(parts[0]) \(parts.dropFirst().joined(separator: "."))"
            for entry in entries where entry["state"] as? String == "Booted" {
                guard let udid = entry["udid"] as? String, let name = entry["name"] as? String else { continue }
                devices.append(SimulatorDevice(udid: udid, name: name, runtime: runtimeName, apps: []))
            }
        }
        return devices.sorted { $0.name < $1.name }
    }

    private static func userApps(on udid: String) async -> [SimulatorApp] {
        let result = await Shell.xcrun(["simctl", "listapps", udid])
        // listapps prints an old-style (OpenStep) property list.
        guard result.status == 0,
              let list = try? PropertyListSerialization.propertyList(from: Data(result.output.utf8), format: nil) as? [String: [String: Any]] else { return [] }
        return list.compactMap { bundleID, info -> SimulatorApp? in
            guard info["ApplicationType"] as? String == "User" else { return nil }
            let name = info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String ?? bundleID
            return SimulatorApp(udid: udid, bundleID: bundleID, name: name)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

enum Shell {
    struct Result {
        let status: Int32
        let output: String
    }

    static func xcrun(_ arguments: [String], timeout: TimeInterval = 30) async -> Result {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: run(arguments, timeout: timeout))
            }
        }
    }

    @discardableResult
    static func xcrunSync(_ arguments: [String]) -> Result {
        run(arguments, timeout: 10)
    }

    private static func run(_ arguments: [String], timeout: TimeInterval) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return Result(status: -1, output: error.localizedDescription)
        }
        let deadline = DispatchWorkItem { [weak process] in
            process?.terminate()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        deadline.cancel()
        return Result(status: process.terminationStatus, output: String(decoding: output, as: UTF8.self))
    }
}
