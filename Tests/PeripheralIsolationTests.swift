import Foundation

@main
struct PeripheralIsolationTests {
    static func main() {
        let suite = "SimBLE.PeripheralIsolationTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { fatalError("Cannot create test defaults") }
        defer { defaults.removePersistentDomain(forName: suite) }

        let physical = UUID()
        let otherDevice = UUID()
        let registry = PeripheralIdentityRegistry(defaults: defaults)
        let a = registry.virtualID(for: physical, udid: "sim-a", bundleID: "app-a")
        assert(registry.virtualID(for: physical, udid: "sim-a", bundleID: "app-a") == a,
               "Repeated advertisements must preserve the identifier")
        let b = registry.virtualID(for: physical, udid: "sim-b", bundleID: "app-a")
        let c = registry.virtualID(for: physical, udid: "sim-a", bundleID: "app-b")
        assert(a != b && a != c && b != c, "Different apps and simulators need different identifiers")
        assert(registry.virtualID(for: otherDevice, udid: "sim-a", bundleID: "app-a") != a)
        assert(registry.physicalID(for: a, udid: "sim-a", bundleID: "app-a") == physical)
        assert(registry.physicalID(for: a, udid: "sim-b", bundleID: "app-a") == nil,
               "A virtual UUID must not resolve from another simulator")
        assert(registry.physicalID(for: a, udid: "sim-a", bundleID: "app-b") == nil,
               "A virtual UUID must not resolve from another app")
        let restored = PeripheralIdentityRegistry(defaults: defaults)
        assert(restored.virtualID(for: physical, udid: "sim-a", bundleID: "app-a") == a,
               "App restarts must keep the same UUID")
        assert(restored.physicalID(for: a, udid: "sim-a", bundleID: "app-a") == physical,
               "retrievePeripherals must work after restart")

        let exclusive = PeripheralAccessCoordinator(allowSharing: { false })
        assert(exclusive.acquire(physical, appKey: "sim-a|app-a", session: 1))
        assert(exclusive.acquire(physical, appKey: "sim-a|app-a", session: 2),
               "Two CBCentralManagers in the same app may share")
        assert(!exclusive.acquire(physical, appKey: "sim-b|app-a", session: 3),
               "Different simulators must not interleave commands")
        assert(!exclusive.acquire(physical, appKey: "sim-a|app-b", session: 4),
               "Different apps must not interleave commands")
        assert(exclusive.holds(physical, session: 1))
        assert(!exclusive.holds(physical, session: 3))
        assert(exclusive.acquire(otherDevice, appKey: "sim-b|app-a", session: 3),
               "Other devices are independent")
        exclusive.release(physical, session: 1)
        assert(!exclusive.acquire(physical, appKey: "sim-b|app-a", session: 3),
               "One remaining central must retain ownership")
        exclusive.releaseAll(session: 2)
        assert(exclusive.acquire(physical, appKey: "sim-b|app-a", session: 3),
               "A released physical device becomes available")
        exclusive.releaseAll(session: 3)
        assert(!exclusive.holds(physical, session: 3))
        assert(!exclusive.holds(otherDevice, session: 3))

        // Competing connection attempts from independent session queues must not race.
        let racing = PeripheralAccessCoordinator(allowSharing: { false })
        let resultLock = NSLock()
        var winners: [Int] = []
        DispatchQueue.concurrentPerform(iterations: 64) { index in
            if racing.acquire(physical, appKey: "sim-\(index)|app-\(index)", session: index + 100) {
                resultLock.lock()
                winners.append(index)
                resultLock.unlock()
            }
        }
        assert(winners.count == 1, "Only one concurrent app may claim the device")
        racing.releaseAll(session: winners[0] + 100)
        assert(racing.acquire(physical, appKey: "next-sim|next-app", session: 500),
               "A released concurrent claim must free the peripheral")

        let shared = PeripheralAccessCoordinator(allowSharing: { true })
        assert(shared.acquire(physical, appKey: "sim-a|app-a", session: 1))
        assert(shared.acquire(physical, appKey: "sim-b|app-a", session: 2),
               "Explicit shared mode allows two simulated apps")
        shared.releaseAll(session: 1)
        assert(shared.holds(physical, session: 2))

        print("Peripheral identity and ownership tests passed")
    }
}
