import CoreBluetooth
import Foundation
import Network
import Observation

@MainActor
@Observable
final class BridgeServer {
    enum Status: Equatable {
        case starting
        case listening
        case failed(String)
    }

    static let port: UInt16 = 50505

    private(set) var status: Status = .starting
    private(set) var bluetoothState: CBManagerState = .unknown
    /// Connected shim sessions per app key; an app with several CBCentralManagers has several.
    private(set) var connectedApps: [String: Int] = [:]

    @ObservationIgnored private let logs: LogStore
    @ObservationIgnored private let selection: SelectionSnapshot
    @ObservationIgnored private let directory: AppDirectory
    @ObservationIgnored private let decoders: DecoderRegistry
    @ObservationIgnored private let identities = PeripheralIdentityRegistry()
    @ObservationIgnored private let access = PeripheralAccessCoordinator()
    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var sessions: [ObjectIdentifier: BridgeSession] = [:]
    @ObservationIgnored private var sessionCount: Int = 0
    @ObservationIgnored private var monitor: BluetoothStateMonitor?

    init(logs: LogStore, selection: SelectionSnapshot, directory: AppDirectory, decoders: DecoderRegistry) {
        self.logs = logs
        self.selection = selection
        self.directory = directory
        self.decoders = decoders
    }

    func start() {
        // Owning a central from launch also triggers the macOS Bluetooth permission prompt up front.
        monitor = BluetoothStateMonitor { [weak self] state in
            Task { @MainActor in
                self?.bluetoothState = state
            }
        }

        let parameters = NWParameters.tcp
        parameters.acceptLocalOnly = true
        parameters.allowLocalEndpointReuse = true
        guard let port = NWEndpoint.Port(rawValue: Self.port), let listener = try? NWListener(using: parameters, on: port) else {
            status = .failed("Cannot listen on port \(Self.port)")
            return
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                self?.accept(connection)
            }
        }
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                self?.listenerChanged(state)
            }
        }
        listener.start(queue: .main)
        self.listener = listener
    }

    private func listenerChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            status = .listening
            logs.append(appKey: nil, source: "Bridge", .bridge, .app, "Listening", detail: "127.0.0.1:\(Self.port)")
        case let .failed(error):
            if case let .posix(code) = error, code == .EADDRINUSE {
                status = .failed("Port \(Self.port) is in use. Stop any other bridge helper and relaunch.")
            } else {
                status = .failed(error.localizedDescription)
            }
        default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        sessionCount += 1
        let events = BridgeSession.Events(
            registered: { [weak self] _, key in
                Task { @MainActor in
                    self?.connectedApps[key, default: 0] += 1
                }
            },
            closed: { [weak self] session in
                Task { @MainActor in
                    self?.remove(session)
                }
            }
        )
        let session = BridgeSession(connection: connection, number: sessionCount, logs: logs, selection: selection, directory: directory,
                                    decoders: decoders, identities: identities, access: access, events: events)
        sessions[ObjectIdentifier(session)] = session
        session.start()
    }

    private func remove(_ session: BridgeSession) {
        sessions[ObjectIdentifier(session)] = nil
        guard let key = session.appKey, let count = connectedApps[key] else { return }
        connectedApps[key] = count > 1 ? count - 1 : nil
    }
}

final class BluetoothStateMonitor: NSObject, CBCentralManagerDelegate {
    private let onChange: (CBManagerState) -> Void
    private var central: CBCentralManager?

    init(onChange: @escaping (CBManagerState) -> Void) {
        self.onChange = onChange
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        onChange(central.state)
    }
}
