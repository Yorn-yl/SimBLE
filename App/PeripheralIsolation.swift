import Foundation

/// The Mac's CoreBluetooth identifiers belong to the host, not to an iOS simulator.
/// Persist a different identifier for each simulator/app while retaining a reverse
/// mapping for retrievePeripherals(withIdentifiers:) after the simulated app restarts.
final class PeripheralIdentityRegistry: @unchecked Sendable {
    private struct Scope: Hashable, Codable {
        let udid: String
        let bundleID: String
    }

    private struct Record: Codable {
        let scope: Scope
        let physical: UUID
        let virtual: UUID
    }

    private static let storageKey = "peripheralIdentities.v1"
    private let lock = NSLock()
    private let defaults: UserDefaults
    private var forward: [Scope: [UUID: UUID]] = [:]
    private var reverse: [Scope: [UUID: UUID]] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let records = try? JSONDecoder().decode([Record].self, from: data) {
            for record in records {
                forward[record.scope, default: [:]][record.physical] = record.virtual
                reverse[record.scope, default: [:]][record.virtual] = record.physical
            }
        }
    }

    func virtualID(for physical: UUID, udid: String, bundleID: String) -> UUID {
        let scope = Scope(udid: udid, bundleID: bundleID)
        lock.lock()
        defer { lock.unlock() }
        if let known = forward[scope]?[physical] {
            return known
        }
        let identifier = UUID()
        forward[scope, default: [:]][physical] = identifier
        reverse[scope, default: [:]][identifier] = physical
        let records = forward.flatMap { scope, mappings in
            mappings.map { physical, virtual in Record(scope: scope, physical: physical, virtual: virtual) }
        }
        if let data = try? JSONEncoder().encode(records) {
            defaults.set(data, forKey: Self.storageKey)
        }
        return identifier
    }

    func physicalID(for virtual: UUID, udid: String, bundleID: String) -> UUID? {
        lock.lock()
        defer { lock.unlock() }
        return reverse[Scope(udid: udid, bundleID: bundleID)]?[virtual]
    }
}

/// Prevent two independent simulated apps from interleaving arbitrary GATT command
/// protocols on the same physical device. Sharing can be explicitly enabled for
/// testing CoreBluetooth's shared-device behavior, but it cannot demultiplex
/// application-specific notifications/responses (such as command transactions).
final class PeripheralAccessCoordinator: @unchecked Sendable {
    static let sharingKey = "allowSharedPeripheralConnections"

    private let lock = NSLock()
    private let allowSharing: () -> Bool
    // Physical identifier -> simulated app key -> Mac bridge session IDs.
    private var owners: [UUID: [String: Set<Int>]] = [:]

    init(allowSharing: @escaping () -> Bool = {
        UserDefaults.standard.bool(forKey: PeripheralAccessCoordinator.sharingKey)
    }) {
        self.allowSharing = allowSharing
    }

    func acquire(_ physical: UUID, appKey: String, session: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        var claimed = owners[physical] ?? [:]
        if !allowSharing() && claimed.keys.contains(where: { $0 != appKey }) {
            return false
        }
        claimed[appKey, default: []].insert(session)
        owners[physical] = claimed
        return true
    }

    func holds(_ physical: UUID, session: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return owners[physical]?.values.contains(where: { $0.contains(session) }) ?? false
    }

    func release(_ physical: UUID, session: Int) {
        lock.lock()
        defer { lock.unlock() }
        releaseLocked(physical, session: session)
    }

    func releaseAll(session: Int) {
        lock.lock()
        defer { lock.unlock() }
        for identifier in Array(owners.keys) {
            releaseLocked(identifier, session: session)
        }
    }

    private func releaseLocked(_ physical: UUID, session: Int) {
        guard var claimed = owners[physical] else { return }
        for appKey in Array(claimed.keys) {
            claimed[appKey]?.remove(session)
            if claimed[appKey]?.isEmpty == true {
                claimed[appKey] = nil
            }
        }
        owners[physical] = claimed.isEmpty ? nil : claimed
    }
}
