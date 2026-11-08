import AppKit
import CoreGraphics
import os
import UniversalKMCore

/// Active displays in the system arrangement (design D14): global CG bounds, stable UUIDs, the main
/// display. Refreshes on CGDisplayRegisterReconfigurationCallback.
@MainActor
final class DisplayLayoutProvider {
    private let log = Logger(subsystem: "com.universalkm.UniversalKM", category: "displays")
    private(set) var displays: [DisplayInfo] = []
    var onChange: (([DisplayInfo]) -> Void)?

    init() {
        displays = Self.read()
        let context = Unmanaged.passUnretained(self).toOpaque()
        CGDisplayRegisterReconfigurationCallback({ _, flags, context in
            // Called once before and once after a change; read the result after it.
            guard !flags.contains(.beginConfigurationFlag), let context else { return }
            let provider = Unmanaged<DisplayLayoutProvider>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in provider.refresh() }
        }, context)
    }

    func refresh() {
        let new = Self.read()
        guard new != displays else { return }
        displays = new
        log.info("displays: \(new.map { "\($0.uuid.prefix(8)) \(Int($0.frame.minX)),\(Int($0.frame.minY)) \(Int($0.frame.width))×\(Int($0.frame.height))\($0.isMain ? " main" : "")" }.joined(separator: "; "), privacy: .public)")
        onChange?(new)
    }

    static func read() -> [DisplayInfo] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).compactMap { id in
            guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(),
                  let string = CFUUIDCreateString(nil, uuid) as String?
            else { return nil }
            return DisplayInfo(uuid: string, frame: CGDisplayBounds(id), isMain: CGDisplayIsMain(id) != 0)
        }
    }
}
