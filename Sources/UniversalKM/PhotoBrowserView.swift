import AppKit
import SwiftUI
import UniversalKMCore

/// The photo window's content (add-iphone-photo-browser design D3, D4): device choice, state, grid,
/// transfers.
struct PhotoBrowserView: View {
    @ObservedObject var model: PhotoBrowserModel

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            ZStack {
                PhotoGrid(model: model)
                    .opacity(model.items.isEmpty ? 0 : 1)
                if let message = stateMessage {
                    VStack(spacing: 6) {
                        Image(systemName: message.icon).font(.largeTitle).foregroundStyle(.secondary)
                        Text(message.title).font(.headline)
                        if let detail = message.detail {
                            Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: 420)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                }
            }
            Divider()
            footer
            if let notice = model.notice, model.actionError == nil {
                Divider()
                HStack {
                    Image(systemName: "doc.on.clipboard").foregroundStyle(.secondary)
                    Text(notice).font(.callout).lineLimit(2)
                    Spacer()
                    Button { model.notice = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
            }
            if let error = model.actionError {
                Divider()
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                    Text(error).font(.callout).lineLimit(2)
                    Spacer()
                    Button { model.actionError = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
            }
            if !model.transfers.isEmpty {
                Divider()
                transfers
            }
        }
        .frame(minWidth: 520, minHeight: 360)
    }

    private struct Message {
        var icon: String
        var title: String
        var detail: String?
    }

    private var stateMessage: Message? {
        switch model.status {
        case .noDevice:
            Message(icon: "cable.connector", title: String(localized: "Connect the iPhone with a cable"),
                    detail: String(localized: "Photos and videos are read over USB; Wi‑Fi does not show them."))
        case .opening:
            Message(icon: "hourglass", title: String(localized: "Opening the iPhone…"))
        case .restricted:
            Message(icon: "lock.iphone", title: String(localized: "Unlock the iPhone"),
                    detail: String(localized: "If the iPhone asks, tap “Trust” and enter its passcode."))
        case .locked:
            Message(icon: "lock.iphone", title: String(localized: "Unlock the iPhone"))
        case .reading(let count) where model.items.isEmpty:
            Message(icon: "hourglass", title: String(localized: "Reading the photos… \(count)"))
        case .ready where model.items.isEmpty:
            Message(icon: "photo.on.rectangle", title: String(localized: "No photos or videos on the iPhone"))
        case .failed(let text):
            Message(icon: "exclamationmark.triangle", title: text)
        default:
            nil
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            if model.devices.count > 1 {
                Picker("", selection: Binding(get: { model.deviceID ?? "" }, set: { model.choose($0) })) {
                    ForEach(model.devices) { Text($0.name).tag($0.id) }
                }
                .labelsHidden()
                .fixedSize()
            } else {
                Text(model.deviceName ?? "iPhone").font(.callout.weight(.medium))
            }
            Spacer()
            Button { model.copyToClipboard(model.selectedItems) } label: { Label("Copy", systemImage: "doc.on.doc") }
                .disabled(model.selection.isEmpty)
                .help("Copy the selected items, then paste them in Finder with ⌘V")
            Button { PhotoBrowserActions.download(model, model.selectedItems) } label: { Label("Download…", systemImage: "arrow.down.circle") }
                .disabled(model.selection.isEmpty)
                .help("Download the selected items to a folder on the Mac")
            Button { model.delete(model.selectedItems) } label: { Label("Delete…", systemImage: "trash") }
                .disabled(model.selection.isEmpty || !model.canDelete)
                .help(model.canDelete ? String(localized: "Delete the selected items from the device")
                                      : String(localized: "The device does not allow deleting now"))
        }
        .labelStyle(.titleAndIcon)
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            if case .reading(let count) = model.status, !model.items.isEmpty {
                ProgressView().controlSize(.mini)
                Text("Reading the photos… \(count)")
            } else if !model.items.isEmpty {
                Text(model.selection.isEmpty ? String(localized: "\(model.items.count) items")
                                             : String(localized: "\(model.selection.count) of \(model.items.count) selected"))
            }
            Spacer()
            if model.camera != nil {
                Text("New photos appear after reconnecting the cable.")
            }
            if model.camera != nil, !model.canDelete, model.status == .ready {
                Text("·")
                Text("The device does not allow deleting now")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10).padding(.vertical, 5)
    }

    private var transfers: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Transfers").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if model.transfers.contains(where: { !$0.isActive }) {
                    Button("Clear") { model.clearFinished() }.buttonStyle(.borderless).font(.caption)
                }
            }
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(model.transfers) { TransferRow(transfer: $0, cancel: model.cancel) }
                }
            }
            .frame(maxHeight: 120)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
    }
}

@MainActor
enum PhotoBrowserActions {
    static func download(_ model: PhotoBrowserModel, _ items: [PhotoItem]) {
        guard !items.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Download Here")
        panel.directoryURL = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        model.download(items, into: folder)
    }
}

/// The one photo window of the app (design D2): the iPhone on the cable, not tied to a panel device.
@MainActor
final class PhotoBrowsers: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var model: PhotoBrowserModel?
    private var title: Any?

    func show() {
        NSApp.activate()
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let model = PhotoBrowserModel()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = String(localized: "iPhone Photos")
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: PhotoBrowserView(model: model))
        window.setFrameAutosaveName("PhotoBrowser")
        window.center()
        window.delegate = self
        title = model.$devices.combineLatest(model.$deviceID).sink { [weak window] devices, id in
            let name = devices.first { $0.id == id }?.name
            window?.title = name.map { String(localized: "Photos on \($0)") } ?? String(localized: "iPhone Photos")
        }
        self.window = window
        self.model = model
        model.start()
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        model?.stop()
        model = nil
        window = nil
        title = nil
    }
}
