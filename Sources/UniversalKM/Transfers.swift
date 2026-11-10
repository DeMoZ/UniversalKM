import AppKit
import Carbon
import SwiftUI

// Shared by the Android file window and the iPhone photo window (add-iphone-photo-browser design D7).

/// One download or upload in the file window (add-android-file-browser design D5).
@MainActor
final class FileTransfer: ObservableObject, Identifiable {
    enum Direction { case download, upload }
    enum State: Equatable {
        case queued, running, finished
        case failed(String)
    }

    let id = UUID()
    let name: String
    let direction: Direction
    @Published var done: UInt64 = 0
    @Published var total: UInt64 = 0
    @Published var state = State.queued
    nonisolated let cancellation = ADBCancellation()

    init(name: String, direction: Direction) {
        self.name = name
        self.direction = direction
    }

    var isActive: Bool { state == .queued || state == .running }
}

/// Counts the downloads of one ⌘C.
@MainActor
final class CopyBatch {
    private var remaining: Int
    private(set) var failed = false

    init(count: Int) { remaining = count }

    /// True when this was the last one.
    func finish(failed: Bool) -> Bool {
        remaining -= 1
        if failed { self.failed = true }
        return remaining == 0
    }
}

/// NSFilePromiseProvider calls it on its own queue. `write` downloads the file the provider's
/// `userInfo` describes to the URL and calls back from any thread once the file has its real name
/// (add-android-file-browser design D5, add-iphone-photo-browser design D5).
final class PromiseDelegate: NSObject, NSFilePromiseProviderDelegate, @unchecked Sendable {
    typealias Write = @Sendable (Any?, URL, @escaping @Sendable (Error?) -> Void) -> Void
    private let name: @Sendable (Any?) -> String
    private let write: Write
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        return queue
    }()

    init(name: @escaping @Sendable (Any?) -> String, write: @escaping Write) {
        self.name = name
        self.write = write
    }

    func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        name(provider.userInfo)
    }

    func filePromiseProvider(_ provider: NSFilePromiseProvider, writePromiseTo url: URL,
                             completionHandler: @escaping (Error?) -> Void) {
        let done = UncheckedSendable(completionHandler)
        write(UncheckedSendable(provider.userInfo).value, url) { error in done.value(error) }
    }

    func operationQueue(for provider: NSFilePromiseProvider) -> OperationQueue { queue }
}

/// A completion handler AppKit gives without Sendable; it may be called from any thread.
struct UncheckedSendable<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

/// One transfer: name, progress, Cancel.
struct TransferRow: View {
    @ObservedObject var transfer: FileTransfer
    let cancel: (FileTransfer) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: transfer.direction == .download ? "arrow.down" : "arrow.up").foregroundStyle(.secondary)
            Text(transfer.name).lineLimit(1).truncationMode(.middle).frame(maxWidth: 200, alignment: .leading)
            switch transfer.state {
            case .queued:
                Text("Waiting…").foregroundStyle(.secondary)
                Spacer()
            case .running:
                if transfer.total > 0 {
                    ProgressView(value: Double(min(transfer.done, transfer.total)), total: Double(transfer.total)).controlSize(.small)
                } else {
                    ProgressView().controlSize(.small)
                    Spacer()
                }
                Text(progressText).foregroundStyle(.secondary).monospacedDigit()
            case .finished:
                Text("Done").foregroundStyle(.secondary)
                Spacer()
            case .failed(let message):
                Text(message).foregroundStyle(.red).lineLimit(1)
                Spacer()
            }
            if transfer.isActive {
                Button { cancel(transfer) } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .help("Cancel")
            }
        }
        .font(.caption)
    }

    private var progressText: String {
        let done = ByteCountFormatter.string(fromByteCount: Int64(clamping: transfer.done), countStyle: .file)
        guard transfer.total > 0 else { return done }
        return "\(done) / \(ByteCountFormatter.string(fromByteCount: Int64(clamping: transfer.total), countStyle: .file))"
    }
}

/// The letter of a key as on the Latin layout, so ⌘C, ⌘V and the others work while a Russian or
/// another non-Latin layout is on, the way menu shortcuts do in macOS.
enum LatinKey {
    static func of(_ event: NSEvent) -> String? {
        if let typed = event.charactersIgnoringModifiers?.lowercased(), typed.unicodeScalars.allSatisfy(\.isASCII), !typed.isEmpty {
            return typed
        }
        return translate(event.keyCode)
    }

    private static func translate(_ keyCode: UInt16) -> String? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue() as Data
        var deadKeys: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        let status = data.withUnsafeBytes { bytes -> OSStatus in
            guard let layout = bytes.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return -1 }
            return UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: length).lowercased()
    }
}
