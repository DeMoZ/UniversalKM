import AppKit
import ImageCaptureCore
import os
import UniversalKMCore

private let log = Logger(subsystem: "com.universalkm", category: "photos")

/// Errors of the photo window, with texts for the transfer rows.
enum PhotoError: LocalizedError {
    case disconnected, cancelled, failed(String)

    var errorDescription: String? {
        switch self {
        case .disconnected: String(localized: "The connection to the iPhone was lost")
        case .cancelled: String(localized: "Cancelled")
        case .failed(let text): text
        }
    }
}

/// The photo window of an iPhone or iPad on the cable (add-iphone-photo-browser design D1–D6), through
/// ImageCaptureCore: the devices, the session of the chosen one, its catalog, downloads one at a time,
/// deletion. ImageCaptureCore calls back on the main thread or on its own queues; every callback hops to
/// the main actor before it touches the state.
@MainActor
final class PhotoBrowserModel: NSObject, ObservableObject {
    enum Status: Equatable {
        case noDevice, opening, restricted, locked
        case reading(Int)
        case ready
        case failed(String)
    }

    struct Device: Identifiable, Equatable {
        let id: String
        let name: String
    }

    @Published private(set) var devices: [Device] = []
    @Published private(set) var deviceID: String?
    @Published private(set) var status = Status.noDevice
    @Published private(set) var items: [PhotoItem] = []
    @Published var selection: Set<String> = []
    @Published private(set) var canDelete = false
    @Published private(set) var transfers: [FileTransfer] = []
    @Published var notice: String?
    @Published var actionError: String?

    private let browser = ICDeviceBrowser()
    private var cameras: [String: ICCameraDevice] = [:]
    private var files: [String: ICCameraFile] = [:]
    private var running = false

    var camera: ICCameraDevice? { deviceID.flatMap { cameras[$0] } }
    var deviceName: String? { devices.first { $0.id == deviceID }?.name }
    var isReady: Bool { status == .ready || { if case .reading = status { true } else { false } }() }
    var selectedItems: [PhotoItem] { items.filter { selection.contains($0.id) } }

