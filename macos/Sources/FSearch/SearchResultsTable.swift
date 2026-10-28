import AppKit
import SwiftUI

/// Native reusable cells draw only the visible portion of a potentially large
/// result list. SwiftUI state changes do not reconstruct every result row.
struct SearchResultsTable: NSViewRepresentable {
    @ObservedObject private var language = LanguageSettings.shared
    @ObservedObject var model: SearchModel
    @ObservedObject private var appearance = AppearanceSettings.shared
    let preview: (SearchHit) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(model: model, preview: preview) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        let table = ResultsTableView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.scrollerStyle = .legacy
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        table.style = .fullWidth
        table.autoresizingMask = [.width]
        table.rowHeight = AppAppearance.rowHeight
        table.usesAutomaticRowHeights = false
        table.intercellSpacing = NSSize(width: 6, height: 0)
        table.usesAlternatingRowBackgroundColors = false
        table.backgroundColor = .clear
        table.headerView = nil
        table.allowsMultipleSelection = false
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        for column in [ResultColumn.name, .kind, .size, .modified] {
            let native = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
            native.title = column.title
            switch column {
            case .name: native.width = 330; native.minWidth = 180
            case .path: native.width = 430; native.minWidth = 220
            case .kind: native.width = 78; native.minWidth = 60
            case .size: native.width = 85; native.minWidth = 65
            case .modified, .created: native.width = 180; native.minWidth = 155
            }
            native.resizingMask = column == .name || column == .path ? [.userResizingMask, .autoresizingMask] : [.userResizingMask]
            if column != .created {
                native.sortDescriptorPrototype = NSSortDescriptor(key: column.rawValue, ascending: true)
                native.headerToolTip = L("对全部结果排序")
            }
            table.addTableColumn(native)
        }
        table.delegate = context.coordinator
        table.dataSource = context.coordinator
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.openSelection)
        table.preview = { [weak coordinator = context.coordinator] in coordinator?.previewSelection() }
        table.copyFile = { [weak coordinator = context.coordinator] in coordinator?.copyFileSelection() }
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.setDraggingSourceOperationMask(.copy, forLocal: true)
        table.menu = context.coordinator.makeMenu()
        context.coordinator.attach(table: table, scroll: scroll)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.preview = preview
        context.coordinator.update()
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) { coordinator.stop() }

    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuItemValidation {
        let model: SearchModel
        var preview: (SearchHit) -> Void
        private weak var table: NSTableView?
        private var rows = SearchRows()
        private var revision = -1
        private var generation = -1
        private var scrollToTopRevision = -1
        private var theme: ThemeColor?
        private var languageCode: String?
        private var changingSelection = false
        private var changingSort = false
        private var scrollObserver: NSObjectProtocol?
        private var viewportWork: DispatchWorkItem?
        private var paintWork: DispatchWorkItem?
        private var pending: [String: Operation] = [:]
        private var repaint = Set<String>()
        private let loader = FilePresentationLoader.shared
        private let filePlaceholder = NSImage(systemSymbolName: "doc", accessibilityDescription: nil)
        private let folderPlaceholder = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)

        init(model: SearchModel, preview: @escaping (SearchHit) -> Void) {
            self.model = model
            self.preview = preview
        }

        func attach(table: NSTableView, scroll: NSScrollView) {
            self.table = table
            scroll.contentView.postsBoundsChangedNotifications = true
            scrollObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, !self.changingSelection else { return }
                    self.scheduleViewport()
                }
            }
        }

        func update() {
            guard let table else { return }
            if languageCode != Localization.languageCode {
                languageCode = Localization.languageCode
                table.menu = makeMenu()
                for column in table.tableColumns {
                    column.title = ResultColumn(rawValue: column.identifier.rawValue)?.title ?? ""
                    column.headerToolTip = L("对全部结果排序")
                }
                var visible = IndexSet()
                table.enumerateAvailableRowViews { _, row in visible.insert(row) }
                table.reloadData(forRowIndexes: visible, columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
            }
            if table.rowHeight != AppAppearance.rowHeight {
                table.rowHeight = AppAppearance.rowHeight
                table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<table.numberOfRows))
                scheduleViewport()
            }
            if theme != AppearanceSettings.savedTheme {
                theme = AppearanceSettings.savedTheme
                table.enumerateAvailableRowViews { row, _ in
                    row.needsDisplay = true
                    for case let cell as ResultCell in row.subviews { cell.updateAppearance(selected: row.isSelected) }
                }
                table.needsDisplay = true
            }
            let descriptors = model.sort.map { [NSSortDescriptor(key: $0.column.rawValue, ascending: $0.ascending)] } ?? []
            if table.sortDescriptors != descriptors {
                changingSort = true
                table.sortDescriptors = descriptors
                changingSort = false
            }
            if revision != model.dataRevision {
                let reset = generation != model.displayGeneration || scrollToTopRevision != model.scrollToTopRevision
                let visible = table.rows(in: table.visibleRect)
                let first = visible.location != NSNotFound && rows.indices.contains(visible.location) ? rows[visible.location].path : nil
                let offset = visible.location == NSNotFound ? 0 : table.visibleRect.minY - table.rect(ofRow: visible.location).minY
                let previousCount = rows.count
                rows = model.hits
                revision = model.dataRevision
                generation = model.displayGeneration
                scrollToTopRevision = model.scrollToTopRevision
                changingSelection = true
                if previousCount == rows.count {
                    // A sort changes the permutation, not the row count.
                    // Refresh allocated cells instead of rebuilding the table.
                    var allocated = IndexSet()
                    table.enumerateAvailableRowViews { _, row in
                        if self.rows.indices.contains(row) { allocated.insert(row) }
                    }
                    table.reloadData(forRowIndexes: allocated, columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
                } else { table.reloadData() }
                if let selected = model.selected, let row = model.row(for: selected) {
                    table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                } else { table.deselectAll(nil) }
                if reset { table.scroll(NSPoint.zero) }
                else if let first, let row = model.row(for: first) {
                    table.scroll(NSPoint(x: table.visibleRect.minX, y: table.rect(ofRow: row).minY + offset))
                }
                changingSelection = false
                scheduleViewport()
            }
            let selectedRow = model.selected.flatMap { model.row(for: $0) } ?? -1
            if table.selectedRow != selectedRow {
                changingSelection = true
                if selectedRow >= 0 { table.selectRowIndexes(IndexSet(integer: selectedRow), byExtendingSelection: false) }
                else { table.deselectAll(nil) }
                changingSelection = false
            }
        }

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            guard rows.indices.contains(row) else { return nil }
            return rows[row].fileURL as NSURL
        }

        func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
            guard let row = rowIndexes.first, rows.indices.contains(row) else { return }
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            model.selected = rows[row].path
        }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let view = FloatingResultRow()
            view.striped = row % 2 == 1
            return view
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard rows.indices.contains(row), let identifier = tableColumn?.identifier,
                  let column = ResultColumn(rawValue: identifier.rawValue) else { return nil }
            let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? ResultCell ?? ResultCell(column: column)
            cell.identifier = identifier
            cell.updateAppearance(selected: tableView.selectedRow == row)
            let hit = rows[row]
            cell.moreAction = { [weak self] button in
                guard let self, let table = self.table, let current = self.model.row(for: hit.path) else { return }
                table.selectRowIndexes(IndexSet(integer: current), byExtendingSelection: false)
                self.makeMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY + 3), in: button)
            }
            switch column {
            case .name:
                cell.textField?.stringValue = hit.name
                cell.subtitle?.stringValue = (hit.path as NSString).deletingLastPathComponent
                cell.imageView?.image = loader.cached(hit)?.icon ?? (hit.isDirectory ? folderPlaceholder : filePlaceholder)
                cell.toolTip = hit.path
                requestPresentation(row)
            case .path:
                cell.textField?.stringValue = hit.path
                cell.toolTip = hit.path
            case .size: cell.textField?.stringValue = hit.sizeText
            case .kind: cell.textField?.stringValue = hit.kindText.replacingOccurrences(of: L(" 文件"), with: "")
            case .modified: cell.textField?.stringValue = hit.modified == .distantPast ? "—" : hit.modified.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits).hour().minute())
            case .created:
                cell.textField?.stringValue = loader.cached(hit)?.createdText ?? hit.createdText
                requestPresentation(row)
            }
            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !changingSelection, let table else { return }
            let value = rows.indices.contains(table.selectedRow) ? rows[table.selectedRow].path : nil
            if model.selected != value { model.selected = value }
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard !changingSort, let descriptor = tableView.sortDescriptors.first, let key = descriptor.key,
                  let column = ResultColumn(rawValue: key) else { return }
            model.setSort(ResultSort(column: column, ascending: descriptor.ascending))
        }

        private func visibleRows(padding: Int = 0) -> Range<Int> {
            guard let table else { return 0..<0 }
            let range = table.rows(in: table.visibleRect)
            guard range.location != NSNotFound else { return 0..<0 }
            let lower = max(0, range.location - padding)
            let upper = min(rows.count, range.location + range.length + padding)
            return lower..<max(lower, upper)
        }

        private func requestPresentation(_ row: Int) {
            guard rows.indices.contains(row), visibleRows(padding: 8).contains(row) else { return }
            let hit = rows[row]
            guard loader.cached(hit) == nil, pending[hit.path] == nil else { return }
            pending[hit.path] = loader.load(hit) { [weak self] _ in
                guard let self else { return }
                self.pending.removeValue(forKey: hit.path)
                self.repaint.insert(hit.path)
                self.schedulePaint()
            }
        }

        private func schedulePaint() {
            guard paintWork == nil else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self, let table = self.table else { return }
                self.paintWork = nil
                let visible = self.visibleRows()
                for path in self.repaint {
                    guard let row = self.model.row(for: path), visible.contains(row), self.rows[row].path == path,
                          let presentation = self.loader.cached(self.rows[row]) else { continue }
                    for (index, column) in table.tableColumns.enumerated() {
                        guard let cell = table.view(atColumn: index, row: row, makeIfNecessary: false) as? ResultCell else { continue }
                        if column.identifier.rawValue == ResultColumn.name.rawValue { cell.imageView?.image = presentation.icon }
                        if column.identifier.rawValue == ResultColumn.created.rawValue { cell.textField?.stringValue = presentation.createdText }
                    }
                }
                self.repaint.removeAll(keepingCapacity: true)
            }
            paintWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: work)
        }

        private func scheduleViewport() {
            viewportWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                let range = self.visibleRows(padding: 8)
                if !range.isEmpty { self.model.loadMoreIfNeeded(lastVisibleRow: range.upperBound - 1) }
                let wanted = Set(range.map { self.rows[$0].path })
                for path in Array(self.pending.keys) where !wanted.contains(path) {
                    self.pending.removeValue(forKey: path)?.cancel()
                }
                for row in range {
                    if self.loader.cached(self.rows[row]) != nil { self.repaint.insert(self.rows[row].path) }
                    else { self.requestPresentation(row) }
                }
                self.schedulePaint()
            }
            viewportWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.035, execute: work)
        }

        private var selected: SearchHit? {
            guard let row = table?.selectedRow, rows.indices.contains(row) else { return nil }
            return rows[row]
        }

        @objc func openSelection() { if let selected { model.open(selected) } }
        @objc func previewSelection() { if let selected { preview(selected) } }
        @objc private func revealSelection() { if let selected { model.reveal(selected) } }
        @objc func copyFileSelection() { if let selected { model.copyFile(selected) } }
        @objc private func copyPathSelection() { if let selected { model.copyPath(selected) } }
        @objc private func terminalSelection() { if let selected { model.openTerminal(selected) } }

        func makeMenu() -> NSMenu {
            let menu = NSMenu()
            for (title, action) in [(L("打开"), #selector(openSelection)), (L("快速查看"), #selector(previewSelection)), (L("在访达中显示"), #selector(revealSelection)), (L("复制文件"), #selector(copyFileSelection)), (L("复制路径"), #selector(copyPathSelection)), (L("在终端中打开"), #selector(terminalSelection))] {
                let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
                item.target = self
                menu.addItem(item)
            }
            return menu
        }

        func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { selected != nil }

        func stop() {
            if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
            viewportWork?.cancel()
            paintWork?.cancel()
            pending.values.forEach { $0.cancel() }
            pending.removeAll()
        }
    }
}

