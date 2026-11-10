import AppKit
import SwiftUI
import UniversalKMCore

/// The file window's content (add-android-file-browser design D4): toolbar, list, connection state,
/// transfers.
struct FileBrowserView: View {
    @ObservedObject var model: FileBrowserModel

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            ZStack {
                FileBrowserTable(model: model)
                    .disabled(!model.isConnected)
                    .opacity(model.isConnected ? 1 : 0.4)
                if !model.isConnected {
                    VStack(spacing: 6) {
                        Image(systemName: "iphone.slash").font(.largeTitle).foregroundStyle(.secondary)
                        Text("The device is not connected").font(.headline)
                        Text("The folder opens again by itself when the device is back over Wi‑Fi or USB debugging.")
                            .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                } else if model.isLoading && model.entries.isEmpty {
                    ProgressView().controlSize(.small)
                }
            }
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
        .frame(minWidth: 520, minHeight: 320)
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            ControlGroup {
                Button { model.goBack() } label: { Image(systemName: "chevron.backward") }
                    .disabled(!model.canGoBack)
                    .help("Back")
                Button { model.goUp() } label: { Image(systemName: "arrow.up") }
                    .disabled(model.path.isRoot)
                    .help("Enclosing folder")
            }
            .controlGroupStyle(.navigation)
            .fixedSize()
            Text(model.path.display(rootName: model.name))
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .truncationMode(.head)
            Spacer()
            Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                .keyboardShortcut("r", modifiers: .command)
                .help("Refresh")
            Button { model.makeFolder() } label: { Image(systemName: "folder.badge.plus") }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .help("New Folder")
            Button { FileBrowserActions.download(model, model.selectedEntries) } label: { Label("Download…", systemImage: "arrow.down.circle") }
                .disabled(model.selection.isEmpty)
                .help("Download the selected items to a folder on the Mac")
            Button { FileBrowserActions.upload(model) } label: { Label("Upload…", systemImage: "arrow.up.circle") }
                .help("Upload files from the Mac to this folder")
        }
        .disabled(!model.isConnected)
        .labelStyle(.titleAndIcon)
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
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

/// The panels of "Download…" and "Upload…".
@MainActor
enum FileBrowserActions {
    static func download(_ model: FileBrowserModel, _ entries: [DeviceFileEntry]) {
        guard !entries.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Download Here")
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        model.download(entries, into: folder)
    }

    static func upload(_ model: FileBrowserModel) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Upload")
        guard panel.runModal() == .OK else { return }
        model.upload(panel.urls, into: model.path)
    }
}

/// One file window per Android device (design D4), keyed by its serial number. Follows the Android
/// status for the transport and reads the open folder every 10 seconds while the window is visible.
@MainActor
final class FileBrowsers: NSObject, NSWindowDelegate {
    private struct Open {
        var window: NSWindow
        var model: FileBrowserModel
        var timer: Timer
    }
    private var open: [String: Open] = [:]
    private var transports: [String: String] = [:]

    /// `transport` only for `--files-window`; otherwise it comes from the Android status.
    /// `folder`: open there ("Recordings…"), or in its parent when it does not exist yet.
    func show(key: String, name: String, transport: String? = nil, folder: RemotePath? = nil) {
        if let transport { transports[key] = transport }
        NSApp.activate()
        if let existing = open[key] {
            if let folder { existing.model.reveal(folder) }
            existing.window.makeKeyAndOrderFront(nil)
            return
        }
        let model = FileBrowserModel(key: key, name: name, transport: transports[key])
        if let folder { model.reveal(folder) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = name
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: FileBrowserView(model: model))
        window.setFrameAutosaveName("FileBrowser")
        if open.isEmpty { window.center() } else { window.cascadeTopLeft(from: NSPoint(x: window.frame.minX + 24, y: window.frame.maxY - 24)) }
        window.delegate = self
        let timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak window, weak model] _ in
            Task { @MainActor in
                guard let window, let model, window.occlusionState.contains(.visible), !model.isLoading else { return }
                model.refresh()
            }
        }
        open[key] = Open(window: window, model: model, timer: timer)
        window.makeKeyAndOrderFront(nil)
    }

    /// The Android status changed: each open window follows its device's file transport (design D2).
    func update(_ status: AndroidStatus) {
        transports = Dictionary(status.devices.compactMap { device in device.fileTransport.map { (device.serial, $0) } },
                                uniquingKeysWith: { first, _ in first })
        for (key, entry) in open { entry.model.update(transport: transports[key]) }
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let key = open.first(where: { $0.value.window === window })?.key else { return }
        open[key]?.timer.invalidate()
        for transfer in open[key]?.model.transfers ?? [] where transfer.isActive { transfer.cancellation.cancel() }
        open[key] = nil
    }
}
