import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct LogView: View {
    let logs: LogStore
    let directory: AppDirectory
    let decoders: DecoderLibrary
    let appFilter: String?
    @Binding var selection: LogEntry.ID?
    @State private var searchText: String = ""
    @State private var hiddenCategories: Set<LogEntry.Category> = []
    @State private var followsTail: Bool = true
    /// Newest first by default.
    @AppStorage("logRowLimit") private var rowLimit: Int = 200
    @State private var sortOrder: [LogSort] = [LogSort(.time, order: .reverse)]
    @State private var isConfirmingClear: Bool = false
    /// Columns the user showed or hid, by column ID; the rest follow their defaults. Order and widths
    /// are saved by the NSTableView itself.
    @AppStorage("logColumnVisibility") private var storedVisibility: Data = Data()
    /// Bumped by Reset Columns to rebuild the table without its saved layout.
    @State private var tableGeneration: Int = 0

    private var tableColumns: [LogTableColumn] {
        LogTableColumn.all(decoderColumns: decoders.tableColumns)
    }

    private var visibilityOverrides: [String: Bool] {
        (try? JSONDecoder().decode([String: Bool].self, from: storedVisibility)) ?? [:]
    }

    private func isVisible(_ column: LogTableColumn) -> Bool {
        visibilityOverrides[column.id] ?? column.isVisibleByDefault
    }

    private func setVisible(_ column: LogTableColumn, _ isVisible: Bool) {
        var overrides = visibilityOverrides
        overrides[column.id] = isVisible
        storedVisibility = (try? JSONEncoder().encode(overrides)) ?? Data()
    }

    private func visibilityBinding(_ column: LogTableColumn) -> Binding<Bool> {
        Binding(get: { isVisible(column) }, set: { setVisible(column, $0) })
    }

    /// The newest `rowLimit` matching entries, in the chosen order. Filtering covers the whole history;
    /// only the table is limited, which keeps sorting and scrolling light.
    private func visibleEntries(from filtered: [LogEntry]) -> [LogEntry] {
        var start = max(0, filtered.count - rowLimit)
        // A selected entry stays listed while newer ones arrive, instead of dropping out under the reader.
        if let selection, let index = filtered.lastIndex(where: { $0.id == selection }), index < start {
            start = index
        }
        let newest = Array(filtered[start...])
        // Entries arrive in time order, so sorting by time is just the order or its reverse.
        if let first = sortOrder.first, first.field == .time {
            return first.order == .forward ? newest : Array(newest.reversed())
        }
        return newest.sorted { lhs, rhs in
            for comparator in sortOrder {
                let result = comparator.compare(lhs, rhs)
                if result != .orderedSame {
                    return result == .orderedAscending
                }
            }
            return lhs.id < rhs.id
        }
    }

    private func subtitle(showing shown: Int, matching: Int) -> String {
        let scope = appFilter == nil ? "" : " · \(filterName)"
        return shown < matching ? "Newest \(shown) of \(matching) entries\(scope)" : "\(matching) entries\(scope)"
    }

    private var filteredEntries: [LogEntry] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        return logs.entries.filter { entry in
            if hiddenCategories.contains(entry.category) {
                return false
            }
            if let appFilter, entry.appKey != appFilter {
                return false
            }
            guard !query.isEmpty else { return true }
            return entry.event.lowercased().contains(query)
                || entry.peripheral.lowercased().contains(query)
                || entry.source.lowercased().contains(query)
                || entry.summary.lowercased().contains(query)
        }
    }

    var body: some View {
        let matching = filteredEntries
        let entries = visibleEntries(from: matching)
        LogTableView(
            entries: entries,
            columns: tableColumns,
            isVisible: isVisible,
            setVisible: setVisible,
            sortOrder: $sortOrder,
            selection: $selection,
            followsNewest: followsTail && sortOrder.first?.field == .time
        )
        .id(tableGeneration)
        .overlay {
            if entries.isEmpty {
                ContentUnavailableView(emptyTitle, systemImage: "text.page.slash", description: Text(emptyDescription))
            }
        }
        .searchable(text: $searchText, placement: .toolbar, prompt: "Filter logs")
        .navigationTitle("SimBLE")
        .navigationSubtitle(subtitle(showing: entries.count, matching: matching.count))
        .toolbar {
            ToolbarItemGroup {
                Menu {
                    ForEach(LogEntry.Category.allCases) { category in
                        Toggle(category.rawValue, isOn: Binding(
                            get: { !hiddenCategories.contains(category) },
                            set: { isShown in
                                if isShown {
                                    hiddenCategories.remove(category)
                                } else {
                                    hiddenCategories.insert(category)
                                }
                            }
                        ))
                    }
                } label: {
                    Label("Categories", systemImage: "line.3.horizontal.decrease.circle")
                }
                .help("Show or hide log categories")
                Menu {
                    ForEach(tableColumns.filter { !$0.id.hasPrefix("decoder.") }, id: \.id) { column in
                        Toggle(column.title, isOn: visibilityBinding(column))
                    }
                    ForEach(decoders.decoders) { decoder in
                        Section(decoder.name) {
                            ForEach(tableColumns.filter { $0.id.hasPrefix("decoder.\(decoder.name).") }, id: \.id) { column in
                                Toggle(column.title, isOn: visibilityBinding(column))
                            }
                        }
                    }
                    Divider()
                    Button("Reset Columns") {
                        storedVisibility = Data()
                        UserDefaults.standard.removeObject(forKey: "NSTableView Columns v2 \(LogTableView.autosaveName)")
                        UserDefaults.standard.removeObject(forKey: "NSTableView Columns \(LogTableView.autosaveName)")
                        tableGeneration += 1
                    }
                } label: {
                    Label("Columns", systemImage: "tablecells")
                }
                .help("Choose columns (also by right-clicking the header); drag a header to reorder")
                Picker("Rows", selection: $rowLimit) {
                    ForEach([50, 100, 200, 500, 1000], id: \.self) { limit in
                        Text("\(limit) rows").tag(limit)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
                .help("How many of the newest matching entries the table shows")
                Toggle(isOn: $followsTail) {
                    Label("Follow", systemImage: "arrow.down.to.line")
                }
                .disabled(sortOrder.first?.field != .time)
                .help("Keep the newest entry in view while sorted by time; scroll away or select an older row to pause")
                Toggle(isOn: Binding(get: { logs.isPaused }, set: { logs.isPaused = $0 })) {
                    Label("Pause", systemImage: "pause")
                }
                .help("Freeze the list; entries are still collected")
                Button {
                    export(matching)
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .help("Save every entry matching the current filters as text, not only the rows shown")
                Button {
                    isConfirmingClear = true
                } label: {
                    Label("Clear", systemImage: "trash")
                }
                .confirmationDialog("Delete all log entries?", isPresented: $isConfirmingClear) {
                    Button("Delete All Entries", role: .destructive) {
                        selection = nil
                        logs.clear()
                    }
                } message: {
                    Text("This also deletes the history kept across launches. It cannot be undone.")
                }
                .help("Delete all entries, including the history kept across launches")
            }
        }
    }

    private var filterName: String {
        guard let appFilter else { return "All Apps" }
        let parts = appFilter.split(separator: "|", maxSplits: 1).map(String.init)
        return parts.count == 2 ? directory.label(bundleID: parts[1], udid: parts[0]) : appFilter
    }

    private var emptyTitle: String {
        logs.entries.isEmpty ? "No Bluetooth activity yet" : "No matching entries"
    }

    private var emptyDescription: String {
        if logs.entries.isEmpty {
            return "Switch on an app in the sidebar and launch it; its Bluetooth traffic appears here."
        }
        if appFilter != nil {
            return "\(filterName) has no entries. Select All Apps to see everything, or check that its switch is on and relaunch it."
        }
        return "Clear the search text or show more categories."
    }

    private func export(_ entries: [LogEntry]) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate, .withTime])
        panel.nameFieldStringValue = "SimBLE \(stamp).log"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = entries.map(\.exportText).joined(separator: "\n")
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}

