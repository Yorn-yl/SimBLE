import CoreBluetooth
import Foundation
import Network
import SimBLEDecoderKit

/// One TCP connection from the simulator. A loader connection sends `hello` and gets the attach decision;
/// a shim connection sends `register` and then drives one Mac CBCentralManager for one app-side central.
final class BridgeSession: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    struct Events {
        let registered: (BridgeSession, String) -> Void
        let closed: (BridgeSession) -> Void
    }

    private let connection: NWConnection
    private let queue: DispatchQueue
    private let number: Int
    private let logs: LogStore
    private let selection: SelectionSnapshot
    private let directory: AppDirectory
    private let identities: PeripheralIdentityRegistry
    private let access: PeripheralAccessCoordinator
    private let events: Events
    private(set) var appKey: String?
    private var identity: (bundleID: String, udid: String)?
    /// Resolved per entry: the simulator list may load after the app registers.
    private var source: String {
        guard let identity else { return "central #\(number)" }
        return directory.label(bundleID: identity.bundleID, udid: identity.udid)
    }
    private var central: CBCentralManager?
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var pendingWrites: [UUID: [(Data, CBCharacteristic)]] = [:]
    private var pendingReads: Set<String> = []
    private let decoders: DecoderRegistry
    /// One decoder per peripheral, characteristic and direction, since messages can span BLE packets.
    private var streams: [String: Stream] = [:]

    /// A stream's decoder, or none when no plugin accepts it, as of one plugin generation.
    private struct Stream {
        let generation: Int
        let name: String?
        let decoder: PacketDecoder?
    }
    private var buffer: Data = Data()
    private var isClosed: Bool = false

    init(connection: NWConnection, number: Int, logs: LogStore, selection: SelectionSnapshot, directory: AppDirectory,
         decoders: DecoderRegistry, identities: PeripheralIdentityRegistry, access: PeripheralAccessCoordinator, events: Events) {
        self.connection = connection
        self.number = number
        self.logs = logs
        self.selection = selection
        self.directory = directory
        self.decoders = decoders
        self.identities = identities
        self.access = access
        self.events = events
        self.queue = DispatchQueue(label: "sim-ble-bridge.session-\(number)")
        super.init()
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.receive()
            case .failed, .cancelled:
                self?.close()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func close() {
        guard !isClosed else { return }
        isClosed = true
        if let central {
            if central.isScanning {
                central.stopScan()
            }
            // A scan/retrieve does not imply ownership: only cancel our own connections.
            for peripheral in peripherals.values where peripheral.state != .disconnected && access.holds(peripheral.identifier, session: number) {
                central.cancelPeripheralConnection(peripheral)
            }
            log(.bridge, .app, "App disconnected", detail: "Released its Mac connections")
        }
        access.releaseAll(session: number)
        central = nil
        peripherals.removeAll()
        connection.cancel()
        events.closed(self)
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data {
                buffer.append(data)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = buffer[buffer.startIndex ..< newline]
                    buffer.removeSubrange(buffer.startIndex ... newline)
                    if let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                        handle(message)
                    }
                }
            }
            if isComplete || error != nil {
                close()
            } else {
                receive()
            }
        }
    }

    private func send(_ message: [String: Any], then completion: (() -> Void)? = nil) {
        guard !isClosed, var data = try? JSONSerialization.data(withJSONObject: message) else { return }
        data.append(0x0A)
        connection.send(content: data, completion: .contentProcessed { _ in
            completion?()
        })
    }

    private func sendEvent(_ event: String, _ peripheral: CBPeripheral? = nil, _ fields: [String: Any] = [:], error: Error? = nil) {
        var message = fields
        message["ev"] = event
        message["error"] = encode(error)
        if let peripheral {
            message["id"] = virtualID(for: peripheral).uuidString
            // The MTU grows after the Mac negotiates it, so every event carries the current value.
            if peripheral.state == .connected {
                message["mtuWith"] = peripheral.maximumWriteValueLength(for: .withResponse)
                message["mtuWithout"] = peripheral.maximumWriteValueLength(for: .withoutResponse)
            }
        }
        send(message)
    }

    private func virtualID(for peripheral: CBPeripheral) -> UUID {
        guard let identity else { return peripheral.identifier }
        return identities.virtualID(for: peripheral.identifier, udid: identity.udid, bundleID: identity.bundleID)
    }

    // MARK: Logging

    private func log(
        _ direction: LogEntry.Direction,
        _ category: LogEntry.Category,
        _ event: String,
        peripheral: CBPeripheral? = nil,
        detail: String = "",
        data: Data? = nil,
        decoded: (name: String, messages: [DecodedMessage])? = nil,
        error: Error? = nil
    ) {
        logs.append(appKey: appKey, source: source, direction, category, event, peripheral: label(peripheral), detail: detail, data: data,
                    decoder: decoded?.name, messages: decoded?.messages ?? [], error: error?.localizedDescription)
    }

    private func decode(_ data: Data?, _ direction: PacketDirection, _ peripheral: CBPeripheral,
                        _ characteristic: CBCharacteristic) -> (name: String, messages: [DecodedMessage])? {
        guard let data else { return nil }
        let context = PacketContext(service: Self.decoderUUID(characteristic.service?.uuid),
                                    characteristic: Self.decoderUUID(characteristic.uuid), direction: direction)
        let key = "\(direction)|\(readKey(peripheral, characteristic))"
        let generation = decoders.generation
        if streams[key]?.generation != generation {
            let made = decoders.makeDecoder(for: context)
            streams[key] = Stream(generation: made?.generation ?? generation, name: made?.name, decoder: made?.decoder)
        }
        guard let stream = streams[key], let name = stream.name, let decoder = stream.decoder else { return nil }
        return (name, decoder.decode(data))
    }

    /// Devices may declare 16-bit UUIDs in their 128-bit form, which CoreBluetooth then prints in full;
    /// plugins get the 4-digit form either way, as `PacketContext` documents.
    private static func decoderUUID(_ uuid: CBUUID?) -> String {
        guard let string = uuid?.uuidString else { return "" }
        let base = "-0000-1000-8000-00805F9B34FB"
        guard string.count == 36, string.hasPrefix("0000"), string.hasSuffix(base) else { return string }
        return String(string.dropFirst(4).prefix(4))
    }

    private func label(_ peripheral: CBPeripheral?) -> String {
        guard let peripheral else { return "" }
        let short = String(virtualID(for: peripheral).uuidString.prefix(8))
        return peripheral.name.map { "\($0) · \(short)" } ?? short
    }

    private func path(_ characteristic: CBCharacteristic) -> String {
        "\(characteristic.service?.uuid.description ?? "?") / \(characteristic.uuid)"
    }

    private func readKey(_ peripheral: CBPeripheral, _ characteristic: CBCharacteristic) -> String {
        "\(peripheral.identifier)|\(characteristic.service?.uuid.uuidString ?? "")|\(characteristic.uuid.uuidString)"
    }

    // MARK: Commands

    private func handle(_ message: [String: Any]) {
        guard !isClosed, let operation = message["op"] as? String else { return }
        let uuids: ([String]?) -> [CBUUID]? = { strings in strings?.map(CBUUID.init(string:)) }

        switch operation {
        case "hello":
            answerLoader(message)
            return
        case "register":
            register(message)
            return
        default:
            break
        }
        // A loader's hello socket is not a GATT client, and all simulated app identity
        // must be established before any request is allowed to touch the Mac radio.
        guard appKey != nil else {
            close()
            return
        }
        let central = ensureCentral()
        guard central.state == .poweredOn || operation == "retrieve" || operation == "retrieveConnected" else {
            log(.toDevice, .app, "Ignored \(operation)", detail: "Mac Bluetooth is not powered on")
            return
        }

        switch operation {
        case "scan":
            var options: [String: Any] = [:]
            let allowDuplicates = message["allowDuplicates"] as? Bool == true
            if allowDuplicates {
                options[CBCentralManagerScanOptionAllowDuplicatesKey] = true
            }
            let services = uuids(message["services"] as? [String])
            log(.toDevice, .scan, "Start scan",
                detail: "services: \(services?.map(\.description).joined(separator: ", ") ?? "any")\(allowDuplicates ? ", duplicates" : "")")
            central.scanForPeripherals(withServices: services, options: options)
        case "stopScan":
            log(.toDevice, .scan, "Stop scan")
            central.stopScan()
        case "retrieve":
            let identifiers = (message["ids"] as? [String] ?? []).compactMap(UUID.init(uuidString:))
            // Never pass another app's virtual UUID (or an old host UUID) to CoreBluetooth.
            let physical = identifiers.compactMap { identifier -> UUID? in
                guard let identity else { return nil }
                return identities.physicalID(for: identifier, udid: identity.udid, bundleID: identity.bundleID)
            }
            let found = central.retrievePeripherals(withIdentifiers: physical)
            log(.toDevice, .connection, "Retrieve peripherals", detail: "\(identifiers.count) requested, \(found.count) known to the Mac")
            respond(to: message, with: found)
        case "retrieveConnected":
            let services = uuids(message["services"] as? [String]) ?? []
            let found = central.retrieveConnectedPeripherals(withServices: services)
            log(.toDevice, .connection, "Retrieve connected peripherals",
                detail: "services: \(services.map(\.description).joined(separator: ", ")), \(found.count) found")
            respond(to: message, with: found)
        case "connect":
            guard let peripheral = peripheral(for: message) else {
                let error = NSError(domain: CBErrorDomain, code: CBError.unknownDevice.rawValue,
                                    userInfo: [NSLocalizedDescriptionKey: "Unknown device on the Mac side"])
                log(.toDevice, .connection, "Connect failed", detail: message["id"] as? String ?? "", error: error)
                sendEvent("failToConnect", nil, ["id": message["id"] ?? ""], error: error)
                return
            }
            guard let appKey, access.acquire(peripheral.identifier, appKey: appKey, session: number) else {
                let error = NSError(domain: CBErrorDomain, code: CBError.connectionFailed.rawValue,
                                    userInfo: [NSLocalizedDescriptionKey: "Device is in use by another simulator app. Enable shared device connections only for multi-client testing."])
                log(.toDevice, .connection, "Connect rejected", peripheral: peripheral, error: error)
                sendEvent("failToConnect", nil, ["id": message["id"] ?? ""], error: error)
                return
            }
            // Do not install a GATT delegate until this session has obtained a lease.
            peripheral.delegate = self
            log(.toDevice, .connection, "Connect", peripheral: peripheral)
            central.connect(peripheral)
        case "disconnect":
            if let peripheral = ownedPeripheral(for: message) {
                log(.toDevice, .connection, "Disconnect", peripheral: peripheral)
                central.cancelPeripheralConnection(peripheral)
            }
        case "discoverServices":
            guard let peripheral = ownedPeripheral(for: message) else { return }
            let services = uuids(message["services"] as? [String])
            log(.toDevice, .gatt, "Discover services", peripheral: peripheral, detail: services?.map(\.description).joined(separator: ", ") ?? "all")
            peripheral.discoverServices(services)
        case "discoverCharacteristics":
            guard let peripheral = ownedPeripheral(for: message), let service = service(for: message, in: peripheral) else { return }
            let characteristics = uuids(message["chars"] as? [String])
            log(.toDevice, .gatt, "Discover characteristics", peripheral: peripheral,
                detail: "\(service.uuid): \(characteristics?.map(\.description).joined(separator: ", ") ?? "all")")
            peripheral.discoverCharacteristics(characteristics, for: service)
        case "read":
            guard let peripheral = ownedPeripheral(for: message), let characteristic = characteristic(for: message, in: peripheral) else { return }
            pendingReads.insert(readKey(peripheral, characteristic))
            log(.toDevice, .data, "Read", peripheral: peripheral, detail: path(characteristic))
            peripheral.readValue(for: characteristic)
        case "write":
            guard let peripheral = ownedPeripheral(for: message),
                  let characteristic = characteristic(for: message, in: peripheral),
                  let data = (message["data"] as? String).flatMap({ Data(base64Encoded: $0) }) else { return }
            if message["withResponse"] as? Bool == true {
                log(.toDevice, .data, "Write", peripheral: peripheral, detail: path(characteristic), data: data,
                    decoded: decode(data, .toDevice, peripheral, characteristic))
                peripheral.writeValue(data, for: characteristic, type: .withResponse)
            } else {
                log(.toDevice, .data, "Write without response", peripheral: peripheral, detail: path(characteristic), data: data,
                    decoded: decode(data, .toDevice, peripheral, characteristic))
                // The shim always reports canSendWriteWithoutResponse, so flow control happens here.
                pendingWrites[peripheral.identifier, default: []].append((data, characteristic))
                drainWrites(for: peripheral)
            }
        case "notify":
            guard let peripheral = ownedPeripheral(for: message), let characteristic = characteristic(for: message, in: peripheral) else { return }
            let enabled = message["enabled"] as? Bool == true
            log(.toDevice, .gatt, enabled ? "Enable notifications" : "Disable notifications", peripheral: peripheral, detail: path(characteristic))
            peripheral.setNotifyValue(enabled, for: characteristic)
        case "readRSSI":
            if let peripheral = ownedPeripheral(for: message) {
                log(.toDevice, .connection, "Read RSSI", peripheral: peripheral)
                peripheral.readRSSI()
            }
        default:
            log(.toDevice, .app, "Unknown operation \(operation)")
        }
    }

    private func answerLoader(_ message: [String: Any]) {
        let bundleID = message["bundleId"] as? String ?? ""
        let udid = message["udid"] as? String ?? ""
        let key = AppKey.make(udid: udid, bundleID: bundleID)
        let attach = selection.contains(key)
        if attach {
            logs.append(appKey: key, source: directory.label(bundleID: bundleID, udid: udid), .bridge, .app, "App launched, bridge attached",
                        detail: "pid \(message["pid"] ?? "?")")
        }
        // Cancelling right away would drop the unsent reply.
        send(["attach": attach]) { [connection] in
            connection.cancel()
        }
    }

    private func register(_ message: [String: Any]) {
        // Missing values would merge independent apps into the same ownership scope.
        guard appKey == nil,
              let bundleID = message["bundleId"] as? String, !bundleID.isEmpty,
              let udid = message["udid"] as? String, !udid.isEmpty else {
            close()
            return
        }
        let key = AppKey.make(udid: udid, bundleID: bundleID)
        // A shim must still be selected when it registers/reconnects. Loader checks
        // alone are not sufficient for long-running sessions or local TCP clients.
        guard selection.contains(key) else {
            close()
            return
        }
        appKey = key
        identity = (bundleID, udid)
        log(.bridge, .app, "App connected", detail: "central #\(number), pid \(message["pid"] ?? "?")")
        events.registered(self, key)
        _ = ensureCentral()
    }

    private func ensureCentral() -> CBCentralManager {
        if let central {
            return central
        }
        let central = CBCentralManager(delegate: self, queue: queue)
        self.central = central
        return central
    }

    private func respond(to message: [String: Any], with found: [CBPeripheral]) {
        for peripheral in found {
            track(peripheral)
        }
        send([
            "re": message["req"] ?? 0,
            "peripherals": found.map { peripheral -> [String: Any] in
                var entry: [String: Any] = ["id": virtualID(for: peripheral).uuidString]
                entry["name"] = peripheral.name
                return entry
            },
        ])
    }

    private func track(_ peripheral: CBPeripheral) {
        peripherals[peripheral.identifier] = peripheral
        // Scanning another app's device must not capture its GATT callback delegate.
        if access.holds(peripheral.identifier, session: number) {
            peripheral.delegate = self
        }
    }

    private func peripheral(for message: [String: Any]) -> CBPeripheral? {
        guard let virtual = (message["id"] as? String).flatMap(UUID.init(uuidString:)),
              let identity,
              let identifier = identities.physicalID(for: virtual, udid: identity.udid, bundleID: identity.bundleID) else {
            return nil
        }
        if let known = peripherals[identifier] {
            return known
        }
        guard let retrieved = central?.retrievePeripherals(withIdentifiers: [identifier]).first else { return nil }
        track(retrieved)
        return retrieved
    }

    private func ownedPeripheral(for message: [String: Any]) -> CBPeripheral? {
        guard let peripheral = peripheral(for: message),
              access.holds(peripheral.identifier, session: number) else {
            log(.toDevice, .connection, "Ignored unowned peripheral operation",
                detail: message["id"] as? String ?? "unknown")
            return nil
        }
        return peripheral
    }

    private func service(for message: [String: Any], in peripheral: CBPeripheral) -> CBService? {
        guard let uuid = message["service"] as? String else { return nil }
        return peripheral.services?.first { $0.uuid == CBUUID(string: uuid) }
    }

    private func characteristic(for message: [String: Any], in peripheral: CBPeripheral) -> CBCharacteristic? {
        guard let uuid = message["char"] as? String else { return nil }
        return service(for: message, in: peripheral)?.characteristics?.first { $0.uuid == CBUUID(string: uuid) }
    }

    private func drainWrites(for peripheral: CBPeripheral) {
        while peripheral.canSendWriteWithoutResponse, var queue = pendingWrites[peripheral.identifier], !queue.isEmpty {
            let (data, characteristic) = queue.removeFirst()
            pendingWrites[peripheral.identifier] = queue
            peripheral.writeValue(data, for: characteristic, type: .withoutResponse)
        }
    }

    private func encode(_ error: Error?) -> [String: Any]? {
        guard let error = error as NSError? else { return nil }
        return ["domain": error.domain, "code": error.code, "message": error.localizedDescription]
    }

    private func characteristicFields(_ characteristic: CBCharacteristic) -> [String: Any] {
        ["service": characteristic.service?.uuid.uuidString ?? "", "char": characteristic.uuid.uuidString]
    }

    private func advertisementFields(_ data: [String: Any]) -> [String: Any] {
        var result: [String: Any] = [:]
        if let name = data[CBAdvertisementDataLocalNameKey] as? String { result["localName"] = name }
        if let manufacturer = data[CBAdvertisementDataManufacturerDataKey] as? Data { result["manufacturerData"] = manufacturer.base64EncodedString() }
        if let uuids = data[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] { result["serviceUUIDs"] = uuids.map(\.uuidString) }
        if let uuids = data[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID] { result["overflowServiceUUIDs"] = uuids.map(\.uuidString) }
        if let uuids = data[CBAdvertisementDataSolicitedServiceUUIDsKey] as? [CBUUID] { result["solicitedServiceUUIDs"] = uuids.map(\.uuidString) }
        if let serviceData = data[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] {
            var encoded: [String: String] = [:]
            for (uuid, value) in serviceData {
                encoded[uuid.uuidString] = value.base64EncodedString()
            }
            result["serviceData"] = encoded
        }
        if let power = data[CBAdvertisementDataTxPowerLevelKey] as? NSNumber { result["txPower"] = power }
        if let connectable = data[CBAdvertisementDataIsConnectable] as? NSNumber { result["isConnectable"] = connectable }
        return result
    }

    // MARK: CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        log(.bridge, .app, "Mac Bluetooth state", detail: BluetoothStateText.describe(central.state))
        sendEvent("state", nil, ["state": central.state.rawValue])
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        track(peripheral)
        var parts: [String] = ["RSSI \(RSSI)"]
        if let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String {
            parts.append("name \(name)")
        }
        if let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] {
            parts.append("services \(services.map(\.description).joined(separator: ", "))")
        }
        log(.fromDevice, .advertisement, "Advertisement", peripheral: peripheral, detail: parts.joined(separator: ", "),
            data: advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data)
        var fields: [String: Any] = ["rssi": RSSI, "adv": advertisementFields(advertisementData)]
        fields["name"] = peripheral.name
        sendEvent("discovered", peripheral, fields)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        log(.fromDevice, .connection, "Connected", peripheral: peripheral,
            detail: "MTU \(peripheral.maximumWriteValueLength(for: .withoutResponse)) without response")
        sendEvent("connected", peripheral)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        access.release(peripheral.identifier, session: number)
        log(.fromDevice, .connection, "Failed to connect", peripheral: peripheral, error: error)
        sendEvent("failToConnect", peripheral, error: error)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        access.release(peripheral.identifier, session: number)
        log(.fromDevice, .connection, "Disconnected", peripheral: peripheral, error: error)
        pendingWrites[peripheral.identifier] = nil
        streams = streams.filter { !$0.key.contains(peripheral.identifier.uuidString) }
        sendEvent("disconnected", peripheral, error: error)
    }

    // MARK: CBPeripheralDelegate

    func peripheralDidUpdateName(_ peripheral: CBPeripheral) {
        log(.fromDevice, .connection, "Name updated", peripheral: peripheral)
        var fields: [String: Any] = [:]
        fields["name"] = peripheral.name
        sendEvent("name", peripheral, fields)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        log(.fromDevice, .gatt, "Services", peripheral: peripheral,
            detail: peripheral.services?.map(\.uuid.description).joined(separator: ", ") ?? "", error: error)
        sendEvent("services", peripheral, ["services": peripheral.services?.map(\.uuid.uuidString) ?? []], error: error)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        let characteristics = service.characteristics ?? []
        log(.fromDevice, .gatt, "Characteristics", peripheral: peripheral,
            detail: "\(service.uuid): " + characteristics.map { "\($0.uuid) [\(PropertyText.describe($0.properties))]" }.joined(separator: ", "),
            error: error)
        sendEvent("characteristics", peripheral, [
            "service": service.uuid.uuidString,
            "chars": characteristics.map { ["uuid": $0.uuid.uuidString, "props": $0.properties.rawValue] },
        ], error: error)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        let isReadResponse = pendingReads.remove(readKey(peripheral, characteristic)) != nil
        log(.fromDevice, .data, isReadResponse ? "Read response" : "Notification", peripheral: peripheral, detail: path(characteristic),
            data: characteristic.value, decoded: decode(characteristic.value, .fromDevice, peripheral, characteristic), error: error)
        var fields = characteristicFields(characteristic)
        fields["data"] = characteristic.value?.base64EncodedString()
        sendEvent("value", peripheral, fields, error: error)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        log(.fromDevice, .data, "Write acknowledged", peripheral: peripheral, detail: path(characteristic), error: error)
        sendEvent("wrote", peripheral, characteristicFields(characteristic), error: error)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        log(.fromDevice, .gatt, characteristic.isNotifying ? "Notifications on" : "Notifications off", peripheral: peripheral,
            detail: path(characteristic), error: error)
        var fields = characteristicFields(characteristic)
        fields["enabled"] = characteristic.isNotifying
        sendEvent("notifyState", peripheral, fields, error: error)
    }

    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        log(.fromDevice, .connection, "RSSI", peripheral: peripheral, detail: "\(RSSI)", error: error)
        sendEvent("rssi", peripheral, ["rssi": RSSI], error: error)
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        drainWrites(for: peripheral)
    }
}

enum BluetoothStateText {
    static func describe(_ state: CBManagerState) -> String {
        switch state {
        case .poweredOn: "On"
        case .poweredOff: "Off"
        case .unauthorized: "Not allowed (System Settings › Privacy & Security › Bluetooth)"
        case .unsupported: "Unsupported"
        case .resetting: "Resetting"
        default: "Unknown"
        }
    }
}

enum PropertyText {
    static func describe(_ properties: CBCharacteristicProperties) -> String {
        let names: [(CBCharacteristicProperties, String)] = [
            (.read, "read"), (.write, "write"), (.writeWithoutResponse, "write-no-rsp"), (.notify, "notify"), (.indicate, "indicate"),
        ]
        return names.filter { properties.contains($0.0) }.map(\.1).joined(separator: " ")
    }
}
