import AppKit
import os
import UniversalKMCore

/// The state of one device's file window (design D2–D8): the folder shown, the connection, the
/// transfers. Device work runs on two serial queues: listings and shell commands on one, transfers on
/// the other (one sync connection at a time), so browsing does not wait for a transfer.
@MainActor
final class FileBrowserModel: ObservableObject {
    let key: String
    let name: String
    @Published private(set) var transport: String?
    @Published private(set) var path = RemotePath.root
    @Published private(set) var entries: [DeviceFileEntry] = []
    @Published private(set) var isLoading = false
    @Published private(set) var transfers: [FileTransfer] = []
    /// Last error of an action (rename, new folder, delete), shown under the list.
    @Published var actionError: String?
    /// A short note under the list ("Copied…").
    @Published var notice: String?
    @Published var sortKey = DeviceFileEntry.SortKey.name { didSet { resort() } }
    @Published var ascending = true { didSet { resort() } }
    /// Names selected in the list.
    @Published var selection: Set<String> = []
    /// Names to select after the next listing (a new folder, an upload).
    var pendingSelection: Set<String> = []

    private var back: [RemotePath] = []
    private var client: ADBFileClient?
    private var listGeneration = 0
    private let log = Logger(subsystem: "com.universalkm.UniversalKM", category: "files")
    private let listQueue = DispatchQueue(label: "ukm.files.list", qos: .userInitiated)
    private let transferQueue = DispatchQueue(label: "ukm.files.transfer", qos: .utility)

    init(key: String, name: String, transport: String?) {
        self.key = key
        self.name = name
        setTransport(transport)
    }

    var isConnected: Bool { transport != nil }
    var selectedEntries: [DeviceFileEntry] { entries.filter { selection.contains($0.name) } }
    var canGoBack: Bool { !back.isEmpty }

    // MARK: Connection (design D2)

    /// The status of the device changed: a new transport reads the folder again, none shows "not connected".
    func update(transport: String?) {
        guard transport != self.transport else { return }
        setTransport(transport)
    }

    private func setTransport(_ transport: String?) {
        self.transport = transport
        client = transport.map(ADBFileClient.init(transport:))
        if transport == nil {
            entries = []
        } else {
            refresh()
        }
    }

    // MARK: Navigation

    func open(_ entry: DeviceFileEntry) {
        if entry.isDirectory {
            go(to: path.appending(entry.name))
        } else {
            openFile(entry)
        }
    }

    func go(to new: RemotePath, remember: Bool = true) {
        guard new != path else { return }
        if remember { back.append(path) }
        path = new
        entries = []
        refresh()
    }

    func goUp() {
        if let parent = path.parent { go(to: parent) }
    }

    func goBack() {
        guard let previous = back.popLast() else { return }
        go(to: previous, remember: false)
    }

    /// Reads the folder shown. Listings answered after the folder or the transport changed are dropped.
    func refresh() {
        guard let client else { return }
        listGeneration += 1
        let generation = listGeneration, path = self.path
        isLoading = true
        listQueue.async { [weak self] in
            let result = Result { try client.list(path.string) }
            Task { @MainActor in self?.listed(result, generation: generation, client: client) }
        }
    }

    private func listed(_ result: Result<[ADBSync.Entry], Error>, generation: Int, client: ADBFileClient) {
        guard generation == listGeneration, client === self.client else { return }
        isLoading = false
        switch result {
        case .success(let list):
            entries = DeviceFileEntry.sorted(DeviceFileEntry.visible(list), by: sortKey, ascending: ascending)
        case .failure(ADBFileError.notConnected):
            // adb still lists the transport for a moment after the device left: the status catches up.
            entries = []
            actionError = Self.message(ADBFileError.notConnected)
        case .failure(let error):
            // An unreadable folder is empty, without an error (design D7).
            log.info("files: list \(self.path.string, privacy: .public): \(String(describing: error), privacy: .public)")
            entries = []
        }
    }

    private func resort() {
        entries = DeviceFileEntry.sorted(entries, by: sortKey, ascending: ascending)
    }

    // MARK: Changes on the device

    func makeFolder() {
        let name = FileNames.unique(String(localized: "New Folder")) { taken($0) }
        pendingSelection = [name]
        runShell(ADBShell.makeDirectory(path.appending(name).string))
    }

