import AppKit
import SwiftUI
import UniformTypeIdentifiers
import UniversalKMCore

/// The grid of photos and videos (add-iphone-photo-browser design D4): thumbnails on demand, multiple
/// selection, drags into Finder as file promises, ⌘C/⌘A/Delete with any keyboard layout, context menu.
struct PhotoGrid: NSViewRepresentable {
    @ObservedObject var model: PhotoBrowserModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSScrollView {
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 148, height: 190)
        layout.minimumInteritemSpacing = 8
        layout.minimumLineSpacing = 8
        layout.sectionInset = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        let grid = PhotoCollectionView()
        grid.collectionViewLayout = layout
        grid.isSelectable = true
        grid.allowsMultipleSelection = true
        grid.backgroundColors = [.textBackgroundColor]
        grid.register(PhotoCell.self, forItemWithIdentifier: PhotoCell.identifier)
        grid.dataSource = context.coordinator
        grid.delegate = context.coordinator
        grid.setDraggingSourceOperationMask(.copy, forLocal: false)
        grid.coordinator = context.coordinator
        grid.menu = context.coordinator.menu
        context.coordinator.grid = grid
        let scroll = NSScrollView()
        scroll.documentView = grid
        scroll.hasVerticalScroller = true
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.update(model.items, selection: model.selection)
    }

    @MainActor
    final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate, NSMenuDelegate {
        let model: PhotoBrowserModel
        weak var grid: NSCollectionView?
        private var items: [PhotoItem] = []
        private let promises: PromiseDelegate
        let menu = NSMenu()

        init(model: PhotoBrowserModel) {
            self.model = model
            promises = PromiseDelegate(name: { ($0 as? PromisedPhoto)?.name ?? "photo" }) { [model] info, url, done in
                guard let photo = info as? PromisedPhoto else { return done(PhotoError.disconnected) }
                model.download(id: photo.id, to: url, completion: done)
            }
            super.init()
            menu.delegate = self
        }

        func update(_ items: [PhotoItem], selection: Set<String>) {
            guard let grid else { return }
            if items != self.items {
                self.items = items
                grid.reloadData()
            }
            let wanted = Set(items.indices.filter { selection.contains(items[$0].id) }.map { IndexPath(item: $0, section: 0) })
            if grid.selectionIndexPaths != wanted { grid.selectionIndexPaths = wanted }
        }

        var selected: [PhotoItem] { model.selectedItems }

        // Data source

        func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { items.count }

        func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
            let cell = collectionView.makeItem(withIdentifier: PhotoCell.identifier, for: indexPath) as! PhotoCell
            let item = items[indexPath.item]
            cell.show(item)
            cell.thumbnail.image = model.thumbnail(item.id) { [weak cell] image in
                guard let cell, cell.itemID == item.id else { return }
                cell.thumbnail.image = image ?? PhotoCell.placeholder(item)
            } ?? PhotoCell.placeholder(item)
            return cell
        }

        // Selection

        func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) { syncSelection() }
        func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) { syncSelection() }

        private func syncSelection() {
            guard let grid else { return }
            let ids = Set(grid.selectionIndexPaths.compactMap { items.indices.contains($0.item) ? items[$0.item].id : nil })
            if ids != model.selection { model.selection = ids }
        }

        // Drag into Finder (design D5)

        func collectionView(_ collectionView: NSCollectionView, canDragItemsAt indexPaths: Set<IndexPath>, with event: NSEvent) -> Bool { true }

        func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
            let item = items[indexPath.item]
            let type = UTType(filenameExtension: FileNames.split(item.name).1) ?? .data
            let provider = NSFilePromiseProvider(fileType: type.identifier, delegate: promises)
            provider.userInfo = PromisedPhoto(id: item.id, name: item.name)
            return provider
        }

        // Context menu

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let grid, !model.items.isEmpty else { return }
            // A right click on an unselected item selects it, as in Finder.
            let point = grid.convert(grid.window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil)
            if let path = grid.indexPathForItem(at: point), !grid.selectionIndexPaths.contains(path) {
                grid.selectionIndexPaths = [path]
                syncSelection()
            }
            guard !model.selection.isEmpty else {
                menu.addItem(withTitle: String(localized: "Select All"), action: #selector(selectAll), keyEquivalent: "").target = self
                return
            }
            menu.addItem(withTitle: String(localized: "Copy"), action: #selector(copySelected), keyEquivalent: "").target = self
            menu.addItem(withTitle: String(localized: "Download…"), action: #selector(downloadSelected), keyEquivalent: "").target = self
            menu.addItem(.separator())
            let delete = menu.addItem(withTitle: String(localized: "Delete…"), action: #selector(deleteSelected), keyEquivalent: "")
            delete.target = self
            delete.isEnabled = model.canDelete
        }

        @objc func copySelected() { model.copyToClipboard(selected) }
        @objc func downloadSelected() { PhotoBrowserActions.download(model, selected) }
        @objc func deleteSelected() { model.delete(selected) }
        @objc func selectAll() { grid?.selectAll(nil); syncSelection() }
    }
}

/// What a drag into Finder promises: one photo or video (its Live Photo video comes along).
struct PromisedPhoto {
    var id: String
    var name: String
}

/// The grid with Finder's keys. The app has no main menu, so ⌘C and ⌘A are handled here.
final class PhotoCollectionView: NSCollectionView {
    weak var coordinator: PhotoGrid.Coordinator?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 51, 117: coordinator?.deleteSelected() // Delete, Forward Delete
        default: super.keyDown(with: event)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
              window?.firstResponder === self, let key = LatinKey.of(event) else { return super.performKeyEquivalent(with: event) }
        switch key {
        case "c": coordinator?.copySelected()
        case "a": coordinator?.selectAll()
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }
}

/// One thumbnail with its name, date and size; a video shows its length, a Live Photo its badge.
final class PhotoCell: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("PhotoCell")
    private(set) var itemID: String?
    let thumbnail = NSImageView()
    private let badge = NSTextField(labelWithString: "")
    private let name = NSTextField(labelWithString: "")
    private let details = NSTextField(labelWithString: "")
    private let box = NSView()

    private static let dateFormat: DateFormatter = {
        let format = DateFormatter()
        // Compact: the cell is narrow, and a full date with the era does not fit.
        format.setLocalizedDateFormatFromTemplate("dMMyyHHmm")
        return format
    }()

    override func loadView() {
        view = NSView()
        box.wantsLayer = true
        box.layer?.cornerRadius = 6
        thumbnail.imageScaling = .scaleProportionallyUpOrDown
        thumbnail.wantsLayer = true
        thumbnail.layer?.cornerRadius = 4
        thumbnail.layer?.masksToBounds = true
        badge.font = .systemFont(ofSize: 10, weight: .semibold)
        badge.textColor = .white
        badge.wantsLayer = true
        badge.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        badge.layer?.cornerRadius = 3
        for label in [name, details] {
            label.lineBreakMode = .byTruncatingMiddle
            label.alignment = .center
        }
        name.font = .systemFont(ofSize: 11)
        details.font = .systemFont(ofSize: 10)
        details.maximumNumberOfLines = 2
        details.textColor = .secondaryLabelColor
        for subview in [box, thumbnail, badge, name, details] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            box.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            box.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            box.topAnchor.constraint(equalTo: view.topAnchor),
            box.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            thumbnail.topAnchor.constraint(equalTo: view.topAnchor, constant: 6),
            thumbnail.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 6),
            thumbnail.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -6),
            thumbnail.heightAnchor.constraint(equalToConstant: 128),
            badge.trailingAnchor.constraint(equalTo: thumbnail.trailingAnchor, constant: -4),
            badge.bottomAnchor.constraint(equalTo: thumbnail.bottomAnchor, constant: -4),
            name.topAnchor.constraint(equalTo: thumbnail.bottomAnchor, constant: 4),
            name.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 4),
            name.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -4),
            details.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 1),
            details.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 4),
            details.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -4),
        ])
    }

    func show(_ item: PhotoItem) {
        itemID = item.id
        name.stringValue = item.name
        let size = ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)
        details.stringValue = [item.created.map(Self.dateFormat.string(from:)), size].compactMap { $0 }.joined(separator: "\n")
        switch (item.kind, item.isLivePhoto) {
        case (.video, _): badge.stringValue = " ▶ \(PhotoItem.duration(item.duration)) "
        case (.photo, true): badge.stringValue = " LIVE "
        default: badge.stringValue = ""
        }
        badge.isHidden = badge.stringValue.isEmpty
        updateSelection()
    }

    static func placeholder(_ item: PhotoItem) -> NSImage? {
        NSImage(systemSymbolName: item.kind == .video ? "video" : "photo", accessibilityDescription: nil)
    }

    override var isSelected: Bool { didSet { updateSelection() } }

    private func updateSelection() {
        box.layer?.backgroundColor = isSelected ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.35).cgColor : nil
    }
}
