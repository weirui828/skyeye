import Darwin
import Foundation

// Darwin spawn flags (spawn.h); defined here so we don't depend on how the macros import.
private let spawnSetSID: Int32 = 0x0400
private let spawnCloexecDefault: Int32 = 0x4000

/// A child process started in its own session, so stopping it also stops
/// everything it spawned (npm → node, etc.).
public final class ManagedProcess: @unchecked Sendable {
    public let pid: pid_t
    private let lock = NSLock()
    private var exited = false
    private var exitSource: DispatchSourceProcess?
    private var logWriterProcess: Process?

    private init(pid: pid_t) { self.pid = pid }

    public var isRunning: Bool { lock.withLock { !exited } }

    /// Spawns `executable` with stdin from /dev/null and stdout+stderr appended to `logFile`.
    /// `onExit` is called on a background thread once the process has exited.
    public static func spawn(
        executable: String, arguments: [String], directory: String?,
        environment: [String: String], logFile: URL, logWriter: URL? = nil,
        onExit: @escaping @Sendable (ExitStatus) -> Void
    ) throws -> ManagedProcess {
        var outputPipe: Pipe?
        var logger: Process?
        if let logWriter {
            let pipe = Pipe()
            _ = fcntl(pipe.fileHandleForReading.fileDescriptor, F_SETFD, FD_CLOEXEC)
            _ = fcntl(pipe.fileHandleForWriting.fileDescriptor, F_SETFD, FD_CLOEXEC)
            let writer = Process()
            writer.executableURL = logWriter
            writer.arguments = [logFile.path]
            writer.standardInput = pipe.fileHandleForReading
            writer.standardOutput = FileHandle.nullDevice
            writer.standardError = FileHandle.standardError
            try writer.run()
            try pipe.fileHandleForReading.close()
            outputPipe = pipe
            logger = writer
        }
        defer { try? outputPipe?.fileHandleForWriting.close() }
        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        posix_spawn_file_actions_addopen(&fileActions, 0, "/dev/null", O_RDONLY, 0)
        if let outputPipe {
            posix_spawn_file_actions_adddup2(&fileActions, outputPipe.fileHandleForWriting.fileDescriptor, 1)
        } else {
            posix_spawn_file_actions_addopen(&fileActions, 1, logFile.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        }
        posix_spawn_file_actions_adddup2(&fileActions, 1, 2)
        if let directory {
            posix_spawn_file_actions_addchdir_np(&fileActions, directory)
        }

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        let flags = spawnSetSID | spawnCloexecDefault | Int32(POSIX_SPAWN_SETSIGDEF) | Int32(POSIX_SPAWN_SETSIGMASK)
        posix_spawnattr_setflags(&attr, Int16(flags))
        var allSignals = ~sigset_t(0)
        posix_spawnattr_setsigdefault(&attr, &allSignals)
        var noSignals = sigset_t(0)
        posix_spawnattr_setsigmask(&attr, &noSignals)

        let argv: [UnsafeMutablePointer<CChar>?] = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, executable, &fileActions, &attr, argv, envp)
        guard rc == 0 else {
            throw SkyEyeError("Could not launch \(executable): \(String(cString: strerror(rc)))")
        }

        let process = ManagedProcess(pid: pid)
        process.logWriterProcess = logger
        Thread.detachNewThread {
            var status: Int32 = 0
            while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
            // Clean up anything the command left behind in its process group.
            kill(-pid, SIGTERM)
            process.lock.withLock { process.exited = true }
            onExit(ExitStatus(rawWaitStatus: status))
        }
        return process
    }

    /// Re-attaches to a process group leader a previous SkyEye started and left running. It isn't our child, so
    /// `onExit` gets `.unknown`. Returns nil if the process is already gone.
    public static func adopt(pid: pid_t, onExit: @escaping @Sendable (ExitStatus) -> Void) -> ManagedProcess? {
        let process = ManagedProcess(pid: pid)
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global())
        source.setEventHandler { [weak source] in
            source?.cancel()
            kill(-pid, SIGTERM)
            process.lock.withLock { process.exited = true }
            onExit(.unknown)
        }
        process.exitSource = source
        source.resume()
        // If it exited before the source was registered, the source never fires.
        guard kill(pid, 0) == 0 else {
            source.cancel()
            return nil
        }
        return process
    }

    /// When the kernel started `pid` (microseconds since 1970), or nil if there's no such process.
    public static func startTime(of pid: pid_t) -> UInt64? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec
    }

    /// Sends `signal` to the whole process group.
    public func signal(_ signal: Int32) {
        guard isRunning else { return }
        kill(-pid, signal)
    }

    /// SIGTERM, then SIGKILL if it's still around after `grace` seconds.
    public func terminate(grace: TimeInterval = 5) {
        signal(SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + grace) { [self] in
            signal(SIGKILL)
        }
    }
}