    func rename(_ entry: DeviceFileEntry, to newName: String) {
        let newName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty, newName != entry.name else { return }
        guard !newName.contains("/") else {
            actionError = String(localized: "A name cannot contain “/”.")
            return
        }
        guard !taken(newName) else {
            actionError = String(localized: "“\(newName)” already exists.")
            return
        }
        pendingSelection = [newName]
        runShell(ADBShell.move(path.appending(entry.name).string, path.appending(newName).string))
    }

    func delete(_ selected: [DeviceFileEntry]) {
        guard !selected.isEmpty else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = selected.count == 1
            ? String(localized: "Delete “\(selected[0].name)” from \(name)?")
            : String(localized: "Delete \(selected.count) items from \(name)?")
        alert.informativeText = String(localized: "They are deleted from the device at once, without the Trash.")
        alert.addButton(withTitle: String(localized: "Delete"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.buttons[0].hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let paths = selected.map { path.appending($0.name).string }
        runShell(paths.map(ADBShell.remove))
    }

    private func taken(_ name: String) -> Bool {
        entries.contains { $0.name.compare(name, options: .caseInsensitive) == .orderedSame }
    }

    private func runShell(_ commands: String...) { runShell(commands) }

    private func runShell(_ commands: [String]) {
        guard let client else { return }
        actionError = nil
        listQueue.async { [weak self] in
            var failure: String?
            for command in commands {
                do { try client.shell(command) } catch { failure = Self.message(error); break }
            }
            Task { @MainActor in
                guard let self else { return }
                if let failure { self.actionError = failure }
                self.refresh()
            }
        }
    }

    // MARK: Transfers (design D5, D6)

    /// Downloads the selected entries into a Mac folder, each under a free name.
    func download(_ selected: [DeviceFileEntry], into folder: URL) {
        for entry in selected {
            enqueue(entry.name, .download) { [path] client, transfer in
                try Self.download(path.appending(entry.name), isDirectory: entry.isDirectory, into: folder,
                                  name: entry.name, client: client, transfer: transfer)
            }
        }
    }

    /// For a drag into Finder: downloads one entry to `url` (a free name next to it if taken) and reports.
    nonisolated func download(_ entry: DeviceFileEntry, in folder: RemotePath, to url: URL,
                              completion: @escaping @Sendable (Error?) -> Void) {
        Task { @MainActor in
            self.enqueue(entry.name, .download, completion: completion) { client, transfer in
                try Self.download(folder.appending(entry.name), isDirectory: entry.isDirectory,
                                  into: url.deletingLastPathComponent(), name: url.lastPathComponent,
                                  client: client, transfer: transfer)
            }
        }
    }

    /// ⌘C (design D8a): downloads the selection into a fresh temporary folder and puts those files on
    /// the clipboard once all are there, so ⌘V in Finder copies them. Nothing goes on the clipboard if one fails.
    func copyToClipboard(_ selected: [DeviceFileEntry]) {
        guard !selected.isEmpty else { return }
        let folder = Self.temporaryRoot.appendingPathComponent("Copied").appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            actionError = error.localizedDescription
            return
        }
        notice = String(localized: "Copying \(selected.count) items…")
        let batch = CopyBatch(count: selected.count)
        for entry in selected {
            enqueue(entry.name, .download, completion: { [weak self] error in
                Task { @MainActor in
                    guard batch.finish(failed: error != nil), let self else { return }
                    if batch.failed {
                        self.notice = nil
                        return
                    }
                    let urls = selected.map { folder.appendingPathComponent($0.name) as NSURL }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.writeObjects(urls)
                    self.notice = String(localized: "Copied. Paste in Finder with ⌘V.")
                }
            }) { [path] client, transfer in
                try Self.download(path.appending(entry.name), isDirectory: entry.isDirectory, into: folder,
                                  name: entry.name, client: client, transfer: transfer)
            }
        }
    }

    /// Double-click on a file (design D8): download into the temporary folder, open with the default app.
    func openFile(_ entry: DeviceFileEntry) {
        let remote = path.appending(entry.name)
        let folder = Self.temporaryRoot.appendingPathComponent(key).appendingPathComponent(remote.components.dropLast().joined(separator: "/"))
        enqueue(entry.name, .download, completion: { error in
            guard error == nil else { return }
            Task { @MainActor in NSWorkspace.shared.open(folder.appendingPathComponent(entry.name)) }
        }) { client, transfer in
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let target = folder.appendingPathComponent(entry.name)
            try? FileManager.default.removeItem(at: target)
            try Self.download(remote, isDirectory: false, into: folder, name: entry.name, client: client, transfer: transfer)
        }
    }

    /// Files opened with a double-click; removed when the app quits.
    static let temporaryRoot = FileManager.default.temporaryDirectory.appendingPathComponent("UniversalKM", isDirectory: true)

    /// Uploads Mac files and folders into `target` (the folder shown, or a folder in it). Names that
    /// exist there are asked about once: replace or skip (design D6).
    func upload(_ urls: [URL], into target: RemotePath) {
        guard let client, !urls.isEmpty else { return }
        listQueue.async { [weak self] in
            let existing = (try? client.list(target.string)).map { Set($0.map(\.name)) } ?? []
            Task { @MainActor in self?.upload(urls, into: target, existing: existing) }
        }
    }

    private func upload(_ urls: [URL], into target: RemotePath, existing: Set<String>) {
        let clashes = urls.filter { existing.contains($0.lastPathComponent) }
        var replace: Set<URL> = []
        var askAgain = true
        var replaceAll = false
        for url in clashes {
            if askAgain {
                let alert = NSAlert()
                alert.messageText = String(localized: "“\(url.lastPathComponent)” already exists on \(name).")
                alert.informativeText = String(localized: "Replace it with the one from the Mac?")
                alert.addButton(withTitle: String(localized: "Replace"))
                alert.addButton(withTitle: String(localized: "Skip"))
                if clashes.count > 1 {
                    alert.showsSuppressionButton = true
                    alert.suppressionButton?.title = String(localized: "Apply to all")
                }
                replaceAll = alert.runModal() == .alertFirstButtonReturn
                askAgain = alert.suppressionButton?.state != .on
            }
            if replaceAll { replace.insert(url) }
        }
        for url in urls where !existing.contains(url.lastPathComponent) || replace.contains(url) {
            let replacing = replace.contains(url)
            if target == path { pendingSelection.insert(url.lastPathComponent) }
            enqueue(url.lastPathComponent, .upload) { client, transfer in
                try Self.upload(url, into: target, replacing: replacing, client: client, transfer: transfer)
            }
        }
    }

    func cancel(_ transfer: FileTransfer) {
        transfer.cancellation.cancel()
    }

    func clearFinished() {
        transfers.removeAll { !$0.isActive }
    }

    private func enqueue(_ name: String, _ direction: FileTransfer.Direction,
                         completion: (@Sendable (Error?) -> Void)? = nil,
                         _ work: @escaping @Sendable (ADBFileClient, TransferProgress) throws -> Void) {
        guard let client else {
            completion?(ADBFileError.notConnected)
            return
        }
        let transfer = FileTransfer(name: name, direction: direction)
        transfers.append(transfer)
        let progress = TransferProgress(transfer)
        transferQueue.async { [weak self] in
            if transfer.cancellation.isCancelled {
                progress.finish(ADBFileError.cancelled)
                completion?(ADBFileError.cancelled)
                return
            }
            progress.start()
            var failure: Error?
            do { try work(client, progress) } catch { failure = error }
            progress.finish(failure)
            completion?(failure)
            Task { @MainActor in self?.refresh() }
        }
    }

    // MARK: Transfer work (off the main thread)

    /// Downloads a file or a whole folder into `folder` as `name` (a free name if taken), through a
    /// hidden partial name, so nothing incomplete has the real name (design D5).
    nonisolated private static func download(_ remote: RemotePath, isDirectory: Bool, into folder: URL, name: String,
                                             client: ADBFileClient, transfer: TransferProgress) throws {
        let manager = FileManager.default
        let partial = folder.appendingPathComponent(DeviceFileEntry.partialName(for: name))
        try? manager.removeItem(at: partial)
        do {
            if isDirectory {
                // The whole tree first: the total for the progress.
                var files: [(RemotePath, String, UInt64)] = []
                var folders: [String] = []
                func walk(_ dir: RemotePath, _ relative: String) throws {
                    for entry in try client.list(dir.string, cancel: transfer.cancellation)
                    where entry.name != "." && entry.name != ".." && !DeviceFileEntry.isPartial(entry.name) {
                        let child = relative.isEmpty ? entry.name : relative + "/" + entry.name
                        if entry.isDirectory {
                            folders.append(child)
                            try walk(dir.appending(entry.name), child)
                        } else {
                            files.append((dir.appending(entry.name), child, entry.size))
                        }
                    }
                }
                try walk(remote, "")
                transfer.setTotal(files.reduce(0) { $0 + $1.2 })
                try manager.createDirectory(at: partial, withIntermediateDirectories: true)
                for folder in folders {
                    try manager.createDirectory(at: partial.appendingPathComponent(folder), withIntermediateDirectories: true)
                }
                var before: UInt64 = 0
                for (path, relative, size) in files {
                    try client.download(path.string, to: partial.appendingPathComponent(relative), cancel: transfer.cancellation) {
                        transfer.setDone(before + $0)
                    }
                    before += size
                }
            } else {
                if let stat = try client.stat(remote.string) { transfer.setTotal(stat.size) }
                try client.download(remote.string, to: partial, cancel: transfer.cancellation) { transfer.setDone($0) }
            }
            let free = FileNames.unique(name) { manager.fileExists(atPath: folder.appendingPathComponent($0).path) }
            try manager.moveItem(at: partial, to: folder.appendingPathComponent(free))
        } catch {
            try? manager.removeItem(at: partial)
            throw error
        }
    }

    /// Uploads a Mac file or folder into `target` through a hidden partial name, then moves it in place
    /// (design D5). Partial leftovers of earlier transfers in `target` are removed first.
    nonisolated private static func upload(_ url: URL, into target: RemotePath, replacing: Bool,
                                           client: ADBFileClient, transfer: TransferProgress) throws {
        let name = url.lastPathComponent
        let partial = target.appending(DeviceFileEntry.partialName(for: name)).string
        try client.shell(ADBShell.removePartials(in: target.string))
        do {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDirectory {
                var files: [(URL, String, UInt64)] = []
                var folders: [String] = []
                let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey]
                let base = url.standardizedFileURL.path
                for case let item as URL in FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) ?? .init() {
                    let values = try item.resourceValues(forKeys: Set(keys))
                    let relative = String(item.standardizedFileURL.path.dropFirst(base.count + 1))
                    if values.isDirectory == true { folders.append(relative) } else { files.append((item, relative, UInt64(values.fileSize ?? 0))) }
                }
                transfer.setTotal(files.reduce(0) { $0 + $1.2 })
                try client.shell(ADBShell.makeDirectory(partial), cancel: transfer.cancellation)
                for folder in folders {
                    try client.shell(ADBShell.makeDirectory(partial + "/" + folder), cancel: transfer.cancellation)
                }
                var before: UInt64 = 0
                for (file, relative, size) in files {
                    try client.upload(file, to: partial + "/" + relative, cancel: transfer.cancellation) { transfer.setDone(before + $0) }
                    before += size
                }
            } else {
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(UInt64.init) ?? 0
                transfer.setTotal(size)
                try client.upload(url, to: partial, cancel: transfer.cancellation) { transfer.setDone($0) }
            }
            let final = target.appending(name).string
            if replacing { try client.shell(ADBShell.remove(final)) }
            try client.shell(ADBShell.move(partial, final))
        } catch {
            _ = try? client.shell(ADBShell.remove(partial))
            throw error
        }
    }

    // MARK: Errors

    nonisolated static func message(_ error: Error) -> String {
        switch error {
        case ADBFileError.notConnected: String(localized: "The device is not connected")
        case ADBFileError.connectionLost: String(localized: "Connection to the device lost")
        case ADBFileError.cancelled: String(localized: "Cancelled")
        case ADBFileError.failed(let text): text
        case ADBFileError.shell(_, let output): output.isEmpty ? String(localized: "The device refused") : output
        case ADBFileError.protocolError(let text): text
        default: error.localizedDescription
        }
    }
}

/// Progress of one transfer from the transfer queue to the main thread, at most 10 updates a second.
final class TransferProgress: @unchecked Sendable {
    private let transfer: FileTransfer
    private let lock = NSLock()
    private var lastSent = Date.distantPast

    init(_ transfer: FileTransfer) {
        self.transfer = transfer
    }

    var cancellation: ADBCancellation { transfer.cancellation }

    func start() {
        let transfer = self.transfer
        Task { @MainActor in transfer.state = .running }
    }

    func setTotal(_ total: UInt64) {
        let transfer = self.transfer
        Task { @MainActor in transfer.total = total }
    }

    func setDone(_ done: UInt64) {
        lock.lock()
        let now = Date()
        let send = now.timeIntervalSince(lastSent) >= 0.1
        if send { lastSent = now }
        lock.unlock()
        guard send else { return }
        let transfer = self.transfer
        Task { @MainActor in transfer.done = max(transfer.done, done) }
    }

    func finish(_ error: Error?) {
        let transfer = self.transfer
        let message = error.map(FileBrowserModel.message)
        Task { @MainActor in
            if let message {
                transfer.state = .failed(message)
            } else {
                transfer.done = transfer.total
                transfer.state = .finished
            }
        }
    }
}
