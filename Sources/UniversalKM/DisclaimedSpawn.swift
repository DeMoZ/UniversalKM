import Darwin
import Foundation

/// Runs a program as a process responsible for itself (fix-adb-server-local-network design D1), through
/// `responsibility_spawnattrs_setdisclaim`, the call terminals use so that macOS asks about the program's
/// own privacy permissions instead of the app's. Looked up at run time: without it, a normal spawn.
enum DisclaimedSpawn {
    private typealias SetDisclaim = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32
    private static let setDisclaim: SetDisclaim? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_spawnattrs_setdisclaim")
        .map { unsafeBitCast($0, to: SetDisclaim.self) }

    /// Exit status, or -1 if the program could not start or ran past `timeout` (then it is killed).
    static func run(_ path: String, _ arguments: [String], timeout: TimeInterval) -> Int32 {
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        _ = setDisclaim?(&attributes, 1)
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        for fd in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] {
            posix_spawn_file_actions_addopen(&actions, fd, "/dev/null", fd == STDIN_FILENO ? O_RDONLY : O_WRONLY, 0)
        }
        let argv = ([path] + arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        guard posix_spawn(&pid, path, &actions, &attributes, argv, environ) == 0 else { return -1 }
        let deadline = Date().addingTimeInterval(timeout)
        var status: Int32 = 0
        while waitpid(pid, &status, WNOHANG) == 0 {
            if Date() > deadline {
                kill(pid, SIGKILL)
                waitpid(pid, &status, 0)
                return -1
            }
            usleep(50_000)
        }
        return (status & 0x7f) == 0 ? (status >> 8) & 0xff : -1
    }
}
