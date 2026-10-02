import Foundation
import Observation
import SimBLEDecoderKit

struct LogEntry: Identifiable, Sendable {
    enum Direction: String, Sendable {
        case toDevice
        case fromDevice
        case bridge

        var symbol: String {
            switch self {
            case .toDevice: "→"
            case .fromDevice: "←"
            case .bridge: "•"
            }
        }
    }

    enum Category: String, CaseIterable, Identifiable, Sendable {
        case app = "App"
        case scan = "Scan"
        case advertisement = "Advertisement"
        case connection = "Connection"
        case gatt = "GATT"
        case data = "Data"

        var id: String { rawValue }
    }

    let id: Int
    let date: Date
    /// `udid|bundleId` of the simulator app, nil for bridge-wide events.
    let appKey: String?
    let source: String
    let direction: Direction
    let category: Category
    let peripheral: String
    let event: String
    let detail: String
    let data: Data?
    /// Name of the plugin that decoded `messages`.
    let decoder: String?
    /// Messages this chunk completed; usually one, empty while a message is still arriving.
    let messages: [DecodedMessage]
    let error: String?

    /// The message the table columns show.
    var message: DecodedMessage? { messages.first }

    /// The decoded fields as aligned text, one block per message.
    var decoded: String? {
        guard !messages.isEmpty else { return nil }
        let width: Int = (messages.flatMap(\.fields).map(\.name.count).max() ?? 0) + 2
        return messages.map { message in
            message.fields.map { field in
                let lines = field.value.split(separator: "\n", omittingEmptySubsequences: false)
                let indent = String(repeating: " ", count: width)
                return field.name.padding(toLength: width, withPad: " ", startingAt: 0) + lines.joined(separator: "\n" + indent)
            }.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    func value(for column: TableDecoderColumn) -> String {
        guard decoder == column.decoder else { return "" }
        return message?.columns[column.column.id] ?? ""
    }

    var summary: String {
        var parts: [String] = []
        if !detail.isEmpty {
            parts.append(detail)
        }
        if let data {
            parts.append(Hex.preview(data))
        }
        if let error {
            parts.append("error: \(error)")
        }
        return parts.joined(separator: "  ")
    }

    var exportLine: String {
        "\(LogEntry.timeFormatter.string(from: date))  \(source)  \(direction.symbol) \(category.rawValue)  \(peripheral)  \(event)  \(summary)"
    }

    /// The export line, the full raw bytes when the summary truncates them, and the decoded fields.
    var exportText: String {
        var text = exportLine
        if let data, data.count > 24 {
            text += "\n    raw: " + Hex.string(data)
        }
        if let decoded {
            text += "\n" + decoded.split(separator: "\n", omittingEmptySubsequences: false).map { "    " + $0 }.joined(separator: "\n")
        }
        return text
    }

    static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
}

enum Hex {
    static func string(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    static func preview(_ data: Data, limit: Int = 24) -> String {
        let shown = string(data.prefix(limit))
        return data.count > limit ? "\(shown) … (\(data.count) bytes)" : "\(shown) (\(data.count) bytes)"
    }

}

/// Collects entries from session queues and hands them to the main actor in batches,
/// so a notification stream does not trigger a UI update per packet.
final class PendingLogEntries: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [LogEntry] = []
    private var nextID: Int = 0
    private var flushScheduled: Bool = false

    /// Returns true when the caller must schedule a flush.
    func add(_ make: (Int) -> LogEntry) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        entries.append(make(nextID))
        nextID += 1
        if flushScheduled {
            return false
        }
        flushScheduled = true
        return true
    }

    /// Continues the IDs of entries stored by earlier launches.
    func startIDs(after lastID: Int) {
        lock.lock()
        defer { lock.unlock() }
        nextID = max(nextID, lastID + 1)
    }

    func take() -> [LogEntry] {
        lock.lock()
        defer { lock.unlock() }
        let taken = entries
        entries.removeAll(keepingCapacity: true)
        flushScheduled = false
        return taken
    }
}

@MainActor
@Observable
final class LogStore {
    private(set) var entries: [LogEntry] = []
    var isPaused: Bool = false {
        didSet {
            if !isPaused {
                flush()
            }
        }
    }