struct EntryInspector: View {
    enum DataView: String, CaseIterable, Identifiable {
        case raw = "Raw"
        case decoded = "Decoded"
        case both = "Both"

        var id: String { rawValue }
    }

    let entry: LogEntry?
    @AppStorage("inspectorDataView") private var dataView: DataView = .both

    var body: some View {
        if let entry {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    field("Time", LogEntry.timeFormatter.string(from: entry.date))
                    field("App", entry.source)
                    field("Direction", entry.direction == .toDevice ? "App → device" : entry.direction == .fromDevice ? "Device → app" : "Bridge")
                    field("Category", entry.category.rawValue)
                    field("Event", entry.event)
                    if !entry.peripheral.isEmpty {
                        field("Device", entry.peripheral)
                    }
                    if !entry.detail.isEmpty {
                        field("Detail", entry.detail)
                    }
                    if let error = entry.error {
                        field("Error", error)
                            .foregroundStyle(.red)
                    }
                    if let data = entry.data {
                        if entry.decoded != nil {
                            Picker("Data view", selection: $dataView) {
                                ForEach(DataView.allCases) { view in
                                    Text(view.rawValue).tag(view)
                                }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                        }
                        if dataView != .decoded || entry.decoded == nil {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text("Raw · \(data.count) bytes")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Button("Copy Hex") {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(Hex.string(data), forType: .string)
                                    }
                                    .controlSize(.small)
                                }
                                Text(Hex.string(data))
                                    .font(.system(size: 11, design: .monospaced))
                                    .textSelection(.enabled)
                            }
                        }
                        if dataView != .raw, let decoded = entry.decoded {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Decoded · \(entry.decoder ?? "")")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(decoded)
                                    .font(.system(size: 11, design: .monospaced))
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
        } else {
            Text("Select a log entry")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func field(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .textSelection(.enabled)
        }
    }
}

/// Sorting for the log table. Values compare as people read them: numbers numerically, "0x…" values as hex,
/// and empty cells last in either direction.
struct LogSort: SortComparator, Hashable {
    enum Field: Hashable {
        case time, app, direction, category, device, event, detail
        case decoder(TableDecoderColumn)
    }

    let field: Field
    var order: SortOrder = .forward

    init(_ field: Field, order: SortOrder = .forward) {
        self.field = field
        self.order = order
    }

    func compare(_ lhs: LogEntry, _ rhs: LogEntry) -> ComparisonResult {
        let result: ComparisonResult
        if field == .time {
            result = lhs.id == rhs.id ? .orderedSame : lhs.id < rhs.id ? .orderedAscending : .orderedDescending
        } else {
            let left = text(lhs)
            let right = text(rhs)
            if left.isEmpty != right.isEmpty {
                return left.isEmpty ? .orderedDescending : .orderedAscending
            }
            if let leftHex = Self.hexValue(left), let rightHex = Self.hexValue(right), leftHex != rightHex {
                result = leftHex < rightHex ? .orderedAscending : .orderedDescending
            } else {
                result = left.localizedStandardCompare(right)
            }
        }
        guard order == .reverse else { return result }
        switch result {
        case .orderedAscending: return .orderedDescending
        case .orderedDescending: return .orderedAscending
        case .orderedSame: return .orderedSame
        }
    }

    private func text(_ entry: LogEntry) -> String {
        switch field {
        case .time: ""
        case .app: entry.source
        case .direction: entry.direction.symbol
        case .category: entry.category.rawValue
        case .device: entry.peripheral
        case .event: entry.event
        case .detail: entry.summary
        case let .decoder(column): entry.value(for: column)
        }
    }

    /// The leading "0x…" number, e.g. 0x2A from "0x2A Start".
    private static func hexValue(_ text: String) -> UInt64? {
        guard text.hasPrefix("0x") || text.hasPrefix("0X") else { return nil }
        return UInt64(text.dropFirst(2).prefix { $0.isHexDigit }, radix: 16)
    }
}
