import AppKit
import Observation
import SwiftUI

@main
struct SimBLEApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("SimBLE", id: "main") {
            ContentView(model: appDelegate.model)
        }
        .defaultSize(width: 1280, height: 800)
    }
}

@MainActor
@Observable
final class AppModel {
    let logs = LogStore()
    let settings = InjectionSettings()
    let directory = AppDirectory()
    let decoders = DecoderLibrary()
    let server: BridgeServer
    let simulators: SimulatorService
    private(set) var installError: String?

    init() {
        server = BridgeServer(logs: logs, selection: settings.snapshot, directory: directory, decoders: decoders.registry)
        simulators = SimulatorService(loaderPath: Installer.loaderPath, directory: directory, logs: logs)
    }

    func start() {
        do {
            try Installer.install()
        } catch {
            installError = error.localizedDescription
        }
        decoders.reload()
        server.start()
        simulators.start()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model: AppModel

    override init() {
        // The model opens the log database, so the data has to be in place first.
        Installer.migrateLegacyDirectories()
        model = AppModel()
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.simulators.removeInjection()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

struct ContentView: View {
    let model: AppModel
    @State private var appFilter: String? = SidebarView.allApps
    @State private var selectedEntry: LogEntry.ID?
    @State private var showsInspector: Bool = false

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model, appFilter: $appFilter)
                .navigationSplitViewColumnWidth(min: 260, ideal: 300)
        } detail: {
            LogView(logs: model.logs, directory: model.directory, decoders: model.decoders, appFilter: appFilter == SidebarView.allApps ? nil : appFilter,
                    selection: $selectedEntry)
                .onChange(of: selectedEntry) { _, entry in
                    // The table needs the width; the inspector only opens for a selected entry.
                    showsInspector = entry != nil
                }
                .inspector(isPresented: $showsInspector) {
                    EntryInspector(entry: model.logs.entries.last { $0.id == selectedEntry })
                        .inspectorColumnWidth(min: 280, ideal: 360)
                }
                .toolbar {
                    ToolbarItem {
                        Button {
                            showsInspector.toggle()
                        } label: {
                            Label("Inspector", systemImage: "sidebar.right")
                        }
                    }
                }
        }
    }
}
