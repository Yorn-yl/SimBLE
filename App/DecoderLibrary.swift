import Foundation
import Observation
import SimBLEDecoderKit

/// A loaded plugin as the UI sees it.
struct DecoderInfo: Identifiable, Hashable {
    let name: String
    let columns: [DecoderColumn]
    let path: String

    var id: String { name }

    /// Shipped inside the app; user plugins live in DecoderLibrary.userDirectory.
    var isBuiltIn: Bool {
        Bundle.main.builtInPlugInsURL.map { path.hasPrefix($0.path) } ?? false
    }
}

/// A plugin column placed in the log table; the customization ID keeps the user's layout per plugin.
struct TableDecoderColumn: Identifiable, Hashable {
    let decoder: String
    let column: DecoderColumn
    let title: String

    var id: String { "decoder.\(decoder).\(column.id)" }
}

/// Stream decoders for bridge sessions, readable from any queue. A reload bumps the generation,
/// and sessions drop decoders made by an older one.
final class DecoderRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var plugins: [DecoderPlugin] = []
    private var currentGeneration: Int = 0

    var generation: Int {
        lock.lock()
        defer { lock.unlock() }
        return currentGeneration
    }

    func replace(with plugins: [DecoderPlugin]) {
        lock.lock()
        defer { lock.unlock() }
        self.plugins = plugins
        currentGeneration += 1
    }

    func makeDecoder(for context: PacketContext) -> (name: String, decoder: PacketDecoder, generation: Int)? {
        lock.lock()
        defer { lock.unlock() }
        guard let plugin = plugins.first(where: { $0.accepts(context) }) else { return nil }
        return (plugin.name, plugin.makeDecoder(for: context), currentGeneration)
    }
}

/// Loads decoder plugins: the ones built into the app, then ~/Library/Application Support/SimBLE/Decoders,
/// where a plugin replaces a built-in one of the same file name.
@MainActor
@Observable
final class DecoderLibrary {
    static let userDirectory: URL = Installer.supportDirectory.appending(path: "Decoders", directoryHint: .isDirectory)

    private(set) var decoders: [DecoderInfo] = []
    private(set) var problems: [String] = []
    @ObservationIgnored let registry = DecoderRegistry()
    private static let entryPoint = "simble_make_decoder_plugin"

    var tableColumns: [TableDecoderColumn] {
        let titles: [String] = decoders.flatMap { $0.columns.map(\.title) }
        return decoders.flatMap { decoder in
            decoder.columns.map { column in
                // Two plugins with a same-titled column get the plugin name to tell them apart.
                let isShared = titles.filter { $0 == column.title }.count > 1
                return TableDecoderColumn(decoder: decoder.name, column: column,
                                          title: isShared ? "\(column.title) (\(decoder.name))" : column.title)
            }
        }
    }

    /// Copies plugin dylibs into the user directory, replacing ones with the same file name, and loads them.
    func install(_ urls: [URL]) {
        let manager = FileManager.default
        try? manager.createDirectory(at: Self.userDirectory, withIntermediateDirectories: true)
        var failures: [String] = []
        for url in urls where url.pathExtension == "dylib" {
            let destination = Self.userDirectory.appending(path: url.lastPathComponent)
            do {
                if manager.fileExists(atPath: destination.path) {
                    try manager.removeItem(at: destination)
                }
                try manager.copyItem(at: url, to: destination)
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        reload()
        problems += failures
    }

    /// Deletes a user plugin; built-in plugins stay. Its code stays mapped until the app quits.
    func remove(_ decoder: DecoderInfo) {
        guard !decoder.isBuiltIn else { return }
        try? FileManager.default.removeItem(atPath: decoder.path)
        reload()
    }

    func reload() {
        try? FileManager.default.createDirectory(at: Self.userDirectory, withIntermediateDirectories: true)
        var files: [String: URL] = [:]
        for directory in [Bundle.main.builtInPlugInsURL, Self.userDirectory].compactMap({ $0 }) {
            let contents = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            for url in contents where url.pathExtension == "dylib" {
                files[url.lastPathComponent] = url
            }
        }

        var plugins: [DecoderPlugin] = []
        var infos: [DecoderInfo] = []
        var problems: [String] = []
        for url in files.values.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            do {
                let plugin = try load(url)
                guard !infos.contains(where: { $0.name == plugin.name }) else {
                    problems.append("\(url.lastPathComponent): another plugin is already named \(plugin.name)")
                    continue
                }
                plugins.append(plugin)
                infos.append(DecoderInfo(name: plugin.name, columns: plugin.columns, path: url.path))
            } catch {
                problems.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        registry.replace(with: plugins)
        decoders = infos
        self.problems = problems
    }

    /// dlopen caches images by path, so each load goes through a fresh copy; a rebuilt plugin then
    /// loads without restarting. Old images stay mapped, which is fine for a debugging tool.
    private func load(_ url: URL) throws -> DecoderPlugin {
        let copy = FileManager.default.temporaryDirectory.appending(path: "SimBLEDecoders", directoryHint: .isDirectory)
            .appending(path: "\(UUID().uuidString)-\(url.lastPathComponent)")
        try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: url, to: copy)
        guard let handle = dlopen(copy.path, RTLD_NOW | RTLD_LOCAL) else {
            throw PluginError(message: String(cString: dlerror()))
        }
        guard let symbol = dlsym(handle, Self.entryPoint) else {
            throw PluginError(message: "missing entry point \(Self.entryPoint)")
        }
        typealias Factory = @convention(c) () -> UnsafeMutableRawPointer
        guard let plugin = importDecoderPlugin(unsafeBitCast(symbol, to: Factory.self)()) else {
            throw PluginError(message: "entry point did not return a DecoderPlugin")
        }
        return plugin
    }

    private struct PluginError: LocalizedError {
        let message: String

        var errorDescription: String? { message }
    }
}