    @ObservationIgnored private var held: [LogEntry] = []
    @ObservationIgnored private let pending = PendingLogEntries()
    @ObservationIgnored private let file = LogFile()
    @ObservationIgnored private let database = LogDatabase()
    private let capacity: Int = 200_000

    init() {
        // IDs continue from the stored history before any session can log.
        pending.startIDs(after: database.maximumID)
        Task { [database, capacity] in
            let history = await Task.detached { database.recentEntries(limit: capacity) }.value
            // Entries logged while the history loaded are newer; they stay after it.
            entries = history + entries
        }
    }

    nonisolated func append(
        appKey: String?,
        source: String,
        _ direction: LogEntry.Direction,
        _ category: LogEntry.Category,
        _ event: String,
        peripheral: String = "",
        detail: String = "",
        data: Data? = nil,
        decoder: String? = nil,
        messages: [DecodedMessage] = [],
        error: String? = nil
    ) {
        let date = Date()
        let needsFlush = pending.add { id in
            LogEntry(id: id, date: date, appKey: appKey, source: source, direction: direction, category: category,
                     peripheral: peripheral, event: event, detail: detail, data: data, decoder: decoder, messages: messages, error: error)
        }
        if needsFlush {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                MainActor.assumeIsolated {
                    self?.flush()
                }
            }
        }
    }

    /// Also deletes the stored history.
    func clear() {
        _ = pending.take()
        held.removeAll()
        entries.removeAll()
        database.deleteAll()
    }

    private func flush() {
        let batch = pending.take()
        file.write(batch)
        database.insert(batch)
        held.append(contentsOf: batch)
        guard !isPaused, !held.isEmpty else { return }
        entries.append(contentsOf: held)
        held.removeAll(keepingCapacity: true)
        // Trimming in chunks keeps removeFirst from running on every batch.
        if entries.count > capacity + capacity / 10 {
            entries.removeFirst(entries.count - capacity)
        }
    }
}

/// Appends every entry as text to ~/Library/Logs/SimBLE/bridge.log, across launches, including entries
/// collected while the list is paused. Past 50 MB the file moves to bridge.1.log and a new one starts.
final class LogFile: @unchecked Sendable {
    static let directory: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/SimBLE", directoryHint: .isDirectory)
    private static let rotationSize: UInt64 = 50 * 1024 * 1024

    private let queue = DispatchQueue(label: "sim-ble-bridge.log-file")
    private let current = LogFile.directory.appending(path: "bridge.log")
    private var handle: FileHandle?

    init() {
        let manager = FileManager.default
        try? manager.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        // The per-launch file of earlier versions.
        try? manager.removeItem(at: Self.directory.appending(path: "bridge.previous.log"))
        handle = open()
    }

    func write(_ entries: [LogEntry]) {
        guard !entries.isEmpty else { return }
        queue.async { [self] in
            let text = entries.map { $0.exportText + "\n" }.joined()
            handle?.write(Data(text.utf8))
            if let size = try? handle?.offset(), size > Self.rotationSize {
                try? handle?.close()
                let rotated = Self.directory.appending(path: "bridge.1.log")
                try? FileManager.default.removeItem(at: rotated)
                try? FileManager.default.moveItem(at: current, to: rotated)
                handle = open()
            }
        }
    }

    private func open() -> FileHandle? {
        if !FileManager.default.fileExists(atPath: current.path) {
            FileManager.default.createFile(atPath: current.path, contents: nil)
        }
        let handle = try? FileHandle(forWritingTo: current)
        _ = try? handle?.seekToEnd()
        return handle
    }
}
