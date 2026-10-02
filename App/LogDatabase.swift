import Foundation
import SimBLEDecoderKit
import SQLite3

/// Keeps log entries across launches in ~/Library/Application Support/SimBLE/logs.sqlite, with the raw
/// bytes and the decoded messages as they were logged, so history does not depend on today's plugins.
/// All access runs on one serial queue.
final class LogDatabase: @unchecked Sendable {
    static let url: URL = Installer.supportDirectory.appending(path: "logs.sqlite")
    /// Rows kept on disk; the oldest go first.
    private static let retention: Int = 1_000_000

    private let queue = DispatchQueue(label: "sim-ble-bridge.database")
    private var database: OpaquePointer?
    private var insertsSinceTrim: Int = 0
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init() {
        try? FileManager.default.createDirectory(at: Installer.supportDirectory, withIntermediateDirectories: true)
        guard sqlite3_open_v2(Self.url.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            database = nil
            return
        }
        execute("""
            PRAGMA journal_mode = WAL;
            CREATE TABLE IF NOT EXISTS entries (
                id INTEGER PRIMARY KEY, date REAL NOT NULL, app_key TEXT, source TEXT NOT NULL, direction TEXT NOT NULL,
                category TEXT NOT NULL, peripheral TEXT NOT NULL, event TEXT NOT NULL, detail TEXT NOT NULL,
                data BLOB, decoder TEXT, messages BLOB, error TEXT
            );
            """)
    }

    var maximumID: Int {
        queue.sync {
            var maximum = -1
            query("SELECT MAX(id) FROM entries") { statement in
                if sqlite3_column_type(statement, 0) != SQLITE_NULL {
                    maximum = Int(sqlite3_column_int64(statement, 0))
                }
            }
            return maximum
        }
    }

    /// The newest `limit` entries, oldest first.
    func recentEntries(limit: Int) -> [LogEntry] {
        queue.sync {
            var entries: [LogEntry] = []
            let sql = """
                SELECT id, date, app_key, source, direction, category, peripheral, event, detail, data, decoder, messages, error
                FROM (SELECT * FROM entries ORDER BY id DESC LIMIT \(limit)) ORDER BY id
                """
            query(sql) { statement in
                if let entry = entry(from: statement) {
                    entries.append(entry)
                }
            }
            return entries
        }
    }

    func insert(_ entries: [LogEntry]) {
        guard !entries.isEmpty else { return }
        queue.async { [self] in
            guard let database else { return }
            var statement: OpaquePointer?
            let sql = "INSERT OR REPLACE INTO entries VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(statement) }
            execute("BEGIN")
            for entry in entries {
                bind(entry, to: statement)
                sqlite3_step(statement)
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
            }
            execute("COMMIT")
            insertsSinceTrim += entries.count
            if insertsSinceTrim >= 10_000 {
                insertsSinceTrim = 0
                execute("DELETE FROM entries WHERE id <= (SELECT MAX(id) FROM entries) - \(Self.retention)")
            }
        }
    }

    func deleteAll() {
        queue.async { [self] in
            execute("DELETE FROM entries; VACUUM;")
        }
    }

    // MARK: SQLite

    private func execute(_ sql: String) {
        guard let database else { return }
        sqlite3_exec(database, sql, nil, nil, nil)
    }

    private func query(_ sql: String, row: (OpaquePointer?) -> Void) {
        guard let database else { return }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            row(statement)
        }
    }

    /// SQLite copies bound text and blobs immediately with this destructor.
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func bind(_ entry: LogEntry, to statement: OpaquePointer?) {
        func text(_ index: Int32, _ value: String?) {
            if let value {
                sqlite3_bind_text(statement, index, value, -1, transient)
            } else {
                sqlite3_bind_null(statement, index)
            }
        }
        func blob(_ index: Int32, _ value: Data?) {
            guard let value, !value.isEmpty else {
                sqlite3_bind_null(statement, index)
                return
            }
            value.withUnsafeBytes { bytes in
                _ = sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(value.count), transient)
            }
        }
        sqlite3_bind_int64(statement, 1, Int64(entry.id))
        sqlite3_bind_double(statement, 2, entry.date.timeIntervalSince1970)
        text(3, entry.appKey)
        text(4, entry.source)
        text(5, entry.direction.rawValue)
        text(6, entry.category.rawValue)
        text(7, entry.peripheral)
        text(8, entry.event)
        text(9, entry.detail)
        blob(10, entry.data)
        text(11, entry.decoder)
        blob(12, entry.messages.isEmpty ? nil : try? encoder.encode(entry.messages))
        text(13, entry.error)
    }

    private func entry(from statement: OpaquePointer?) -> LogEntry? {
        func text(_ index: Int32) -> String? {
            sqlite3_column_text(statement, index).map { String(cString: $0) }
        }
        func blob(_ index: Int32) -> Data? {
            guard let bytes = sqlite3_column_blob(statement, index) else { return nil }
            return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, index)))
        }
        guard let direction = text(4).flatMap(LogEntry.Direction.init(rawValue:)),
              let category = text(5).flatMap(LogEntry.Category.init(rawValue:)) else { return nil }
        return LogEntry(
            id: Int(sqlite3_column_int64(statement, 0)),
            date: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
            appKey: text(2),
            source: text(3) ?? "",
            direction: direction,
            category: category,
            peripheral: text(6) ?? "",
            event: text(7) ?? "",
            detail: text(8) ?? "",
            data: blob(9),
            decoder: text(10),
            messages: blob(11).flatMap { try? decoder.decode([DecodedMessage].self, from: $0) } ?? [],
            error: text(12)
        )
    }
}
