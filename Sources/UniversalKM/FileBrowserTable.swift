import AppKit
import SwiftUI
import UniformTypeIdentifiers
import UniversalKMCore

/// The list of the file window (add-android-file-browser design D4): an NSTableView, because it gives
/// file promises for drags into Finder, drops from Finder, multiple selection, in-place rename and keys.
struct FileBrowserTable: NSViewRepresentable {
    @ObservedObject var model: FileBrowserModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = FileTableView()
        table.coordinator = context.coordinator
        table.style = .inset
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.allowsColumnReordering = false
        table.rowHeight = 22
        for (id, title, width) in [("name", String(localized: "Name"), 320.0),
                                   ("size", String(localized: "Size"), 90.0),
                                   ("modified", String(localized: "Date Modified"), 170.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            column.minWidth = id == "name" ? 120 : 60
            column.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: true)
            if id == "size" { column.headerCell.alignment = .right }
            table.addTableColumn(column)
        }
        table.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.doubleClicked(_:))
        table.registerForDraggedTypes([.fileURL])
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        let menu = NSMenu()
        menu.delegate = context.coordinator
        table.menu = menu
        context.coordinator.table = table

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        return scroll
    }

    func updateNSView(_ view: NSScrollView, context: Context) {
        context.coordinator.show(model.entries)
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate, NSTextFieldDelegate {
        let model: FileBrowserModel
        weak var table: NSTableView?
        private var entries: [DeviceFileEntry] = []
        private var icons: [String: NSImage] = [:]
        private let promises: PromiseDelegate
        private static let sizes: ByteCountFormatter = {
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            return formatter
        }()
        private static let dates: DateFormatter = {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            formatter.doesRelativeDateFormatting = true
            return formatter
        }()

        init(model: FileBrowserModel) {
            self.model = model
            promises = PromiseDelegate(name: { ($0 as? PromisedFile)?.entry.name ?? "file" }) { [model] info, url, done in
                guard let file = info as? PromisedFile else { return done(ADBFileError.protocolError("no file")) }
                model.download(file.entry, in: file.folder, to: url, completion: done)
            }
        }

        /// New entries: the selection is kept by name, plus the names the model asked to select.
        func show(_ new: [DeviceFileEntry]) {
            guard let table, new != entries else { return }
            var keep = Set(table.selectedRowIndexes.compactMap { $0 < entries.count ? entries[$0].name : nil })
            keep.formUnion(model.pendingSelection)
            entries = new
            table.reloadData()
            let rows = IndexSet(entries.indices.filter { keep.contains(entries[$0].name) })
            table.selectRowIndexes(rows, byExtendingSelection: false)
            if !model.pendingSelection.isEmpty, let first = rows.first {
                table.scrollRowToVisible(first)
                model.pendingSelection.subtract(entries.map(\.name))
            }
            updateSelection()
        }

        var selected: [DeviceFileEntry] {
            table?.selectedRowIndexes.compactMap { $0 < entries.count ? entries[$0] : nil } ?? []
        }

        private func updateSelection() {
            let names = Set(selected.map(\.name))
            if model.selection != names { model.selection = names }
        }

        // MARK: Data

        func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

        func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
            guard let column, row < entries.count else { return nil }
            let entry = entries[row]
            let id = column.identifier
            let cell = tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView ?? makeCell(id)
            switch id.rawValue {
            case "name":
                cell.textField?.stringValue = entry.name
                cell.imageView?.image = icon(entry)
            case "size":
                cell.textField?.stringValue = entry.isDirectory ? "--" : Self.sizes.string(fromByteCount: Int64(clamping: entry.size))
            default:
                cell.textField?.stringValue = Self.dates.string(from: entry.modified)
            }
            return cell
        }

        private func makeCell(_ id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
            let cell = NSTableCellView()
            cell.identifier = id
            let text = NSTextField(labelWithString: "")
            text.lineBreakMode = .byTruncatingMiddle
            text.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(text)
            cell.textField = text
            if id.rawValue == "name" {
                let image = NSImageView()
                image.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(image)
                cell.imageView = image
                text.isEditable = true
                text.delegate = self
                NSLayoutConstraint.activate([
                    image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                    image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    image.widthAnchor.constraint(equalToConstant: 16),
                    image.heightAnchor.constraint(equalToConstant: 16),
                    text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
                ])
            } else {
                text.textColor = .secondaryLabelColor
                if id.rawValue == "size" { text.alignment = .right }
                text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2).isActive = true
            }
            NSLayoutConstraint.activate([
                text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }

        private func icon(_ entry: DeviceFileEntry) -> NSImage {
            let ext = entry.isDirectory ? "/" : (entry.name as NSString).pathExtension.lowercased()
            if let icon = icons[ext] { return icon }
            let type = entry.isDirectory ? UTType.folder : (UTType(filenameExtension: ext) ?? .data)
            let icon = NSWorkspace.shared.icon(for: type)
            icons[ext] = icon
            return icon
        }

        // MARK: Selection, sorting, opening

        func tableViewSelectionDidChange(_ notification: Notification) {
            updateSelection()
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard let descriptor = tableView.sortDescriptors.first, let key = descriptor.key.flatMap(DeviceFileEntry.SortKey.init) else { return }
            model.sortKey = key
            model.ascending = descriptor.ascending
        }

        @objc func doubleClicked(_ sender: NSTableView) {
            let row = sender.clickedRow
            guard row >= 0, row < entries.count else { return }
            model.open(entries[row])
        }

        func openSelected() {
            if let entry = selected.first, selected.count == 1 { model.open(entry) }
        }

        // MARK: Rename (in place)

        func beginRename() {
            guard let table, selected.count == 1, let row = table.selectedRowIndexes.first, model.isConnected else { return }
            table.editColumn(0, row: row, with: nil, select: true)
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField, let table else { return }
            let row = table.row(for: field)
            guard row >= 0, row < entries.count else { return }
            let entry = entries[row]
            let name = field.stringValue
            field.stringValue = entry.name
            model.rename(entry, to: name)
        }

        func control(_ control: NSControl, textShouldBeginEditing fieldEditor: NSText) -> Bool { model.isConnected }

        // MARK: Drag into Finder (file promises)

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            guard model.isConnected, row < entries.count else { return nil }
            let entry = entries[row]
            let type = entry.isDirectory ? UTType.folder : (UTType(filenameExtension: (entry.name as NSString).pathExtension) ?? .data)
            let provider = NSFilePromiseProvider(fileType: type.identifier, delegate: promises)
            provider.userInfo = PromisedFile(entry: entry, folder: model.path)
            return provider
        }

        // MARK: Drop from Finder

        func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                       proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
            guard model.isConnected, info.draggingSource as? NSTableView !== tableView, !Self.fileURLs(info.draggingPasteboard).isEmpty else { return [] }
            if operation == .on, row >= 0, row < entries.count, entries[row].isDirectory { return .copy }
            tableView.setDropRow(-1, dropOperation: .on)
            return .copy
        }

        func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                       dropOperation: NSTableView.DropOperation) -> Bool {
            let urls = Self.fileURLs(info.draggingPasteboard)
            guard !urls.isEmpty else { return false }
            var target = model.path
            if dropOperation == .on, row >= 0, row < entries.count, entries[row].isDirectory { target = target.appending(entries[row].name) }
            model.upload(urls, into: target)
            return true
        }

        static func fileURLs(_ pasteboard: NSPasteboard) -> [URL] {
            pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        }

        /// ⌘V: the files copied in Finder go into the folder shown.
        func paste() {
            let urls = Self.fileURLs(.general)
            if model.isConnected, !urls.isEmpty { model.upload(urls, into: model.path) }
        }

        // MARK: Context menu

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let table, model.isConnected else { return }
            let row = table.clickedRow
            if row >= 0, !table.selectedRowIndexes.contains(row) {
                table.selectRowIndexes([row], byExtendingSelection: false)
            }
            let onItem = row >= 0
            func add(_ title: String, _ action: Selector, enabled: Bool = true) {
                let item = NSMenuItem(title: title, action: enabled ? action : nil, keyEquivalent: "")
                item.target = self
                menu.addItem(item)
            }
            if onItem {
                add(String(localized: "Open"), #selector(menuOpen), enabled: selected.count == 1)
                add(String(localized: "Copy"), #selector(menuCopy))
                add(String(localized: "Download…"), #selector(menuDownload))
                menu.addItem(.separator())
                add(String(localized: "Rename"), #selector(menuRename), enabled: selected.count == 1)
                add(String(localized: "Delete…"), #selector(menuDelete))
            } else {
                table.deselectAll(nil)
                add(String(localized: "New Folder"), #selector(menuNewFolder))
                add(String(localized: "Upload…"), #selector(menuUpload))
                add(String(localized: "Paste"), #selector(menuPaste), enabled: !Self.fileURLs(.general).isEmpty)
            }
        }

        @objc private func menuOpen() { openSelected() }
        @objc private func menuCopy() { model.copyToClipboard(selected) }
        @objc private func menuDownload() { FileBrowserActions.download(model, selected) }
        @objc private func menuRename() { beginRename() }
        @objc private func menuDelete() { model.delete(selected) }
        @objc private func menuNewFolder() { model.makeFolder() }
        @objc private func menuUpload() { FileBrowserActions.upload(model) }
        @objc private func menuPaste() { paste() }
    }
}

/// What a drag into Finder promises: one entry of one folder.
struct PromisedFile {
    var entry: DeviceFileEntry
    var folder: RemotePath
}

/// The table with Finder's keys (design D4). The app has no main menu (menu bar only), so ⌘V, ⌘C, ⌘X
/// and ⌘A are handled here, for the table and for the field editor while renaming.
final class FileTableView: NSTableView {
    weak var coordinator: FileBrowserTable.Coordinator?

    override func keyDown(with event: NSEvent) {
        let command = event.modifierFlags.contains(.command)
        switch (event.keyCode, command) {
        case (36, false), (76, false): coordinator?.beginRename()            // Return
        case (51, _), (117, _): coordinator.map { $0.model.delete($0.selected) } // Delete, Forward Delete
        case (125, true): coordinator?.openSelected()                        // ⌘↓
        case (126, true): coordinator?.model.goUp()                          // ⌘↑
        default: super.keyDown(with: event)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command), let key = LatinKey.of(event) else { return super.performKeyEquivalent(with: event) }
        // The toolbar's ⌘R and ⇧⌘N, here too so they work with any keyboard layout.
        if !(window?.firstResponder is NSTextView) {
            switch (key, flags) {
            case ("r", .command): coordinator?.model.refresh(); return true
            case ("n", [.command, .shift]): coordinator?.model.makeFolder(); return true
            default: break
            }
        }
        guard flags == .command else { return super.performKeyEquivalent(with: event) }
        if let editor = window?.firstResponder as? NSTextView, editor.isFieldEditor {
            switch key {
            case "v": editor.paste(nil)
            case "c": editor.copy(nil)
            case "x": editor.cut(nil)
            case "a": editor.selectAll(nil)
            default: return super.performKeyEquivalent(with: event)
            }
            return true
        }
        guard window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        switch key {
        case "v": coordinator?.paste()
        case "c": coordinator.map { $0.model.copyToClipboard($0.selected) }
        case "a": selectAll(nil)
        case "[": coordinator?.model.goBack()
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }
}
