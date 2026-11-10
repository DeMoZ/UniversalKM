import Foundation

/// One photo or video of an iPhone as the photo window shows it (add-iphone-photo-browser design D4, D5).
/// Built from an `ICCameraFile` in the app; plain data here so sorting and naming are testable.
public struct PhotoItem: Hashable, Identifiable, Sendable {
    public enum Kind: Sendable { case photo, video }

    /// Stable for the connection: the item's place in the catalog (`ICCameraFile.relatedUUID` or the name).
    public var id: String
    public var name: String
    public var created: Date?
    /// Bytes of the main file, without the Live Photo video.
    public var size: Int64
    /// Seconds; 0 for photos.
    public var duration: Double
    public var kind: Kind
    /// The Live Photo video ("IMG_0001.MOV" next to "IMG_0001.HEIC"), from `sidecarFiles`.
    public var sidecars: [String]

    public init(id: String, name: String, created: Date?, size: Int64, duration: Double, kind: Kind, sidecars: [String] = []) {
        self.id = id
        self.name = name
        self.created = created
        self.size = size
        self.duration = duration
        self.kind = kind
        self.sidecars = sidecars
    }

    public var isLivePhoto: Bool { kind == .photo && !sidecars.isEmpty }

    /// Video file extensions of iPhone media, for the kind when the type is unknown.
    public static let videoExtensions: Set<String> = ["mov", "mp4", "m4v", "avi", "3gp"]

    public static func kind(ofName name: String) -> Kind {
        videoExtensions.contains(FileNames.split(name).1.lowercased()) ? .video : .photo
    }

    /// Newest first; items without a date last; ties by name so the order is stable.
    public static func sorted(_ items: [PhotoItem]) -> [PhotoItem] {
        items.sorted { a, b in
            switch (a.created, b.created) {
            case let (x?, y?) where x != y: return x > y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        }
    }

    /// "1:05", "1:02:03" for a video's length.
    public static func duration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let (h, m, s) = (total / 3600, total / 60 % 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// Free names on the Mac for the item and its Live Photo video, with one base name for all
    /// ("IMG_0001 2.HEIC" and "IMG_0001 2.MOV"), so they stay a pair.
    public func freeNames(isTaken: (String) -> Bool) -> (main: String, sidecars: [String]) {
        let files = [name] + sidecars
        let parts = files.map(FileNames.split)
        let base = parts[0].0
        func names(_ newBase: String) -> [String] {
            parts.map { part in
                // A sidecar with another base (unexpected) keeps its own base, renamed the same way.
                let b = part.0 == base ? newBase : part.0 + String(newBase.dropFirst(base.count))
                return part.1.isEmpty ? b : "\(b).\(part.1)"
            }
        }
        var candidate = names(base)
        var number = 2
        while candidate.contains(where: isTaken) {
            candidate = names("\(base) \(number)")
            number += 1
        }
        return (candidate[0], Array(candidate.dropFirst()))
    }
}
