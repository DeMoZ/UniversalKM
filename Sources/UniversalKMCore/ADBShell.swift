import Foundation

/// Shell commands on the device through `shell:` (design D1). The old `shell:` service has no exit
/// code, so each command ends with a marker line that carries it.
public enum ADBShell {
    static let marker = "UKM_RC="

    /// One argument for the device's sh: in single quotes, a quote inside as '\''.
    public static func quote(_ argument: String) -> String {
        "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// `shell:` service text: the quoted words, then a new line and the exit code. `printf` gets `$?`
    /// before it runs, and its leading new line ends output that had none.
    public static func service(_ words: [String]) -> String {
        "shell:" + words.map(quote).joined(separator: " ") + "; printf '\\n\(marker)%d\\n' $?"
    }

    public static func makeDirectory(_ path: String) -> String { service(["mkdir", "-p", path]) }
    public static func move(_ from: String, _ to: String) -> String { service(["mv", "-f", from, to]) }
    public static func remove(_ path: String) -> String { service(["rm", "-rf", path]) }

    /// Removes leftovers of unfinished uploads in `folder` (add-android-file-browser design D5):
    /// the folder quoted, the `*` outside the quotes so the shell expands it.
    public static func removePartials(in folder: String) -> String {
        "shell:rm -rf " + quote(folder) + "/.*" + quote(DeviceFileEntry.partialSuffix) + "; printf '\\n\(marker)%d\\n' $?"
    }

    /// Exit code and output (without the marker) of a command from `service`; nil when the marker is missing.
    public static func result(_ output: String) -> (code: Int, output: String)? {
        var lines = output.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        while let last = lines.last, last.isEmpty { lines.removeLast() }
        guard let last = lines.last, last.hasPrefix(marker), let code = Int(last.dropFirst(marker.count)) else { return nil }
        lines.removeLast()
        // The new line `printf` adds before the marker.
        if lines.last?.isEmpty == true { lines.removeLast() }
        return (code, lines.joined(separator: "\n"))
    }
}
