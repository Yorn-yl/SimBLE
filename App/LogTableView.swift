import AppKit
import SwiftUI

/// A log table column: the built-in ones and those declared by decoder plugins.
struct LogTableColumn: Hashable {
    let id: String
    let title: String
    let sortField: LogSort.Field
    let isVisibleByDefault: Bool
    let width: CGFloat
    let minWidth: CGFloat
    let maxWidth: CGFloat

    static func all(decoderColumns: [TableDecoderColumn]) -> [LogTableColumn] {
        [
            LogTableColumn(id: "time", title: "Time", sortField: .time, isVisibleByDefault: true, width: 96, minWidth: 84, maxWidth: 120),
            LogTableColumn(id: "app", title: "App", sortField: .app, isVisibleByDefault: false, width: 150, minWidth: 60, maxWidth: 400),
            LogTableColumn(id: "direction", title: "↕", sortField: .direction, isVisibleByDefault: true, width: 26, minWidth: 22, maxWidth: 40),
            LogTableColumn(id: "category", title: "Category", sortField: .category, isVisibleByDefault: false, width: 90, minWidth: 60, maxWidth: 160),
            LogTableColumn(id: "device", title: "Device", sortField: .device, isVisibleByDefault: false, width: 160, minWidth: 60, maxWidth: 400),
            LogTableColumn(id: "event", title: "Event", sortField: .event, isVisibleByDefault: true, width: 150, minWidth: 80, maxWidth: 300),
            LogTableColumn(id: "detail", title: "Detail", sortField: .detail, isVisibleByDefault: false, width: 420, minWidth: 120, maxWidth: 4000),
        ] + decoderColumns.map { column in
            LogTableColumn(id: column.id, title: column.title, sortField: .decoder(column),
                           isVisibleByDefault: column.column.isVisibleByDefault, width: 110, minWidth: 30, maxWidth: 600)
        }
    }

    func text(for entry: LogEntry) -> String {
        switch sortField {
        case .time: LogEntry.timeFormatter.string(from: entry.date)
        case .app: entry.source
        case .direction: entry.direction.symbol
        case .category: entry.category.rawValue
        case .device: entry.peripheral
        case .event: entry.event
        case .detail: entry.summary
        case let .decoder(column): entry.value(for: column)
        }
    }

    func color(for entry: LogEntry) -> NSColor {
        switch sortField {
        case .time, .category: .secondaryLabelColor
        case .direction: entry.direction == .toDevice ? .systemBlue : entry.direction == .fromDevice ? .systemGreen : .secondaryLabelColor
        case .event, .detail: entry.error == nil ? .labelColor : .systemRed
        case let .decoder(column): entry.message?.isError == true && entry.decoder == column.decoder ? .systemRed : .labelColor
        default: .labelColor
        }
    }

    var font: NSFont {
        switch sortField {
        case .time: .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        case .detail: .monospacedSystemFont(ofSize: NSFont.systemFontSize - 1, weight: .regular)
        default: .systemFont(ofSize: NSFont.systemFontSize)
        }
    }
}

/// The log list as a plain NSTableView. SwiftUI's Table creates a hosting view per cell for every row
/// that moves and each one registers with the window, so a re-sort costs time quadratic in the cells
/// (about a second for 200 rows); reusable text cells keep a re-sort to a reload of the visible rows.
struct LogTableView: NSViewRepresentable {
    static let autosaveName = "SimBLELogTable"

    let entries: [LogEntry]
    let columns: [LogTableColumn]
    let isVisible: (LogTableColumn) -> Bool
    let setVisible: (LogTableColumn, Bool) -> Void
    @Binding var sortOrder: [LogSort]
    @Binding var selection: LogEntry.ID?
    /// Keeps the newest entry in view (the top row when sorted newest first, otherwise the last one)
    /// while the reader is at that edge.
    let followsNewest: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let tableView = NSTableView()
        tableView.style = .fullWidth
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowHeight = 22
        tableView.intercellSpacing = NSSize(width: 8, height: 0)
        tableView.allowsColumnReordering = true
        tableView.allowsColumnResizing = true
        tableView.allowsMultipleSelection = false
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.dataSource = context.coordinator
        tableView.delegate = context.coordinator
        let headerMenu = NSMenu()
        headerMenu.delegate = context.coordinator
        tableView.headerView?.menu = headerMenu

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        context.coordinator.tableView = tableView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.update(with: self)
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        var parent: LogTableView
        weak var tableView: NSTableView?
        private var entries: [LogEntry] = []
        private var columnsByID: [String: LogTableColumn] = [:]
        private var isSyncing: Bool = false
        private static let cellIdentifier = NSUserInterfaceItemIdentifier("cell")

        init(_ parent: LogTableView) {
            self.parent = parent
        }

        func update(with parent: LogTableView) {
            self.parent = parent
            guard let tableView else { return }
            isSyncing = true
            defer { isSyncing = false }
            syncColumns(in: tableView)
            syncSortIndicator(in: tableView)
            reload(tableView, with: parent.entries)
        }

