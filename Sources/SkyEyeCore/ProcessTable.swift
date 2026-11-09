import Darwin
import Foundation

/// What the kernel says about a process.
///
/// A process chooses its own arguments, so `ps` can be told anything: a listener can call itself
/// `/usr/libexec/something` or mention an app in an argument. These come from the kernel instead, and they are
/// exact where `lsof` escapes a path it prints (a newline, or any name that isn't ASCII).
public enum ProcessTable {
    /// The file the process is running.
    public static func executable(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    /// The process's working directory. Only for processes of the same user.
    public static func workingDirectory(_ pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = string(&info.pvi_cdir.vip_path)
        return path.isEmpty ? nil : path
    }

    /// The process's name: its executable's file name, cut to what the kernel keeps.
    public static func name(_ pid: Int32) -> String? {
        guard var info = info(pid) else { return nil }
        let long = string(&info.pbi_name)
        let short = string(&info.pbi_comm)
        return long.isEmpty ? (short.isEmpty ? nil : short) : long
    }

    static func info(_ pid: Int32) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? info : nil
    }

    /// A fixed-size C character array, read up to its first NUL or its end.
    private static func string<T>(_ field: inout T) -> String {
        withUnsafeBytes(of: &field) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }
}
