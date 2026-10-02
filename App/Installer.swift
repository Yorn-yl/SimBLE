import Foundation

/// Copies the loader, shim and LLDB hook out of the app bundle to a stable location, so paths baked into
/// simulator environments and ~/.lldbinit survive moving or rebuilding the app.
enum Installer {
    static let supportDirectory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "SimBLE", directoryHint: .isDirectory)
    static var loaderPath: String { supportDirectory.appending(path: "libSimBLELoader.dylib").path }

    /// Moves history, plugins and text logs from the directories the app used as "SimBLE Bridge".
    /// Runs before anything opens them.
    static func migrateLegacyDirectories() {
        let manager = FileManager.default
        let library = manager.homeDirectoryForCurrentUser.appending(path: "Library", directoryHint: .isDirectory)
        for (legacy, current) in [
            (supportDirectory.deletingLastPathComponent().appending(path: "SimBLEBridge"), supportDirectory),
            (library.appending(path: "Logs/SimBLEBridge"), LogFile.directory),
        ] where manager.fileExists(atPath: legacy.path) && !manager.fileExists(atPath: current.path) {
            try? manager.moveItem(at: legacy, to: current)
        }
    }

    static func install() throws {
        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        for name in ["libSimBLELoader.dylib", "libSimBLEShim.dylib", "sim_ble_inject.py"] {
            guard let source = Bundle.main.url(forResource: name, withExtension: nil) else {
                throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: name])
            }
            let contents = try Data(contentsOf: source)
            let destination = supportDirectory.appending(path: name)
            // Atomic replacement: running simulator processes keep the old mapped file instead of crashing.
            if (try? Data(contentsOf: destination)) != contents {
                try contents.write(to: destination, options: .atomic)
            }
        }
        try installLLDBHook()
    }

    private static func installLLDBHook() throws {
        let lldbinit = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".lldbinit")
        let hook = "command script import \"\(supportDirectory.appending(path: "sim_ble_inject.py").path)\""
        let existing = (try? String(contentsOf: lldbinit, encoding: .utf8)) ?? ""
        var lines = existing.components(separatedBy: "\n").filter { !$0.contains("sim_ble_inject.py") }
        if lines.last == "" {
            lines.removeLast()
        }
        lines.append(hook)
        let updated = lines.joined(separator: "\n") + "\n"
        if updated != existing {
            try updated.write(to: lldbinit, atomically: true, encoding: .utf8)
        }
    }
}
