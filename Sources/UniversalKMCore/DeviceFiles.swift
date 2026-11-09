import Foundation

/// A folder in the device's shared storage (design D3): components below `/sdcard`.
public struct RemotePath: Hashable, Sendable {
    public static let rootPath = "/sdcard"
    public static let root = RemotePath([])

    public private(set) var components: [String]

    public init(_ components: [String]) {
        self.components = components
    }

    public var isRoot: Bool { components.isEmpty }
    public var name: String? { components.last }

    public var parent: RemotePath? {
        isRoot ? nil : RemotePath(Array(components.dropLast()))
    }

    public func appending(_ name: String) -> RemotePath {
        RemotePath(components + [name])
    }

    /// The path on the device. The root ends with "/" so that adb follows the `/sdcard` symlink.
    public var string: String {
        isRoot ? Self.rootPath + "/" : Self.rootPath + "/" + components.joined(separator: "/")
    }

    /// "DCIM › Camera"; the root is `rootName`.
    public func display(rootName: String) -> String {
        ([rootName] + components).joined(separator: " › ")
    }
}

/// One file or folder in a listing.
public struct DeviceFileEntry: Hashable, Sendable, Identifiable {
    public var name: String
    public var isDirectory: Bool
    public var size: UInt64
    public var modified: Date

    public var id: String { name }

    public init(name: String, isDirectory: Bool, size: UInt64, modified: Date) {
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.modified = modified
    }

    /// Temporary files of unfinished transfers (design D5).
    public static func isPartial(_ name: String) -> Bool {
        name.hasPrefix(".") && name.hasSuffix(partialSuffix)
    }

    public static let partialSuffix = ".ukm-part"

    /// ".<name>.ukm-part" next to the real name.
    public static func partialName(for name: String) -> String { "." + name + partialSuffix }

    /// The entries of a LIST reply worth showing: no "." and "..", no hidden files (as Finder),
    /// no partial transfers.
    public static func visible(_ entries: [ADBSync.Entry]) -> [DeviceFileEntry] {
        entries.filter { !$0.name.hasPrefix(".") && !$0.name.isEmpty }
            .map { DeviceFileEntry(name: $0.name, isDirectory: $0.isDirectory, size: $0.isDirectory ? 0 : $0.size, modified: $0.modified) }
    }

    public enum SortKey: String, Sendable {
        case name, size, modified
    }

    /// Folders first, then files, each sorted by `key`; ties and names compare as Finder does
    /// (by name, A to Z, whatever the direction).
    public static func sorted(_ entries: [DeviceFileEntry], by key: SortKey, ascending: Bool) -> [DeviceFileEntry] {
        entries.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            let order: ComparisonResult = switch key {
            case .name: a.name.localizedStandardCompare(b.name)
            case .size: a.size == b.size ? .orderedSame : (a.size < b.size ? .orderedAscending : .orderedDescending)
            case .modified: a.modified == b.modified ? .orderedSame : (a.modified < b.modified ? .orderedAscending : .orderedDescending)
            }
            if order == .orderedSame { return a.name.localizedStandardCompare(b.name) == .orderedAscending }
            return ascending ? order == .orderedAscending : order == .orderedDescending
        }
    }
}

public enum FileNames {
    /// A free name as Finder makes it: "photo.jpg" → "photo 2.jpg", "Docs" → "Docs 2".
    public static func unique(_ name: String, isTaken: (String) -> Bool) -> String {
        guard isTaken(name) else { return name }
        let (base, ext) = split(name)
        var number = 2
        while true {
            let candidate = ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)"
            if !isTaken(candidate) { return candidate }
            number += 1
        }
    }

    /// "photo.jpg" → ("photo", "jpg"); ".nomedia" and "Docs" have no extension.
    static func split(_ name: String) -> (String, String) {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return (name, "") }
        return (String(name[..<dot]), String(name[name.index(after: dot)...]))
    }
}