        private func syncColumns(in tableView: NSTableView) {
            let desired = Dictionary(uniqueKeysWithValues: parent.columns.map { ($0.id, $0) })
            guard desired != columnsByID else {
                applyVisibility(in: tableView)
                return
            }
            let wanted: Set<String> = Set(desired.keys)
            for tableColumn in tableView.tableColumns where !wanted.contains(tableColumn.identifier.rawValue) {
                tableView.removeTableColumn(tableColumn)
            }
            for tableColumn in tableView.tableColumns {
                tableColumn.title = desired[tableColumn.identifier.rawValue]?.title ?? tableColumn.title
            }
            let existing = Set(tableView.tableColumns.map(\.identifier.rawValue))
            for column in parent.columns where !existing.contains(column.id) {
                let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.id))
                tableColumn.title = column.title
                tableColumn.width = column.width
                tableColumn.minWidth = column.minWidth
                tableColumn.maxWidth = column.maxWidth
                tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: column.id, ascending: column.sortField != .time)
                tableView.addTableColumn(tableColumn)
            }
            columnsByID = desired
            // Setting the name restores the saved order and widths of the columns present now.
            tableView.autosaveName = nil
            tableView.autosaveName = LogTableView.autosaveName
            tableView.autosaveTableColumns = true
            applyVisibility(in: tableView)
        }

        private func applyVisibility(in tableView: NSTableView) {
            for tableColumn in tableView.tableColumns {
                guard let column = columnsByID[tableColumn.identifier.rawValue] else { continue }
                let isHidden = !parent.isVisible(column)
                if tableColumn.isHidden != isHidden {
                    tableColumn.isHidden = isHidden
                }
            }
        }

        private func syncSortIndicator(in tableView: NSTableView) {
            guard let sort = parent.sortOrder.first,
                  let column = parent.columns.first(where: { $0.sortField == sort.field }) else { return }
            let descriptor = NSSortDescriptor(key: column.id, ascending: sort.order == .forward)
            if tableView.sortDescriptors.first != descriptor {
                tableView.sortDescriptors = [descriptor]
            }
        }

        /// Reloads while keeping the reader's place. Following only happens while the newest edge is in view,
        /// so scrolling away or selecting a row further down stops it until the reader scrolls back.
        private func reload(_ tableView: NSTableView, with newEntries: [LogEntry]) {
            let isNewestFirst = parent.sortOrder.first?.order == .reverse
            let visible = tableView.rows(in: tableView.visibleRect)
            let isAtNewestEdge = entries.isEmpty || visible.length == 0
                || (isNewestFirst ? visible.location == 0 : NSMaxRange(visible) >= entries.count)
            let follows = parent.followsNewest && isAtNewestEdge

            // A selection change alone needs no reload, which would also move the rows.
            if newEntries.count == entries.count, zip(newEntries, entries).allSatisfy({ $0.id == $1.id }) {
                syncSelection(in: tableView)
                return
            }

            let anchor: (id: LogEntry.ID, minY: CGFloat)? = {
                guard !follows, visible.length > 0, visible.location < entries.count else { return nil }
                return (entries[visible.location].id, tableView.rect(ofRow: visible.location).minY)
            }()
            entries = newEntries
            tableView.reloadData()
            syncSelection(in: tableView)

            if follows, !entries.isEmpty {
                tableView.scrollRowToVisible(isNewestFirst ? 0 : entries.count - 1)
            } else if let anchor, let row = entries.firstIndex(where: { $0.id == anchor.id }),
                      let clipView = tableView.enclosingScrollView?.contentView {
                // Shift by how far the anchor row moved, so content insets do not matter.
                var origin = clipView.bounds.origin
                origin.y += tableView.rect(ofRow: row).minY - anchor.minY
                clipView.scroll(to: origin)
                tableView.enclosingScrollView?.reflectScrolledClipView(clipView)
            }
        }

        private func syncSelection(in tableView: NSTableView) {
            if let selected = parent.selection, let row = entries.firstIndex(where: { $0.id == selected }) {
                if tableView.selectedRow != row {
                    tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                }
            } else if tableView.selectedRow != -1 {
                tableView.deselectAll(nil)
            }
        }

        // MARK: Data source and delegate

        func numberOfRows(in tableView: NSTableView) -> Int {
            entries.count
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn, let column = columnsByID[tableColumn.identifier.rawValue], row < entries.count else { return nil }
            let cell = tableView.makeView(withIdentifier: Self.cellIdentifier, owner: nil) as? NSTableCellView ?? makeCell()
            let entry = entries[row]
            cell.textField?.stringValue = column.text(for: entry)
            cell.textField?.textColor = column.color(for: entry)
            cell.textField?.font = column.font
            cell.textField?.alignment = column.sortField == .direction ? .center : .natural
            return cell
        }

        private func makeCell() -> NSTableCellView {
            let cell = NSTableCellView()
            cell.identifier = Self.cellIdentifier
            let label = NSTextField(labelWithString: "")
            label.lineBreakMode = .byTruncatingTail
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            cell.textField = label
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isSyncing, let tableView else { return }
            let row = tableView.selectedRow
            parent.selection = row >= 0 && row < entries.count ? entries[row].id : nil
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard !isSyncing, let descriptor = tableView.sortDescriptors.first, let key = descriptor.key,
                  let column = columnsByID[key] else { return }
            parent.sortOrder = [LogSort(column.sortField, order: descriptor.ascending ? .forward : .reverse)]
        }

        // MARK: Header menu

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            for column in parent.columns {
                let item = NSMenuItem(title: column.title, action: #selector(toggleColumn(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = column.id
                item.state = parent.isVisible(column) ? .on : .off
                menu.addItem(item)
            }
        }

        @objc private func toggleColumn(_ item: NSMenuItem) {
            guard let id = item.representedObject as? String, let column = columnsByID[id] else { return }
            parent.setVisible(column, !parent.isVisible(column))
        }
    }
}
