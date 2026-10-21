import CoreBluetooth
import SwiftUI
import UniformTypeIdentifiers

struct SidebarView: View {
    static let allApps: String = "*"

    let model: AppModel
    @Binding var appFilter: String?
    @State private var isRefreshing: Bool = false
    @AppStorage(PeripheralAccessCoordinator.sharingKey) private var allowSharing = false

    var body: some View {
        List(selection: $appFilter) {
            Section("Bridge") {
                statusRows
            }
            Section("Decoders") {
                decoderRows
            }
            Section("Logs") {
                Label("All Apps", systemImage: "list.bullet.rectangle")
                    .tag(Optional(Self.allApps))
            }
            if model.simulators.devices.isEmpty {
                Section("Simulators") {
                    Text(model.simulators.lastError ?? "No booted iOS simulator")
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(model.simulators.devices) { device in
                Section("\(device.name) · \(device.runtime)") {
                    if device.apps.isEmpty {
                        Text("No installed apps").foregroundStyle(.secondary)
                    }
                    ForEach(device.apps) { app in
                        AppRow(model: model, device: device, app: app)
                            .tag(Optional(app.id))
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem {
                Button {
                    isRefreshing = true
                    Task {
                        await model.simulators.refresh(reloadApps: true)
                        isRefreshing = false
                    }
                } label: {
                    Label("Reload Simulators", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(isRefreshing)
                .help("Reload booted simulators and their installed apps")
            }
        }
    }

    @ViewBuilder
    private var decoderRows: some View {
        ForEach(model.decoders.decoders) { decoder in
            HStack {
                Label(decoder.name, systemImage: "puzzlepiece.extension")
                Spacer()
                Text(decoder.isBuiltIn ? "Built-in" : "User")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .help(decoder.path)
            .contextMenu {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: decoder.path)])
                }
                if !decoder.isBuiltIn {
                    Button("Remove", role: .destructive) {
                        model.decoders.remove(decoder)
                    }
                }
            }
        }
        if model.decoders.decoders.isEmpty {
            Text("No decoder plugins").foregroundStyle(.secondary)
        }
        ForEach(model.decoders.problems, id: \.self) { problem in
            Label(problem, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        }
        HStack {
            Button("Add Plugin") {
                let panel = NSOpenPanel()
                panel.allowsMultipleSelection = true
                panel.allowedContentTypes = [UTType(filenameExtension: "dylib") ?? .data]
                panel.message = "Choose decoder plugins (.dylib) built with make-decoder.sh"
                if panel.runModal() == .OK {
                    model.decoders.install(panel.urls)
                }
            }
            .help("Install decoder plugins into your plugin folder")
            Button("Reload") {
                model.decoders.reload()
            }
            .help("Load new and rebuilt plugins; streams switch to them on their next packet")
            Button("Open Folder") {
                NSWorkspace.shared.open(DecoderLibrary.userDirectory)
            }
            .help("Folder for your own plugins (built-in ones are inside the app): \(DecoderLibrary.userDirectory.path)")
        }
        .buttonStyle(.link)
    }

    @ViewBuilder
    private var statusRows: some View {
        switch model.server.status {
        case .starting:
            Label("Starting…", systemImage: "hourglass")
        case .listening:
            Label("Listening on 127.0.0.1:\(String(BridgeServer.port))", systemImage: "network")
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        }
        Label("Mac Bluetooth: \(BluetoothStateText.describe(model.server.bluetoothState))", systemImage: "antenna.radiowaves.left.and.right")
            .foregroundStyle(model.server.bluetoothState == .poweredOn ? Color.primary : Color.orange)
        Toggle("Shared device connections (unsafe)", isOn: $allowSharing)
            .help("Allow separate simulator apps to use the same physical peripheral. Notifications and protocol responses are not isolated. Disconnect existing clients to return to exclusive access.")
        if let installError = model.installError {
            Label("Install failed: \(installError)", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        }
    }
}

private struct AppRow: View {
    let model: AppModel
    let device: SimulatorDevice
    let app: SimulatorApp

    private var key: String { app.id }

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(model.server.connectedApps[key] != nil ? Color.green : Color.clear)
                .frame(width: 7, height: 7)
                .help("Connected to the bridge")
            VStack(alignment: .leading, spacing: 1) {
                Text(app.name)
                Text(app.bundleID)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            Spacer()
            Button {
                Task {
                    await model.simulators.relaunch(app, on: device)
                }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Relaunch \(app.name) so the bridge setting applies")
            Toggle("Bridge", isOn: Binding(
                get: { model.settings.isSelected(key) },
                set: { model.settings.setSelected(key, $0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .help("Load the Bluetooth bridge into \(app.name) on its next launch")
        }
        .contextMenu {
            Button("Relaunch with Current Setting") {
                Task {
                    await model.simulators.relaunch(app, on: device)
                }
            }
            Button("Copy Bundle Identifier") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(app.bundleID, forType: .string)
            }
        }
    }
}