    override init() {
        super.init()
        browser.delegate = self
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue:
            ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue)!
    }

    /// While the window is open (design D3): the session keeps the iPhone busy for Photos and Image Capture.
    func start() {
        guard !running else { return }
        running = true
        browser.start()
    }

    func stop() {
        guard running else { return }
        running = false
        for transfer in transfers where transfer.isActive { cancel(transfer) }
        camera?.requestCloseSession()
        browser.stop()
        cameras = [:]
        devices = []
        deviceID = nil
        reset(.noDevice)
    }

    func choose(_ id: String) {
        guard id != deviceID, cameras[id] != nil else { return }
        camera?.requestCloseSession()
        failActive(.disconnected)
        deviceID = id
        open()
    }

    private func open() {
        guard let camera else { return reset(.noDevice) }
        reset(.opening)
        camera.delegate = self
        if camera.hasOpenSession { catalogChanged(camera) } else { camera.requestOpenSession() }
    }

    private func reset(_ status: Status) {
        self.status = status
        items = []
        files = [:]
        selection = []
        canDelete = false
    }

    // MARK: Catalog (design D4)

    fileprivate func catalogChanged(_ camera: ICCameraDevice, complete: Bool = false) {
        guard camera === self.camera else { return }
        if camera.isAccessRestrictedAppleDevice {
            status = .restricted
        } else if camera.isLocked {
            status = .locked
        }
        var files: [String: ICCameraFile] = [:]
        var items: [PhotoItem] = []
        for case let file as ICCameraFile in camera.mediaFiles ?? [] {
            guard let name = file.name else { continue }
            let id = Self.id(of: file)
            // The same asset can be listed in two DCIM folders (seen after deleting a Live Photo, task 1.1):
            // one cell for it.
            guard files[id] == nil else { continue }
            files[id] = file
            let sidecars = (file.sidecarFiles ?? []).compactMap(\.name)
            let kind: PhotoItem.Kind = file.uti.map { $0.contains("movie") || $0.contains("video") } == true
                ? .video : PhotoItem.kind(ofName: name)
            items.append(PhotoItem(id: id, name: name, created: file.creationDate, size: Int64(file.fileSize),
                                   duration: file.duration, kind: kind, sidecars: sidecars))
        }
        self.files = files
        self.items = PhotoItem.sorted(items)
        selection.formIntersection(files.keys)
        if !camera.isAccessRestrictedAppleDevice, !camera.isLocked {
            if complete || status == .ready { status = .ready } else { status = .reading(items.count) }
        }
        updateCanDelete()
    }

    nonisolated static func id(of file: ICCameraItem) -> String {
        (file as? ICCameraFile)?.relatedUUID ?? ((file.parentFolder?.name ?? "") + "/" + (file.name ?? ""))
    }

    fileprivate func updateCanDelete() {
        guard let camera else { canDelete = false; return }
        canDelete = camera.capabilities.contains(ICDeviceCapability.cameraDeviceCanDeleteOneFile.rawValue) && !camera.isLocked
            && !camera.isAccessRestrictedAppleDevice
    }

    fileprivate func added(_ device: ICDevice) {
        guard let camera = device as? ICCameraDevice, isApple(camera), let id = camera.uuidString else { return }
        cameras[id] = camera
        devices = cameras.map { Device(id: $0.key, name: $0.value.name ?? "iPhone") }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        log.info("photos: \(camera.name ?? "?", privacy: .public) on the cable")
        if deviceID == nil || cameras[deviceID!] == nil {
            deviceID = id
            open()
        }
    }

    fileprivate func removed(_ device: ICDevice) {
        guard let id = device.uuidString, cameras[id] != nil else { return }
        cameras[id] = nil
        devices.removeAll { $0.id == id }
        guard id == deviceID else { return }
        failActive(.disconnected)
        deviceID = nil
        if let next = devices.first { deviceID = next.id; open() } else { reset(.noDevice) }
    }

    private func isApple(_ camera: ICCameraDevice) -> Bool {
        camera.usbVendorID == 0x05AC || ["iPhone", "iPad", "iPod"].contains(where: { camera.productKind?.contains($0) == true })
    }

    // MARK: Thumbnails (design D4)

    let thumbnails = NSCache<NSString, NSImage>()
    private var thumbnailWaiters: [String: [(NSImage?) -> Void]] = [:]
    private var thumbnailQueue: [String] = []
    private var thumbnailsInFlight = 0

    /// The cached thumbnail now, or nil and `ready` later. The newest requests go first (the visible cells).
    func thumbnail(_ id: String, ready: @escaping (NSImage?) -> Void) -> NSImage? {
        if let image = thumbnails.object(forKey: id as NSString) { return image }
        if thumbnailWaiters[id] == nil { thumbnailQueue.append(id) }
        thumbnailWaiters[id, default: []].append(ready)
        pumpThumbnails()
        return nil
    }

    private func pumpThumbnails() {
        while thumbnailsInFlight < 3, let id = thumbnailQueue.popLast() {
            guard let file = files[id] else { thumbnailWaiters[id] = nil; continue }
            thumbnailsInFlight += 1
            file.requestThumbnailData(options: [.init(rawValue: kCGImageSourceThumbnailMaxPixelSize as String): 320]) { [weak self] data, _ in
                let image = data.flatMap(NSImage.init(data:))
                let sendable = UncheckedSendable(image)
                Task { @MainActor in
                    guard let self else { return }
                    self.thumbnailsInFlight -= 1
                    if let image = sendable.value { self.thumbnails.setObject(image, forKey: id as NSString) }
                    for waiter in self.thumbnailWaiters.removeValue(forKey: id) ?? [] { waiter(sendable.value) }
                    self.pumpThumbnails()
                }
            }
        }
    }

    // MARK: Downloads (design D5)

    private enum Destination {
        /// Into a folder under free names.
        case folder(URL)
        /// The main file at exactly this URL (a Finder promise); the Live Photo video next to it.
        case file(URL)
    }

    private struct Job {
        let item: PhotoItem
        let destination: Destination
        let transfer: FileTransfer
        let completion: ([URL]?, Error?) -> Void
    }

    private var queue: [Job] = []
    private var current: (job: Job, progress: Progress?, observer: NSKeyValueObservation?)?
    private var deleteAfterCopies: Set<String>?

    func download(_ selected: [PhotoItem], into folder: URL) {
        for item in selected { enqueue(item, .folder(folder)) { _, _ in } }
    }

    /// A drag into Finder (NSFilePromiseProvider): calls back from the main actor.
    nonisolated func download(id: String, to url: URL, completion: @escaping @Sendable (Error?) -> Void) {
        Task { @MainActor in
            guard let item = self.items.first(where: { $0.id == id }) else { return completion(PhotoError.disconnected) }
            self.enqueue(item, .file(url)) { _, error in completion(error) }
        }
    }

    func copyToClipboard(_ selected: [PhotoItem]) {
        guard !selected.isEmpty else { return }
        let folder = FileBrowserModel.temporaryRoot.appendingPathComponent("Copied").appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            actionError = error.localizedDescription
            return
        }
        notice = String(localized: "Copying \(selected.count) items…")
        let batch = CopyBatch(count: selected.count)
        var urls: [URL] = []
        for item in selected {
            enqueue(item, .folder(folder)) { [weak self] saved, error in
                urls += saved ?? []
                guard batch.finish(failed: error != nil), let self else { return }
                guard !batch.failed else { self.notice = nil; return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects(urls as [NSURL])
                self.notice = String(localized: "Copied. Paste in Finder with ⌘V.")
            }
        }
    }

    private func enqueue(_ item: PhotoItem, _ destination: Destination, completion: @escaping ([URL]?, Error?) -> Void) {
        let transfer = FileTransfer(name: item.name, direction: .download)
        transfer.total = UInt64(max(0, item.size))
        transfers.append(transfer)
        queue.append(Job(item: item, destination: destination, transfer: transfer, completion: completion))
        next()
    }

    private func next() {
        guard current == nil else { return }
        guard !queue.isEmpty else { return runDeferredDelete() }
        let job = queue.removeFirst()
        guard let file = files[job.item.id], let camera, camera.hasOpenSession else {
            return finish(job, nil, PhotoError.disconnected)
        }
        let target: URL = switch job.destination {
        case .folder(let folder): folder
        case .file(let url): url.deletingLastPathComponent()
        }
        let part = target.appendingPathComponent(".ukm-part-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: part, withIntermediateDirectories: true)
        } catch {
            return finish(job, nil, error)
        }
        job.transfer.state = .running
        let options: [ICDownloadOption: Any] = [
            .downloadsDirectoryURL: part,
            .saveAsFilename: job.item.name,
            ICDownloadOption(rawValue: "ICDownloadSidecarFiles"): true,
        ]
        let sendableJob = UncheckedSendable(job)
        let progress = file.requestDownload(options: options) { [weak self] _, error in
            let error = error.map(UncheckedSendable.init)
            Task { @MainActor in self?.downloaded(sendableJob.value, part: part, error: error?.value) }
        }
        let total = job.transfer.total
        let transfer = job.transfer
        let observer = progress?.observe(\.fractionCompleted) { progress, _ in
            let done = UInt64(Double(total) * min(1, max(0, progress.fractionCompleted)))
            Task { @MainActor in transfer.done = max(transfer.done, done) }
        }
        current = (job, progress, observer)
    }

    private func downloaded(_ job: Job, part: URL, error: Error?) {
        guard current?.job.transfer === job.transfer else { return }
        current = nil
        defer { try? FileManager.default.removeItem(at: part); next() }
        if job.transfer.cancellation.isCancelled { return finish(job, nil, PhotoError.cancelled) }
        if let error {
            log.error("photos: download failed: \(error.localizedDescription, privacy: .public)")
            return finish(job, nil, camera == nil ? PhotoError.disconnected : PhotoError.failed(error.localizedDescription))
        }
        let manager = FileManager.default
        do {
            let main: URL, sidecars: [URL]
            switch job.destination {
            case .folder(let folder):
                let names = job.item.freeNames { manager.fileExists(atPath: folder.appendingPathComponent($0).path) }
                main = folder.appendingPathComponent(names.main)
                sidecars = names.sidecars.map(folder.appendingPathComponent)
            case .file(let url):
                main = url
                let folder = url.deletingLastPathComponent()
                let base = FileNames.split(url.lastPathComponent).0
                sidecars = job.item.sidecars.map { name in
                    let ext = FileNames.split(name).1
                    return folder.appendingPathComponent(FileNames.unique(ext.isEmpty ? base : "\(base).\(ext)") {
                        manager.fileExists(atPath: folder.appendingPathComponent($0).path)
                    })
                }
            }
            try manager.moveItem(at: part.appendingPathComponent(job.item.name), to: main)
            var saved = [main]
            for (name, url) in zip(job.item.sidecars, sidecars) {
                let source = part.appendingPathComponent(name)
                // The video of a Live Photo may be missing on the device: the photo alone is still a copy.
                guard manager.fileExists(atPath: source.path) else { continue }
                try manager.moveItem(at: source, to: url)
                saved.append(url)
            }
            finish(job, saved, nil)
        } catch {
            finish(job, nil, error)
        }
    }

    private func finish(_ job: Job, _ saved: [URL]?, _ error: Error?) {
        if let error {
            job.transfer.state = .failed(error.localizedDescription)
        } else {
            job.transfer.done = job.transfer.total
            job.transfer.state = .finished
        }
        job.completion(saved, error)
    }

    func cancel(_ transfer: FileTransfer) {
        transfer.cancellation.cancel()
        if let index = queue.firstIndex(where: { $0.transfer === transfer }) {
            finish(queue.remove(at: index), nil, PhotoError.cancelled)
            if queue.isEmpty, current == nil { runDeferredDelete() }
        } else if current?.job.transfer === transfer {
            current?.progress?.cancel()
            camera?.cancelDownload()
        }
    }

    func clearFinished() {
        transfers.removeAll { !$0.isActive }
    }

    private func failActive(_ error: PhotoError) {
        let jobs = queue + (current.map { [$0.job] } ?? [])
        queue = []
        current = nil
        for job in jobs { finish(job, nil, error) }
        deleteAfterCopies = nil
    }

    // MARK: Deletion (design D6)

    func delete(_ selected: [PhotoItem]) {
        guard !selected.isEmpty, canDelete else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        let device = deviceName ?? "iPhone"
        alert.messageText = selected.count == 1
            ? String(localized: "Delete “\(selected[0].name)” from \(device)?")
            : String(localized: "Delete \(selected.count) photos and videos from \(device)?")
        alert.informativeText = String(localized: "They are deleted from the device’s photo library.")
        alert.addButton(withTitle: String(localized: "Delete"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.buttons[0].hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let ids = Set(selected.map(\.id))
        let copying = (queue.map(\.item.id) + (current.map { [$0.job.item.id] } ?? [])).contains(where: ids.contains)
        if copying {
            // Wait until the copies of these items are done (spec "Скопировать и удалить").
            deleteAfterCopies = (deleteAfterCopies ?? []).union(ids)
            notice = String(localized: "The photos are deleted when their copying is done.")
        } else {
            requestDelete(ids)
        }
    }

    private func runDeferredDelete() {
        guard let ids = deleteAfterCopies else { return }
        deleteAfterCopies = nil
        let failed = transfers.filter { transfer in
            if case .failed = transfer.state { return items.contains { ids.contains($0.id) && $0.name == transfer.name } }
            return false
        }
        if !failed.isEmpty {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = String(localized: "Some photos were not copied. Delete them from the device anyway?")
            alert.addButton(withTitle: String(localized: "Delete"))
            alert.addButton(withTitle: String(localized: "Keep"))
            alert.buttons[0].hasDestructiveAction = true
            guard alert.runModal() == .alertFirstButtonReturn else { notice = nil; return }
        }
        notice = nil
        requestDelete(ids)
    }

    private func requestDelete(_ ids: Set<String>) {
        guard let camera else { return }
        // A Live Photo goes with its video: the photo alone is answered "deleted" but stays on the iPhone
        // (task 1.1).
        let targets: [ICCameraItem] = ids.compactMap { files[$0] }.flatMap { [$0] + ($0.sidecarFiles ?? []) }
        guard !targets.isEmpty else { return }
        _ = camera.requestDeleteFiles(targets, deleteFailed: { failed in
            let names = failed.values.compactMap(\.name)
            Task { @MainActor in log.error("photos: delete failed for \(names.count) items") }
        }, completion: { [weak self] result, error in
            let failedIDs = UncheckedSendable((result[.failed] ?? []).map(Self.id))
            let message = error?.localizedDescription
            Task { @MainActor in
                guard let self else { return }
                if message != nil || !failedIDs.value.isEmpty {
                    self.selection = Set(failedIDs.value).intersection(self.files.keys)
                    self.actionError = String(localized: "Some items were not deleted: \(message ?? "the device refused")")
                }
            }
        })
    }
}

// MARK: ImageCaptureCore delegates

extension PhotoBrowserModel: ICDeviceBrowserDelegate, ICCameraDeviceDelegate {
    nonisolated func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        let device = UncheckedSendable(device)
        Task { @MainActor in self.added(device.value) }
    }

    nonisolated func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        let device = UncheckedSendable(device)
        Task { @MainActor in self.removed(device.value) }
    }

    nonisolated func didRemove(_ device: ICDevice) {
        let device = UncheckedSendable(device)
        Task { @MainActor in self.removed(device.value) }
    }

    nonisolated func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {
        // -9943 "Please unlock" comes first even for an unlocked, trusted iPhone; the access restriction
        // is lifted right after (task 1.1), so only the state of the device counts.
        let camera = UncheckedSendable(device as? ICCameraDevice)
        let message = error?.localizedDescription
        Task { @MainActor in
            guard let camera = camera.value else { return }
            if let message { log.info("photos: open session: \(message, privacy: .public)") }
            self.catalogChanged(camera)
        }
    }

    nonisolated func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {}

    nonisolated func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
        let camera = UncheckedSendable(device)
        Task { @MainActor in self.catalogChanged(camera.value, complete: true) }
    }

    nonisolated func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {
        let camera = UncheckedSendable(camera)
        Task { @MainActor in self.catalogChanged(camera.value) }
    }

    nonisolated func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {
        let camera = UncheckedSendable(camera)
        Task { @MainActor in self.catalogChanged(camera.value) }
    }

    nonisolated func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {
        let camera = UncheckedSendable(camera)
        Task { @MainActor in self.catalogChanged(camera.value) }
    }

    nonisolated func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {
        let camera = UncheckedSendable(device as? ICCameraDevice)
        Task { @MainActor in if let camera = camera.value { self.catalogChanged(camera) } }
    }

    nonisolated func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {
        let camera = UncheckedSendable(device as? ICCameraDevice)
        Task { @MainActor in if let camera = camera.value { self.catalogChanged(camera) } }
    }

    nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem, error: Error?) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?, for item: ICCameraItem, error: Error?) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {}
}