private final class ResultsTableView: NSTableView {
    var preview: (() -> Void)?
    var copyFile: (() -> Void)?

    @objc func copy(_ sender: Any?) { if selectedRow >= 0 { copyFile?() } }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) { return selectedRow >= 0 }
        return super.validateUserInterfaceItem(item)
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49, event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty, selectedRow >= 0 {
            preview?()
        } else { super.keyDown(with: event) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let clicked = row(at: convert(event.locationInWindow, from: nil))
        guard clicked >= 0 else { return nil }
        selectRowIndexes(IndexSet(integer: clicked), byExtendingSelection: false)
        window?.makeFirstResponder(self)
        return super.menu(for: event)
    }
}

private final class ResultCell: NSTableCellView {
    var subtitle: NSTextField?
    var moreAction: ((NSButton) -> Void)?
    private let column: ResultColumn
    private var resultSelected = false
    private var moreButton: NSButton?
    init(column: ResultColumn) {
        self.column = column
        super.init(frame: .zero)
        let text = NSTextField(labelWithString: "")
        text.translatesAutoresizingMaskIntoConstraints = false
        text.maximumNumberOfLines = 1
        text.cell?.usesSingleLineMode = true
        text.lineBreakMode = column == .name || column == .path ? .byTruncatingMiddle : .byTruncatingTail
        text.font = column == .name ? .systemFont(ofSize: 15, weight: .regular) : .systemFont(ofSize: 12)
        text.textColor = column == .name || column == .path ? AppAppearance.nativeText : AppAppearance.nativeMuted
        if column == .size { text.alignment = .right }
        if column == .kind { text.alignment = .center }
        textField = text
        addSubview(text)
        var leading = leadingAnchor
        var inset: CGFloat = 6
        if column == .name {
            let image = NSImageView()
            image.translatesAutoresizingMaskIntoConstraints = false
            image.imageScaling = .scaleProportionallyDown
            imageView = image
            addSubview(image)
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
                image.centerYAnchor.constraint(equalTo: centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 36), image.heightAnchor.constraint(equalToConstant: 36),
            ])
            leading = image.trailingAnchor
            inset = 18
            let detail = NSTextField(labelWithString: "")
            detail.translatesAutoresizingMaskIntoConstraints = false
            detail.font = .systemFont(ofSize: 12)
            detail.textColor = AppAppearance.nativeMuted
            detail.lineBreakMode = .byTruncatingMiddle
            detail.maximumNumberOfLines = 1
            addSubview(detail)
            subtitle = detail
            NSLayoutConstraint.activate([
                detail.leadingAnchor.constraint(equalTo: leading, constant: inset),
                detail.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
                detail.topAnchor.constraint(equalTo: centerYAnchor, constant: 2),
            ])
        }
        var trailing = trailingAnchor
        if column == .modified {
            let button = NSButton(image: NSImage(systemSymbolName: "ellipsis", accessibilityDescription: L("更多文件操作"))!, target: self, action: #selector(showMore(_:)))
            button.translatesAutoresizingMaskIntoConstraints = false
            button.isBordered = false
            button.image?.isTemplate = true
            button.contentTintColor = .labelColor
            button.toolTip = L("更多文件操作")
            button.setAccessibilityLabel(L("更多文件操作"))
            moreButton = button
            addSubview(button)
            NSLayoutConstraint.activate([
                button.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
                button.centerYAnchor.constraint(equalTo: centerYAnchor),
                button.widthAnchor.constraint(equalToConstant: 28), button.heightAnchor.constraint(equalToConstant: 28),
            ])
            trailing = button.leadingAnchor
        }
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: leading, constant: inset),
            text.trailingAnchor.constraint(equalTo: trailing, constant: -6),
            text.centerYAnchor.constraint(equalTo: centerYAnchor, constant: column == .name ? -10 : 0),
        ])
    }
    func updateAppearance(selected: Bool) {
        resultSelected = selected
        let foreground = AppAppearance.nativeOnResultSelection
        let secondary = foreground.withAlphaComponent(0.85)
        textField?.textColor = selected ? (column == .name || column == .path ? foreground : secondary)
            : (column == .name || column == .path ? AppAppearance.nativeText : AppAppearance.nativeMuted)
        subtitle?.textColor = selected ? secondary : AppAppearance.nativeMuted
        moreButton?.contentTintColor = selected ? foreground : .labelColor
        if let moreButton {
            let label = L("更多文件操作")
            if moreButton.toolTip != label {
                moreButton.toolTip = label
                moreButton.setAccessibilityLabel(label)
            }
        }
        needsDisplay = true
    }
    @objc private func showMore(_ sender: NSButton) { moreAction?(sender) }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if column == .kind && !resultSelected {
            AppAppearance.rowAlternate.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 15), xRadius: 12, yRadius: 12).fill()
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private final class FloatingResultRow: NSTableRowView {
    var striped = false
    override var isSelected: Bool {
        didSet {
            for case let cell as ResultCell in subviews { cell.updateAppearance(selected: isSelected) }
        }
    }
    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        (subview as? ResultCell)?.updateAppearance(selected: isSelected)
    }
    override func drawBackground(in dirtyRect: NSRect) {
        if striped {
            AppAppearance.rowAlternate.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 12, yRadius: 12).fill()
        }
    }
    override func drawSelection(in dirtyRect: NSRect) {
        AppAppearance.nativeAccent.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 14, yRadius: 14).fill()
    }
}
