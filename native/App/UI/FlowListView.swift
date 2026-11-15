import AppKit

final class FlowListView: NSScrollView, NSTableViewDataSource, NSTableViewDelegate {
    private let table = NSTableView()
    private var updating = false
    var strings: [String] = [] {
        didSet {
            guard oldValue != strings else { return }
            updating = true
            defer { updating = false }
            let selection = table.selectedRowIndexes
            let origin = contentView.bounds.origin
            table.reloadData()
            table.selectRowIndexes(selection.intersection(IndexSet(integersIn: strings.indices)), byExtendingSelection: false)
            contentView.scroll(to: origin)
            reflectScrolledClipView(contentView)
        }
    }
    func clearSelection() { table.deselectAll(nil) }
    var onSelection: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    var selectedIndexes: IndexSet { table.selectedRowIndexes }
    var allowsMultipleSelection: Bool {
        get { table.allowsMultipleSelection }
        set { table.allowsMultipleSelection = newValue }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        borderType = .noBorder
        hasVerticalScroller = true
        autohidesScrollers = true
        drawsBackground = true
        backgroundColor = Titanium.background
        table.frame = NSRect(origin: .zero, size: frame.size)
        table.autoresizingMask = [.width]
        table.headerView = nil
        table.rowHeight = 27
        table.intercellSpacing = .zero
        table.backgroundColor = Titanium.background
        table.usesAlternatingRowBackgroundColors = true
        table.allowsEmptySelection = true
        table.style = .plain
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("item"))
        column.width = frame.width - 10
        table.addTableColumn(column)
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openRow)
        documentView = table
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    func select(_ index: Int) { table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false); onSelection?() }
    func numberOfRows(in tableView: NSTableView) -> Int { strings.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("flow-value")
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? ValueCell) ?? ValueCell()
        cell.identifier = identifier
        cell.label.stringValue = strings[row]
        cell.toolTip = strings[row]
        return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) { if !updating { onSelection?() } }
    @objc private func openRow() { onDoubleClick?() }
}
